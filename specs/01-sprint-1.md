# Sprint 1 — read-only watcher

Status: **done**

## Goal

Run `dcd watch` and see exactly what Hyprland reports about the screens, live, as you
plug and unplug. Nothing gets changed. This settles the facts before dcd touches
anything: what each monitor is called, its identity, its modes, and how quickly a
plug-in shows up.

## Checkpoint (checked in the running app)

1. Boot with HDMI plugged in, run `dcd watch`: both screens print.
2. Boot without HDMI, run `dcd watch`, then plug in HDMI: a `connected` line appears
   with a timestamp.
3. Unplug: a `removed` line appears. Replug: `connected` again.
4. Toggle the panel, never the only lit screen: `hyprctl keyword monitor eDP-1,1920x1080@144,auto,1.25`
   then `hyprctl keyword monitor eDP-1,disable`. dcd prints `disabled → enabled`, then
   `enabled → disabled`.
5. Ctrl+C: dcd exits cleanly, and the screens are unchanged.

## Tasks

### T1 — Project skeleton

- `build.zig` + `build.zig.zon` for Zig 0.17, with `zig-wayland-native` as a dependency
  (see open question Q1).
- Vendor `protocol/wlr-output-management-unstable-v1.xml` from wlr-protocols, with the
  source commit noted in a comment. Generate bindings with `addProtocols(.extra = ...)`.
- Only the `client` module and the generated bindings. No `present` module.
- `zig build run -- watch` runs it.

### T2 — Connect and bind

- Connect to the compositor, get the registry, and bind `zwlr_output_manager_v1` at
  `min(advertised, 4)`.
- If the global is missing, exit with: `compositor does not support
  wlr-output-management`.

### T3 — Head model

For each head, keep:
- name (e.g. `HDMI-A-1`), make, model, serial;
- enabled, current mode, position, scale;
- its list of modes (width × height @ refresh, and which one is preferred).

Also:
- On a head's `finished` event, remove it.
- On a mode's `finished` event, remove that mode.
- Build an identity string `make model serial`. Sprint 4 uses it as the memory key, so
  print it now.
- Mark the built-in panel: a name starting with `eDP-`, `LVDS-` or `DSI-`.

### T4 — Snapshots and diffs

On every `done(serial)`, compare against the previous snapshot and print only the
changes, each with milliseconds since start. The first `done` prints the full table.

```
[    12ms] serial 1
  eDP-1     builtin  enabled   1920x1080@144.00 scale 1.25  "BOE 0x0BC9 Unknown"
  HDMI-A-1  external enabled   1920x1080@180.00 scale 1.00  "Dell Inc. G2724D ABC123"
[  8412ms] serial 2  - HDMI-A-1 removed
[ 11030ms] serial 3  + HDMI-A-1 connected (disabled)
[ 11031ms] serial 4  ~ HDMI-A-1 disabled → enabled
```

Keep the diff a pure function, `diff(old, new) → []Change`, so it can be tested without
a compositor.

### T5 — Event loop and exit

- A hand-written `poll` loop on the Wayland fd: when it's readable, call
  `Connection.read`, then `dispatchPending`, and flush before polling again.
- A `signalfd` for SIGINT and SIGTERM in the same poll set, for a clean exit.
- No timers or sockets yet.

### T6 — Tests (after the checkpoint passes)

- `diff` tests: connect, remove, enable/disable change, mode change, nothing changed.
- Identity and built-in panel detection, including unknown make, model or serial.
- No compositor needed. Fake head snapshots only.

## Not in this sprint

Applying configurations, daemon mode, saved state, notifications, IPC, a toggle
command, and removing kanshi.

## Done when

All 5 checkpoint steps pass on your machine and the T6 tests pass with `zig build test`.

## Decisions

- **Q1. Dependency:** local path `../zig-work/others/zig-wayland-native` (commit `3348c3a`).
- **Q2. Directory:** stays `~/Work/screen`.
- **Q3. kanshi:** not running.
- **Protocol XML:** copied from the `wlr-protocols` package (r112.a741f0a) into `protocol/`.

## Checkpoint results (2026-11-17, Hyprland 0.57.2)

| Step | Result |
|---|---|
| 1. Both screens print | pass |
| 2/3. Unplug and replug HDMI | pass: `removed` and `connected` arrive immediately, each followed by `done` |
| 4. Toggle the panel via Hyprland config | **Hyprland bug**, see below |
| 5. Ctrl+C exits cleanly | pass |

**Finding:** when a monitor is changed through Hyprland's own config (`hyprctl eval
hl.monitor`, or a config reload), clients that are already connected get head events
with the state from *before* the change (`enabled=1` after disabling, `enabled=0` after
enabling), and no `done`. A fresh connection sees the correct state. That stale state
then shows up at the next real `done`: after a config reload, the HDMI unplug printed
`eDP-1 enabled → disabled`, while the panel was actually on.

Hotplug itself is reported correctly and immediately.

**Consequence for sprint 2:** dcd must not trust a long-lived connection's state after
changes it didn't make. Before deciding or verifying, take a fresh snapshot.
