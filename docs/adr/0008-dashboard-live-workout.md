---
status: accepted
---

# The Dashboard shows the workout running on the band; extends ADR 0005

The owner wants to see, in the app, that a workout is running on the band and how it is going. The band already tells the app: `workoutStatusWatch` (Health 8/26) arrives on start, pause, resume and finish with the sport and a timestamp. While one runs, a workout card sits at the top of the Dashboard and opens a Workout sheet: sport, elapsed time, running or paused, live heart rate, steps and active energy, and for GPS sports the distance and pace from the phone.

`WorkoutLiveService` holds the realtime stream (`RealtimeHolder.workout`) from start to finish. ADR 0005 rejected keeping the stream open because it makes the band measure heart rate continuously; during a workout the band does that anyway, so the cost is gone. Steps and energy are the stream's daily totals minus their value at the first event after the start. Distance is summed from the fixes `WorkoutGpsService` streams to the band, so indoor sports show none. The band's own distance and pace only arrive in the workout file after it ends.

What 0005 keeps: nothing is stored. The session lives in memory and ends on finish, after 10 minutes without a link, or when the band is forgotten; the workout reaches Apple Health from the band's file, as before.

Limits, accepted: there is no command to ask the band whether a workout is running, so one started while the app was disconnected appears only at its next pause or resume, with steps and energy counted from then (flagged in the sheet). A link drop keeps the session for 10 minutes, since the app drops links itself (a background task's expiry, a stale-link retry); the live stream restarts on the next handshake. A finish sent into the gap is lost: a band gone longer ends the session, but one that reconnects sooner leaves the workout on screen until a new workout starts or the app relaunches. Whether the status timestamp is the workout's start or the event's own time is unconfirmed; every status logs it raw.

The same session drives a Live Activity on the Lock Screen and in the Dynamic Island (`MyBandWidgets`), with the same numbers and nothing more. iOS starts one only while the app is in front, so a workout begun with the phone locked posts a notification and the activity starts at the next foreground. A finish removes every workout activity at once, and each push sets a 10-minute stale date, so an app killed mid-workout leaves an activity marked "Not updating" rather than a clock that looks live.

Rejected: starting a band workout from the app. No app-to-band command for it is known in the protocol or GadgetBridge. Also rejected: showing an idle card with a start hint, which would be permanent clutter for an instruction the app can't act on.
