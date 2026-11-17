# dcd — display configuration daemon

Status: **sprints 1–3 done; sprint 4 (toggle) deferred**

## Problem

kanshi always opened on the laptop screen, so every time the external was plugged in,
the mode had to be switched by hand. Switching was unreliable: the external sometimes
wouldn't come up until kanshi was killed. Windows doesn't work like that. It remembers
the mode you last used with a monitor and applies it on its own.

## What dcd does

- **Two modes only:** `laptop` (built-in panel on, external off) and `external`
  (external on, panel off).
- **Remembers:** the last mode is saved per set of connected monitors and applied
  automatically on boot and on plug-in. A monitor seen for the first time gets
  `external`.
- **A switch either works or tells you:** after Hyprland reports `succeeded`, dcd reads
  the screens back and checks the result is really in place. If it isn't, dcd retries
  once, then falls back to `laptop` and sends a notification.
- **Never leaves you with zero screens:** if the external is unplugged while in
  `external` mode, the panel is turned back on immediately.
- **Never needs killing:** if dcd exits or crashes, the screens stay as they are.
  Restarting it is always safe.
- **The only thing that configures monitors:** kanshi is removed, and Hyprland's own
  config keeps just the catch-all monitor rule.

## Not in scope

- Extend and mirror modes.
- Profiles or a config file.
- Tracking windows across monitors (parked idea; it only matters with extend).

## How it works

dcd is a Wayland client that uses `zwlr_output_manager_v1` (wlr-output-management)
through `zig-wayland-native`:

1. Hyprland sends one **head** per monitor (name, make, model, serial, modes, enabled),
   then **done(serial)**. It sends this again on every plug or unplug.
2. dcd builds a configuration for that serial, sets each head enabled or disabled, and
   applies it.
3. Hyprland replies **succeeded**, **failed**, or **cancelled** (the screens changed in
   the meantime: look again and retry).

## Sprints

| # | Builds | Checkpoint |
|---|---|---|
| 1 | Read-only watcher: print every head and every hotplug change, live | Boot, then plug in HDMI: dcd prints it |
| 2 | One-shot `dcd laptop` / `dcd external` with apply, read-back check and fallback | Both switches work both ways, every time |
| 3 | Daemon: automatic rules on plug-in, unplug and failure, plus notifications. kanshi removed | Boot, then plug in: the external comes up without a command |
| 4 | Remember the mode per monitor set, plus a toggle command for a keybind | The mode survives replugs and reboots, and Win+P-style toggling works |

Each sprint gets its tests once it works, before the next one starts.
