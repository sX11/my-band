---
status: accepted
---

# The Dashboard shows today's activity; supersedes ADR 0001's no-data rule

ADR 0001 cut every in-app view of health data and left the Dashboard with connection state, sync freshness, battery and the sync action. The owner of this fork wants a glance at today's totals without opening Apple Health, so the Dashboard gains one Today tile: steps, calories, standing hours and a current heart rate.

The rule this keeps from 0001 is that Apple Health stays the only place health data is *stored and explored*. The tile shows the band's own live counters and is never persisted: `TodayActivityService` reads one realtime-stats snapshot (START, stop on the first heart rate above 10 bpm or after 30 s) and holds it in memory. No history, no charts, no `SleepDetail` hypnogram — those still belong to Apple Health, and the rest of 0001 (Liquid Glass for chrome, `GetSleepStateIntent` for sleep questions) stands.

Rejected: reading the totals back from HealthKit. It would show what was last synced, not what the band counts now, and it would need read authorization for types the app otherwise only writes. Also rejected: keeping the realtime stream open while the Dashboard is visible — the band measures heart rate continuously while it runs, which costs battery for a number that changes slowly.
