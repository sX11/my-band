---
status: accepted, pending hardware validation
---

# Steps, distance and active energy go to Apple Health raw per minute

The iPhone records the same three quantities the band does. The app used to write only the band's surplus per minute, `max(0, band - iPhone)`, reading the iPhone's sums with an `HKStatisticsCollectionQuery` first. HealthKit refuses reads while the phone is locked (`errorDatabaseInaccessible`), which is when background syncs run, so nearly every background sync failed.

Apple Health does not add overlapping samples from different sources together: it resolves each overlap by the user's order in Health > Steps > Data Sources & Access. `HealthKitManager.writeActivity` therefore writes the band's full value for each minute and reads nothing. Which source wins a minute both recorded is the user's choice; with iPhone above My Band, the band only adds minutes the phone missed. The sync identifiers (`mb-steps-rec-`, `mb-dist-rec-`, `mb-cal-rec-` plus the minute) and the monotonic version are kept, so a re-synced minute replaces its old surplus sample.

Rejected: keeping the reconciliation and deferring it until an unlocked sync. It keeps the read, delays steps whenever the phone is locked, and undercounts when My Band ranks above the iPhone: Health then takes the surplus alone for a shared minute. Also rejected: hourly samples, as better-mi-fitness-sync writes. An hour-long sample wins or loses the whole hour against the iPhone instead of minute by minute.

Not yet validated on hardware. The earlier observation of a doubled walk (200 to 400 steps) was made with a whole-day step sample from `writeDailySummary`, not per-minute samples.
