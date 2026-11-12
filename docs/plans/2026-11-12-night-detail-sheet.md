# Night detail sheet, morning summary and night rating

Status: draft
Date: 2026-11-12

## Problem

The Sleep & trends page (ADR 0010) shows seven nights as stacked bars and nothing more. HRV,
heart rate and SpO₂ for a night are in Apple Health, but the app gives no way to look at one
night's stages next to them. There is also no way to say how a night felt, and nothing prompts
a look in the morning. Mockup: option 2B, the compact sheet, on the "Night detail mockups"
canvas (NightCompact.dc.html), without its meta label and its "Open in Apple Health" button.

## Decisions

| # | Decision | Chosen | Because | Cost / what it forecloses |
|---|---|---|---|---|
| 1 | Night shape | `SleepTrend.nights` also returns per night its main sleep: `start`/`end` of the longest run of asleep minutes in the day's bucket, gaps up to 60 min joined; `segments: [Segment]` (runs of one stage, awake included) inside that span; computed `mainAsleep` (asleep minutes of those segments), which the sheet's Asleep tile, its delta and the latest-night row show; `minutes` and `total` (asleep, naps included) unchanged, and the bar keeps `total` | the same per-minute merge the bar uses (`HealthTrends.swift:58`); a day's bucket also holds daytime naps (`SleepTrendTests.swift:27`), which must not stretch the span, pull daytime vitals or swell the sheet's asleep time | `Night` grows; a nap counts in the bar but not in the sheet's span, strip, asleep time or vitals |
| 2 | Vitals model | `struct NightVitals { hr, hrv, spo2: [VitalPoint] }` with computed `hrMin`, `hrAvg`, `hrvMedian`, `spo2Avg`, `spo2Min`; pure `NightVitals.split(_:spans:)` in `HealthTrends.swift` | testable without HealthKit, like `SleepTrend.nights` | raw points for 7 nights held in memory |
| 3 | Health read | `HealthKitManager.nightVitals(spans: [Date: DateInterval]) async throws -> [Date: NightVitals]`: one `HKSampleQueryDescriptor` per type (heart rate, HRV SDNN, SpO₂), predicate = OR of the night spans, every source | ADR 0010 reads every source; a median and sparklines need raw samples, which statistics queries don't give | 3 more queries each time the page appears |
| 4 | When loaded | with the trends in `TrendsView.load()`, after sleep (the spans come from it) | the sheet opens and the strip switches nights instantly | the page load waits on the vitals |
| 5 | Failure | same do/catch as the page; a locked iPhone shows the existing unlock card | one error path | a vitals-only error blanks the page |
| 6 | Opening | a `chartOverlay` with a `SpatialTapGesture` on `SleepTrendCard`, mapped through `ChartProxy.value(atX:)` to the tapped bar's day → `.sheet(item:)`, one open per tap and no drag gesture; plus a row under the chart for the latest night ("Tue 11 Nov · 6 h 16 m asleep · HRV 22 ms") that opens it | a tap-only gesture leaves horizontal swipes to the page view, which `chartXSelection`'s drag competes for; mockup 1 keeps that row; it also gives VoiceOver a target | no drag-to-scrub across bars |
| 7 | Sheet | new `My Band/UI/Trends/NightDetailSheet.swift`, `.presentationDetents([.large])`, drag indicator; a strip of the 7 window days, a day without a night disabled | mockup 2B; only the 7 trend nights (your pick) | no paging past the window |
| 8 | Tiles | asleep and HRV median, each with a delta vs the mean of the other nights (hidden when fewer than 2 others have a value); lowest HR with the average under it; SpO₂ average with the lowest under it | 2B; your pick | up mint, down amber for both (more sleep and higher HRV read as better) |
| 9 | Missing data | a tile shows "—"; a sparkline row says "No readings" | HealthKit returns nothing for a denied read (ADR 0010) | can't tell denied from none |
| 10 | Stage strip | one bar of `segments` in the `MB` stage colours, then a row per stage with its time | 2B | — |
| 11 | ADR | append `## Addendum 2026-11-12` to `docs/adr/0010-sleep-and-trends-page.md` | ADRs 0003 and 0006 use addenda | — |
| 12 | Docs | CLAUDE.md's Sleep & trends mentions gain the night sheet; CHANGELOG Unreleased › Added | repo rule: changelog before the commit | — |
| 13 | Tests | `SleepTrendTests.swift`: span, segments and awake from the merge; `NightVitals.split` (points outside every span dropped, each point to its night) and the stats (median, min, average, delta with fewer than 2 others) | the pure functions carry the logic; UI and HealthKit aren't unit-tested here | sheet layout checked by hand on the device |
| 14 | Branch | `feat/night-detail-sheet` off `main` | the repo has a remote | — |
| 15 | Rating store | `enum NightRatings` in new `My Band/Models/NightRatings.swift`: UserDefaults key `nightRatings`, `[yyyy-MM-dd: Int]`, `rating(for:)` / `set(_:for:)`, entries over 90 days old pruned on write | your pick; survives the SwiftData store reset (`My_BandApp.swift:20`) | not in Apple Health; the app's first stored health-like value (ADR addendum) |
| 16 | Rating control | under the tiles, `Slider(0...5, step: 1)` with the value shown; unrated reads "Slide to rate" with a dimmed thumb at 0; saved when the drag ends; a Clear button removes it; any night in the strip | your picks | no half points |
| 17 | Notify decision | pure `MorningSleepNotifier.shouldNotify(nightStart:nightEnd:awakeFlag:now:lastNotifiedDay:enabled:)`: closed (`awakeFlag` ≠ 0), started before 03:00 today, ended today between 03:00 and 12:00, at least 3 h long, now ≥ 05:00, not yet sent for that day, switch on | event-driven (your pick), once per night; a closed nap is a session too (`SleepPacketParser.swift:190`) and must not read as last night, a long morning nap included | late, or never, when no sync runs in the morning; a night begun after 03:00 gets only the fallback |
| 18 | Notify post | new `My Band/Health/MorningSleepNotifier.swift`, called last in `BandSyncer.flushSleep`, after the night's `writeSleep`, its vitals and `writeHRV`, and only when `context.save()` and the sleep write succeeded (`BandSyncer.swift:635`), for the stored records `storeReport` returns (their `awakeFlag` set); text "Last night: 6 h 16 m asleep. Rate it and see HR, HRV and SpO₂." (asleep minutes from the band's phases); `userInfo["night"] = yyyy-MM-dd`; UserDefaults `morningNotifiedDay` set only after posting | the night must be readable when the notification is tapped; a failed save or write leaves the day un-notified | numbers are the band's, not Health's merge |
| 19 | Tap routing | new `NotificationRouter` (`UNUserNotificationCenterDelegate`) set in `AppDelegate.didFinishLaunching`; a tap sets `@Observable AppNavigation.shared.openNight`; `RootView` sets `page = 0` and `TrendsView` opens the sheet once its trends load; `willPresent` shows a banner only for `morningSleep-*` and returns `[]` otherwise | no delegate exists yet, so today no notification shows in the foreground; `RootView.swift:41` owns `page` | Find phone and battery notifications keep their current foreground behaviour |
| 20 | Setting | UserDefaults `morningSleepNotification`, default on; a "Morning sleep summary" section in `BandSettingsView`, outside the subtree disabled while the band is disconnected (`BandSettingsView.swift:52`) | your pick; the app's other switches live there; phone-side switches must work without the band | — |
| 21 | Permission | no new request: `FindPhoneService.setup` already asks on every bootstrap (`FindPhoneService.swift:46`); without permission the post is skipped quietly and the section shows a note | one place asks today | a denial stays silent |
| 22 | ADR | the addendum also covers the rating store and the notification | ADRs 0005 and 0010 say nothing is stored | — |
| 23 | Tests | `shouldNotify` cases (open night, before 05:00, already sent, switched off, yesterday's night); `NightRatings` round trip and pruning; the fallback time per day (decision 26) | pure parts | the tap-through checked by hand on the device |
| 24 | Fallback setting | under "Morning sleep summary" in `BandSettingsView`: a second switch "Also at a set time" (`morningFallbackEnabled`, default on) and a time row: "Band alarm + 30 min" or a picked time (`morningFallbackTime`, default 08:30) | your review comment | two switches in one section |
| 25 | Fallback schedule | one-shot `UNCalendarNotificationTrigger` per morning for the next 7 days, re-planned on each foreground and after each sync; text "See last night and rate it."; `userInfo["night"]` = that day. One replan at a time: a request during one runs once after it, with the inputs read then. A replan computes the plan, adds or replaces requests by identifier first, then removes only pending `morningSleep-*` identifiers no longer planned (pure `fallbackChanges`, compared by identifier and fire time to the minute), and does nothing when the pending set already matches; `morningNotifiedDay` is re-read before each add, so a morning already notified gets no fallback. A switch turned off removes every pending fallback | a repeating trigger can't skip a day; 7 ahead covers days the app doesn't run; concurrent replans and a remove-all-then-add left gaps and duplicates | only as fresh as the last app run |
| 26 | Fallback time | per day: the first enabled band alarm firing 03:00–12:00 that morning (`AlarmService.nextFire`, `AlarmService.swift:129`) + 30 min; a one-time alarm (`repeatDays` 0, which monthly and workday alarms map to) counts only for the morning its own next firing after now lands on; no alarm that morning, or no list read yet → the picked time. Re-planned when `AlarmService` receives a list (a new `onListLoaded` callback) and on foreground; without the list, a sync keeps the last plan and so does a foreground once fallbacks are pending, planning with the picked time only when none are | the list arrives asynchronously after `RootView` asks (`RootView.swift:53`); `syncToHealth` never reads it; a one-time alarm rings once, not every morning | a headless sync can't refresh alarm-based times; a monthly alarm reads as one-time |
| 27 | One per morning | both paths use the identifier `morningSleep-<yyyy-MM-dd>`; the sync path removes that day's pending and delivered requests, then posts, without sound when that day's fallback was already delivered | one notification a morning, the numbered text wins without a second alert; the repo removes delivered ones explicitly (`FindPhoneService.swift:91`) | — |
| 28 | Apple Health sleep schedule | out of scope, filed to the backlog: its bedtime/wake-up exist in the iOS 27.2 SDK only as private symbols (`SleepDaySummary.UserSettings.Schedule` in `HealthKit.tbd`, absent from the public Swift interface) | no public API | the fallback can't follow Health's schedule |

Rejected: option 2A's pushed full page (you picked 2B); a Health query per strip tap (lags, and
the deltas need every night anyway); `HKStatisticsQuery` per night (no median, no points); a
the rating in
SwiftData (lost on a store reset) or rewritten into the band's Health sample metadata (samples
are immutable: a delete-and-rewrite of the night).

## Plan

1. **Branch and backlog.** `git checkout -b feat/night-detail-sheet main`; file a `#worth(later)` backlog item "Fallback morning notification can't follow Apple Health's sleep schedule: no public API" (decision 28) in its own `chore(backlog)` commit.
2. **Night shape** — `My Band/Health/HealthTrends.swift`: add `Segment { start, end, stage }`,
   and `start`, `end`, `segments` and computed `mainAsleep` to `SleepTrend.Night`; build them in
   `SleepTrend.nights` from the same `byMinute` merge (runs of equal stage between the night's
   main sleep: the longest asleep run, gaps up to 60 min joined).
   Tests first in `My BandTests/SleepTrendTests.swift`: a night with an awake gap gives one awake
   segment and the right span; a night plus an afternoon nap gives the night's span only, while
   `total` still counts the nap; a band awake minute overriding an iPhone asleep minute shows as
   awake; `mainAsleep` leaves out the nap and the awake minutes `total` skips only the latter of;
   the existing `minutes` expectations are unchanged.
3. **Vitals model** — same file: `VitalPoint { date, value }`, `NightVitals` with its stats,
   `NightVitals.split(_ points: [VitalKind: [VitalPoint]], spans: [Date: DateInterval]) -> [Date: NightVitals]`,
   and `NightVitals.delta(_ value: Double?, others: [Double]) -> Double?` (nil under 2 others).
   Tests in `SleepTrendTests.swift`: a point between two spans is dropped; median of an even
   count; delta nil with one other night.
4. **Health read** — `My Band/Health/HealthKitManager.swift`, Trends section: `nightVitals(spans:)`
   as decision 3; HRV in ms, SpO₂ ×100. No new permission: all three are already read types
   (`HealthKitManager.swift:88`). Not unit-testable; verified in step 14.
5. **Rating store** — `My Band/Models/NightRatings.swift` (decision 15). Tests: new
   `My BandTests/NightRatingsTests.swift` on a suite-scoped `UserDefaults(suiteName:)`: set and
   read back; clear; an entry 91 days old is pruned on the next write.
6. **Sheet** — `My Band/UI/Trends/NightDetailSheet.swift`: day strip, header ("Night of Mon 10 →
   Tue 11", the main sleep's span, "23:10 – 06:40 asleep"), the four tiles, the rating slider, stage strip with per-stage rows,
   and three sparkline rows (Swift Charts `LineMark`, no axes). Takes `nights`,
   `vitals: [Date: NightVitals]` and a binding to the selected day. Reuses `MBCard`, `MB`
   colours and `MBFormat`; stage colours from the trend card's scale.
7. **Trends wiring** — `My Band/UI/Trends/TrendsView.swift`: `Trends` gains
   `vitals: [Date: NightVitals]`, loaded in `load()` after sleep from the nights' spans;
   `SleepTrendCard` gets a `chartOverlay` tap (decision 6) and the latest-night row; `.sheet(item:)`
   on the page. Order matters: this needs steps 2–4.
8. **Navigation state** — new `My Band/AppNavigation.swift`, beside `AppDelegate.swift` and
   `My_BandApp.swift` at the target root: `@Observable @MainActor final class AppNavigation { static let shared; var openNight: Date? }`.
   `RootView.swift`: on `openNight` set, `page = 0`; the request starts a fresh `TrendsView.load()`,
   and only a load begun after it consumes and clears it; a night not in the loaded trends opens
   the sheet on the latest night.
9. **Notification router** — new `My Band/NotificationRouter.swift` (delegate: `didReceive`
   reads `userInfo["night"]` into `AppNavigation.shared.openNight`; `willPresent` returns
   `.banner` for `morningSleep-*` identifiers and `[]` for the rest, as today). Set as the centre's delegate in `AppDelegate.didFinishLaunching`, before it
   returns, so a cold launch from a tap is caught. Check `CheckBandBatteryIntent` and
   `FindPhoneService` notifications still behave: they carry no `night`, so the router ignores
   them.
10. **Notifier** — `My Band/Health/MorningSleepNotifier.swift`: `shouldNotify` (decision 17) and
    `post(for session: SleepSession)` under identifier `morningSleep-<day>`, removing that day's
    pending and delivered requests first, silent when the fallback was delivered (decision 27);
    called last in `BandSyncer.flushSleep`, after the sleep, vitals and HRV writes, when
    `context.save()` and the night's `writeSleep` succeeded (`BandSyncer.swift:635`), for the
    records `storeReport` returns. Tests: new `My BandTests/MorningSleepNotifierTests.swift` with the
    `shouldNotify` cases (open night, before 05:00, already sent, switched off, yesterday's night,
    an afternoon nap, a night under 3 h, a closed 06:00–10:00 morning nap). No permission request of its own (decision 21).
11. **Fallback** — same file: pure `fallbackTime(for day: Date, alarms: [AlarmService.Alarm]?, picked: DateComponents, now: Date, calendar:) -> Date`
    (decision 26), pure `fallbackChanges(pending:planned:)`, and a serialized `replan(_ reason:)`
    (decision 25), which plans one fallback per morning for the next 7 days, skipping a day
    already notified. Called with `.foreground` from the `scenePhase == .active` handler, `.sync`
    after each sync, and `.change` from a new `AlarmService.onListLoaded` callback, set in
    `AppServices.bootstrap` (`AlarmService.swift:148` is where a list reply lands), and from the
    settings. Tests in `MorningSleepNotifierTests.swift`: an alarm at 07:00 gives 07:30; an alarm at
    14:00 or none gives the picked time; no alarm list gives the picked time; a one-time alarm at
    07:00 tomorrow gives 07:30 tomorrow and the picked time on the other days; an unchanged plan
    gives no changes, a dropped day one removal, a moved time one replacement. Order: needs step 10's
    identifier scheme.
12. **Setting** — `My Band/UI/Settings/BandSettingsView.swift`: a "Morning sleep summary"
    section placed outside the `.disabled(!connected)` subtree (`BandSettingsView.swift:52`), with the switch (`@AppStorage("morningSleepNotification")`, default true), the
    "Also at a set time" switch, the time row (band alarm + 30 min, or a `DatePicker` time), and
    the denied note. Turning either switch off removes the pending fallbacks.
13. **Docs** — `docs/adr/0010-sleep-and-trends-page.md` addendum (sheet; vitals read per night
    from every source; the rating kept in UserDefaults as the one stored value, and why; the
    morning notification and its sync dependence); CLAUDE.md: the Sleep & trends mentions in
    the intro, the Health row of the overview table, "Apple Health is the surface" note and the
    voice note gain the night sheet, the Models tree gains `NightRatings.swift`, the
    "There is no equivalent trigger for 'woke up'" note gains the morning summary;
    `CHANGELOG.md` Unreleased › Added.
14. **Verify on the device** — install (`xcodebuild … -destination "platform=iOS,id=<iPhone>"`
    then `xcrun devicectl device install app`), open Trends, tap a bar and the latest-night
    row, switch nights in the strip, rate and clear, reopen to see the rating kept. For the
    notification: set `morningNotifiedDay` empty and sync after a closed night (or wait for a
    morning), tap the notification from the lock screen with the app killed. For the fallback:
    pick a time two minutes ahead, kill the app, wait for it; then sync a closed night and check
    the shown fallback is replaced, not doubled.

## Verification

- Steps 2, 3, 5, 10, 11: `xcodebuild test -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 17 Pro"`;
  each new test seen failing first (revert its logic, run, restore), per the repo's habit.
- Steps 4, 6–9, 12: build passes; behaviour checked in step 14 on the iPhone. These have no
  automated check.
- The full suite stays green (211 today).

## Out of scope

- Nights older than the 7-day window; ratings shown on the trends chart; respiratory rate;
  writing the rating to Apple Health; editing stages; following Apple Health's sleep schedule
  (no public API, decision 28).

## Risks

- ! Background syncs may rarely run in the morning, so the numbered notification may arrive late;
  the fixed-time fallback covers the morning, but only as far ahead as the last app run planned.
- ! A chart tap inside the paged `TabView` may still lose to the page swipe on some touches;
  the latest-night row works either way.
- ! Ratings live in UserDefaults: deleting the app deletes them, and they are in no backup but
  the device's.
- ! The fallback time follows the band alarms only after a connection read the list; a changed
  alarm moves the fallback at the next foreground or sync.
- Nothing here touches external systems or deployed copies; a `git revert` undoes it, except
  the ratings and the `morningNotifiedDay` key left in UserDefaults on the device (harmless).
