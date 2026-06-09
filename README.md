# Swingers

A standalone pendulum swing timer addon for **Ashita v4** (FFXI / HorizonXI).

![Ashita v4](https://img.shields.io/badge/Ashita-v4-blue)
![License](https://img.shields.io/badge/license-MIT-green)

---

## What It Does

Displays a half-arc pendulum that fills from right to left as your melee swing progresses.

The arc uses a **cyan → yellow → red** color gradient so you can see at a glance how close you are to your next swing.

- **Pendulum bob** at the leading edge (turns red when swing is imminent)
- **White flash** on swing land for clear visual feedback
- **Draggable** — position it anywhere on screen
- **MNK Martial Arts** support — proper H2H delay calculation with tier-based reduction
- **Bare-hand detection** — works even with no weapon equipped on MNK

---

## Installation

1. Copy the `swingers` folder into your Ashita `addons/` directory
2. Load in-game:
   ```
   /addon load swingers
   ```

---

## Commands

| Command | Description |
| --- | --- |
| `/swingers show` | Show the timer |
| `/swingers hide` | Hide the timer |
| `/swingers lock` | Lock position |
| `/swingers unlock` | Unlock for dragging |
| `/swingers radius N` | Set arc radius (default: 40) |
| `/swingers thickness N` | Set line thickness (default: 4) |
| `/swingers segments N` | Set arc smoothness (default: 24) |

---

## How It Works

Swingers monitors action packet `0x28` (melee swings) and builds a rolling average of your swing interval. It includes full MNK Martial Arts tier handling (levels 15/25/40/55/70) and proper H2H delay formula (`480 + weapon_delay - MA_reduction`), so it works correctly for all jobs without any other addons.

Settings are saved per-character via Ashita's settings library.

---

## Author

**TreeFidyDad**
