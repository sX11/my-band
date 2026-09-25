# Changelog (English)

English notes for changes that also appear, in Portuguese, in [CHANGELOG.md](CHANGELOG.md), the
project's full history.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added

- **Band alarms** (`BLE/AlarmService.swift`, `UI/Alarms/AlarmsView.swift`, `UI/Dashboard/DashboardView.swift`): a "Next alarm" tile on the Dashboard shows the next enabled alarm; tapping it opens the Alarms screen to switch alarms on or off, swipe to delete, and add one with a time and weekdays. The band is the source of truth: each change is sent to it and the list is read back (schedule type 17, subtypes 0/1/2/4, ported from GadgetBridge's `XiaomiScheduleService`; weekday bitmask Mon=1 … Sun=64). The alarm-create reply is routed apart from the reminder reply, so it can't be recorded as a reminder id and deleted by the next calendar sync. Switching an alarm edits the band's own record, so repeat modes the app doesn't model survive; forgetting the band clears the list. Tested on hardware (2026-09-25).
- **Pull to refresh on the Dashboard** (`UI/Dashboard/DashboardView.swift`): pulling down runs the same coalesced sync as the button while the band is connected.

### Changed

- **User-facing text is in English** (UI, errors, notifications, Siri phrases and `Info.plist` usage strings).

### Fixed

- **The Dashboard's "last sync" time froze** (`UI/Dashboard/DashboardView.swift`): the relative time was computed at render and nothing re-rendered it. A 30 s `TimelineView` keeps it current, and a sync under a minute old reads "Just now".
- **The two Dashboard tiles had different heights** (`UI/Dashboard/DashboardView.swift`, `UI/DesignSystem/MBMetricTile.swift`): the battery tile has no footer unless charging. Both now match the taller one.
