# NextAuto

A standalone next-auto-attack swing timer for **Ashita v4** (FFXI / HorizonXI).

![Ashita v4](https://img.shields.io/badge/Ashita-v4-blue)
![License](https://img.shields.io/badge/license-MIT-green)

> Formerly known as **Swingers**.

---

## What It Does

Displays a configurable timer that fills as your melee swing recharges, so you can
see at a glance how close you are to your next auto-attack.

- **Shape from bar to arc** — a single curve slider morphs the timer from a flat bar
  all the way to a full semicircle pendulum
- **Horizontal or vertical** orientation
- **Color gradient** (defaults cyan → yellow → red) — fully customizable
- **Reverse fill** — fill from either end
- **Pendulum bob** at the leading edge (optional)
- **Optional background window** for visibility in bright zones
- **Combat aware** — hides or freezes when you are not engaged
- **Pauses during weaponskills, job abilities, and spellcasts**, then resumes from
  where it left off
- **MNK Martial Arts** support — proper H2H delay calculation with tier-based reduction
- **Bare-hand detection** — works even with no weapon equipped on MNK

---

## Installation

1. Copy the `nextauto` folder into your Ashita `addons/` directory
2. Load in-game:
   ```
   /addon load nextauto
   ```

---

## Configuration

Open the config menu with `/nextauto` (or `/na`). Everything is adjustable live with
sliders, checkboxes, and color pickers — settings save automatically per character.

| Setting | Description |
| --- | --- |
| Length | End-to-end span in pixels |
| Thickness / Height | Stroke thickness |
| Smoothness | Number of segments (higher = smoother arc) |
| Curve | 0 = straight bar, 1 = full semicircle arc |
| Vertical | Run the timer vertically |
| Reverse fill | Fill from the opposite end |
| Colors | Start / Mid / End gradient colors |
| Show pendulum bob | Toggle the leading-edge bob |
| Background window | Draw a backing panel + pick its color/alpha |
| Hide out of combat | Hide entirely when not engaged |
| Freeze out of combat | (when not hiding) freeze instead of running |
| Lock position | Lock the window so it can't be dragged |

---

## Commands

| Command | Description |
| --- | --- |
| `/nextauto` or `/na` | Toggle the config menu |
| `/nextauto show` / `hide` | Show or hide the timer |
| `/nextauto lock` / `unlock` | Lock or unlock position |
| `/nextauto reset` | Reset all settings to defaults |
| `/nextauto preset NAME` | Apply a color preset: `classic`, `ion`, or `frost` |
| `/nextauto length N` | Set the span |
| `/nextauto thickness N` | Set the stroke thickness |
| `/nextauto segments N` | Set smoothness |
| `/nextauto curve F` | Set the curve (-1.0–1.0; negative mirrors the arc) |
| `/nextauto debug` | Toggle action-packet logging (for diagnosing timing) |

The legacy `/swingers` command still works as an alias.

---

## How It Works

NextAuto monitors action packet `0x28` and builds a rolling average of your swing
interval. It includes full MNK Martial Arts tier handling (levels 15/25/40/55/70) and
the proper H2H delay formula (`480 + weapon_delay - MA_reduction`), so it works
correctly for all jobs without any other addons.

Weaponskills, job abilities, spellcasts, ranged attacks, pet commands, Dancer
steps, and RUN actions freeze the timer for the duration of the action's
animation lock (~2.0s by default), then it resumes from exactly where it
paused — so the bar never drifts ahead of your real swing. When you are not
engaged it hides (or freezes, your choice).

Settings are saved per-character via Ashita's settings library.

---

## Author

**TreeFidyDad**
