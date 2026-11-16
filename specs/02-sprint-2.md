# Sprint 2 — switch, verify, fall back

Status: **done**

## Goal

`dcd laptop` and `dcd external` switch screens on command, and every switch is checked.
The command ends in one of three states, and always says which:

- **done**: the requested screen is on and the other is off, confirmed by reading the
  screens back;
- **fell back**: the switch didn't stick, so dcd put the laptop panel back on;
- **refused**: the switch wasn't possible (e.g. `external` with nothing plugged in), and
  nothing was changed.

It never ends with no lit screen and no message.

## Checkpoint (checked in the running app)

1. `dcd external`: panel off, HDMI on. It prints `external: done`.
2. `dcd laptop`: HDMI off, panel on. It prints `laptop: done`.
3. Alternate the two 10 times in a row: every switch prints `done`.
4. Unplug HDMI, run `dcd external`: it prints `refused: no external monitor connected`,
   and the screens are unchanged.
5. Run `dcd watch` in a second terminal during steps 1–3: Hyprland reports
   dcd's changes to the long-running client correctly, with a `done` and the right
   state. This answers the sprint 1 question about changes made through the protocol.
6. The panel comes back at 1920x1080@144 and the external at 1920x1080@179.99, both scale 1.

## Behaviour

### The switch

1. Connect fresh and wait for the first `done`. That snapshot is the truth; sprint 1
   showed a long-lived connection can be stale.
2. Plan the switch from the snapshot (a pure function, see T2):
   - `external` needs an external head; `laptop` needs the built-in head. Otherwise:
     **refused**.
   - Never plan a configuration with zero enabled heads.
   - If the screens already match the mode, there's nothing to do: **done**.
3. Create a configuration with the snapshot's serial. The protocol requires every head
   to be listed, so: `enable_head` the target, with mode, position 0,0 and scale; and
   `disable_head` every other head.
4. `apply`, then handle the reply:
   - `succeeded`: go to verify.
   - `cancelled`: the screens changed meanwhile (e.g. a hotplug). Take a new snapshot
     and re-plan, at most 3 times. Then fall back.
   - `failed`: fall back.
5. **Verify:** open a new connection, take a snapshot, and check the target is enabled
   in the planned mode and every other head is disabled. The protocol itself says a
   successful apply doesn't guarantee the result matches, and sprint 1 showed stale
   reads on an old connection.
   - Pass: **done**.
   - Fail: retry the whole switch once, then fall back.

### Fallback

Apply `laptop`. If that fails or doesn't verify too, enable **every** head. Any lit
screen is better than none. Print what happened at each step.

### Choosing the mode for a head that's being turned on

- Always the largest resolution, at the highest refresh rate available at that
  resolution: 1920x1080@144 for the panel (not its "preferred" 60 Hz), 1920x1080@179.99
  for the Samsung.
- Scale 1, position 0,0.

## Tasks

### T1 — Snapshot as a reusable step

Factor sprint 1's code into `snapshot(conn) → Snapshot`: connect, bind, wait for the
first `done`, return heads + serial + the live head objects (needed for
`enable_head` / `disable_head`). `watch` keeps working on top of it.

### T2 — Planner (pure)

`plan(heads, mode) → Plan | Refusal`. A `Plan` lists the head to enable (with mode,
position and scale) and the heads to disable. Also `pickMode(head) → Mode`, and
`verify(heads, plan) → bool`.

### T3 — Apply

Build the `zwlr_output_configuration_v1` from a plan, apply it, and wait for
`succeeded` / `failed` / `cancelled`. Destroy the configuration afterwards.

### T4 — Commands

`dcd laptop` and `dcd external`: snapshot, plan, apply, verify, retry, fall back, exactly
as described above. Exit codes: 0 done, 1 fell back, 2 refused.

### T5 — Tests (after the checkpoint passes)

- `plan`: each mode with both heads, with the panel only, with the external only; the
  already-in-mode case; never zero enabled heads.
- `pickMode`: largest resolution, then highest refresh.
- `verify`: a match, a wrong head enabled, the right head at the wrong mode.

## Not in this sprint

Daemon mode, reacting to hotplug, notifications, remembering the mode, the toggle
keybind, and multiple external monitors (dcd picks the first external; see Q3).

## Decisions

- **Mode:** largest resolution at the highest refresh. Panel 1080p@144, external
  1080p@180 (179.99 as reported).
- **Scale:** 1 for both screens.
- **Several externals:** out of scope; `external` uses the first one.
- **Fallback testing:** a hidden `--force-fail` flag skips the real apply and reports it
  as failed, so the fallback path runs for real.
- **Verify timing:** Hyprland may apply a configuration slightly after `succeeded`, so
  verification re-reads the screens every 250 ms for up to 2 s before declaring a
  mismatch.
- **No hanging:** every wait on the compositor has a 5 s timeout.

## Checkpoint results (2026-11-17, Hyprland 0.57.2)

| Step | Result |
|---|---|
| 1. `dcd external` | pass |
| 2. `dcd laptop` | pass |
| 3. 10 alternating switches | pass: 10/10 `done`, 0.7 to 4.3 s each (mostly Hyprland's modeset) |
| 4. `external` with HDMI unplugged | pass: `refused: no external monitor connected`, nothing changed |
| 5. Long-running `dcd watch` during switches | **unreliable**, see below |
| 6. Modes and scale | pass: panel 1080p@144, external 1080p@179.99, scale 1 |
| Fallback (`--force-fail`) | pass: external → laptop; laptop → every screen on (side by side) |

**Bug found and fixed:** the plan borrowed head names from the connection's snapshot.
The compositor's report of the change replaced that snapshot, so verification compared
freed memory and always failed. Plans now own copies of their names.

**Step 5:** the long-running `dcd watch` saw the first few switches and then nothing for
the remaining ~20, and some of what it did see was out of date. While switching,
Hyprland briefly creates a `FALLBACK` head and removes and re-adds the HDMI head. This
confirms the sprint 1 finding, now for changes made through the protocol too. This run
wasn't traced with strace, so a dcd-side cause isn't fully ruled out.

**Consequence for sprint 3:** the daemon may use its long-lived connection only as a
"something changed" signal. Every decision reads the screens over a fresh connection, as
the switch commands already do.
