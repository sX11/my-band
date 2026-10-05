---
status: accepted
---

# A Workouts screen reads past workouts back from Apple Health; amends ADRs 0005 and 0006

ADRs 0005 and 0006 kept health history out of the app and rejected reading data back from HealthKit. The owner wants a list of recent workouts with their totals without opening Apple Health, so a Workouts page sits one swipe left of the Dashboard: the newest 50 workouts, grouped by month, each opening a detail with date, time, duration, distance, pace or speed, active energy, average METs, average/highest/lowest heart rate, and indoor or outdoor.

Unlike 0006's snapshot, this is history, and the band can't supply it: it hands over each workout file once and forgets it after the ACK. Apple Health already holds every workout the app wrote, so the page queries it each time it appears (`HealthKitManager.recentWorkouts`) and keeps the result in memory. 0005's two reasons against reading back don't apply here. Read authorization for workouts is already requested, because every share type is also requested for read. The page also asks for Health access itself, which is a no-op once answered. And the query is limited to this app's source (`HKSource.default()`), so no iPhone or other app's workout appears as the band's.

What 0005 and 0006 keep: nothing new is stored, and there are no charts, routes, graphs or splits. Those stay in Apple Health. The other health types are still not read back.

Limits, accepted: a locked iPhone refuses the read (`errorDatabaseInaccessible`) and the page says to unlock. Each workout written since this ADR carries the band's sport in its metadata (`MiBandWorkoutKind`). Workouts written before that rebuild the sport from the `HKWorkoutActivityType` plus the indoor and swim-location metadata, so a trail run reads as an outdoor run, a trek as a hike, and free training as a generic workout. Heart rate comes from the band's summary in the workout metadata, falling back to the workout's own statistics. If read access to workouts is switched off in Health, HealthKit returns an empty list rather than an error, so the page shows "No workouts yet".

Rejected: keeping a local copy of each workout in SwiftData at sync time. It would duplicate what Apple Health already stores, and it would drift from Health whenever a workout is deleted there.
