---
status: accepted
---

# A Sleep & trends page charts seven days of Apple Health; amends ADRs 0001, 0005 and 0006

ADR 0001 cut every chart and the `SleepDetail` hypnogram, and ADRs 0005 and 0006 kept history in Apple Health. The owner wants trends of several readings in the app. So a page left of the Dashboard (`TrendsView`) charts the last seven days: sleep per night by stage, resting heart rate, steps, SpO₂ and weight.

The trends are read from Apple Health each time the page appears, the way Workouts is (ADR 0009). Unlike Workouts, they include every source, because the owner wants the numbers the Health app shows. Steps therefore include the iPhone's, and the page says so. Quantity trends are `HKStatisticsCollectionQuery` daily sums or averages, which merge sources as Health does. Sleep has no such merge, and the iPhone's `asleepUnspecified` overlaps the band's night. So `SleepTrend.nights` counts each minute once and keeps the band's stage where both claim it. A night belongs to the day it ends on, cut at 18:00.

What 0005 and 0006 keep: nothing read here is stored, and the Dashboard stays a status screen. The health data lives on the side pages.

Limits, accepted: the window is fixed at seven days. A locked iPhone refuses the read and the page asks to unlock. If read access to a type is switched off in Health, HealthKit returns nothing for it rather than an error, so that card says there is no data. A nap after 18:00 counts toward the next night.

Rejected: building the trends from SwiftData and the sync snapshot. They hold only the band's data, so steps would not match the Health app, and only sleep is kept day by day. Also rejected: summing sleep samples across sources, which doubles a night the iPhone and the band both recorded. Also dropped: a last-night hypnogram above the trends, from the band's `SleepSession`s. The Health sheet already shows last night's stages (ADR 0006), and the owner wants this page to be only the seven-day charts.
