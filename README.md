# OmaSpaces

![OmaSpaces panel — At Work and At Home spaces](preview.png)

Workspace profiles for the Omarchy bar. One click on the grid icon, pick
**At Work**, and Chrome opens on workspace 1, X on 2, WhatsApp on 3 — every
time, in the same places.

## Install

Omarchy 4.x (Quattro). From a terminal:

```bash
omarchy plugin add https://github.com/L0nE-F0x/omarchy-omaspaces.git --enable
omarchy bar put lonefox.omaspaces --section left
```

OmaSpaces does not rewrite your Hyprland or shell config for you. Spaces are
stored in `~/.config/omarchy/omaspaces.json`, created the first time you save
or capture one.

### Optional: apply a space at login

If a space has **Apply this space at login** turned on, install the bundled
post-boot hook yourself (one-time):

```bash
mkdir -p ~/.config/omarchy/hooks/post-boot.d
cp ~/.config/omarchy/plugins/lonefox.omaspaces/hooks/omaspaces-login.hook \
  ~/.config/omarchy/hooks/post-boot.d/
chmod +x ~/.config/omarchy/hooks/post-boot.d/omaspaces-login.hook
```

Without that copy, the login flag in the panel is ignored. The hook only runs
the engine's `login` command; it does not write other config.

## Remove

```bash
omarchy plugin remove lonefox.omaspaces --yes
```

Then, if you installed the login hook:

```bash
rm -f ~/.config/omarchy/hooks/post-boot.d/omaspaces-login.hook
```

Your saved spaces in `~/.config/omarchy/omaspaces.json` are left alone so you
can keep them if you reinstall.

## Dependencies

All local. OmaSpaces does not phone home.

| Need | Used for |
|---|---|
| `/usr/bin/python3` | `omaspaces` engine |
| `hyprctl` | list clients, move windows, dispatch launches |
| Hyprland event socket | *Close workspace gaps* only: noticing a window close |
| Omarchy shell / Quickshell | bar widget and panel UI |

No network, no downloads, no sudo. The engine talks only to the local
Hyprland sockets: `hyprctl` for commands, and the event socket while
*Close workspace gaps* is on.

## Using it

- **Left click** the bar icon for the list of spaces. Click one to apply it.
- **Right click** the bar icon to re-apply the last space without opening
  the panel.
- **Capture the current layout** turns whatever is on screen right now into a
  new space, apps and workspace numbers already filled in.
- The **gear** on a row opens its editor: rename it, add or drop apps, change
  which workspace each one lands on.
- **Close workspace gaps** at the bottom of the list is an on/off switch; see
  below.
- Keyboard, with the panel open: `1`–`9` apply that space, `↑`/`↓` and `Enter`
  do the same, `e` edits the highlighted space, `n` makes a new one, `c`
  captures the current layout, `g` flips *Close workspace gaps*, `Esc` closes.

Applying a space never closes anything by default. An app that is already
running is moved to its workspace rather than started a second time.

## Per-space options

| Option | What it does |
|---|---|
| Finish on workspace | Where you end up once everything is open. |
| Follow along while it opens | Focus each target workspace as its app starts. Leave it on — it is what makes browser windows land right the first time. |
| Close everything else first | Closes every window that is not part of the space before opening it. Off by default. |
| Apply this space at login | Runs this space once per boot, via the optional `post-boot.d` hook above. Only one space can hold it. |

## Close workspace gaps

Off by default. When it is on and a workspace in the middle empties — you
close its last window, or move it away — every occupied workspace to its right
shifts one to the left, so 1, 2, 4, 5 becomes 1, 2, 3, 4. If the workspace you
are looking at moves, the view goes with it.

- Only numbered workspaces are touched. Special (scratchpad) and named
  workspaces stay where they are.
- It reacts to a window closing or moving, never to a workspace switch, so
  turning it on does not reshuffle anything until the next close.
- It pauses while a space is being applied. A space that leaves a gap on
  purpose (apps on 1, 2 and 5) keeps it until the next time a window closes.
- Workspaces are renumbered as one sequence, whichever monitor they are on.

The switch is stored as `compactWorkspaces` in `omaspaces.json`. While it is on,
the panel keeps one `omaspaces watch` process running; turning it off, or
removing the plugin, stops it. Nothing is added to your autostart.

## CLI

The engine runs without the panel:

```bash
~/.config/omarchy/plugins/lonefox.omaspaces/omaspaces list
~/.config/omarchy/plugins/lonefox.omaspaces/omaspaces apply at-work
~/.config/omarchy/plugins/lonefox.omaspaces/omaspaces capture "Recording Content"
~/.config/omarchy/plugins/lonefox.omaspaces/omaspaces compact           # close gaps once, now
~/.config/omarchy/plugins/lonefox.omaspaces/omaspaces compact toggle    # or on / off / status
```

`compact toggle` is handy on a keybinding; the panel's switch follows it. For
example, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + G", "Toggle workspace gap closing",
  hl.dsp.exec_cmd(os.getenv("HOME") .. "/.config/omarchy/plugins/lonefox.omaspaces/omaspaces compact toggle"))
```

## How placement works

Hyprland can pin a launched window to a workspace with a process token, and
for a normal app that is enough. It is not enough for a Chrome web app:
`chrome --app=URL` hands the request to the browser that is already running,
and *that* process opens the window with no token.

So every launch is verified rather than trusted. The engine focuses the
target workspace, launches, waits for the new window to map, and — if it
still landed somewhere else — moves it. It also records the window class the
app turned out to have, which is how the next apply knows the app is already
open.

## Files

```
manifest.json              plugin metadata and bar-widget settings schema
BarWidget.qml              the bar icon
Panel.qml                  list of spaces and the per-space editor
omaspaces                  engine: apply, capture, login, compact, watch (Python 3)
hooks/omaspaces-login.hook optional post-boot hook (copy into place yourself)
preview.png                marketplace card image
```

Config: `~/.config/omarchy/omaspaces.json`

After changing the QML, rescan or restart the shell:

```bash
omarchy-shell shell rescanPlugins
```

## License

MIT. See `LICENSE`.
