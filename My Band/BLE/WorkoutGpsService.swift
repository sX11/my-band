import CoreLocation
import OSLog

// MARK: - WorkoutGpsService
//
// Handles the GPS handshake between the band and the phone during workouts.
//
// Protocol (GadgetBridge XiaomiHealthService):
//   Band → app : workoutOpenWatch  (type=8, subtype=30)  — repeated every ~1 s while waiting
//   App  → band: workoutOpenReply  (type=8, subtype=30)  — {3,2,10} = no GPS / {0,2,2} = GPS fix ready
//   App  → band: workoutLocation   (type=8, subtype=48)  — streamed once per fix, only after workout started
//   Band → app : workoutStatusWatch(type=8, subtype=26)  — status 0=started, 1=resumed, 2=paused, 3=finished
//
// Without a reply to workoutOpenWatch the band hangs indefinitely at "waiting for GPS".

@Observable
@MainActor
final class WorkoutGpsService: NSObject {

    private(set) var isActive = false

    /// Fired when the band reports a workout has finished (workoutStatusWatch, status=finished).
    /// Carries the workout's activity file ids straight from the status message (concatenated
    /// 7-byte ids; empty if the firmware omitted them) so BandSyncer can fetch exactly those
    /// files instead of re-listing the whole backlog.
    var onWorkoutFinished: ((Data) -> Void)?

    private weak var bandManager: BandManager?
    private let locationManager = CLLocationManager()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "GPS")

    private var gpsFixAcquired = false
    private var workoutStarted = false

    // MARK: - Setup

    func setup(manager: BandManager) {
        bandManager = manager

        manager.onWorkoutOpenWatch = { [weak self] sport in
            Task { @MainActor in self?.handleWorkoutOpen(sport: sport) }
        }
        manager.onWorkoutStatusWatch = { [weak self] status, fileIds in
            Task { @MainActor in self?.handleWorkoutStatus(status, fileIds: fileIds) }
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // No distance gate: deliver every fix CoreLocation computes (~1 Hz) so the band records a
        // smooth, time-uniform track. A distance filter (e.g. 5 m) ties the cadence to pace and
        // emits nothing while stopped/slow, which left the recorded route sparse.
        locationManager.distanceFilter  = kCLDistanceFilterNone
        // Required so the GPS stream keeps flowing while the user looks at the band, not the
        // phone. Only takes effect once the user grants "Always Allow"; with "While Using" the
        // stream pauses when the app backgrounds and the band shows "GPS lost".
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    // MARK: - Incoming band commands

    private func handleWorkoutOpen(sport: UInt32) {
        log.debug("Workout open request (sport=\(sport))")

        // Skip GPS for indoor / stationary sports (strength, yoga, pool, machines…). Reply "GPS
        // disabled" so the band starts immediately without waiting for a fix it won't record, and
        // never start CoreLocation. Unknown sport codes fall through to the GPS path — safer to give
        // an unrecognised outdoor sport its route than to silently drop it.
        if let kind = WorkoutSummaryParser.workoutKind(fromCode: Int(sport)), !kind.usesGps {
            log.info("Workout sport=\(sport) (\(String(describing: kind))) doesn't use GPS — replying disabled")
            replyGpsDisabled()
            return
        }

        let authStatus = locationManager.authorizationStatus

        switch authStatus {
        case .notDetermined:
            // Two-step prompt: must ask `WhenInUse` first, and iOS only allows the upgrade to
            // `Always` once the WhenInUse prompt has been answered. We trigger the first prompt
            // here; the upgrade is requested in locationManagerDidChangeAuthorization once iOS
            // moves to `authorizedWhenInUse`. The band keeps re-sending workoutOpenWatch every
            // ~1 s, so a new handleWorkoutOpen call will reach the .authorizedAlways branch
            // below shortly after the user accepts.
            log.info("Location not determined — requesting WhenInUse authorization")
            isActive       = true
            gpsFixAcquired = false
            workoutStarted = false
            locationManager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse:
            log.info("Have WhenInUse — requesting upgrade to Always for background GPS stream")
            locationManager.requestAlwaysAuthorization()
            if !isActive {
                isActive       = true
                gpsFixAcquired = false
                workoutStarted = false
                locationManager.startUpdatingLocation()
            }

        case .authorizedAlways:
            if !isActive {
                isActive       = true
                gpsFixAcquired = false
                workoutStarted = false
                log.info("Starting CoreLocation for workout (sport=\(sport))")
                locationManager.startUpdatingLocation()
            }
            // No reply yet — wait for first fix; onLocation sends the GPS-ready reply.

        case .denied, .restricted:
            log.info("Location denied/restricted — replying GPS disabled")
            replyGpsDisabled()

        @unknown default:
            replyGpsDisabled()
        }
    }

    private func handleWorkoutStatus(_ status: UInt32, fileIds: Data) {
        // Proto WorkoutStatusWatch.status: 0=started, 1=resumed, 2=paused, 3=finished
        switch status {
        case 0, 1:
            log.info("Workout started/resumed — GPS stream active")
            workoutStarted = true
        case 2:
            // Paused — keep CoreLocation running so a resume gets an instant fix, but stop
            // forwarding locations so the band doesn't fold paused-period drift into the
            // workout's distance and route.
            log.info("Workout paused — holding GPS stream")
            workoutStarted = false
        case 3:
            log.info("Workout finished — stopping GPS")
            stopGps()
            onWorkoutFinished?(fileIds)
        default:
            break
        }
    }

    // MARK: - GPS reply helpers

    private func replyGpsDisabled() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.workoutOpenReplyCommand(gpsReady: false))
    }

    private func replyGpsReady() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.workoutOpenReplyCommand(gpsReady: true))
    }

    private func stopGps() {
        isActive       = false
        gpsFixAcquired = false
        workoutStarted = false
        locationManager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManagerDelegate

extension WorkoutGpsService: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in self?.onLocation(loc) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch status {
            case .authorizedWhenInUse:
                // First prompt accepted; immediately ask for the upgrade to Always so the GPS
                // stream survives the screen locking / app backgrounding during the workout.
                if self.isActive {
                    self.log.info("WhenInUse granted — requesting upgrade to Always")
                    manager.requestAlwaysAuthorization()
                    manager.startUpdatingLocation()
                }
            case .authorizedAlways:
                if self.isActive { manager.startUpdatingLocation() }
            case .denied, .restricted:
                if self.isActive { self.replyGpsDisabled() }
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.error("CoreLocation error: \(error.localizedDescription)")
            if self.isActive && !self.gpsFixAcquired { self.replyGpsDisabled() }
        }
    }

    @MainActor
    private func onLocation(_ loc: CLLocation) {
        guard isActive else { return }

        if !gpsFixAcquired {
            gpsFixAcquired = true
            log.info("GPS fix acquired — replying GPS ready to band")
            replyGpsReady()
        }

        guard workoutStarted else { return }

        let ts = UInt32(loc.timestamp.timeIntervalSince1970)
        let proto = XiaomiProto.workoutLocationCommand(
            timestamp: ts,
            latitude:  loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude:  loc.altitude,
            speed:     Float(loc.speed >= 0 ? loc.speed : 0),
            bearing:   Float(loc.course >= 0 ? loc.course : 0)
        )
        bandManager?.sendEncryptedCommand(protoBytes: proto)
        log.debug("GPS location sent: (\(loc.coordinate.latitude, privacy: .private), \(loc.coordinate.longitude, privacy: .private))")
    }
}
