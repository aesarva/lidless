# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS 14+ app (SwiftUI + AppKit). Lives only in the menu bar (`LSUIElement`): a status item, a popover opened by left click, a quick menu on right click, and a Settings window. No Dock icon, no main window.

## Users

MacBook owners — the author, friends, and a GitHub audience — who need the Mac to stay awake on purpose: long-running jobs (downloads, builds, renders, AI agents) while the laptop sits closed on a desk or in a bag; remote access (SSH, Screen Sharing, home services); music or AirPlay with the lid shut; clamshell work with an external display, sometimes off the charger.

## Product Purpose

Keep a Mac awake for exactly as long as the user wants — including with the lid closed — and stop on its own before that becomes dangerous. Success: one click starts a session, closing the lid does not interrupt the job, and the Mac never ends up hot, drained, or permanently unable to sleep because of Lidless.

## Positioning

Lungo-class keep-awake utility, but it works with the lid closed (via `pmset disablesleep` and a narrowly scoped helper) and guards itself: low-battery stop, thermal pause, a time limit for closed-lid-on-battery, and a root watchdog that restores sleep if the app dies.

## Operating Context

Glanced at and clicked from the menu bar dozens of times a day, usually in passing, then left alone for hours. Sessions run while the user is away from the screen; outcomes arrive as notifications. Used in light and dark menu bars, on battery and on power, with the lid open or closed.

## Capabilities and Constraints

- Sessions: presets (15 min, 1 h, 3 h by default; editable), "Until…" a time, indefinite; extend from the ending-soon notification.
- Display: "may sleep" or "stays on" while a session runs.
- Closed-lid mode: separate toggle, effective only during a session; needs a one-time admin-password helper install.
- Safety: stop below a battery threshold (default 20%), pause lid mode when hot, stop when critically hot with the lid closed, pause lid mode after N hours closed on battery (default 4 h).
- Menu-bar icon states: off, on, on with timer (progress ring, optional countdown text), closed-lid mode, attention (safety fired / helper broken).
- Settings: General, Safety, Helper, About. Launch at login.
- Localization: English (source) and Russian.
- Not in the App Store (the privileged helper is not allowed there); distributed as a DMG, Developer ID signing and notarization coming.
- Planned later phases: automatic triggers, integrations (hotkey, URL scheme, CLI, Shortcuts), statistics and widgets.

## Brand Commitments

- Name: **Lidless** (renamed from WakeUp on 2026-10-16).
- Menu-bar glyph family: the "pulse" set — a flat line when off, an ECG pulse when awake, a pulse inside a progress ring with a timer, a pulse above a horizon line in closed-lid mode, and an orange attention dot.
- App icon: currently a glowing warm-white pulse above a thin horizon line on a gradient from night indigo to amber (`App/Resources/AppIcon.icon`). Not binding: the user allowed changing the icon with the visual redesign (2026-10-16).

## Evidence on Hand

No users, testimonials, or metrics yet. The app has not been used on real hardware for its closed-lid checklist yet (README "Manual verification" is pending).

## Product Principles

- Safety is part of the product, not a setting: the Mac must always find its way back to normal sleep.
- One click to start, zero attention while it runs; state must be legible at a glance from the menu bar.
- Honest state: the UI never shows something calmer than what the system is actually doing.
- Native first: feel like part of macOS, express the brand through detail.
