# Sprint 3 — daemon and memory

Status: **done**

## Goal

Plug in the external and it comes up in the right mode. No command typed. The mode is
remembered for each set of connected monitors, like Windows: choose `laptop` once, and
that monitor set comes back as `laptop` after every replug and reboot.

## The model

There is one piece of state: **the desired mode for each set of connected monitors**,
kept in a state file. Everything else reads or writes that state.

- `dcd laptop` / `dcd external` **write** the choice for the current monitor set, then
  apply it (as in sprint 2).
- `dcd daemon` **reads** the choice whenever something might have changed, and applies
  it if the screens don't already match.
- No choice saved yet → the default: `external` if an external is connected, else
  `laptop`.

Since both sides follow the same state, the daemon never undoes a command.

## Checkpoint (checked in the running app)

1. No state file, HDMI plugged in, start `dcd daemon`: external-only is applied.
2. Unplug HDMI: laptop-only. Replug: external-only within ~2 s. No command typed.
3. With the daemon running, `dcd laptop`: it stays laptop-only for a minute (not
   reverted). Unplug and replug: it comes back as laptop-only.
4. `dcd external`: external-only. Unplug and replug: external-only.
5. Log out and back in (or reboot) with HDMI plugged in: the last mode comes up on its
   own.
6. `dcd reload`: the daemon logs a check. With no daemon running: `dcd reload` prints
   `dcd daemon is not running`.
7. A second `dcd daemon`: prints `already running` and exits.
8. `dcd daemon --force-fail`, then replug: a desktop notification says the switch
   failed and the laptop panel is on.
9. Stop the daemon (SIGTERM): the screens are unchanged.

## Behaviour

### Monitor set and state file

- **Key:** the identities (`make model serial`) of every connected head, sorted and
  joined with `|`. The key follows the physical monitors, not the ports they're in.
- **File:** `$XDG_STATE_HOME/dcd/modes`, defaulting to `~/.local/state/dcd/modes`. One
  line per monitor set, human-readable:
  ```
  laptop	China Star Optoelectronics Technology Co., Ltd 0x150F 0x00005600|Samsung Electric Company LS24DG30X H8CY500487
  ```
- Written atomically (temp file + rename), so a crash never leaves it half-written.
- A command writes the choice **before** switching. When the daemon reacts to the
  switch's own events, it already sees the new choice.
- A refused command (e.g. `external` with nothing plugged in) writes nothing.

### Daemon loop

- One long-lived connection, used **only as a trigger**. Any `done` means "go look",
  never "this is the state" (sprints 1 and 2 showed its contents can be stale).
- **Debounce:** Hyprland sends bursts during one switch (a `FALLBACK` head appears, and
  the HDMI head is removed and re-added). Wait until 500 ms pass with no new `done`,
  then check once.
- **Check:** read the screens on a fresh connection, compute the key, look up the
  desired mode, and plan it.
  - Already in place: do nothing (the usual case after the daemon's own switch).
  - Otherwise: run the sprint 2 switch (verify, retry, fallback).
- **Loop guard:** if 3 checks in 30 s each had to switch the same monitor set, stop
  switching that set, log it, and send a notification. A compositor that keeps undoing
  dcd must not make the screens flicker forever.
- **Startup:** do a check immediately (boot, or a restart of the daemon).
- **Signals:** SIGUSR1 → check now. SIGINT/SIGTERM → exit without touching the screens.

### `dcd reload`

Reads the daemon's pid from `$XDG_RUNTIME_DIR/dcd.pid` and sends SIGUSR1. Prints
`dcd daemon is not running` if there's no live daemon.

### `dcd status`

Read-only. Prints the wanted mode for the connected monitors (`saved` or `default`),
the screens as they are, whether they match, and whether the daemon runs:

```
mode:     external (saved)
screens:  HDMI-A-1 on 1920x1080@179.99, eDP-1 off
match:    yes
daemon:   running (pid 17882)
```

Exit code 0 when the screens match, 1 when they don't.

### Single instance

The daemon takes an exclusive `flock` on `$XDG_RUNTIME_DIR/dcd.pid` and writes its pid
there. If the lock is held: print `already running` and exit 1. The lock goes away with
the process, even after a crash, so a stale pid file never blocks a restart.

### Notifications

`notify-send -a dcd`, run in the background. If `notify-send` is missing, dcd only
logs. dcd notifies on:
- a fallback (to laptop, or to every screen on);
- a total failure (nothing could be applied);
- the loop guard tripping.

A successful switch is silent, like Windows.

### Hyprland's `FALLBACK` head

Hyprland briefly creates a virtual head named `FALLBACK` while no real screen is on.
dcd leaves it out of snapshots entirely: it isn't a monitor, mustn't be picked as
"external", and mustn't be part of a monitor set key.

### Logging

The daemon logs one line per decision, with a timestamp: trigger, key, desired mode,
and the outcome. It appends to `$XDG_STATE_HOME/dcd/daemon.log` (a process started by
Hyprland has nowhere useful to print), and also prints to stdout when that is a
terminal.

## Tasks

- **T1 — State file:** parse, serialize, look up, set; key from a snapshot. Pure
  functions, plus an atomic write.
- **T2 — Commands write the choice:** `dcd laptop` / `dcd external` save the choice
  for the current monitor set before switching.
- **T3 — Daemon loop:** long-lived connection as trigger; `signalfd` for INT, TERM and
  USR1; `timerfd` for the debounce; check on startup.
- **T4 — Single instance and reload:** `flock` on the pid file; `dcd reload` sends
  SIGUSR1.
- **T5 — Notifications.**
- **T5b — `dcd status`** (added during the sprint).
- **T6 — Loop guard.**
- **T7 — Drop `FALLBACK`** from snapshots.
- **T8 — README:** the daemon, autostart in Hyprland, the state file, `dcd reload`.
- **T9 — Tests (after the checkpoint passes):** state file round-trip, key ordering and
  identity, default mode with and without a saved choice, loop guard counting,
  `FALLBACK` filtering.

## Not in this sprint

The toggle command for a keybind (sprint 4), and several external monitors at once.

## Decisions

- **Autostart:** inside your existing `hl.on("hyprland.start", ...)` block:
  `hl.exec_cmd("/home/userx/bin/dcd daemon")`. It uses an absolute path, since
  Hyprland's PATH may not include `~/bin`.
- **Boot flash:** both screens are lit for ~1–2 s at login. Accepted.
- **Debounce:** 500 ms. Accepted.
- **Unknown identities:** ignored for now.
- **Log file:** `$XDG_STATE_HOME/dcd/daemon.log`, appended.

## Checkpoint results (2026-11-17, Hyprland 0.57.2)

All 9 steps pass on the real machine: default mode at startup, replug in both modes with
no command typed, `dcd laptop` not reverted by the daemon and remembered across replugs,
the last mode at login via autostart, `dcd reload` with and without a daemon, the
single-instance refusal, the fallback notification (`--force-fail`), and stopping
without touching the screens. `dcd status` was added during the sprint.

**Fix during the sprint:** an unexpected error inside a check is now logged and the
daemon carries on, instead of exiting.

**Known limits for daily use:** the daemon only reacts to changes Hyprland reports.
Plug and unplug events were reliable in every test, but a Hyprland config reload turns
both screens on without a proper report. `dcd status` shows the mismatch and
`dcd reload` fixes it.

**Next (sprint 4, deferred):** a `dcd toggle` command for a keybind.
