# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS 14+ app (SwiftUI + AppKit), universal (Apple Silicon + Intel). Lives only in the menu bar (`LSUIElement`): a status item, a panel opened by left click, a quick menu on right click, and a Settings window. No Dock icon, no main window. A root helper daemon ships inside the bundle and is registered through `SMAppService`.

## Users

MacBook owners (the author, friends, and a GitHub audience) who need the Mac to stay awake on purpose: long-running jobs (downloads, builds, renders, AI agents) while the laptop sits closed on a desk or in a bag; remote access (SSH, Screen Sharing, home services); music or AirPlay with the lid shut; clamshell work with an external display, sometimes off the charger.

## Product Purpose

Keep a Mac awake for exactly as long as the user wants, including with the lid closed, and stop on its own before that becomes dangerous. Success: one click starts a session, closing the lid does not interrupt the job, and the Mac never ends up hot, drained, or permanently unable to sleep because of Lidless.

## Positioning

A Lungo-class keep-awake utility that also works with the lid closed and guards itself. Closed-lid mode uses `pmset disablesleep` through a narrowly scoped root helper the user approves once in System Settings, with no password. Normal sleep is restored when the app quits, crashes or is force-quit, at boot after a reboot, and when the user switches the helper off. A low-battery stop, a thermal pause and a time limit for closed-lid-on-battery keep a forgotten laptop safe.

## Operating Context

Glanced at and clicked from the menu bar dozens of times a day, usually in passing, then left alone for hours. Sessions run while the user is away from the screen; outcomes arrive as notifications. Used in light and dark menu bars, on battery and on power, with the lid open or closed.

## Capabilities and Constraints

- Sessions: presets (15 min, 1 h, 3 h by default; editable), "Until…" a time, indefinite; extend from the ending-soon notification.
- Display: "may sleep" or "stays on" while a session runs.
- Closed-lid mode: separate toggle, effective only during a session; needs a one-time approval of the helper in System Settings → Login Items (no password) and a Developer ID–signed build. A `disablesleep` the user set themselves is never touched.
- Safety: stop below a battery threshold (default 20%), pause lid mode when hot, stop when critically hot with the lid closed, pause lid mode after N hours closed on battery (default 4 h).
- Menu-bar icon states: off, on air, on air with timer (the lamp burns down, optional countdown text), closed-lid mode, attention (a safety rule fired or the helper is unavailable).
- Settings: General, Safety, Helper, About. Launch at login.
- Localization: English (source) and Russian, switchable in the app.
- No network access, analytics or accounts.
- Not in the App Store (privileged helpers are not allowed there). Distributed as a Developer ID–signed, notarized DMG on GitHub Releases.
- Planned later phases: automatic triggers, integrations (hotkey, URL scheme, CLI, Shortcuts), statistics and widgets.

## Brand Commitments

- Name: **Lidless** (renamed from WakeUp on 2026-10-16).
- Visual world: the "On Air" broadcast studio (see DESIGN.md). The ON AIR sign is lit exactly while the Mac is held awake, and red is reserved for being on air.
- Menu-bar glyphs: a quiet flat line when off; a lit red lamp carrying a pulse line on air, burning down with a timer; a horizon line under the lamp in closed-lid mode; an orange attention dot, the only other colour.
- App icon: a lit red ON AIR light box with a warm-white pulse line on studio black (generated raster, provenance in docs/asset-provenance.md).

## Evidence on Hand

Public releases: 0.2.0 (2026-10-21, the first, signed and notarized), 0.3.0 (2026-10-24, `SMAppService` helper). The closed-lid hardware checklist (CONTRIBUTING.md) passed in full on a real MacBook for 0.3.0: lid closed on battery, force quit, helper crash, reboot, Login Items toggle, a foreign `disablesleep`, upgrade from 0.2.0, and removal. No user metrics or testimonials yet.

## Product Principles

- Safety is part of the product, not a setting: the Mac must always find its way back to normal sleep.
- One click to start, zero attention while it runs; state must be legible at a glance from the menu bar.
- Honest state: the UI never shows something calmer than what the system is actually doing.
- Native first: feel like part of macOS, express the brand through detail.
