# Changelog (English)

English notes for the changes made on the `english-ui` / `fix/review-findings` line of work. The
project's full history, in Portuguese, is in [CHANGELOG.md](CHANGELOG.md); these entries mirror its
`[Unreleased]` section for the same changes.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added

- **Last charge date on the Battery tile** (`BLE/BandManager.swift`, `UI/Dashboard/DashboardView.swift`): while not charging, the tile's footer reads "Charged 3 days ago", from `battery.lastCharge.timestampSeconds`. **Not yet validated on hardware** (whether the timestamp marks the start or end of charging).
- **Smart wake-up on band alarms** (`BLE/AlarmService.swift`, `UI/Alarms/AlarmsView.swift`): the New alarm section has a Smart wake-up switch, and a swipe right on an alarm switches it between smart and normal (`AlarmDetails.smart` 1 / 2).
- **Band alarms** (`BLE/AlarmService.swift`, `UI/Alarms/AlarmsView.swift`, `UI/Dashboard/DashboardView.swift`): a "Next alarm" tile on the Dashboard shows the next enabled alarm; tapping it opens the Alarms screen to switch alarms on or off, swipe to delete, and add one with a time and weekdays. The band is the source of truth: each change is sent to it and the list is read back (schedule type 17, subtypes 0/1/2/4, ported from GadgetBridge's `XiaomiScheduleService`; weekday bitmask Mon=1 … Sun=64). The alarm-create reply is routed apart from the reminder reply, so it can't be recorded as a reminder id and deleted by the next calendar sync. Switching an alarm edits the band's own record, so repeat modes the app doesn't model survive; forgetting the band clears the list. Tested on hardware (2026-09-25).
- **Pull to refresh on the Dashboard** (`UI/Dashboard/DashboardView.swift`): pulling down runs the same coalesced sync as the button while the band is connected.

### Changed

- **User-facing text is in English** (UI, errors, notifications, Siri phrases and `Info.plist` usage strings).

### Fixed

- **"Not authorized" failed every Apple Health sync** (`Health/HealthKitManager.swift`): one data type switched off for the app in Health → Data Access (Steps, on hardware 2026-09-26) makes HealthKit reject the whole `store.save`, so nothing was written. Samples of a type the app can't write are now dropped and named in the log, and workouts and routes are skipped when their type is off. A band file whose samples were dropped this way is left un-ACKed, so the band offers it again and it is written once the type is switched on, rather than deleted unwritten.
- **The band's clock was an hour off in summer time** (`BLE/Protocol/XiaomiProto.swift`): `setCurrentTimeCommand` sent `secondsFromGMT` (which already includes DST) as `zoneOffset` and sent `dstOffset` too, so the band applied DST twice. `zoneOffset` is now the standard offset, as GadgetBridge sends it. Calendar alerts, sent as timestamps, fired an hour off for the same reason.
- **Band reminders fired at the wrong time** (`BLE/CalendarSyncService.swift`, `BLE/BandManager.swift`, `UI/RootView.swift`): date-only reminders went to the band at 00:00 (now 09:00, the iOS default), a reminder's alert was ignored in favour of its due time, overdue reminders filled the 20 slots, and location alerts were treated as times. Each reminder now goes at the next alert the iPhone would give. Before re-creating, the band's list (`CMD_REMINDERS_GET`) is read and only this app's reminders are deleted — by acked id or by title and time — so a missed ack no longer leaves an orphan firing forever. Only create acks (subtype 15) count as ids. Forgetting the band clears the sync state. Calendar events also honour fixed-time alerts.
- **"Sync timed out." on a link held open for a long time** (`BLE/BackgroundSyncManager.swift`, `BLE/BandSyncer.swift`): the band stopped answering while the status still read "Connected", and only relaunching the app (a fresh connection) cleared it. A file-list timeout on a link that was already up now drops the connection, re-authenticates and retries the sync once; a file that stalls is still just skipped. There is no retry inside a `BGAppRefreshTask`, from the Shortcuts intents, or on a background wake (their time budget can't hold a reconnect, and a coalesced caller of that kind turns it off for the shared sync), nor when the old link doesn't drop. The reconnect waits for a connect already under way instead of starting a second one. Both timeout points log at error level, persisted on the device, with values marked `.public` so they don't read `<private>`. Validated on hardware (2026-09-25) after a 30-minute open link.
- **The Dashboard's "last sync" time froze** (`UI/Dashboard/DashboardView.swift`): the relative time was computed at render and nothing re-rendered it. A 30 s `TimelineView` keeps it current, and a sync under a minute old reads "Just now".
- **The two Dashboard tiles had different heights** (`UI/Dashboard/DashboardView.swift`, `UI/DesignSystem/MBMetricTile.swift`): the battery tile has no footer unless charging. Both now match the taller one.
- **The AuthKey migration could delete the only copy of the key** (`Auth/AuthKeyStore.swift`): the legacy (bundle-id) item was deleted even when saving under the fixed service failed. It is now deleted only after a successful save; on failure the legacy key is still returned and the migration retries on the next load.
- **A watch face or app upload hung forever when the link dropped** (`BLE/BandManager.swift`, `BLE/Upload/DataUploadService.swift`): the pacing wait was only resumed by `peripheralIsReady`, which never fires on a dead link. The teardown now resumes it, and the upload fails with "Band not connected." instead of finishing into a dead link and showing the face as installed. The check looks at the GATT link, not the auth state, so a band session restart mid-upload doesn't abort it.
- **Frames larger than the MTU silently lost fragments** (`BLE/BandManager.swift`): `writeSPP` sent every fragment at once, and CoreBluetooth drops a write-without-response while its buffer is full, so a large calendar frame or upload chunk arrived corrupted. Fragments now go through a queue drained on `peripheralIsReady`, every later write queues behind it so no bytes interleave into the frame, and a small write with a full buffer queues too instead of being dropped.
- **A truncated daily summary became invented data** (`BLE/PacketParser/DailySummaryParser.swift`): the guard required 30 bytes but the parser reads 41, and the buffer still carries the trailing CRC-32; `LEReader` returns 0 past the end, so a short file was written with zeros (or CRC bytes as SpO₂) and ACKed. The guard now accounts for the CRC: it requires the fields through calories, and the SpO₂ block is read only when complete, so a file ending before it keeps its steps and heart rate.
- **A sleep test that had never passed** (`My BandTests/SleepReconciliationTests.swift`): its expectation contradicted `sanitizeStages` (an inner REM inside a deep stage is dropped, not carved out). The test now covers the cross-file overlap it was written for.
