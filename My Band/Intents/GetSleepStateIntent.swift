import AppIntents
import Foundation
import OSLog

// MARK: - GetSleepStateIntent
//
// "Are you asleep?" — the Shortcuts-native replacement for the Home Assistant "sono
// detectado" trigger that was cut from the roadmap. Instead of the app owning an automation
// (turn off the bedroom lights, run a script), it just answers this question; the user's own
// Shortcuts Personal Automation decides what to do with the answer.
//
// The band has no "fell asleep"/"woke up" push (see CLAUDE.md's BLE protocol notes) — sleep is
// always pull, discovered whenever the app happens to sync. So "is he sleeping" can only ever be
// "as of the last sync", never truly real-time. This intent narrows that gap by forcing a sync
// first (best-effort — a failed sync isn't fatal, it just falls back to whatever's already known)
// and is honest about it: the dialog always states how old the underlying data is, so a Shortcut
// chaining off this isn't silently acting on a stale answer.

struct GetSleepStateIntent: AppIntent {

    static var title: LocalizedStringResource = "Check if I'm asleep"
    static var description = IntentDescription(
        "Syncs with the Mi Band 10 and tells you whether you're asleep, based on the latest known sleep data."
    )

    // Runs in the background without bringing the app to the foreground.
    static var openAppWhenRun = false

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "SleepIntent"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        // Best-effort refresh so the answer isn't working off hours-old data. A failure here (band
        // out of range, already mid-sync, etc.) isn't fatal — fall through to the last local sync,
        // but it IS reported: an answer built on a sync that never happened is exactly the silent
        // staleness this intent exists to avoid.
        var syncFailed = false
        do {
            _ = try await BackgroundSyncManager.shared.syncNow(retryStaleLink: false)
        } catch {
            syncFailed = true
            Self.log.error("Sync do intent de sono falhou: \(error.localizedDescription)")
        }

        guard let session = AppServices.shared.bandSyncer.mostRecentSleepSession() else {
            return .result(
                value: false,
                dialog: syncFailed
                    ? "Couldn't sync with the band and there's no local sleep data."
                    : "No sleep data synced yet."
            )
        }

        let verdict = SleepStateRule.evaluate(session, now: Date())
        let sleeping = verdict.asleep
        Self.log.info("Sleep intent → \(sleeping ? "asleep" : "awake", privacy: .public) (\(verdict.reason, privacy: .public))")

        let freshness = RelativeDateTimeFormatter()
        freshness.locale = Locale(identifier: "en_US")
        freshness.unitsStyle = .abbreviated
        let asOf = freshness.localizedString(for: session.endDate, relativeTo: Date())

        let caveat = syncFailed ? ", not synced just now" : ""
        let dialog = sleeping
            ? "Yes, asleep (data from \(asOf)\(caveat))."
            : "No, awake (data from \(asOf)\(caveat))."
        return .result(value: sleeping, dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - SleepStateRule
//
// While the band has a night open (awakeFlag 0) the report's end keeps pace with each sync, and it
// freezes once the user wakes; the flag only turns 1 an hour or more later (upstream hardware log,
// 2026-10-01). So the gap between end and fetch answers sooner than the flag.

enum SleepStateRule {

    /// End this far behind the fetch means the night stopped growing: the band reports whole
    /// minutes, and the sync itself adds some latency.
    static let stoppedGrowingAfter: TimeInterval = 5 * 60
    /// A report older than this says nothing about now — the sync that would refresh it failed.
    static let staleAfter: TimeInterval = 60 * 60
    /// An end further ahead of the clock than this is a misread header, not a night in progress.
    static let clockSkewTolerance: TimeInterval = 5 * 60

    static func evaluate(_ session: SleepSession, now: Date) -> (asleep: Bool, reason: String) {
        let untrusted = (false, "end date ahead of the clock — untrusted")
        if session.endDate > now.addingTimeInterval(clockSkewTolerance) { return untrusted }
        if let fetched = session.fetchedAt, session.endDate > fetched.addingTimeInterval(clockSkewTolerance) { return untrusted }

        let lastPhase = session.phases.max { $0.startDate < $1.startDate }?.type
        if lastPhase == .awake { return (false, "last phase awake") }

        // Reports stored before the flag and fetch time were kept.
        guard let flag = session.awakeFlag, let fetched = session.fetchedAt else {
            let age = now.timeIntervalSince(session.endDate)
            return (age >= 0 && age < staleAfter, "no flag: ended \(Int(age / 60)) min ago")
        }
        if flag != 0 { return (false, "band closed the night") }
        let lag = fetched.timeIntervalSince(session.endDate)
        if lag > stoppedGrowingAfter { return (false, "night stopped growing \(Int(lag / 60)) min before the fetch") }
        let age = now.timeIntervalSince(fetched)
        if age >= staleAfter { return (false, "open night, but fetched \(Int(age / 60)) min ago") }
        return (true, "open night, growing at the fetch")
    }
}
