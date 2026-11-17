# dcd

**display configuration daemon** for Wayland compositors with wlr-output-management
(built and tested on Hyprland).

dcd switches between two modes:

- **laptop**: the built-in panel on, the external monitor off
- **external**: the external monitor on, the built-in panel off

It remembers which mode you last used with each monitor and applies it whenever that
monitor appears, at boot or on plug-in. If a switch doesn't take effect, it falls back
to the laptop panel and tells you. There's nothing to configure.

## Status

Switching, the daemon and the per-monitor memory work. A toggle command for a keybind is next.

| | |
|---|---|
| `dcd watch`: live view of screens and changes | done |
| `dcd laptop` / `dcd external`: switch, verify, fall back | done |
| daemon: automatic mode on plug-in and unplug, notifications | done |
| remembered mode per monitor set | done |
| `dcd status`, `dcd reload` | done |
| toggle command for a keybind | planned |

## Requirements

- Linux
- Zig 0.17
- A compositor that supports `zwlr_output_manager_v1`: Hyprland, sway, river and others

## Build

```console
$ make prod     # optimized build, installed to ~/bin/dcd
$ make test
$ make watch    # zig build run -- watch
```

Plain `zig build` works too; the binary lands in `zig-out/bin/dcd`.

## Usage

### Start the daemon

Start it with your compositor. In Hyprland's Lua config:

```lua
hl.on("hyprland.start", function ()
    hl.exec_cmd("/home/you/bin/dcd daemon")
end)
```

From then on, plugging in or unplugging a monitor applies the mode you last chose for
that set of monitors. A set you've never chosen for gets `external` if an external
monitor is connected, otherwise `laptop`. Successful switches are silent; fallbacks and
failures send a desktop notification (`notify-send`).

Only one daemon runs at a time. Stopping it leaves the screens as they are.

### `dcd status`

```console
$ dcd status
mode:     external (saved)
screens:  eDP-1 off, HDMI-A-1 on 1920x1080@179.99
match:    yes
daemon:   running (pid 17882)
```

Read-only. Exit code 0 when the screens match the wanted mode, 1 when they don't.

### `dcd reload`

Asks the running daemon to check the screens now: for when you think it missed a
change. It also re-enables switching if the daemon paused itself after the screens
kept changing back (3 switches in 30 s for the same monitors).

### `dcd laptop` / `dcd external`

Switches to one screen and turns the other off, and remembers the choice for the
monitors connected right now; the daemon keeps to it from then on. Each screen gets its largest resolution
at the highest refresh rate it supports, at scale 1.

```console
$ dcd external
external: applying HDMI-A-1 on 1920x1080@179.99 scale 1.00, eDP-1 off
external: done
```

Every switch is checked by reading the screens back. If the compositor rejects the
switch, or the screens don't end up as requested, dcd retries once, then falls back to
the laptop panel. If even that fails, it turns every screen on. It never leaves you
with no lit screen and no message.

| Exit code | Meaning |
|---|---|
| 0 | done: the screens are as requested |
| 1 | fell back: the switch didn't stick; the laptop panel (or every screen) is on |
| 2 | refused: not possible, e.g. `external` with no external monitor; nothing changed |
| 3 | nothing could be applied |

### `dcd watch`

Prints every screen the compositor reports, then one line for each change, with the
time since start. Nothing is changed. Ctrl+C to quit.

```console
$ dcd watch
[       1ms] serial 95147
  HDMI-A-1   external enabled  1920x1080@179.99 scale 1.00  preferred 1920x1080@179.99  "Samsung Electric Company LS24DG30X H8CY500487"
  eDP-1      builtin  disabled -  preferred 1920x1080@60.00  "China Star Optoelectronics Technology Co., Ltd 0x150F 0x00005600"
[    8412ms] serial 95148  - HDMI-A-1 removed
[   11030ms] serial 95149  + HDMI-A-1 connected (disabled)
[   11031ms] serial 95150  ~ HDMI-A-1 disabled → enabled
```

Each line shows:

- the connector name;
- whether it's the built-in panel (`eDP-*`, `LVDS-*`, `DSI-*`) or an external monitor;
- whether it's enabled, with its current mode and scale;
- the monitor's preferred mode;
- its identity (make, model, serial). The identity follows the physical monitor
  whichever port it's plugged into.

## Files

| Path | What |
|---|---|
| `$XDG_STATE_HOME/dcd/modes` (`~/.local/state/dcd/modes`) | the chosen mode per monitor set, one line each |
| `$XDG_STATE_HOME/dcd/daemon.log` | every daemon decision, timestamped in UTC |
| `$XDG_RUNTIME_DIR/dcd.pid` | the daemon's pid and single-instance lock |

A monitor set is identified by each monitor's make, model and serial, so it doesn't
matter which port a monitor is plugged into.

## Using dcd with your compositor

dcd should be the only program that configures your monitors. Don't run it alongside
kanshi or another output manager, and let your compositor's own config turn every
screen on; dcd decides which ones go off.

## How it works

dcd is a Wayland client. It speaks `wlr-output-management-unstable-v1`, the protocol
compositors use to describe their outputs and accept new configurations:

1. The compositor sends one *head* per connected monitor (name, make, model, serial,
   modes, enabled state), then `done` with a serial number. It repeats this whenever
   anything changes, including plug and unplug.
2. To change outputs, dcd creates a configuration for that serial, marks each head
   enabled or disabled, and applies it.
3. The compositor answers `succeeded`, `failed`, or `cancelled` (the outputs changed
   in the meantime, so dcd looks again and retries).

The Wayland client is [zig-wayland-native](https://tangled.org/jcollie.dev/zig-wayland-native),
which has no libwayland dependency. The protocol XML lives in `protocol/`, copied from
[wlr-protocols](https://gitlab.freedesktop.org/wlroots/wlr-protocols).

## Layout

```
protocol/       wlr-output-management protocol definition
src/
  main.zig      commands and `watch`
  outputs.zig   Wayland connection, snapshots, applying a configuration
  switching.zig one switch: plan, apply, verify, retry, fall back
  daemon.zig    the daemon, reload, loop guard, log
  store.zig     the per-monitor-set mode file
  state.zig     snapshots, change detection, planning (pure)
  sys.zig       Linux syscalls for files, locks and processes
specs/      development specs, one per sprint
```
