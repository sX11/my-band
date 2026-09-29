---
status: accepted
---

# The Dashboard keeps the last sync's health readings; amends ADR 0005

ADR 0005 let the Dashboard show the band's live counters and store nothing. The owner wants one place to see the latest value of every health reading the band produces, without opening Apple Health, so a Latest metrics tile opens a Health sheet with them.

The live stream cannot supply these: it carries only steps, calories and heart rate, and its `standingHours` field reads 0 on a Band 10 whose own screen counts stand hours. The sync already parses everything else, so `LatestMetricsStore` keeps one `LatestMetrics` snapshot of the newest values it has seen, and the sheet reads that. The snapshot holds the newest day's summary (resting/average/highest/lowest heart rate, SpO₂, stress and the stood-hours mask), the newest heart-rate, SpO₂, stress and temperature samples from the all-day series and the band's spot measurements, and it is overwritten in place in UserDefaults and cleared when the band is forgotten. The sheet adds the last `SleepSession` already in SwiftData and the scale's last weighing. The Today tile's stood hours come from that snapshot, not from the stream.

What 0005 keeps: Apple Health stays the only place health data is stored as history and explored. The snapshot has no history, and the sheet has no charts or trends.

Rejected: reading the latest values back from HealthKit (0005's reasons still hold — read authorization for every type, and it would show iPhone data as the band's). Also rejected: keeping the snapshot in memory only. It would empty on every launch until a sync ran, and a headless background sync would fill it where no one sees it.
