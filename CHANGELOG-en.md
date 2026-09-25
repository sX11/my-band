# Changelog (English)

English notes for changes that also appear, in Portuguese, in [CHANGELOG.md](CHANGELOG.md), the
project's full history.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added

- **Pull to refresh on the Dashboard** (`UI/Dashboard/DashboardView.swift`): pulling down runs the same coalesced sync as the button while the band is connected.

### Changed

- **User-facing text is in English** (UI, errors, notifications, Siri phrases and `Info.plist` usage strings).

### Fixed

- **The Dashboard's "last sync" time froze** (`UI/Dashboard/DashboardView.swift`): the relative time was computed at render and nothing re-rendered it. A 30 s `TimelineView` keeps it current, and a sync under a minute old reads "Just now".
- **The two Dashboard tiles had different heights** (`UI/Dashboard/DashboardView.swift`, `UI/DesignSystem/MBMetricTile.swift`): the battery tile has no footer unless charging. Both now match the taller one.
