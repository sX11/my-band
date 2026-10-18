# My Band

> Xiaomi made the Mi Band. I turned it into My Band.

Native **iOS/macOS** app (SwiftUI + SwiftData) that connects the iPhone to a **Mi Band 10** over Bluetooth Low Energy and syncs the health data to **Apple Health** — with no Xiaomi cloud in the path, straight from the band to a central, vendor-neutral place. It also exposes state and actions through Shortcuts and Siri, for the iPhone's own automations.

The official Mi Band 10 app does not send every metric the device collects to Apple Health. My Band exists to fill that gap — and so that the health data actually belongs to the user.

---

## Engineering highlights

This is a personal project that served as a lab for BLE, applied cryptography and deep HealthKit integration. What makes it interesting technically:

- **Cryptographic authentication reverse-engineered and validated on hardware.** The Mi Band 10 handshake implemented from scratch in Swift: nonce exchange, HMAC-SHA256, session key derivation via HKDF and encrypted communication with AES (CTR/CCM). Tested on a physical band, with real data.
- **Binary protocol reverse engineering.** Packet format (frames, CRC-16/ARC, reliable transport with ACK, protobuf) and parsers for sleep, workouts and GPS route. Including a **per-second heart rate series that the open-source reference implementation (GadgetBridge) does not decode** — layout reverse-engineered from real captures and validated by CRC-32.
- **Deep HealthKit integration.** Sleep, steps, HR, SpO₂, workouts with GPS route, physical effort, workout effort and heart rate recovery. Steps, distance and energy go raw per minute; Apple Health merges the minutes shared with the iPhone by the Data Sources order.
- **Modern concurrency and architectural discipline.** Swift 5.10, `async/await`, `@Observable`, `@MainActor`, background BLE with state restoration, unit tests with real-data fixtures and an AuthKey that never leaves the Keychain.

---

## Features

| Status | Feature |
|---|---|
| Done | BLE V2 connection with HMAC-SHA256 authentication via AuthKey — **validated on hardware (Mi Band 10)** |
| Done | Protobuf protocol via SwiftProtobuf (types generated from GadgetBridge) |
| Done | Reliable transport with ACK + post-auth init + first-pairing retry |
| Done | Secure AuthKey storage in the Keychain |
| Done | Automatic reconnection with exponential backoff |
| Done | Background BLE (band stays connected with the app suspended) |
| Done | CBCentralManager state restoration after suspension by the system |
| Done | Sleep data sync (XiaomiSppPacketV2 parser) |
| Done | Local persistence with SwiftData (BandDevice, SleepSession, ActivityDay) |
| Done | Reassembly of fragmented BLE frames (activity files > MTU) |
| Done | Battery reading (level + charging) |
| Done | Setup UI (AuthKey + scan/connection) and Dashboard (battery, last sync, sync button, next alarm, band settings, Today card — steps, kcal, stand hours, HR — and Health sheet with the latest reading of each metric) via Claude Design |
| Done | Writes to Apple Health — sleep (stages) and daily activity (steps, calories, distance, HR + resting HR, SpO₂) — **validated on hardware (Mi Band 10)** |
| Done | Background sync via `BGProcessingTask` (reconnects, syncs and reschedules with the app suspended) — **validated on hardware** |
| Done | Manual measurements in Apple Health (HR, SpO₂) — **validated on hardware (Mi Band 10)** |
| Done | Workouts in Apple Health (`HKWorkout` + GPS route + VO₂ max) and GPS handshake with the iPhone (CoreLocation → `workoutLocation` stream) — **validated on hardware** |
| Done | Per-second workout HR series attached to the `HKWorkout` (HR chart inside the workout) — **validated on hardware** |
| Done | Rich metrics in Apple Health — physical effort (METs/min), workout effort (iOS 18+), heart rate recovery, speed/stride and rowing distance, derived from real measurements |
| Done | Raw per-minute steps/distance/energy, merged by Apple Health according to the Data Sources order (put the iPhone above My Band) — **not yet validated on hardware** |
| Done | OKOK/Chipsea BLE scale (broadcast-only) → weight + BMI in Apple Health, with a height profile — **validated on hardware** |
| Done | AuthKey extraction via Xiaomi Cloud (username and password, no Xiaomi app) |
| Done | Unit test target (Swift Testing, 23 tests) with real fixtures — **validated on the iPhone** |
| Done | Shortcuts integration via App Intents and Siri phrases — **validated on hardware** |
| Done | Band battery shortcut with a configurable threshold — notifies only below the threshold, built for the "when the iPhone is plugged into the charger" automation (v1.2) |
| Done | Sleep stage sanitization and deduplication, and physiological validation of vital signs (v1.1) |
| Planned | SleepDetail (hypnogram) + Settings screens |
| Planned | Custom mini app on the band with actionable buttons |

---

## Requirements

- **Xcode 16+**
- **iOS 26+** (runs on Apple silicon Macs as "Designed for iPad and iPhone")
- Personal Apple Developer Program (sideload — not published on the App Store)
- Mi Band 10 with a known AuthKey
- SPM dependency: **SwiftProtobuf** (`apple/swift-protobuf`) — resolved automatically by Xcode

---

## Initial setup

### 1. Get the AuthKey

The AuthKey is a 16-byte key (32 hex characters) tied to your device. Ways to get it:

- **Through the app itself** — Setup guides the extraction via **Xiaomi Cloud with your Xiaomi username and password** (captcha and email 2FA supported; the password is never stored or logged). The app walks the Xiaomi regions and reads the band's AuthKey from its device record. Flow ported from `token_extractor.py`; plain login is confirmed, **captcha and 2FA are still to be validated with a real account**.
- **Via Python** — [`huami-token`](https://github.com/argrento/huami-token): logs in to the Xiaomi account and extracts the token
- **Via GadgetBridge** — export the AuthKey from the app's database on Android

### 2. Enter the AuthKey in the app

On first use, the app opens the **Setup** screen when there is no AuthKey in the Keychain: enter the 32 hex characters of the AuthKey (secure, masked field) and tap **Connect band**. The app validates the key and stores it in the Keychain with access after first unlock (`kSecAttrAccessibleAfterFirstUnlock`), which allows background sync. The key is **never** written to code, logs, SwiftData or UserDefaults.

### 3. Pair the band

The app automatically scans for devices named `Xiaomi Smart Band 10`. When it finds one, it starts the HMAC-SHA256 V2 handshake and keeps the connection persistent.

> **Note:** BLE tests require a physical iPhone. The Simulator and the Mac lack the BLE stack needed to connect to the band.

---

## Architecture

```
My Band/
├── BLE/
│   ├── BandManager.swift         # @Observable @MainActor orchestrator — scan, connect, auth
│   ├── BandAuthenticator.swift   # HMAC-SHA256 V2 handshake (pure, testable)
│   ├── BandSyncer.swift          # Data sync → SwiftData
│   ├── BandScanner.swift         # BLE discovery filters
│   ├── BandProtocol.swift        # XiaomiSppPacketV2 encoding + CRC-16/ARC
│   ├── Crypto/
│   │   └── XiaomiCrypto.swift    # HMAC-SHA256, HKDF-expand, AES-CTR/CCM (CommonCrypto)
│   ├── Protocol/
│   │   ├── XiaomiProto.swift     # Builders/parsers (thin layer over SwiftProtobuf)
│   │   └── xiaomi.pb.swift       # Types generated from xiaomi.proto (GadgetBridge)
│   └── PacketParser/
│       ├── SleepPacketParser.swift     # Sleep 0x08 (stages FB FA FC FF + HR/SpO₂)
│       ├── DailySummaryParser.swift    # Daily totals + shared LEReader
│       ├── DailyDetailsParser.swift    # Per-minute series (HR/SpO₂/distance/stress)
│       ├── ManualSamplesParser.swift   # Manual measurements (HR/SpO₂/stress/temperature)
│       ├── WorkoutSummaryParser.swift  # Workout summaries (blueprint per subtype/version)
│       ├── WorkoutGpsParser.swift      # Workout GPS track (V1/V2)
│       └── XiaomiActivityFile.swift    # 7-byte id meta + routing
│
├── Auth/
│   └── AuthKeyStore.swift        # Keychain: read/write/delete the AuthKey
│
├── Models/                       # SwiftData
│   ├── BandDevice.swift          # Paired device
│   ├── SleepSession.swift        # Sleep session + phases (light/deep/REM/awake)
│   └── ActivityDay.swift         # Steps, calories, distance per day
│
├── Health/
│   └── HealthKitManager.swift    # Writes to Apple Health (sleep/activity/workouts/route)
├── Intents/                      # App Intents + Shortcuts (in development)
└── UI/                           # SwiftUI (in development)
```

Full details on architecture, BLE protocol and conventions in [`CLAUDE.md`](CLAUDE.md).

---

## BLE protocol — Mi Band 10 V2

The Mi Band 10 uses the **XiaomiSppPacketV2** protocol over BLE (confirmed via GadgetBridge).

**Service:** `0000FE95` | **TX (write):** `0000005E` | **RX (notify):** `0000005F`

**Frame (8-byte header; CRC-16/ARC of the payload):**
```
[0xA5][0xA5] preamble
[type][seqNum][lenLo][lenHi][crcLo][crcHi]
[payload...]      # DATA: [channel][opCode][bytes]
```

**Authentication (HMAC-SHA256):**
1. Session config (binary) → band response
2. `CMD_NONCE` (type=1, sub=26) with 16 random bytes from the app
3. Band responds: `watchNonce(16) + HMAC-SHA256(watchNonce+phoneNonce, decKey)(32)`
4. Verify HMAC → derive 4 session keys via HKDF-expand("miwear-auth", 64)
5. `CMD_AUTH` (type=1, sub=27) with `authStep3` (HMAC of the nonces + device info in AES-128-CCM)
6. Post-auth init (time + device info/state/battery) — without it the band re-triggers auth

> **Reliable transport:** every DATA frame received from the band is acknowledged with an ACK (same `seqNum`), or the band retransmits the handshake every ~6 s.
> **First pairing:** the band announces with `auth sub=16` and only emits a verifiable watch-nonce after you accept **on the band and on the iPhone**. The app waits for that acceptance instead of treating the earlier nonces as a wrong key (see [ADR 0003](docs/adr/0003-patient-band-driven-handshake.md)).
> The AuthKey (secretKey) is 16 bytes. It lives **only in the Keychain** — never in logs, SwiftData or UserDefaults.

---

## Interface (UI)

The UI is being built from a **dark-mode-first design system** delivered by Claude Design — an OLED-optimized *midnight* palette, an Aurora indigo accent, health colors mirroring Apple Health and a sleep phase ramp. Copy in **English**, focused on glanceable status and quick configuration (the app is a background gateway). Details on tokens, components and screens in [`CLAUDE.md`](CLAUDE.md#ui--design-system).

---

## References

- [GadgetBridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — reference implementation of the Mi Band 10 V2 protocol (auth, activity/workout parsers, watch faces/RPK, weather)
- [huami-token](https://github.com/argrento/huami-token) — AuthKey extraction via Xiaomi Cloud
- [homeassistant-okokscale](https://github.com/rrooggiieerr/homeassistant-okokscale) (Apache-2.0) — reference for decoding the OKOK/Chipsea BLE scale (VC0 variant)
- [Open-Meteo](https://open-meteo.com/) — weather forecast sent to the band (free, no key)
- AstroBox-NG — BLE protocol reference for wearables (not included in the public repository)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) / [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

> This project ports protocol pieces from GadgetBridge and homeassistant-okokscale (reverse engineering of BLE formats). Credit to those projects is above; no AuthKey, credential or secret is included in the repository.

---

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md).
