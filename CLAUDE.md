# CLAUDE.md — My Band

Architecture guide and guidelines for the **My Band** project: a universal iOS/macOS app that connects to the Mi Band 10 over BLE using the AuthKey, syncs health data to Apple Health and supports Shortcuts through App Intents. Health data lives in Apple Health; the exceptions are the Dashboard's Today card, with the band's live counters (ADR 0005), the live workout card, while the band records a workout (ADR 0008), the Health sheet, with the latest value of each reading from the last sync (ADR 0006), the Workouts screen, with the latest workouts the app itself recorded, read back from Apple Health (ADR 0009), and the Sleep & trends page, with seven days of trends read from Apple Health (ADR 0010).

---

## Project Overview

| Item | Detail |
|---|---|
| Platforms | iOS 26+ (the app target plus the WidgetKit extension `MyBandWidgets`, which draws the workout Live Activity; runs on the Mac via "Designed for iPad and iPhone", not a native macOS target — `IPHONEOS_DEPLOYMENT_TARGET` in the pbxproj is the source of truth) |
| Language | Swift 5.10+ |
| UI | SwiftUI, Liquid Glass on chrome/status (`MBStatusPill` etc.) |
| Persistence | SwiftData |
| Bluetooth | CoreBluetooth (BLE only — the Mi Band 10 does not use Classic BT) |
| Health | HealthKit — the only surface for stored data; the Dashboard shows the day's live counters (ADR 0005) and the latest value of each reading from the last sync (ADR 0006); the Workouts screen reads back the workouts the app itself recorded (ADR 0009); the Sleep & trends page reads seven days of trends (ADR 0010) |
| Automation | App Intents + Shortcuts |
| Distribution | Personal use — sideloaded via a personal Apple Developer Program account (no App Store) |

---

## Module Architecture

```
My Band/
├── App/
│   ├── My_BandApp.swift          # Entry point, global dependency injection
│   └── AppDelegate.swift         # BLE background lifecycle on iOS
│
├── BLE/
│   ├── BandManager.swift         # Central BLE orchestrator (@Observable @MainActor NSObject)
│   ├── BandScanner.swift         # Discovery and filtering of Mi Band devices
│   ├── BandAuthenticator.swift   # AES-128 handshake with the AuthKey
│   ├── BandProtocol.swift        # Mi Band protocol packet encoder/decoder
│   ├── BandSyncer.swift          # Historical data sync (sleep, steps, HR)
│   ├── WorkoutGpsService.swift   # GPS handshake during workouts (band→app workoutOpenWatch)
│   ├── FindPhoneService.swift    # "Find phone": alarm on the iPhone (band→app CMD_FIND_PHONE)
│   ├── CalendarSyncService.swift # app→band push: language, calendar and reminders (EventKit)
│   ├── WeatherSyncService.swift  # app→band push: current weather + forecast (Open-Meteo)
│   ├── ReminderService.swift     # Band reminders: list, create, delete; sole owner of the list and of the create acks
│   ├── BandSettingsService.swift # Band settings (HR, SpO₂, stress, reminders, screen): GET/SET + re-read
│   ├── TodayActivityService.swift # One-shot read of the realtime stats for the Dashboard's Today card
│   ├── WorkoutLiveService.swift  # Workout in progress on the band (status 8/26 + realtime + GPS) for the workout card (ADR 0008)
│   ├── Scale/                    # OKOK/Chipsea BLE scale (independent of the band)
│   │   ├── ScaleManager.swift    # Listens to the advertisement (broadcast-only) and writes weight to Apple Health
│   │   └── ScaleWeightParser.swift # Weight decode (VC0 variant)
│   └── Services/
│       ├── MiBandUUID.swift      # GATT service UUID constants
│       └── PacketParser/         # Parsers per type (sleep, daily, manual, workouts+GPS, in-workout HR)
│
├── Auth/
│   ├── AuthKeyStore.swift        # Secure AuthKey storage in the Keychain
│   ├── XiaomiCloudAuth.swift     # AuthKey extraction via Xiaomi Cloud (username/password login → beaconkey/token)
│   └── XiaomiCloudCrypto.swift   # RC4/SHA-1/SHA-256 for the account API (separate from the BLE XiaomiCrypto)
│
├── Health/
│   ├── HealthKitManager.swift    # Authorization and writes to Apple Health
│   └── HealthSyncService.swift  # Conversion of Mi Band data → HealthKit types
│
├── Intents/
│   ├── SyncBandIntent.swift      # App Intent: sync data now
│   ├── GetSleepStateIntent.swift # App Intent: "are you asleep?" (pull, not push — see note)
│   ├── CheckBandBatteryIntent.swift # App Intent: notifies only if the battery is below the threshold
│   └── BandShortcuts.swift       # AppShortcutsProvider with Siri phrases
│
├── MiniApp/                      # (Future phase) Mini app on the band
│   └── README.md                 # Mini app protocol documentation
│
├── Models/
│   ├── BandDevice.swift          # SwiftData model of the paired device
│   ├── SleepSession.swift        # SwiftData model of a sleep session
│   ├── ActivityDay.swift         # SwiftData model of daily activity
│   ├── LatestMetrics.swift       # Snapshot of the latest value of each reading, for the Health sheet (ADR 0006)
│   ├── HealthSyncLog.swift       # What each sync sent to Apple Health, per type, for the Health sheet
│   ├── WorkoutWindows.swift      # Windows of recorded workouts, so the daily detail excludes distance/energy (ADR 0007)
│   ├── StrengthWorkoutExtras.swift # Matches the phone's strength route and post-workout HR to the band's workout
│   └── HeartRateSample.swift     # SwiftData model of HR samples
│
└── UI/
    ├── Dashboard/                # Main screen with a data summary
    ├── Setup/                    # Setup flow (AuthKey + HA)
    ├── Sleep/                    # Detailed sleep view
    ├── Profile/                  # BodySection: height and weight in the Health sheet (→ BMI in Apple Health)
    ├── Customize/                # Watch faces and RPK apps (opened from Band settings)
    ├── Workouts/                 # List of workouts read from Apple Health (ADR 0009)
    ├── Trends/                   # 7-day trends from Apple Health (ADR 0010)
    ├── Reminders/                # Page to the right of Workouts: band reminders, create/delete (ReminderService)
    ├── Settings/                 # General settings
    └── LiveActivity/             # WorkoutActivityController: workout Live Activity (ADR 0008)
```

Outside `My Band/`: `MyBandWidgets/` (WidgetKit extension; its Info.plist lives in `MyBandWidgets-Info.plist`, at the root, because of the same pitfall as the app's Info.plist) and `Shared/` (synchronized into both targets: `WorkoutActivityAttributes`, `WorkoutClockFormat`).

---

## Mi Band 10 BLE Protocol

> **Protocol confirmed via GadgetBridge** (`XiaomiSppPacketV2`, `XiaomiAuthService`, `MiBand10Coordinator`).
> The earlier implementation (AES-128-ECB + UUIDs FEE0/FEE1) was for the Mi Band 5/6 and was discarded.

### Services and Characteristics (BLE V2)

| UUID | Function |
|---|---|
| `0000FE95-0000-1000-8000-00805F9B34FB` | Xiaomi BLE V2 Service (the only relevant service) |
| `0000005E-0000-1000-8000-00805F9B34FB` | TX — write (app → band, without response) |
| `0000005F-0000-1000-8000-00805F9B34FB` | RX — notify (band → app) |
| `0000180D-0000-1000-8000-00805F9B34FB` | Heart Rate Service (standard GATT) |
| `0000180F-0000-1000-8000-00805F9B34FB` | Battery Service (standard GATT) — what iOS reads for the Batteries widget |
| `00002A19-0000-1000-8000-00805F9B34FB` | Battery Level — `UInt8` 0–100, read + notify (read **only post-auth**, see `CheckBandBatteryIntent`) |

### Frame Format — XiaomiSppPacketV2

8-byte header (confirmed in `XiaomiSppPacketV2.java`; see `BandProtocol.swift`):

```
[0xA5][0xA5]   preamble (2 bytes)
[type]         lower 4 bits = packetType: 1=ACK, 2=SESSION_CONFIG, 3=DATA
[seqNum]       sequence counter (UInt8)
[lenLo][lenHi] payload length (UInt16 LE)
[crcLo][crcHi] CRC-16/ARC of the PAYLOAD only (poly=0x8005, refin/refout, init=0)
[payload...]   payload bytes
```

Payload of a DATA packet (inside the payload above):
```
[channel]  lower 4 bits: 1=PROTOBUF, 2=DATA, 5=ACTIVITY
[opCode]   1=PLAINTEXT, 2=ENCRYPTED (AES-CTR, encryptV2/decryptV2 with IV=key)
[bytes...] Command protobuf (or encrypted bytes, if opCode=2)
```

**Reliable transport (window/ACK).** SPP V2 negotiates `TX_WIN` and numbers the packets. **Every DATA frame received from the band must be acknowledged** with an ACK packet (`type=1`) carrying the same `seqNum` (`BandManager.sendAck`). Without the ACK, the band assumes loss and retransmits the whole handshake every ~6 s. DATA packets sent by the app use their own incrementing counter (`nextSeq`).

**Protobuf via SwiftProtobuf.** The `Command`, `Auth`, `WatchNonce`, `Health`, `System`, etc. messages come from the types generated in `BLE/Protocol/xiaomi.pb.swift` (generated from GadgetBridge's `xiaomi.proto`). `XiaomiProto.swift` is only the thin layer of builders/parsers.

### Authentication Flow (HMAC-SHA256 V2)

1. **Connect** to the BLE device (name `Xiaomi Smart Band 10 XXXX`)
2. **Discover** service `FE95` → characteristics `005E` (TX) and `005F` (RX)
3. **Enable notifications** on `005F`
4. **Session config**: send `Command{type=0, sub=1, payload={mtu=512, version=2}}` on the COMMAND channel
5. **CMD_NONCE** (type=1, sub=26): send the app's 16-byte random nonce
6. **Band responds**: `watchNonce(16) + HMAC-SHA256(watchNonce+phoneNonce, secretKey)(32)`
7. **Verify the band's HMAC**
8. **Derive session keys**:
   ```
   prk = HMAC-SHA256(phoneNonce + watchNonce, secretKey)
   keys[0..63] = HKDF-expand(prk, "miwear-auth", 64)
   decryptionKey  = keys[0..15]
   encryptionKey  = keys[16..31]
   decryptionNonce = keys[32..35]
   encryptionNonce = keys[36..39]
   ```
9. **CMD_AUTH** (type=1, sub=27): `authStep3 { encryptedNonces = HMAC-SHA256(phoneNonce+watchNonce, encKey), encryptedDeviceInfo = AES-128-CCM(authDeviceInfo) }`
   - CCM nonce = `encryptionNonce(4) || zeros(4) || counter=0(4)`
   - Post-auth communication uses AES-CTR with a V2 quirk: **IV = key** (GadgetBridge: "I wish I was kidding")
10. **Band responds** `sub=27` → **Authenticated**, encrypted communication
11. **Mandatory post-auth init** (`sendPostAuthInit`): `setCurrentTime` + `device info (2/2)` + `device state (2/78)` + `battery (2/1)`. Without it the band re-triggers auth every ~6 s.

> **First pairing — the app waits for the user, through two prompts and across the link drop between them** (decision and trade-offs in `docs/adr/0003-patient-band-driven-handshake.md`, including the 2026-09-09 addendum)**.** The first connection asks for **two** confirmations, in order and on different screens: the band raises its own dialog (`auth sub=16`, a subtype GadgetBridge does not even handle) and only then iOS raises the Bluetooth pairing sheet — and to establish the bond **iOS drops the connection**. That is why the wait is a **180 s deadline (`pairingDeadline`) that spans connections**, not a state of the current connection: `resetState` clears only the per-connection flag and `startNonceExchange` restores the wait on reconnecting within the window. While it is open: a mismatched HMAC is expected (the band signs with a bond that does not exist yet) and only extends the window, the watchdog re-arms, and the `retryAuthAfterReconnect` budget **is not spent** — a slow pairing must not end in `badHMAC` ("Wrong AuthKey"). A mismatch on a band we have never authenticated against (`everAuthenticated`, `UserDefaults`) starts the wait instead of counting it. `CBATTError.insufficientAuthentication` on a write **is not a failure**: it is iOS signalling that it is about to ask for pairing — it is the only concrete signal of the second prompt, and it used to kill the handshake the instant the sheet came up. `CBError.peerRemovedPairingInformation` → `AuthError.staleBond` (forget the device in Settings › Bluetooth; reconnecting never fixes it). `PairingStage` (`.band` → `.phone`, only moves forward) feeds the two-step checklist on the connection screen and **does not decide protocol logic**. The `sub=16` and the pre-accept mismatches are confirmed on hardware (Mi Band 10, 2026-06-19 and 2026-09-05); the **full accept path** has **not** been exercised yet — the logs came from an already-paired band and from attempts that were failing.

> **The band reopens the session on its own — and that invalidates the keys.** Right after the post-auth init it sends a new `session-config-accept`, resets its own sequence counter and redoes the handshake (new watch-nonce, new `sub=27`). GadgetBridge (`XiaomiBleProtocolV2.processPacket`, `PACKET_TYPE_SESSION_CONFIG`) calls `startEncryptedHandshake()` on **every** session config packet, regardless of state — that is why. Ignoring that packet leaves the app with the old keys: the band ACKs the transport frame and **silently drops the command**, so the sync hangs until the timeout while the link looks perfect. `handleSessionConfigResponse` redoes the handshake when the state is `.connected` (limit `maxBandSessionRestarts`), and only ignores a repeat that arrives with the handshake still in flight (`.authenticating`) — which is where the 005F bug lived. Confirmed on hardware (2026-09-05).
>
> **The restart lands exactly where the sync starts.** `ensureConnected` resolves on the first auth, so a sync that opened the link sends `FETCH_TODAY` inside the restart window — and it gets lost. `BandManager.onSessionRestart` notifies `BandSyncer`, which fails the in-flight command exchange immediately (`SyncError.sessionRestarted`) and re-sends it after the re-handshake (`surviveSessionRestart` + `BandManager.awaitSession`), for listings and files. `ensureConnected` called with a handshake in progress just waits (reconnecting on top of it redid service discovery and fired a second `authenticate()`). Once `maxBandSessionRestarts` is exceeded, the link is dropped so the standing reconnect starts over clean.

> **Late nonce ≠ failure.** After `CMD_AUTH`, the band re-issues its own watch-nonce — a handshake restart on its side, not a reply to ours. Verifying it against the already-superseded phone-nonce **always** fails; the band confirms the original handshake anyway. `authStep3Sent` makes the app ignore nonces while `CMD_AUTH` is in flight and wait for `sub=27`. For the same reason (a nonce already on the air when our `CMD_NONCE` went out was signed against a phone-nonce the band had not seen yet), `maxNonceMismatches` tolerates 2 mismatches per nonce exchange before escalating — a genuinely wrong AuthKey always mismatches and still ends in `AuthError.badHMAC`. Without this, the same packet brought down a handshake one step from success (hardware log 2026-09-05, where both orders appear: the late nonce before `sub=27` killed the connection, after `sub=27` it was harmless).

> **Auth watchdog.** `armAuthWatchdog()` — 20 s normally, 120 s during pairing — re-armed by every auth packet that makes progress. Before, `AuthError.timeout` only came out of a disconnect: "Authentication timed out." really meant "the link dropped" (now `AuthError.linkDropped`) and a band that went silent hung forever. When it fires **outside** a pairing, the watchdog drops the link so the standing reconnect takes over; inside the pairing window it only re-arms (silence there is a person reading a dialog) and only fails when the window expires, with `AuthError.pairingNotConfirmed`. `retryAuthAfterReconnect` delays the teardown with a growing delay (1–4 s) — reconnecting immediately burned the 4 attempts in seconds.

> The AuthKey (secretKey) is 16 bytes (32 hex chars). Keychain with `kSecAttrAccessibleAfterFirstUnlock`. Never in SwiftData/UserDefaults/logs. Nonces and HMACs **may** be logged in debug (they are not secrets); session keys and the AuthKey, never.

> **The key must survive updates, renames and relaunches** (see `docs/adr/0004-authkey-keychain-durability.md`)**.** `AuthKeyStore` indexes the item by a **fixed** `service` (`com.myband.authkey`), not by the bundle id read at runtime — otherwise a bundle/target rename would make the app present itself as unpaired with the key intact under the old name; the legacy item (bundle id) is migrated on first read. `save` updates in place (the earlier `delete`+`add` lost the key if the add failed) and the item is pinned as **non-synchronizable**, so no iCloud Keychain entry shadows the local one. `isStored` distinguishes `errSecItemNotFound` from `errSecInteractionNotAllowed`: on a background relaunch **before the first unlock after boot** the key exists but is unreadable, and answering "no key" there sent an already-paired user back to setup.

### Sync Commands

| Command | type | subtype | Description |
|---|---|---|---|
| Fetch today | 8 | 1 | Lists the day's pending activity file-ids |
| Fetch past | 8 | 2 | Lists the backlog of days not yet synced |
| Fetch request | 8 | 3 | Requests the content of a file-id (streamed in chunks) |
| Fetch ACK | 8 | 5 | Marks a file-id as synced |

### Band-initiated commands (band → app)

Some features are **push** from the band: it sends the command and the app reacts. `BandManager` decodes them after auth and fires callbacks (`onWorkoutOpenWatch`, `onWorkoutStatusWatch`, `onFindPhone`, `onWeatherConditionsRequest`), consumed by dedicated services.

| Command | type | subtype | Handled by | Reaction |
|---|---|---|---|---|
| `CMD_FIND_PHONE` | 2 (SYSTEM) | 17 | `FindPhoneService` | `system.findDevice` 0=start / ≠0=stop. Alarm: `AVAudioSession.playback` + synthesized looping siren + vibration + notification. Auto-stop after 45 s. |
| `workoutOpenWatch` | 8 (HEALTH) | 30 | `WorkoutGpsService` | Starts CoreLocation and replies GPS ready/disabled |
| `workoutStatusWatch` | 8 (HEALTH) | 26 | `WorkoutGpsService` | started/resumed/paused/finished → controls the GPS stream (paused stops transmitting); on **finished** fires `onWorkoutFinished(fileIds)` → `BandSyncer.syncWorkoutFiles` fetches the named files (summary + GPS route); a **started** can arrive just before the band's `workoutOpenWatch` and is not repeated, so the open handler never clears it (hardware 2026-11-01) |
| `CMD_REQUEST_CONDITIONS_FOR_LOCATION` | 10 (WEATHER) | 3 | `WeatherSyncService` | Band asks for the weather (on connect / on opening the weather screen) → app replies with a weather push, echoing the requested location key/name. See "Configuration sent to the band". |

> **The end of a workout triggers an automatic, targeted sync.** `workoutStatusWatch` status=finished **carries the `activityFileIds`** of the just-recorded workout (summary + GPS route). `BandManager` passes them on in the callback (`onWorkoutStatusWatch(status, fileIds)`) → `WorkoutGpsService.onWorkoutFinished(fileIds)` → `BandSyncer` waits ~8 s (for the band to flush the file) and runs `syncWorkoutFiles(_:)` if still connected, fetching/parsing/writing/ACKing **exactly** those files — without re-listing the backlog (FETCH_TODAY/PAST). Firmware that omits the ids falls back to the full `syncToHealth()`. The per-file processing loop is shared in `BandSyncer.processActivityFiles`. Daily totals, which the workout also updates, are left for the next regular sync.
>
> **There is no equivalent trigger for "woke up".** The Mi Band 10 does not send an end-of-sleep event; sleep is only fetched when the app runs the fetch (foreground or `BackgroundSyncManager`). Outside the end of a workout, the model remains **pull**: the app reconnects and fetches the pending file-ids.

### Configuration sent to the band (app → band)

`CalendarSyncService` (language/calendar/reminders) and `WeatherSyncService` (weather, via Open-Meteo) do an encrypted push at the end of `BandSyncer.syncToHealth()`, together with the health/exercise data and while the link is up (best-effort — it does not bring down the health sync). Each section is independent — a denied permission or no network does not block the others. The calendar and iPhone-reminders sections can be switched off in Band settings › Copies on the band (`CalendarSyncService.pushCalendarKey` / `pushRemindersKey`, `UserDefaults`, on by default); off clears the app's pushed copies on the next sync.

| Data | type | subtype | Proto | Source / notes |
|---|---|---|---|---|
| Language | 2 (SYSTEM) | 6 `CMD_LANGUAGE` | `system.language.code` | `Locale` → lowercase `"pt_br"` |
| Calendar | 12 | 1 `CMD_CALENDAR_SET` | `calendar.calendarSync.event[]` | EventKit, next 30 days, ≤50, **replaces** the set on the band |
| Reminder (list) | 17 (SCHEDULE) | 14 `CMD_REMINDERS_GET` | `schedule.reminders` | the band's list (ids, title/time, `maxReminders`), read before each push |
| Reminder (create) | 17 | 15 `CMD_REMINDERS_CREATE` | `schedule.createReminder` | EventKit, one band reminder per timed alert still to come (else due date › 09:00 if date only); for a plain daily/weekly/monthly/yearly repeat a passed alert rolls to its next time; ≤20 and ≤ the band's free slots |
| Reminder (delete) | 17 | 18 `CMD_REMINDERS_DELETE` | `schedule.deleteReminder.id[]` | deletes only this app's reminders before recreating |
| Weather (location) | 10 | 7 `CMD_ADD_LOCATION` | `weather.location` | `WeatherSyncService`, key `accu:<hash>` |
| Weather (current) | 10 | 0 `CMD_SET_CURRENT_WEATHER` | `weather.current` | Open-Meteo, Guarapuava |
| Weather (forecast) | 10 | 1 `CMD_UPDATE_DAILY_FORECAST` | `weather.forecast` | 7 days (today + 6) |

> **Weather is request-driven — the band asks, the app answers.** The Mi Band 10 sends `CMD_REQUEST_CONDITIONS_FOR_LOCATION` (type=10, subtype=3) on connect and on opening the weather screen; the screen is **waiting for the reply to that request**, so the proactive push (at the end of `syncToHealth()`) alone does not populate the widget. `BandManager.handleWeatherCommand` routes subtype=3 to the `onWeatherConditionsRequest` callback, and `WeatherSyncService` replies with a full push (location → current → forecast). The reply **echoes the location key/name the band asked for** (`requestedKey`/`requestedName`) so it can bind the data; without a request, the push uses the default location with `isCurrentLocation=true`. Status≠0 in the band's replies to our pushes (subtypes 0/1/7) is logged. Mirrors GadgetBridge's `XiaomiWeatherService.onConditionRequestReceived`.

> **Reminders created in the app.** The Reminders page, to the right of Workouts (`ReminderService`), creates reminders directly on the band, with a title (≤20 characters, GadgetBridge's limit, not confirmed on the Band 10), date/time and repeat (`repeatMode` 0/1/5/7/8 = once/daily/weekly/monthly/yearly; weekly carries the weekday in `repeatFlags` as the alarms' bitmask, Mon=1…Sun=64 — not GadgetBridge's weekday number Mon=1…Sun=7, which the band read as a bitmask: a Saturday sent as 6 fired on Tuesday and Wednesday, confirmed on hardware 2026-11-11). The proto has only one time per reminder: "every day at 10, 13, 16 and 19" becomes four daily reminders with the same title (one slot each, checked together before sending), grouped into one row on screen. The limit comes from the list's `maxReminders`; without it, the app does not limit. `ReminderService` is the **sole** owner of `onReminderList`/`onScheduleAck` — `CalendarSyncService` uses its `fetchList`/`create` — and matches each ack to the oldest pending create (the band replies in order). Reminders created here are kept in `UserDefaults` by title+time (not by the ack id, which a lost ack would shift; `ReminderService.key` — a repeating reminder keys only the date parts its repeat keeps, because the band lists it with the date moved on to its next firing) and the push of the iPhone's reminders never deletes them; only the oldest band reminder per key is protected, so a pushed copy with the same title, repeat and time stays the push's.
>
> **The reminder id is assigned by the band.** The create carries no id; the band replies with `schedule.ackId` (type=17, subtype=15). `ReminderService` captures those ids (`BandManager.onScheduleAck`) and passes them to `CalendarSyncService`, which persists them (`UserDefaults`) together with the title and time of each reminder sent. On the next sync it reads the band's list (`onReminderList`) and deletes the ids it knows **and** those that match what it sent by title, repeat and time (`ReminderService.key`). A reminder it meant to delete stays its own until the band stops listing it (`CalendarSyncService.owned`), and a delete the band didn't take leaves the signature unsaved, so the next sync retries — neither a lost ack nor a lost delete leaves an orphan firing forever. Once per install (`myband.reminderTitleCleanupDone.2`, renamed so it ran again after repeating reminders were keyed without their date) it also deletes any unprotected reminder titled like one the previous push sent, to clear copies the old date-keyed matching lost, including those of iPhone reminders since completed; that one pass can also delete a same-titled reminder another app created, every later push leaves those alone. Without the list, the push is postponed to the next sync. `Forget band` clears this state (`CalendarSyncService.forgetBand`).

> **Frames > MTU.** A calendar with many events exceeds the ATT MTU. `BandManager.writeSPP` fragments the frame into MTU-sized chunks (`maximumWriteValueLength`); the band reassembles them by the length declared in the frame. Auth/init packets fit in one chunk — the handshake path is unchanged.

The same file-id mechanism serves **all** data types — each 7-byte id (`XiaomiActivityFileMeta`) declares its type/subtype/detailType, and `BandSyncer.syncToHealth()` routes it to the right parser:

| File type | subtype | Parser |
|---|---|---|
| Daily summary | `0x00` SUMMARY | `DailySummaryParser` |
| Daily detail (per minute) | `0x00` DETAILS | `DailyDetailsParser` |
| Sleep (by duration) | `0x08` (any detail) | `SleepDetailsParser` (see note) |
| Sleep (by transition) | `0x03` DETAILS | `SleepStagesParser` (see note) |
| Manual measurements | `0x06` | `ManualSamplesParser` |
| Workout (summary) | SPORTS · SUMMARY | `WorkoutSummaryParser` |
| Workout (GPS route) | SPORTS · GPS | `WorkoutGpsParser` |
| Workout (HR/sec detail) | SPORTS · DETAILS | `WorkoutDetailsParser` |

> **Per-second workout HR series (`WorkoutDetailsParser`).** During a workout the band records a `SPORTS · DETAILS` file (subtype `0x08`) with **one HR sample per second**. GadgetBridge does **not** parse it (`XiaomiActivityParser.createForSports` only handles `SUMMARY`/`GPS_TRACK` and discards the rest), so the layout was reverse-engineered from a real capture (Mi Band 10, 2026-06-23, version 3) and validated by CRC-32: `[id:7][pad:1][header:11]` with the duration (s) at `u16@10` (== number of samples), followed by `duration` samples `[hr:u8][flag:u8][00][00]`, 1 Hz from the start (hr=0 during the ~18 s of sensor acquisition; `flag=1` every ~12 samples, a keyframe — ignored). `BandSyncer` matches the series to the workout by timestamp (same as the GPS route) and `HealthKitManager.writeWorkouts` attaches the samples to the `HKWorkout` (in the builder, before `finishWorkout`, sync-id per sample). Only version 3 is confirmed; other versions → empty series (the file is still ACKed). For other subtypes/versions of `SPORTS · DETAILS` (e.g. `0x16`, version 5) the parser returns empty and the `else` branch of `processActivityFiles` just ACKs — without the ACK the band re-offers the file on every connection (perpetual re-download; one of them was 12 KB). New fixtures: `dumpActivityFileFixture` (DEBUG).

Sleep `0x08`: each stage entry is a UInt16 BE — bits[15:12]=stage (0=awake,1=light,2=deep,3=rem), bits[11:0]=duration_min.

> **Two sleep formats.** GadgetBridge uses `SleepStagesParser` for `0x03` (ACTIVITY_SLEEP_STAGES, a layout of **transition events**, stage codes `2=deep,3=light,4=rem,5=awake`) and `SleepDetailsParser` for `0x08` (a layout by **duration**). **Validated on hardware (Mi Band 10, 2026-06-21): the real sleep fetch works with `SleepDetailsParser` — the band emits `0x08`.** `0x03` used to fall into the same parser, which read the bytes at the wrong offsets; it now goes to the ported `SleepStagesParser` (version 2 only, as in GadgetBridge; covered by a synthetic file, **not** by a real capture). Versions of `0x08` outside 1–5 return empty instead of guessing the layout. In v5 the header bitmask is 2 bytes (real header `DF C0`): HR is bit 8, SpO₂ bit 9, snore bit 10. One file carries a summary + stages pair per **re-scoring** of the night, each covering it from bedtime and re-classifying earlier stretches; the latest wins where they overlap (`latestRevisionWins`), pinned by a real v5 capture in `SleepFixtures.swift`. `BandSyncer` logs one line per sleep file (`Sleep file … N session(s), N phase(s), N HR, N SpO₂`) — that line is how you see, in the console, whether a night arrived and in which format. A night with no stage packets whose summary has zero stage minutes but a `sleep_duration` (type-16 bytes 1–2) is a **short nap**: once the band closed it (`awakeFlag` ≠ 0, the header's isAwake byte) it becomes one `.unspecified` phase, written as `asleepUnspecified` (the band did not classify those minutes); while still open (`awakeFlag` 0) it has no session, and a file left with nothing to write is not ACKed (`shouldHoldOpenSleepFile`), so the band offers it again once closed. Not yet seen on hardware.
>
> **Stored nights can be re-parsed.** Each `SleepSession` keeps the raw file (`rawData`, external storage), but only the report reaching furthest among those with the same bedtime and file subtype keeps it (each such file contains the earlier ones), and only for 90 days (expiry runs at most once a day, in the foreground). A same-hash record is the same file only if its stored byte count matches. When `BandSyncer.sleepParserRevision` differs from the one applied (`UserDefaults`), the first foreground sync with the iPhone unlocked and sleep writable re-parses every stored file — at the end of `syncToHealth`, after the band's files and the config pushes — and rewrites those nights (phases and sleep HR/SpO₂) in Apple Health: every night's old ∪ new window is cleared first (`HealthKitManager.clearSleep`), then each night is written on its own; a failed night, or one with samples dropped for permission, keeps the revision unapplied, so the next sync retries. Dates go through `ParsedSleep.inRange`, as on the regular path. **Bump the revision whenever a sleep parser reads the same bytes differently.** Nights stored before raw files were kept have nothing to re-read.
>
> **A sleep file is never acknowledged without being read, and it never brings down the rest.** If the band answers a fetch with another file still un-ACKed, that file is routed normally and only then ACKed (it used to be ACKed blindly, losing its content); a sleep file only after its night is written to Health and the local sessions are saved, and a band stuck on a sleep file that can't be written ends the fetch (the sync is then not marked done, so the next wake retries); one written but held un-ACKed is skipped. A corrupt-dated session is dropped, not stored, and its file is still ACKed so it doesn't come back every sync. Writing sleep runs isolated in `processActivityFiles`: if it throws, only the sleep files stay un-ACKed and come back on the next sync — manual measurements, workouts and daily detail carry on. Each file fetch uses an **inactivity** timeout (10 s without a chunk), not a fixed ceiling.

### Installing watch faces and apps (app → band)

Customization feature (`BLE/Upload/`), ported from GadgetBridge. The proto messages were already in `xiaomi.pb.swift`. **Does not touch firmware** (`TYPE_FIRMWARE=32`) — brick risk.

| Layer | type | subtypes | Service |
|---|---|---|---|
| Watch faces | 4 | list=0, set=1, delete=2, install=4 | `WatchfaceService` |
| Apps (RPK / quick apps) | 20 | list=0, install=1, installed=2, delete=3 | `AppInstallService` |
| Chunked upload | 22 | uploadStart=0 | `DataUploadService` |

**Install flow (identical for faces and apps, only the type tag changes):**
1. App announces the file: faces `watchfaceInstallStart{id,size}`; apps `rpkInfo{id,versionCode,size}`.
2. Band replies with a status (faces `watchface.installStatus`; apps `rpk.rpkInstallStart.cmd`). `0` = accepted.
3. App opens the upload: `CMD_UPLOAD_START{type, md5(file), size}` (type **16**=watchface, **64**=rpk).
4. Band replies `dataUploadAck{unknown2, resumePosition, chunkSize (default 2048)}` — supports resuming.
5. App builds the envelope and transmits it in chunks:
   ```
   envelope = [0x00][type][md5:16][size:u32 LE][file bytes from resumePosition]
   payload  = envelope + crc32(envelope):u32 LE
   chunk    = [totalParts:u16 LE][currentPart:u16 LE][slice of (chunkSize-4) bytes]
   ```
6. Watch face: when done, the app sends `set` (activate) + `list`. RPK app: the band sends `installed` (sub=2) and the app requests `list`.

> **Upload chunks go on the DATA channel (2) in plaintext** — `XiaomiSppPacket.buildDataChunk`, opCode PLAINTEXT (GadgetBridge: `CHANNEL_DATA → OPCODE_SEND_PLAINTEXT`). Unlike commands (PROTOBUF channel, AES-CTR): the envelope protects itself with md5 + crc32. `BandManager.sendDataChunk` does **pacing** against CoreBluetooth's `writeWithoutResponse` buffer via `peripheralIsReady(toSendWriteWithoutResponse:)`, otherwise a large upload overflows the buffer and loses frames.

> **File formats** (`InstallableFile`): watch face = binary, magic `0x5A 0xA5`, NUL-terminated numeric id at `0x28`, name at `0x68`. App = ZIP with `manifest.json` (`package`/`name`/`versionCode`), read by `MiniZip` (Foundation does not decompress ZIP entries on iOS) + inflate via the `Compression` framework (`COMPRESSION_ZLIB` = raw deflate).

> **To validate on hardware:** the exact channel for the chunks (DATA=2) and the pacing; and whether the Mi Band 10 accepts community faces (there may be a region/model lock). Import via document picker (Files), download by URL and share sheet (`onOpenURL` + `CFBundleDocumentTypes`).

### Background BLE on iOS

- `bluetooth-central` configured via `INFOPLIST_KEY_UIBackgroundModes = "bluetooth-central"` in `project.pbxproj` (not in a separate Info.plist — see "Known Pitfalls")
- `CBCentralManager` instantiated with `CBCentralManagerOptionRestoreIdentifierKey: "com.myband.central"` for state restoration
- Implement `centralManager(_:willRestoreState:)` to reconnect after the app is suspended
- Automatic reconnect via `connect(_:options:)` on receiving `didDisconnectPeripheral`, with exponential backoff (max. 5 attempts)

### Sync orchestration

`BackgroundSyncManager` is the **single entry point** for every sync (foreground or background). Every trigger goes through `syncNow(disconnectWhenDone:)`, which **coalesces** concurrent calls into a single in-flight `Task` — the Dashboard button, App Intent/Siri, BGTask and the BLE wake never fire two fetches at once. `disconnectWhenDone`: `nil` = only disconnects if the sync itself opened the link (a live foreground link stays up); `true`/`false` forces it (background wakes pass `true` to free the radio). After a successful sync the release waits for `BandManager.drainWrites` (write queue drained + 0.75 s grace, 3 s ceiling), so the last fire-and-forget file ACKs can leave before the link drops, on a failed sync too (CoreBluetooth reports no delivery, so the grace is an estimate). `syncToHealth()`/`syncWorkoutFiles()` also have a reentrancy guard (`!isSyncing`), serialized by `@MainActor` (guard + set before the first `await`).

Background triggers, in order of frequency/reliability:
1. **BLE wake (state restoration).** When the band comes back into range, CoreBluetooth relaunches the app; on authenticating, `BandSyncer.onAuthenticated` calls `syncOnBackgroundWakeIfStale()` — it only runs in the background, throttled by `lastHealthSync` (15 min), and disconnects at the end. It is the most reliable path (the BLE event is what wakes the app); the throttle is skipped when a sync with the iPhone locked left files for later (`BandSyncer.filesAwaitingUnlock`).
2. **`BGAppRefreshTask`** (`com.myband.refresh`) — light, scheduled frequently by the OS.
3. **`BGProcessingTask`** (`com.myband.sync`) — heavy/deferrable, usually runs while charging.
4. **iPhone unlock.** If the last sync, done with the iPhone locked, left un-ACKed files, `protectedDataDidBecomeAvailable` fires `syncNow` — only if the app is alive at that moment.

Both BGTasks are registered in `register()` (from `AppDelegate.didFinishLaunching` — the only window `BGTaskScheduler.register` allows) and rescheduled in `scheduleNext()` on going to the background (`scenePhase`). `Info.plist`: both ids in `BGTaskSchedulerPermittedIdentifiers` and the background modes `fetch` (app-refresh) + `processing`. On a cold launch triggered by a task or an intent, the sync calls the idempotent `AppServices.bootstrap` itself (`ensureDependencies()`), as each intent's `perform()` does, so it never depends on which launch path ran first. The `expirationHandler` is installed **in the `register` closure itself**, on the scheduler's queue, before the hop to the main actor — that hop has taken 6 s in a freshly resumed app, and a task that expires without a handler is completed as failed by iOS (which then schedules less). `finish(_:success:)` guarantees a single `setTaskCompleted`, whether it comes from the sync or from the expiration.

> The end of a workout has its own path (`handleWorkoutFinished`): it waits ~8 s for the file flush and fetches the named file-ids via `syncWorkoutFiles`, without going through `syncNow` (but protected by the same `!isSyncing` guard).

---

## AuthKey Extraction

Onboarding (`UI/Setup/SetupView.swift`) is a step machine: `intro → choose → (xiaomi | key) → connection`. The `choose` screen offers both methods; both end up producing a 32-char hex that goes through `AuthKeyStore.saveHex` (validation + Keychain) and on to `ConnectingView` (the same `onConnect` in `RootView`).

### Method 1 — Manual Input (`SetupView.keyEntry`)
- The user obtains the AuthKey via external tools (GadgetBridge export, `token_extractor/`, Xiaomi Cloud) and pastes it into the field
- The app shows a 32-character hex field with validation
- Save in the Keychain with `kSecAttrAccessibleAfterFirstUnlock` (accessible in the background)
- It is the **fallback** for every failure of method 2 (an "Enter AuthKey manually" link at each step)

### Method 2 — Xiaomi Cloud via username/password (`Auth/XiaomiCloudAuth.swift`, `UI/Setup/XiaomiLoginView.swift`)
Ports `PasswordXiaomiCloudConnector` from `token_extractor/token_extractor.py` — login with the Xiaomi account username and password, typed on this screen. It replaced the earlier QR flow (`QrCodeXiaomiCloudConnector`): a **deliberate trade-off** — the QR version never exposed the password to the app (authentication happened entirely on Xiaomi's side), but it depended on a second device or on a fragile long-poll while the user left and returned to the app. Login+password is more direct and depends on nothing else, at the cost of the password passing through the My Band process memory — never persisted, never logged, only used to build the MD5 hash and the encrypted body of the login POST. Flow (mirrors the Python steps):

1. `GET serviceLogin` → `_sign` (rarely, a ready session with `ssecurity` already comes back)
2. `POST serviceLoginAuth2` with `user` + `hash=MD5(password)` + `_sign` → `ssecurity`, `userId`, `location`
   - If `captchaUrl` comes back: show the image, the user types the text, re-send the POST with `captCode`
   - If `notificationUrl` comes back: it is email 2FA — follow the chain `identity/list` → `sendEmailTicket` → the user types the received code → `verifyEmail` → `identity/result/check` → `Auth2/end` (reads `ssecurity` from the non-standard header `extension-pragma`, which is why these calls use a delegate that **does not follow redirects** — only that way can the headers of the redirect response itself be read) → redirect to `sts.api.io.mi.com/sts`, which finally sets the `serviceToken` cookie
3. If step 2 did not already come with `serviceToken` (flow without 2FA): `GET location` → `serviceToken` cookie — this is the step that **confirms the login actually happened**, before moving on to the device lookup
4. For each region (`cn, de, us, ru, tw, sg, in, i2`), **encrypted** calls: `get_homes` + `get_dev_cnt` → homes; `get_devices` → devices; the Mi Band 10 is `miwear.watch.*` with a numeric `did` (does not contain `blt`) and already carries the AuthKey in the `token` field — it only falls back to `blt_get_beaconkey` for legacy BLE devices without an inline `token`
5. One band → auto-selects; several → the user chooses; the key goes into the same `onConnect`

- **Phase machine** (`XiaomiCloudAuth.Phase`): `idle → enteringCredentials → authenticating → [awaitingCaptcha | awaiting2FA] → confirmingLogin → fetchingDevices → done`. Captcha and 2FA suspend the login `Task` in a `CheckedContinuation` held on the instance; `submitCaptcha`/`submit2FACode` (called by the UI) resolve it — there is no polling, it is step by step.
- **API crypto** (`Auth/XiaomiCloudCrypto.swift`, separate from the BLE `XiaomiCrypto`): RC4/ARC4 with pycryptodome's **1024-byte keystream drop**, SHA-1, SHA-256 and MD5 (CryptoKit `Insecure.MD5` — only for compatibility with the endpoint's legacy password hash, not a security choice of ours). `signedNonce = base64(SHA256(b64dec(ssecurity) || b64dec(nonce)))`; each param is `base64(RC4(key=b64dec(signedNonce)))`; signature `base64(SHA1("POST&path&k=v&...&signedNonce"))` — **key order preserved** and **`quote_plus`** encoding (a replica of `requests.urlencode`, otherwise `+`/`/`/`=` break the signature or the `_sign`/password hash, which also go through the login query string). Path = everything after the first `"com"`, with `/app/` → `/`.
- **Ephemeral `URLSession`** with its own in-memory cookie jar — nothing from the login persists to disk.
- Debug logs (`[XiaomiCloud]`, DEBUG only) print status/cookies/token presence — **never** the values of the username, password, `serviceToken` or beaconkey/token.
- **To validate (real account):** the Xiaomi Cloud endpoints are fragile and region/account-dependent, and the email 2FA chain in particular chases several redirects and a non-standard header — ported faithfully from the reference, but not yet validated live (simple login, with captcha, and with 2FA).
- **Caution**: the token/beaconkey is the pairing secret — treated like the AuthKey (Keychain, never logged/persisted outside it).

---

## HealthKit

### Data Types to Write

| Mi Band data | HealthKit type |
|---|---|
| Sleep (start/end/phases) | `HKCategoryTypeIdentifier.sleepAnalysis` |
| Steps | `HKQuantityTypeIdentifier.stepCount` |
| Heart rate | `HKQuantityTypeIdentifier.heartRate` |
| SpO2 | `HKQuantityTypeIdentifier.oxygenSaturation` |
| Active calories | `HKQuantityTypeIdentifier.activeEnergyBurned` |
| Walking distance | `HKQuantityTypeIdentifier.distanceWalkingRunning` |
| Resting HR | `HKQuantityTypeIdentifier.restingHeartRate` |
| Body temperature (manual measurement) | `HKQuantityTypeIdentifier.bodyTemperature` |
| VO₂max (workout) | `HKQuantityTypeIdentifier.vo2Max` |
| Cycling / swimming distance (workout) | `HKQuantityTypeIdentifier.distanceCycling` / `.distanceSwimming` |
| Strokes (swimming) | `HKQuantityTypeIdentifier.swimmingStrokeCount` |
| Workout | `HKObjectType.workoutType()` via `HKWorkoutBuilder` (mapped to `HKWorkoutActivityType`) |
| Workout route (GPS) | `HKSeriesType.workoutRoute()` via `HKWorkoutRouteBuilder` (strength: the phone's sparse track, see below) |
| Post-strength heart rate (3 min, phone-captured from realtime stats) | `HKQuantityTypeIdentifier.heartRate` (`mb-recovery-<sec>`), associated with the workout |
| Weight (BLE scale) | `HKQuantityTypeIdentifier.bodyMass` (+ `.bodyMassIndex` derived from `.height` read from Health) |
| Physical effort (METs/min: band active kcal ÷ weight from Health) | `HKQuantityTypeIdentifier.physicalEffort` |
| Workout effort, 1–10 scale (average HR ÷ age-based max HR, Tanaka) | `.estimatedWorkoutEffortScore` (iOS 18+, via `relateWorkoutEffortSample`) |
| Heart rate recovery (peak at workout end − HR/min at end+60 s) | `HKQuantityTypeIdentifier.heartRateRecoveryOneMinute` |
| Workout speed (GPS V2 points, m/s) | `.runningSpeed` / `.cyclingSpeed` |
| Average running stride (distance ÷ steps) | `HKQuantityTypeIdentifier.runningStrideLength` |
| Rowing distance (iOS 18+; previously fell into walking distance) | `HKQuantityTypeIdentifier.distanceRowing` |

> **`appleStandHour` is NOT writable.** `HKCategoryTypeIdentifier.appleStandHour` is reserved (the system derives it from the Apple Watch). Including it in `requestAuthorization(toShare:)` throws `NSInvalidArgumentException`. The band's stand-hours mask stays local only — there is no "stand hour" type writable by third-party apps. The same goes for `appleExerciseTime`, `appleMoveTime`, `appleStandTime` (activity rings) and `walkingHeartRateAverage` — all read-only for third parties, no workaround.
>
> **Heart rate recovery runs on the daily file path, not in `writeWorkouts`.** The workout's 1 Hz series ends exactly at the end of the workout (count == duration), so the end+60 s reading only arrives in the following daily detail file. `writeHeartRateRecoveries` queries the **app's own** recent workouts in Health (independent of which sync recorded the workout), matches the peak of the last minute (1 Hz series, `HKStatisticsQuery` discreteMax) with the per-minute reading closest to end+60 s (±30 s) and writes the delta. Best-effort in `BandSyncer` — it does not block the files' ACKs.
>
> **Strength workouts get two phone-side extras** (`WorkoutGpsService`, matched in `StrengthWorkoutExtras`). The band records no GPS for strength, so the phone keeps a sparse track (one point per 10 min, plus the end) and `processActivityFiles` hands it to `writeWorkouts` as the route, only when the band's files carried no track within ±2 min; the stash entry is dropped once the workout files are ACKed with the route attached, so a workout written with the iPhone locked gets its route again on the unlocked rewrite. After the workout the phone records 3 min of realtime HR (`onRecoveryHRRecorded`); `BandSyncer` saves it as `heartRate` the moment the capture ends and associates it with the workout (`RecoveryPairing`): with the one already written, else held and linked when the workout is written. Both are in memory only, aged out after 48 h and cleared by `Forget band`; an aged-out entry loses only the link, the samples are already in Health. This is **not** heart rate recovery: it writes plain `heartRate` points after the workout's end (the window is not extended), never `heartRateRecoveryOneMinute`, which stays with `writeHeartRateRecoveries` and its per-minute reading. Both best-effort; neither holds an ACK. **Not yet validated on hardware**, including whether `add(_:to:)` accepts samples outside the workout's window.
>
> **Mobility stays iPhone-exclusive.** `walkingSpeed`/`walkingStepLength` are writable, but they would feed the Mobility metrics, which stay iPhone-exclusive on purpose — that is why the speed series is only written for running/cycling (`speedType(_:)` returns nil for walking/hiking) and the stride uses `runningStrideLength`, not `walkingStepLength`.

### Permissions (Info.plist)
```
NSHealthUpdateUsageDescription
NSHealthShareUsageDescription
```

### Deduplication
- Before writing, query existing samples in the period to avoid duplicates
- Use `HKQueryAnchor` with persistence in SwiftData for incremental syncs
- Every save batch keeps only the last sample per `HKMetadataKeySyncIdentifier` (`deduplicatingBySyncIdentifier`): a repeated identifier in one batch can fail the whole save
- Every band-data write drops samples dated outside `HealthKitManager.validDateRange` (2020-01-01 to now + 1 day): in `save`, and in the writers that bypass it (workouts, routes, sleep windows); corrupt band timestamps, never deleted from Health after the fact

> **Steps / distance / active energy: raw per minute, no reconciliation.** The iPhone records these same quantities; Apple Health **merges** overlapping samples from different sources by the Data Sources order (Health → Steps → Data Sources & Access) instead of summing them — that is what Apple's documentation describes and what better-mi-fitness-sync (open source, same task) assumes when writing raw values. `HealthKitManager.writeActivity` writes the band's value per minute (`mb-steps-rec-`, `mb-dist-rec-`, `mb-cal-rec-` + minute, monotonic version), without reading anything from Health — a locked iPhone refuses reads (`errorDatabaseInaccessible`) but accepts writes. The monotonic version makes each re-sync replace the previous sample for the same minute, including the surplus written by the old reconciliation (`max(0, band − iPhone)`); old minutes the band does not re-offer keep the surplus, with no deletion pass (the per-minute detail is not kept locally). For the iPhone to win the shared minutes, it must sit **above** My Band in the source order (new apps enter at the top). **Not yet validated on hardware.** The earlier observation of a doubled walk (200 → 400) was made with a whole-day steps sample written by `writeDailySummary`, not with per-minute samples.
>
> **The authoritative source of these three quantities is the daily detail file (per minute).** `writeDailySummary` does not write steps/energy: a whole-day sample would win or lose the entire day against the iPhone, instead of minute by minute. It only writes band-exclusive extremes (HR/SpO₂, resting HR). Distance and energy inside a workout are left out (the workout's own samples already carry them); steps are not. **SpO₂** (the iPhone has no such sensor) stays raw per minute in `writeMinuteSamples`. With the iPhone locked everything is written, but the sleep, workout and daily detail files stay un-ACKed (`UIApplication.isProtectedDataAvailable`; sleep is written without the window cleanup, which requires a read): weight, age, sleep cleanup and heart rate recovery read from Health, and an unlocked sync rewrites them under the same sync-ids. The recorded workout windows are kept in `WorkoutWindows` (30 days), so that a daily detail from a later sync still excludes the workout's distance/energy.

---

## BLE Scale (OKOK/Chipsea)

`BLE/Scale/` integrates an OKOK/Chipsea BLE scale, **independent of the band** (its own CoreBluetooth). It ports the weight paths of the [homeassistant-okokscale](https://github.com/rrooggiieerr/homeassistant-okokscale) integration (Apache-2.0).

- **`ScaleWeightParser`** — decodes the weight from the BLE advertisement's *manufacturer data* (`[companyId:2 LE][payload]`). **VC0** variant (validated on hardware, "Yoda1" scale): matched by the **company id's low byte = `0xC0`** (mirrors the integration's `key & 0xFF == 0xC0`); 13-byte payload, weight in `bytes[0..1]` BE, `byte[6]` carries the unit (`(b>>3)&3`: 0=kg, 2=lb, 3=st:lb) and the **final bit** (`b&1`). Normalizes everything to kg.
- **`ScaleManager`** (`@Observable @MainActor NSObject`) — only **scans**, never connects. Writes one weigh-in at a time: any zero/non-final frame **re-arms** (`lastFinalWeight = nil`), and a new non-zero final frame counts as a new weigh-in (stepping on again at the same weight logs again). Writes via `HealthKitManager.writeBodyMass` (`bodyMass` + `bodyMassIndex` when there is a `height` in Health), sync-id by timestamp (idempotent).

> **The scale is broadcast-only.** Confirmed on hardware: it **does not accept a GATT connection** (every `connect` times out, even during the measurement) and **does not advertise a service UUID**. Consequences: (1) listening is **foreground-only** — a scan without a service filter does not work in the background on iOS (the band, with state restoration by UUID, keeps working in the background normally); (2) **only the weight is recoverable**. Impedance **does not reach the phone** — the advertisement carries only the weight (bytes 2-3 are a constant `0x1388`, not impedance) and there is no GATT. The body composition numbers in the OKOK app (fat %, lean mass, water…) are an **estimate from weight + profile**, not real bioimpedance: validated by observing that all the metrics move **monotonically with weight** between two weigh-ins. That is why My Band writes only `bodyMass`/`bodyMassIndex` (measured data), not estimated body composition.

---

## App Intents and Shortcuts

> **Home Assistant was cut from the roadmap** (decision recorded only here, it never had any code — see conversation/history). The direct REST integration this document once specified will not be built. In place of the triggers it would have offered (sleep detected, HR above a threshold), the app exposes **state via App Intent** and leaves the automation entirely to the user's own Shortcuts Personal Automations — without the app needing to know anything about lights, scenes or third-party scripts.

### Available Intents

| Intent | Parameters | Returns |
|---|---|---|
| `SyncBandIntent` | — | Sync status |
| `GetSleepStateIntent` | — | `Bool` (asleep?) + dialog with the age of the data |
| `CheckBandBatteryIntent` | `threshold: Int` (1–100, default 30) | `Int?` (level) + local notification **only** if below the threshold |
| `RunBandMiniAppIntent` | `appId: String` | (Future phase) |

> **`GetSleepStateIntent` is pull, not push.** The band has no "fell asleep"/"woke up" event (see "Band-initiated commands" above) — sleep is only known after the app syncs. The intent forces a sync (`BackgroundSyncManager.shared.syncNow()`, best-effort — a failure is not fatal; the intent waits at most `intentDeadline`, 15 s, then answers from local data while the sync runs on) before answering, and reads the report ending last (ties: latest fetch; `SleepStateRule`). It is "asleep" only if the band still has that night open (`awakeFlag` 0) and the night was still growing at its last fetch: fetched under 1 h ago, ending within 5 min of the fetch, last phase not `.awake`. While a night is open its end keeps pace with each sync and freezes when the user wakes, about an hour before the flag turns 1. Reports stored before `awakeFlag`/`fetchedAt` were kept fall back to the old rule: ended between 0 and 1 h ago and last phase not `.awake`. An end more than 5 min past the clock or past its own fetch is a misread header: `mostRecentSleepSession` skips it, and the rule answers awake. The dialog always states the age of the data ("Yes, asleep (data from X min ago)."), so a chained Personal Automation never silently acts on stale state.

> **`CheckBandBatteryIntent` is silent by default.** Meant for a Personal Automation "when the iPhone charger is connected": a reminder to put the band on charge too. A shortcut that spoke on every run would become noise, so it **has no dialog** — it runs the full sync **holding the link** (`syncNow(disconnectWhenDone: false)`; with the default, the sync disconnected the link it had opened itself and the request below became dead code), asks for a fresh reading while the link is open (`BandManager.refreshBattery` — the in-memory level may be stale on a long connection), waits for the replies (3 s ceiling, not a sleep) and only acts if `level < threshold` **and** the band is not already on the charger, posting a local notification. The level is also returned as the output value, for anyone who wants to chain their own condition. Band out of range, or a sync still running at `intentDeadline` (15 s) → answers with the last known level (past the deadline it skips the fresh reading and releases the link only once the sync ends) instead of failing the shortcut (and the whole automation); no reading at all → `nil`, no notification. The radio is released at the end of the intent, and only if there was no live link before it (a link mid-handshake counts as live).
>
> **The level is the same as in the iOS Batteries widget.** There is no API to read the widget (it uses the private `BatteryCenter` framework), but the **same source** can be read: the standard GATT Battery Service (`0x180F` / `0x2A19`), which iOS queries on paired BLE accessories. `BandManager` discovers it together with `FE95` and, when it exists, `2A19` owns `batteryLevel`; the protobuf `CMD_BATTERY` is still requested because only it carries the charging state (`battery.state == 1`). Without `180F`, the level comes from the protobuf again. **Reading and subscribing to `2A19` only after auth**: if the characteristic requires encryption, touching it on a link with no bond yet would make iOS raise the pairing sheet *before* the band's dialog, reversing the order of the two prompts ADR 0003 relies on. Accepted consequence: without auth there is no GATT read, even if the band exposes it.

### Siri Phrases (AppShortcutsProvider)
- "Sync my band in My Band"
- "Am I asleep in My Band"
- "Check if I'm asleep in My Band"
- "Check band battery in My Band"

---

## UI / Design System

The UI is built from the **Claude Design** handoff (`My Band — Design System`, a bundle exported from claude.ai/design). Recreate it faithfully in SwiftUI — copy the **visual result**, not the HTML/JSX structure of the prototypes.

> **Apple Health is the surface for health data** (ADR 0005, which supersedes 0001). The Dashboard shows connection state, sync freshness, battery, alarms, band settings and the Today card — steps, kcal and HR read once from the band's realtime stats and never stored; stand hours come from the last sync's daily summary. The Health card opens the Health sheet with the latest value of each reading (HR, SpO₂, stress, temperature, day summary, last night), kept as a single overwritten snapshot, plus height and weight to edit and the log of what the syncs sent to Apple Health (ADR 0006 and its addendum). The history shown lives on two side pages, nothing stored: Workouts, with the app's own latest workouts (ADR 0009), and Sleep & trends, with 7-day charts of sleep, resting HR, steps, SpO₂ and weight (ADR 0010). Outside them, no history and no charts.

**The maker's fixed principles:**
1. **Dark-mode first** — "I like night mode".
2. **Simple, direct, glanceable** — the app is a background *gateway*; the UI is for quick status and configuration, not screen time — the Dashboard stays status-only; health data lives on the side pages (ADR 0009, 0010).
3. **Native Apple** — SwiftUI, iOS 26+, Liquid Glass on chrome/status (see ADR 0001), true to the HIG.

**Visual foundations:**
- **Midnight palette** (OLED): base `#0A0B10`, cards `#14161F`, elevated surfaces `#1A1D27`. Elevation by *lightness + hairline* `rgba(255,255,255,.07)`, not shadow.
- **Single accent**: Aurora indigo `#7C7FFF` (interaction, selection, focus, active-connection glow).
- **Health colors** mirror Apple Health: HR `#FF5C7A`, steps `#46E0A0`, SpO₂ `#5BC0F8`, energy `#FF9A4C`.
- **Sleep phase ramp** dusk→deep-night: awake `#F6A052` → REM `#5BC0F8` → light `#8A8CFF` → deep `#4B45C7`.
- **Status**: ok/connected mint `#46E0A0`, connecting/warning amber `#F6C552`, disconnected/error pink `#FF5C6C`.
- **Type**: iOS scale, SF Pro on-device (Geist in the web kit). Large data numerals (48–64px), tabular. AuthKey and technical values in **mono**.
- **Continuous corners**: cards 16, sheets 20, hero/modal 28, round pills. **4-pt grid**, gutter 20, hit target ≥44.
- **Icons**: SF Symbols (the web kit uses Lucide as a stand-in). Status is always color + symbol, never color alone.

**Voice & copy (English):** sentence case, no emoji, address the user as **you**, device = "the band". Calm, factual tone ("Synced 2 min ago", "42 samples in Apple Health"). Health metrics only on the Today card (ADR 0005), on the Health card/sheet (ADR 0006), on the workout card and in the Live Activity while the band records a workout (ADR 0008), on the Workouts screen, with the workouts the app itself recorded (ADR 0009), and on the Sleep & trends page (ADR 0010); outside them a number is always about status/sync. Technical honesty: AuthKey/BLE shown in mono, AuthKey masked by default.

**Screens (`ui_kits/app/`):** `Dashboard` (connection status, sync freshness, battery, sync, alarms, band settings, the Today card — ADR 0005 —, the Health sheet — ADR 0006 — the live workout card — ADR 0008 — and, one swipe to the left, the Workouts page with the latest workouts read from Apple Health — ADR 0009 —, and, one swipe to the right, the Sleep & trends page — ADR 0010 —, and, after Workouts, the Reminders page), `Setup` (AuthKey + scan/connection), `Settings`. Connection status + sync freshness are first-class on every screen.

**Kit components** (`components/`): core (`Button`, `IconButton`, `StatusPill`, `Badge`), forms (`Switch`, `TextField`, `SegmentedControl`), data (`ListRow`, `Card`, `MetricTile`, `SectionHeader`, `SleepBar`). Each one has a `.prompt.md` and a `.d.ts` describing props/variants.

---

## SwiftData — Main Models

```swift
@Model class BandDevice {
    var id: UUID
    var name: String
    var peripheralIdentifier: String  // UUID of the CBPeripheral
    var lastSyncDate: Date?
    // AuthKey stored IN THE KEYCHAIN, not here
}

@Model class SleepSession {
    var id: UUID
    var startDate: Date
    var endDate: Date
    var phases: [SleepPhase]          // Codable embedded
    var healthKitSynced: Bool
    var rawDataHash: Int              // one record per distinct file
    var awakeFlag: Int?               // 0 = night still open on the band
    var fetchedAt: Date?              // last time the band sent this report
    @Attribute(.externalStorage) var rawData: Data?   // furthest report per night, 90 days
    var device: BandDevice?
}

@Model class ActivityDay {
    var date: DateComponents           // year/month/day only
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    var healthKitSynced: Bool
}
```

---

## Changelog

The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Every notable change goes in `CHANGELOG.md` before the commit**, under the categories:

| Category | When to use |
|---|---|
| `Added` | New functionality |
| `Changed` | Change to existing functionality |
| `Deprecated` | Functionality to be removed in a future version |
| `Removed` | Functionality removed |
| `Fixed` | Bug fix |
| `Security` | Vulnerability fix |

Entries pending release go under `## [Unreleased]`. When releasing a version, move them to `## [X.Y.Z] - YYYY-MM-DD`.

Current version: **1.2.0** — see `CHANGELOG.md` for the full history. Next phase, all **to validate on hardware**:

1. Patient pairing on a genuinely **new** pairing (ADR 0003 + addendum) — the 180 s window spanning the bonding link drop, `PairingStage` advancing to `.phone`, whether the iOS sheet actually produces an observable `CBATTError.insufficientAuthentication` (or comes up without rejecting any write), and the session restart the band does after the accept. The 2026-09-05 logs came from an already-paired band and from attempts that were failing, not from a successful accept.
2. The full sync after the session-restart fix — if the band reopens the session and the app re-derives the keys, `FETCH_TODAY` should finally get a reply instead of only ACKs. In the console, a sync on a new connection should show `FETCH_TODAY cut short by a band session restart — re-sending after re-auth` followed by `FETCH_TODAY → N file ID(s)`, and a `Sleep file …` line for each night.
3. The Xiaomi Cloud username/password login with captcha and 2FA (ADR 0002; simple login already confirmed).
4. The `GetSleepStateIntent`.
5. The `CheckBandBatteryIntent` — in particular the on-demand `CMD_BATTERY` outside the post-auth init (the reply arrives in the same `handleSystemCommand`, but it has never been exercised with the link already open for a while). And whether the Mi Band 10 exposes the Battery Service `0x180F` to apps (the `Services:` line in the connection log answers that), whether `2A19` reads without error post-auth and whether the number matches the Batteries widget — the log prints both (`via GATT 2A19` / `via protobuf — keeping GATT`).
6. The Workouts screen — whether `MiBandWorkoutKind` and the swimming location come back from Apple Health on a real workout, and the access request when opening it before the first sync. And the route map: whether band outdoor workouts carry an `HKWorkoutRoute` at all (the `Workout GPS file: N point(s)` and `has no GPS track in this sync` log lines), and whether waiting out `locationUnknown` stops the band's weak-GPS message at the start (`GPS fix acquired (±N m)` vs `No GPS fix in 60 s`). And that the GPS stream reaches the band when its `started` arrives before the GPS request (`Workout started/resumed` before `Workout open request`, then a GPS file with points), and that a track arriving in a later sync than its workout attaches (`Attached a late GPS track`) or stays un-ACKed when the attach fails.
7. The Sleep & trends page — whether sleep from several sources counts each minute only once (the iPhone writes `asleepUnspecified` overlapping the band's night) and whether nights land on the right day with the 18:00 cutoff.
8. The Reminders screen — the `maxReminders` the Mi Band 10 reports (the `Reminders: N of max M` line in the log), whether it truncates titles over 20 characters, and whether the monthly/yearly/weekly repeat modes fire as expected. And whether a daily reminder created with a time still to come today fires today and then every day, and how many times fit in the slots. And that the first sync on this build clears the duplicated iPhone reminders once, that a later sync retries a delete the band didn't take, and that editing a reminder replaces it without a duplicate.

9. Band settings › Vibration — whether the band answers subtype 46 with a type mapping (`Vibration from band ←` in the log) and whether a preset set with subtype 47 sticks (the re-read shows it, and an alert buzzes with the new pattern).

Home Assistant was cut from the roadmap; outside the Workouts and Sleep & trends pages, the UI stays without health history or charts by decision (ADR 0005, which supersedes 0001, 0006, 0009 and 0010).

---

## Code Conventions

- **No obvious comments** — name things well, do not comment what is evident
- **Comment only non-obvious WHYs**: BLE protocol invariants, hardware workarounds
- **@Observable** instead of ObservableObject (Swift 5.9+)
- **async/await** for all BLE and network operations — no nested callbacks
- **`BandManager` is `@Observable @MainActor NSObject`** — not a pure Swift `actor`. CBCentralManagerDelegate requires NSObject; configuring `CBCentralManager` with `queue: .main` makes the callbacks arrive on the main thread, aligned with `@MainActor` without extra bridging
- **No force-unwraps** — handle errors explicitly
- Minimum iOS 17 / macOS 14 — use modern APIs without compatibility shims
- Docs, changelog, ADRs, backlog and code comments are written in English.

---

## Known Pitfalls

### Xcode 16 — PBXFileSystemSynchronizedRootGroup
The project uses automatic folder synchronization (`PBXFileSystemSynchronizedRootGroup`): **any file created inside `My Band/My Band/` is automatically included in the build**.
- **Do not create an `Info.plist` inside `My Band/My Band/`** — it will cause "Multiple commands produce Info.plist".
- The project's Info.plist lives at **`$(SRCROOT)/Info.plist`** (project root, outside the synchronized folder). `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE = "Info.plist"` in the pbxproj.
- When creating subfolders (`BLE/`, `Auth/`, etc.), use the Xcode MCP's `XcodeMakeDir` so they are registered correctly in the project.

### INFOPLIST_KEY_UIBackgroundModes generates `<string>`, not `<array>`
`INFOPLIST_KEY_UIBackgroundModes = "bluetooth-central"` with `GENERATE_INFOPLIST_FILE = YES` generates the wrong type in the plist — `<string>` instead of `<array>`. `CBCentralManager` validates the type at runtime and throws `NSInternalInconsistencyException: State restoration of CBCentralManager is only allowed for applications that have specified the "bluetooth-central" background mode`. **Always use the manual Info.plist** with `<array><string>bluetooth-central</string></array>`.

### CBCentralManagerOptionRestoreIdentifierKey in the Simulator
The iOS Simulator does not support CoreBluetooth state restoration. Wrap it in `#if !targetEnvironment(simulator)` to avoid a crash in the simulator.

### CommonCrypto — Swift access exclusivity
When using `Data.withUnsafeMutableBytes`, capture `data.count` in a local variable **before** the closure to avoid the exclusivity error:
```swift
let capacity = output.count          // capture BEFORE
output.withUnsafeMutableBytes { buf in
    CCCrypt(..., buf.baseAddress, capacity, ...)  // use the variable
}
```

### BandManager.startScan() — Race condition with CBCentralManager
`CBCentralManager` is initialized asynchronously. If `startScan()` is called (e.g. from `.onAppear`) before `centralManagerDidUpdateState(.poweredOn)` fires, the `central.state == .poweredOn` guard fails silently and the scan never starts.
Implemented solution: a `pendingScan` flag in `BandManager`. If BT is not ready, `pendingScan = true`; `centralManagerDidUpdateState` consumes the flag and calls `startScan()` when BT becomes `poweredOn`.

### ModelContainer — fatalError after a watchdog kill
Watchdog kills (app in the background exceeding handler time) can corrupt the SwiftData SQLite file. On the next launch, `ModelContainer(for:configurations:)` fails and the original version called `fatalError` immediately, showing up as "Message from debugger: killed" with no useful log.
Implemented solution: if `ModelContainer` fails, delete the `.store`, `.store-shm` and `.store-wal` files and try again before calling `fatalError`. Losing local data is acceptable in development; in production replace this with a migration.

### dyld AVPlayerView — Debug error on the Mac
When running the app on the Mac (iOS app via the `/System/iOSSupport/` layer), the Xcode debugger loads the MacOSX platform's `libViewDebuggerSupport.dylib`, which tries to resolve `_OBJC_CLASS_$_AVPlayerView` in the iOS AVKit where the class does not exist. The result is "Message from debugger: killed" with no app log.
**It is not an app bug.** Solution: run on a physical iPhone. For BLE, a physical iPhone is required anyway — the Simulator and the Mac do not connect to the Mi Band.

### HealthKit — Reserved Apple Watch Ring Types
HealthKit **expressly forbids** third-party apps from requesting share permission (`toShare`) for the proprietary Apple Watch activity ring identifiers:
- `HKCategoryTypeIdentifierAppleStandHour`
- `HKQuantityTypeIdentifierAppleExerciseTime`
- `HKQuantityTypeIdentifierAppleMoveTime`

Passing any of these types to `requestAuthorization(toShare:read:)` immediately throws `NSInvalidArgumentException: Authorization to share the following types is disallowed: ...`. Exercise time must be counted by the system from the recorded `HKWorkout`s, never written directly.

### Sanitizing the Mi Band's Cumulative Sleep Packets
The Mi Band 10 sends sleep stages (type 17 packets) cumulatively: each one is a full re-scoring of the night, so processing them without merging sums the sleep minutes repeatedly in HealthKit, and pooling them with `sanitizeStages` alone keeps the earliest scoring. `latestRevisionWins` (within a file) and `mergeReports` (reports of one night across syncs) let the newest win. In addition, Xiaomi's raw timestamps in `firstRecordTime` require unsigned decoding (`u32`) and epoch validation to avoid the years 1928 and 1970.

---

## Build and Tests

```bash
# Build (requires Xcode 16+)
xcodebuild -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"

# Unit tests (protocol parsers, HealthKit conversion)
xcodebuild test -scheme "My Band" -destination "platform=iOS Simulator,name=iPhone 15 Pro"
```

- Test BLE protocol logic with real captured data (fixtures in `Tests/Fixtures/`)
- Do not mock `CBCentralManager` in unit tests — test only the parsing/conversion layers
- BLE integration tests only on a physical device

---

## Agent skills

### Issue tracker

Issues and specs are tracked as GitHub Issues in `matheusdanoite/my-band`, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Standard label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

---

## References

- `AstroBox-NG-main/` — BLE protocol reference for wearables and protobuf structure
- [GadgetBridge Mi Band 8/9/10 source](https://codeberg.org/Freeyourgadget/Gadgetbridge) — reference implementation of the protocol
- [OpenWRT Mi Band community docs](https://github.com/argrento/huami-token) — AuthKey extraction via Xiaomi Cloud
- HealthKit Developer Documentation — Apple
- App Intents Developer Documentation — Apple
