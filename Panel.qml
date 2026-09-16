import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// apex-forge-keep: OmaSpaces panel.
//
// Two views in one popup: a list of spaces you can click to apply, and an
// editor for the space you clicked the pencil on. Everything the panel knows
// lives in ~/.config/omarchy/omaspaces.json, which the engine (./omaspaces)
// also reads and writes -- so the file, not this QML, is the source of truth
// and a space applied from a keybinding stays in step with the one applied
// from here.
//
// The panel never launches an app itself. It shells out to ./omaspaces, which
// reports progress as JSON lines; that keeps the slow part (waiting for a cold
// Chrome to map a window) out of the shell process.
Panel {
  id: root
  moduleName: "lonefox.omaspaces"
  ipcTarget: "lonefox.omaspaces"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string enginePath: String(Qt.resolvedUrl("omaspaces")).replace(/^file:\/\//, "")
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config"))
    + "/omarchy/omaspaces.json"

  // apex-forge-keep: Omarchy 4.0.3 replaced the real shell object with a
  // capability-scoped facade, and it grants appLibrary only to plugins whose
  // manifest declares the "menu" kind. OmaSpaces is a bar-widget, so
  // bar.shell.appLibrary arrives null and every icon, plus the whole app
  // picker, goes blank. localAppLibrary below stands in with the same surface
  // (sortedEntries/entryName/entrySubtext/iconSource/refreshIcons), and the
  // binding drops it the moment the host grant comes back.
  readonly property var hostAppLibrary: bar && bar.shell ? bar.shell.appLibrary : null
  readonly property var appLibrary: root.hostAppLibrary ? root.hostAppLibrary : localAppLibrary
  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property int maxWorkspace: Math.min(30, Math.max(1, parseInt(setting("maxWorkspace", 10), 10) || 10))
  readonly property bool autoClose: setting("autoClose", true) !== false

  // --- config --------------------------------------------------------------
  // `cfg` is replaced wholesale on every change: QML does not see mutations
  // inside a var, so every edit goes through mutate().
  property var cfg: ({ version: 1, profiles: [] })
  readonly property var profiles: cfg && Array.isArray(cfg.profiles) ? cfg.profiles : []
  property string lastFileJson: ""

  // --- view ----------------------------------------------------------------
  // Named `view`, never `state`: `state` is an Item builtin and assignments to
  // a shadowing property silently do nothing.
  property string view: "list"          // "list" | "edit"
  property string editId: ""
  property int cursor: 0

  // --- run state -----------------------------------------------------------
  property string busyId: ""
  property string statusText: ""
  property string lastApplied: ""
  property bool lastFailed: false

  readonly property color fg: bar ? bar.foreground : Color.popups.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color quiet: Qt.rgba(fg.r, fg.g, fg.b, 0.35)
  readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.14)
  readonly property color softFill: Qt.rgba(fg.r, fg.g, fg.b, 0.07)

  readonly property var editing: profileById(editId)

  function profileById(id) {
    for (var i = 0; i < profiles.length; i++)
      if (String(profiles[i].id) === String(id)) return profiles[i]
    return null
  }

  // A profile handed to a Repeater comes back as a QVariantMap, and its nested
  // app list no longer answers to Array.isArray. Copy it into a real array (in
  // workspace order, which is how a space reads) before touching it.
  function appsOf(profile) {
    var apps = (profile && profile.apps) ? profile.apps : []
    var out = []
    for (var i = 0; i < apps.length; i++) out.push(apps[i])
    out.sort(function(a, b) { return (a.workspace || 0) - (b.workspace || 0) })
    return out
  }

  function profileIndex(id) {
    for (var i = 0; i < profiles.length; i++)
      if (String(profiles[i].id) === String(id)) return i
    return -1
  }

  // --- lifecycle -----------------------------------------------------------

  function open() {
    root.view = "list"
    root.cursor = 0
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.controller.show()
  }

  function openFromHotkey() { root.open() }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // --- editing -------------------------------------------------------------

  function clone(value) {
    return JSON.parse(JSON.stringify(value))
  }

  function mutate(fn) {
    var next = clone(root.cfg)
    if (!Array.isArray(next.profiles)) next.profiles = []
    fn(next)
    root.cfg = next
    root.persist()
  }

  function mutateProfile(id, fn) {
    root.mutate(function(next) {
      for (var i = 0; i < next.profiles.length; i++) {
        if (String(next.profiles[i].id) === String(id)) { fn(next.profiles[i]); return }
      }
    })
  }

  function slugify(name) {
    var slug = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    return slug.length > 0 ? slug : "space"
  }

  function uniqueId(base) {
    var taken = {}
    for (var i = 0; i < profiles.length; i++) taken[String(profiles[i].id)] = true
    if (!taken[base]) return base
    var n = 2
    while (taken[base + "-" + n]) n++
    return base + "-" + n
  }

  function addProfile() {
    var id = uniqueId(slugify("space"))
    root.mutate(function(next) {
      next.profiles.push({
        id: id,
        name: "New Space",
        apps: [],
        focusWorkspace: 1,
        closeOthers: false,
        applyOnLogin: false,
        walkWorkspaces: true
      })
    })
    root.editId = id
    root.view = "edit"
  }

  function deleteProfile(id) {
    root.mutate(function(next) {
      next.profiles = next.profiles.filter(function(p) { return String(p.id) !== String(id) })
    })
    root.view = "list"
    root.editId = ""
  }

  function renameProfile(id, name) {
    root.mutateProfile(id, function(p) { p.name = String(name) })
  }

  // sortedEntries() hands back scoring wrappers -- { entry, score, key, name }
  // -- not the desktop entries themselves, so every row has to be unwrapped
  // before its id or icon can be read.
  function entryById(id) {
    if (!root.appLibrary) return null
    var want = String(id || "").toLowerCase().replace(/\.desktop$/, "")
    var rows = root.appLibrary.sortedEntries("")
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      var eid = String((entry && entry.id) || "").toLowerCase().replace(/\.desktop$/, "")
      if (eid === want) return entry
    }
    return null
  }

  // The dropdown lists every launcher entry the app library shows, so a space
  // can hold anything Super+Space can start.
  function appOptions() {
    if (!root.appLibrary) return []
    var rows = root.appLibrary.sortedEntries("")
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      var id = String((entry && entry.id) || "").replace(/\.desktop$/, "")
      // An entry with no id would take the dropdown's empty value and show its
      // own name where the "Add an app…" prompt belongs.
      if (id === "") continue
      out.push({
        value: id,
        label: root.appLibrary.entryName(entry),
        description: root.appLibrary.entrySubtext(entry)
      })
    }
    return out
  }

  // A new app goes on the workspace after the last one, so filling a space in
  // order needs no fiddling with numbers.
  function nextWorkspaceFor(profile) {
    var highest = 0
    var apps = profile && Array.isArray(profile.apps) ? profile.apps : []
    for (var i = 0; i < apps.length; i++)
      highest = Math.max(highest, parseInt(apps[i].workspace, 10) || 0)
    return Math.min(root.maxWorkspace, Math.max(1, highest + 1))
  }

  function addApp(desktopId) {
    var entry = entryById(desktopId)
    if (!entry) return
    var profile = root.editing
    var workspace = nextWorkspaceFor(profile)
    root.mutateProfile(root.editId, function(p) {
      if (!Array.isArray(p.apps)) p.apps = []
      p.apps.push({
        desktopId: String(entry.id || "").replace(/\.desktop$/, ""),
        label: root.appLibrary ? root.appLibrary.entryName(entry) : String(entry.id),
        icon: String(entry.icon || ""),
        workspace: workspace,
        matchClass: "",
        matchTitle: ""
      })
    })
  }

  function removeApp(index) {
    root.mutateProfile(root.editId, function(p) {
      if (Array.isArray(p.apps)) p.apps.splice(index, 1)
    })
  }

  function setAppWorkspace(index, workspace) {
    root.mutateProfile(root.editId, function(p) {
      if (Array.isArray(p.apps) && p.apps[index])
        p.apps[index].workspace = Math.min(root.maxWorkspace, Math.max(1, workspace))
    })
  }

  function setFlag(id, key, value) {
    root.mutateProfile(id, function(p) { p[key] = value })
  }

  // --- running the engine --------------------------------------------------

  function applyProfile(id) {
    if (root.busyId !== "" || root.enginePath === "") return
    var profile = profileById(id)
    if (!profile) return
    // An empty space has nothing to open; send the user to its editor instead
    // of flashing a "0 apps" result at them.
    if (!Array.isArray(profile.apps) || profile.apps.length === 0) {
      root.editId = id
      root.view = "edit"
      return
    }
    root.busyId = id
    root.lastFailed = false
    root.statusText = "Opening " + profile.name + "…"
    applyProc.command = [root.enginePath, "apply", id]
    applyProc.running = true
  }

  function reapplyLast() {
    if (root.lastApplied === "") return
    for (var i = 0; i < profiles.length; i++) {
      if (String(profiles[i].name) === root.lastApplied) {
        root.applyProfile(String(profiles[i].id))
        return
      }
    }
  }

  function captureLayout() {
    if (root.busyId !== "" || root.enginePath === "") return
    root.busyId = "__capture"
    root.statusText = "Reading the desktop…"
    captureProc.command = [root.enginePath, "capture", "Captured Space"]
    captureProc.running = true
  }

  function describe(event) {
    var label = String(event.label || "")
    var ws = event.workspace
    switch (String(event.action)) {
      case "opening": return "Opening " + label + " → " + ws
      case "opened":  return label + " on " + ws
      case "moved":   return "Moved " + label + " → " + ws
      case "kept":    return label + " already on " + ws
      case "timeout": return label + " did not open"
      case "failed":  return label + ": " + String(event.reason || "cannot launch")
      default:        return label
    }
  }

  function handleProgress(line) {
    var event
    try { event = JSON.parse(String(line)) } catch (e) { return }

    if (event.event === "app") {
      root.statusText = root.describe(event) + "  (" + event.index + "/" + event.total + ")"
      if (event.action === "timeout" || event.action === "failed") root.lastFailed = true
    } else if (event.event === "done") {
      root.lastApplied = String(event.profile || "")
      var bits = []
      if (event.launched) bits.push(event.launched + " opened")
      if (event.moved) bits.push(event.moved + " moved")
      if (event.kept) bits.push(event.kept + " already there")
      if (event.failed) bits.push(event.failed + " failed")
      root.statusText = root.lastApplied + " ready" + (bits.length ? " · " + bits.join(", ") : "")
      if (event.failed) root.lastFailed = true
    } else if (event.event === "captured") {
      root.editId = String(event.id || "")
      root.view = "edit"
      root.statusText = "Captured " + event.apps + " apps"
    } else if (event.event === "error") {
      root.lastFailed = true
      root.statusText = String(event.message || "failed")
    }
  }

  // SearchableDropdown sizes its search field as
  // `popupRowHeight + control-padding-x - 2 * md`, which at the stock tokens
  // leaves 26px for a TextField whose natural height is 32 -- the field then
  // centres its text in too little room and clips the tops off ascenders, so
  // "chrome" reads as "cnrome". popupRowHeight is the only lever the component
  // exposes, so measure what the field actually needs and raise it to match.
  FontMetrics {
    id: pickerMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  readonly property int pickerRowHeight: {
    var border = Math.max(Style.normalBorderWidth, Style.focusBorderWidth, Style.hoverBorderWidth)
    var field = Math.ceil(pickerMetrics.height) + 2 * Style.spacing.inputPaddingY + 2 * border
    return Math.max(Style.spacing.popupRowHeight,
                    field + 2 * Style.spacing.md - Style.spacing.controlPaddingX)
  }

  Process {
    id: applyProc
    stdout: SplitParser { onRead: function(line) { root.handleProgress(line) } }
    onRunningChanged: {
      if (running) return
      root.busyId = ""
      // The engine writes learned window classes back into the config; reload
      // so the panel does not overwrite them with its stale copy.
      configFile.reload()
      if (root.autoClose && !root.lastFailed && root.view === "list") closeTimer.restart()
    }
  }

  Process {
    id: captureProc
    stdout: SplitParser { onRead: function(line) { root.handleProgress(line) } }
    onRunningChanged: {
      if (running) return
      root.busyId = ""
      configFile.reload()
    }
  }

  Timer {
    id: closeTimer
    interval: 900
    repeat: false
    onTriggered: if (root.opened && root.busyId === "") root.close()
  }

  // --- persistence ---------------------------------------------------------

  function persist() {
    var payload = JSON.stringify(root.cfg, null, 2)
    root.lastFileJson = payload
    configFile.setText(payload + "\n")
  }

  function normalize(raw) {
    var cfg = (raw && typeof raw === "object") ? raw : {}
    if (!Array.isArray(cfg.profiles)) cfg.profiles = []
    for (var i = 0; i < cfg.profiles.length; i++) {
      var p = cfg.profiles[i]
      p.id = String(p.id || root.slugify(p.name || "space"))
      p.name = String(p.name || "Space")
      if (!Array.isArray(p.apps)) p.apps = []
      for (var j = 0; j < p.apps.length; j++) {
        var a = p.apps[j]
        a.workspace = Math.min(30, Math.max(1, parseInt(a.workspace, 10) || 1))
        a.label = String(a.label || a.desktopId || "app")
      }
    }
    cfg.version = 1
    return cfg
  }

  Process {
    id: ensureDir
    running: true
    command: ["mkdir", "-p", root.configPath.replace(/\/[^\/]*$/, "")]
    onRunningChanged: if (!running) configFile.reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var raw = String(text() || "").trim()
        if (raw === root.lastFileJson) return
        root.lastFileJson = raw
        root.cfg = root.normalize(JSON.parse(raw))
      } catch (e) {
        // Keep whatever is on screen; a half-written file fixes itself on the
        // next change event.
      }
    }
    onLoadFailed: {
      // No config yet: the first capture or "New space" writes one.
      root.cfg = { version: 1, profiles: [] }
    }
  }

  // apex-forge-keep: stand-in for the host application engine, used whenever
  // shell.appLibrary is null (see hostAppLibrary above). It mirrors only the
  // surface this panel consumes, so no call site has to know which engine it
  // is talking to.
  QtObject {
    id: localAppLibrary

    // Hidden-entry filters, kept in step with the launcher so the app picker
    // offers exactly what Super+Space would.
    property var configuredHiddenIds: ({})
    property var desktopHiddenIds: ({})

    // Maps an icon name to a file on disk ("omarchy-discord" -> ".../apps/
    // omarchy-discord.png"). The stored icons are bare names, and an
    // unconstrained themed lookup can resolve a short one such as "x" to an
    // action icon from the current theme, so the app/device index wins first.
    property var iconIndex: ({})
    property var pendingIconIndex: ({})

    function normalizeId(id) {
      var value = String(id || "").trim()
      if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
      return value
    }

    function idSetFrom(rawText) {
      var next = ({})
      var lines = String(rawText || "").split(/\n/)
      for (var i = 0; i < lines.length; i++) {
        var id = localAppLibrary.normalizeId(lines[i])
        if (id.length > 0) next[id] = true
      }
      return next
    }

    function isHidden(entry) {
      var id = String((entry && entry.id) || "")
      return localAppLibrary.configuredHiddenIds[id] === true
        || localAppLibrary.desktopHiddenIds[id] === true
    }

    function entryName(entry) {
      return String((entry && entry.name) || (entry && entry.id) || "")
    }

    function entrySubtext(entry) {
      return String((entry && entry.genericName) || (entry && entry.comment) || "")
    }

    // The panel only ever passes the empty query -- entryById() scans the rows
    // itself and the picker filters its own popup -- but the substring pass
    // keeps a non-empty query sane.
    function sortedEntries(query) {
      var q = String(query || "").trim().toLowerCase()
      var values = DesktopEntries.applications.values || []
      var rows = []
      for (var i = 0; i < values.length; i++) {
        var entry = values[i]
        if (!entry || entry.noDisplay) continue
        if (localAppLibrary.isHidden(entry)) continue
        var name = localAppLibrary.entryName(entry)
        if (!name) continue
        if (q.length > 0 && name.toLowerCase().indexOf(q) < 0) continue
        rows.push({ entry: entry, key: name.toLowerCase(), name: name, score: 0 })
      }
      rows.sort(function(a, b) { return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0) })
      return rows
    }

    function iconSource(icon) {
      var value = String(icon || "")
      if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
      if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
      if (value.charAt(0) === "/") return Util.fileUrl(value)
      var found = localAppLibrary.iconIndex[value]
      if (found) return Util.fileUrl(found)
      var themed = Quickshell.iconPath(value, true)
      if (themed.length > 0) return themed
      return Quickshell.iconPath("application-x-executable", true)
    }

    // Qt's icon cache never rescans, so a package installed after the shell
    // started is invisible to the themed lookup until the index picks it up.
    function refreshIcons() {
      if (!localIconIndexScan.running) localIconIndexScan.running = true
    }

    function indexIconLine(path) {
      var value = String(path || "").trim()
      if (value.length === 0) return
      var slash = value.lastIndexOf("/")
      var file = slash >= 0 ? value.slice(slash + 1) : value
      var dot = file.lastIndexOf(".")
      var name = dot > 0 ? file.slice(0, dot) : file
      if (name.length > 0 && localAppLibrary.pendingIconIndex[name] === undefined)
        localAppLibrary.pendingIconIndex[name] = value
    }

    // Same sweep the host engine runs: app and device icons across the XDG
    // icon dirs plus /usr/share/pixmaps, SVG before PNG so the first hit per
    // name is the scalable one.
    function iconIndexScanCommand() {
      return [
        'dirs="$HOME/.icons $HOME/.local/share/icons";',
        'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
        'for ext in svg png; do',
        '  for base in $dirs; do',
        '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
        '  done;',
        '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
        'done'
      ].join(' ')
    }
  }

  Process {
    id: localIconIndexScan
    command: ["bash", "-c", localAppLibrary.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { localAppLibrary.indexIconLine(line) } }
    onStarted: localAppLibrary.pendingIconIndex = ({})
    // Swapping the property, rather than mutating it, re-evaluates every
    // iconSource() binding, so a newly found icon appears without rebuilding
    // the row.
    onExited: localAppLibrary.iconIndex = localAppLibrary.pendingIconIndex
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: localAppLibrary.configuredHiddenIds = localAppLibrary.idSetFrom(text())
    onFileChanged: localAppLibrary.configuredHiddenIds = localAppLibrary.idSetFrom(text())
    onLoadFailed: localAppLibrary.configuredHiddenIds = ({})
  }

  QtObject {
    id: localHiddenScanOutput
    property string text: ""
  }

  // Non-login shell, matching the host engine: a login shell sources the
  // profile, and mise touching ~/.local/share would retrigger the scan.
  Process {
    id: localHiddenScan
    command: ["bash", "-c",
      Util.shellQuote(root.omarchyPath + "/shell/services/hidden-entries.sh") + " "
        + Util.shellQuote([Quickshell.env("XDG_CURRENT_DESKTOP"),
                           Quickshell.env("XDG_SESSION_DESKTOP"),
                           Quickshell.env("DESKTOP_SESSION")]
                          .filter(function(v) { return String(v || "").length > 0 }).join(":"))]
    stdout: SplitParser { onRead: function(line) { localHiddenScanOutput.text += line + "\n" } }
    onStarted: localHiddenScanOutput.text = ""
    onExited: localAppLibrary.desktopHiddenIds = localAppLibrary.idSetFrom(localHiddenScanOutput.text)
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      if (root.hostAppLibrary) return
      localHiddenScan.running = true
      localAppLibrary.refreshIcons()
    }
  }

  Component.onCompleted: if (!root.hostAppLibrary) {
    localHiddenScan.running = true
    localAppLibrary.refreshIcons()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function apply(id: string): void { root.applyProfile(id) }
    function edit(id: string): void {
      root.editId = id
      root.view = "edit"
      root.controller.show()
    }
    function capture(): void { root.captureLayout() }
  }

  // --- view ----------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(root.view === "edit" ? editBody.implicitHeight
                                                                 : listBody.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // PanelKeyCatcher takes keys before its children, so anything that owns
      // the keyboard has to say so: the name field while it has focus, and the
      // app picker while its search popup is open.
      blocked: nameField.activeFocus || appPicker.popupOpen
      onCloseRequested: {
        if (root.view === "edit") { root.view = "list" } else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.view !== "list" || root.profiles.length === 0) return
        root.cursor = Math.max(0, Math.min(root.profiles.length - 1, root.cursor + dy))
      }
      onActivateRequested: {
        if (root.view !== "list") return
        var p = root.profiles[root.cursor]
        if (p) root.applyProfile(String(p.id))
      }
      onTextKey: function(text) {
        if (root.view !== "list") return
        if (text === "c") { root.captureLayout(); return }
        if (text === "n") { root.addProfile(); return }
        if (text === "e") {
          var sel = root.profiles[root.cursor]
          if (sel) { root.editId = String(sel.id); root.view = "edit" }
          return
        }
        var n = parseInt(text, 10)
        if (!isNaN(n) && n >= 1 && n <= root.profiles.length)
          root.applyProfile(String(root.profiles[n - 1].id))
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: root.view === "edit" ? editBody.implicitHeight : listBody.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // ---- list -----------------------------------------------------------
        Column {
          id: listBody
          visible: root.view === "list"
          width: flick.width
          spacing: Style.space(2)

          Item {
            width: parent.width
            implicitHeight: header.implicitHeight

            Row {
              id: header
              width: parent.width
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: root.dim
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "OmaSpaces"
                color: root.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              tooltipText: "New space  (n)"
              foreground: root.dim
              hoverColor: root.fg
              onClicked: root.addProfile()
            }
          }

          Item { width: 1; implicitHeight: Style.space(6) }

          Text {
            visible: root.profiles.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No spaces yet.\n\nArrange your windows the way you like them, then capture the layout below — that becomes a space you can bring back with one click."
            color: root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            lineHeight: 1.3
          }

          Repeater {
            model: root.profiles

            Rectangle {
              id: profileRow
              required property var modelData
              required property int index

              readonly property bool busy: root.busyId === String(modelData.id)
              readonly property bool selected: root.cursor === index && root.profiles.length > 0
              readonly property int appCount: root.appsOf(modelData).length

              width: listBody.width
              implicitHeight: rowContent.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: rowHover.containsMouse || selected ? root.softFill : "transparent"

              MouseArea {
                id: rowHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.cursor = profileRow.index
                onClicked: root.applyProfile(String(profileRow.modelData.id))
              }

              Column {
                id: rowContent
                anchors.left: parent.left
                anchors.right: editButton.left
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Row {
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(profileRow.index + 1)
                    color: root.quiet
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(profileRow.modelData.name)
                    color: root.fg
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: profileRow.modelData.applyOnLogin === true
                    text: ""
                    color: root.quiet
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                // The icon strip is the fastest read of what a space holds:
                // the apps, in workspace order.
                Row {
                  spacing: Style.space(4)
                  visible: profileRow.appCount > 0 && !profileRow.busy

                  Repeater {
                    model: root.appsOf(profileRow.modelData).slice(0, 8)

                    Item {
                      required property var modelData
                      width: Style.space(18)
                      height: Style.space(18)

                      Image {
                        anchors.fill: parent
                        source: root.appLibrary ? root.appLibrary.iconSource(modelData.icon) : ""
                        sourceSize.width: width * 2
                        sourceSize.height: height * 2
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                      }

                      // Which workspace this app lands on, as a badge on the
                      // icon: the whole space reads in one glance without a
                      // second row of text under it.
                      Rectangle {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: -Style.space(2)
                        anchors.bottomMargin: -Style.space(1)
                        width: Math.max(badgeText.implicitWidth + Style.space(3), Style.space(10))
                        height: Style.space(10)
                        radius: height / 2
                        color: bar ? bar.background : Color.popups.background
                        border.width: 1
                        border.color: root.hairline

                        Text {
                          id: badgeText
                          anchors.centerIn: parent
                          text: String(modelData.workspace)
                          color: root.dim
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Math.max(7, Style.font.caption - 2)
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: profileRow.appCount === 0 && !profileRow.busy
                  text: "Empty — open the editor to fill it"
                  color: root.quiet
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: profileRow.busy
                  width: rowContent.width
                  elide: Text.ElideRight
                  text: root.statusText
                  color: root.dim
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              PanelActionButton {
                id: editButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                iconText: ""
                tooltipText: "Edit this space"
                foreground: root.quiet
                hoverColor: root.fg
                onClicked: {
                  root.editId = String(profileRow.modelData.id)
                  root.view = "edit"
                }
              }
            }
          }

          Item { width: 1; implicitHeight: Style.space(6) }

          PanelSeparator { width: parent.width; foreground: root.fg }

          Item { width: 1; implicitHeight: Style.space(6) }

          Button {
            width: parent.width
            leftAlign: true
            bordered: false
            text: root.busyId === "__capture" ? "Reading the desktop…" : "Capture the current layout"
            iconText: ""
            foreground: root.fg
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.caption
            enabled: root.busyId === ""
            onClicked: root.captureLayout()
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.statusText !== "" && root.busyId === ""
            text: root.statusText
            color: root.lastFailed ? (bar ? bar.urgent : Color.urgent) : root.quiet
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---- editor ---------------------------------------------------------
        Column {
          id: editBody
          visible: root.view === "edit"
          width: flick.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: Math.max(backButton.height, nameField.implicitHeight)

            PanelActionButton {
              id: backButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              tooltipText: "Back to the list"
              foreground: root.dim
              hoverColor: root.fg
              onClicked: root.view = "list"
            }

            TextField {
              id: nameField
              anchors.left: backButton.right
              anchors.leftMargin: Style.space(6)
              anchors.right: deleteButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: root.editing ? String(root.editing.name) : ""
              placeholderText: "Name this space"
              foreground: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              onTextChanged: {
                if (root.editing && text !== String(root.editing.name))
                  root.renameProfile(root.editId, text)
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            PanelActionButton {
              id: deleteButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              tooltipText: "Delete this space"
              foreground: root.quiet
              hoverColor: bar ? bar.urgent : Color.urgent
              onClicked: root.deleteProfile(root.editId)
            }
          }

          PanelSectionHeader { width: parent.width; text: "Apps"; foreground: root.dim }

          Repeater {
            model: root.editing && Array.isArray(root.editing.apps) ? root.editing.apps : []

            Item {
              id: appRow
              required property var modelData
              required property int index

              width: editBody.width
              implicitHeight: Math.max(Style.space(24), wsField.implicitHeight)

              Image {
                id: appIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                height: Style.space(18)
                source: root.appLibrary ? root.appLibrary.iconSource(appRow.modelData.icon) : ""
                sourceSize.width: width * 2
                sourceSize.height: height * 2
                fillMode: Image.PreserveAspectFit
                smooth: true
              }

              Text {
                anchors.left: appIcon.right
                anchors.leftMargin: Style.space(8)
                anchors.right: wsField.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: String(appRow.modelData.label)
                color: root.fg
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }

              NumberField {
                id: wsField
                anchors.right: dropButton.left
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                label: ""
                from: 1
                to: root.maxWorkspace
                value: parseInt(appRow.modelData.workspace, 10) || 1
                fieldWidth: Style.space(74)
                foreground: root.fg
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                onModified: function(value) { root.setAppWorkspace(appRow.index, value) }
              }

              PanelActionButton {
                id: dropButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: ""
                tooltipText: "Remove from this space"
                foreground: root.quiet
                hoverColor: bar ? bar.urgent : Color.urgent
                onClicked: root.removeApp(appRow.index)
              }
            }
          }

          SearchableDropdown {
            id: appPicker
            width: parent.width
            showLabel: false
            triggerLabel: "Add an app…"
            placeholderText: "Search apps"
            popupRowHeight: root.pickerRowHeight
            options: root.appOptions()
            value: ""
            foreground: root.fg
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(value) {
              if (value === "") return
              root.addApp(value)
              appPicker.value = ""
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          PanelSectionHeader { width: parent.width; text: "When this space is applied"; foreground: root.dim }

          Item {
            width: parent.width
            implicitHeight: endField.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Finish on workspace"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            NumberField {
              id: endField
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              label: ""
              from: 1
              to: root.maxWorkspace
              value: root.editing ? (parseInt(root.editing.focusWorkspace, 10) || 1) : 1
              fieldWidth: Style.space(74)
              foreground: root.fg
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onModified: function(value) { root.setFlag(root.editId, "focusWorkspace", value) }
            }
          }

          Item {
            width: parent.width
            implicitHeight: walkToggle.height

            Text {
              anchors.left: parent.left
              anchors.right: walkToggle.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.WordWrap
              text: "Follow along while it opens"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            ToggleSwitch {
              id: walkToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.editing ? root.editing.walkWorkspaces !== false : true
              foreground: root.fg
              onToggled: root.setFlag(root.editId, "walkWorkspaces", !checked)
            }
          }

          Item {
            width: parent.width
            implicitHeight: closeToggle.height

            Text {
              anchors.left: parent.left
              anchors.right: closeToggle.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.WordWrap
              text: "Close everything else first"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            ToggleSwitch {
              id: closeToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.editing ? root.editing.closeOthers === true : false
              foreground: root.fg
              onToggled: root.setFlag(root.editId, "closeOthers", !checked)
            }
          }

          Item {
            width: parent.width
            implicitHeight: loginToggle.height

            Text {
              anchors.left: parent.left
              anchors.right: loginToggle.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.WordWrap
              text: "Apply this space at login"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            ToggleSwitch {
              id: loginToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.editing ? root.editing.applyOnLogin === true : false
              foreground: root.fg
              onToggled: {
                var turningOn = !checked
                // Only one space can own the login, so switching it on takes
                // the flag off whichever space had it.
                root.mutate(function(next) {
                  for (var i = 0; i < next.profiles.length; i++) {
                    var p = next.profiles[i]
                    p.applyOnLogin = turningOn && String(p.id) === String(root.editId)
                  }
                })
              }
            }
          }

          Item { width: 1; implicitHeight: Style.space(4) }

          Button {
            width: parent.width
            leftAlign: true
            text: "Apply now"
            iconText: ""
            foreground: root.fg
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.caption
            enabled: root.busyId === ""
            onClicked: {
              root.view = "list"
              root.applyProfile(root.editId)
            }
          }
        }
      }
    }
  }
}
