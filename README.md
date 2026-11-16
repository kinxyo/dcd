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

Early. Only `dcd watch` exists so far; switching and the daemon are next.

| | |
|---|---|
| `dcd watch`: live view of screens and changes | done |
| `dcd laptop` / `dcd external`: switch, verify, fall back | planned |
| daemon: automatic mode on plug-in and unplug, notifications | planned |
| remembered mode per monitor, toggle command for a keybind | planned |

## Requirements

- Linux
- Zig 0.17
- A compositor that supports `zwlr_output_manager_v1`: Hyprland, sway, river and others

## Build

```console
$ zig build                 # binary at zig-out/bin/dcd
$ zig build run -- watch
$ zig build test
```

## Usage

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

## Using dcd with your compositor

dcd should be the only program that configures your monitors. Don't run it alongside
kanshi or another output manager. In Hyprland, keep only a catch-all monitor rule, for
example:

```
monitor = , preferred, auto, auto
```

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
protocol/   wlr-output-management protocol definition
src/
  main.zig  commands, Wayland connection, event loop
  state.zig screen snapshots and change detection (pure, unit-tested)
specs/      development specs, one per sprint
```
