import AppIntents

// MARK: - SyncBandIntent
//
// "Sync band" — Shortcuts / Siri trigger that runs an Apple Health sync on demand.
// Reuses BackgroundSyncManager.syncNow(), which is foreground-aware: it syncs over the live link
// if the app is already connected, otherwise connects, syncs, and disconnects.

struct SyncBandIntent: AppIntent {

    static var title: LocalizedStringResource = "Sync band"
    static var description = IntentDescription(
        "Connects to the Mi Band 10 and syncs health data to Apple Health."
    )

    // Runs in the background without bringing the app to the foreground.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppServices.shared.bootstrap(container: My_BandApp.sharedModelContainer)
        do {
            let sync = BackgroundSyncManager.shared.startIntentSync()
            let outcome = try await BackgroundSyncManager.value(of: sync)
            return .result(dialog: IntentDialog(stringLiteral: Self.summary(outcome)))
        } catch is BackgroundSyncManager.StillSyncing {
            return .result(dialog: "Still syncing with the band. The data will reach Apple Health shortly.")
        } catch SyncError.noDeviceRecord {
            return .result(dialog: "No band paired. Open My Band to set it up.")
        } catch SyncError.notConnected, SyncError.timeout {
            return .result(dialog: "Couldn't connect to the band. Make sure it's nearby.")
        } catch {
            return .result(dialog: "Sync failed: \(error.localizedDescription)")
        }
    }

    private static func summary(_ o: BandSyncer.HealthSyncOutcome) -> String {
        if o.healthSamplesWritten == 0 {
            return "Already up to date. No new data."
        }
        var parts: [String] = []
        if o.sleepSessions  > 0 { parts.append(o.sleepSessions  == 1 ? "1 sleep session"   : "\(o.sleepSessions) sleep sessions") }
        if o.workouts       > 0 { parts.append(o.workouts       == 1 ? "1 workout"            : "\(o.workouts) workouts") }
        if o.dailySummaries > 0 { parts.append(o.dailySummaries == 1 ? "1 daily summary"     : "\(o.dailySummaries) daily summaries") }
        if o.manualSamples  > 0 { parts.append(o.manualSamples  == 1 ? "1 manual measurement"    : "\(o.manualSamples) manual measurements") }

        let detail = parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
        return "Synced to Apple Health\(detail)."
    }
}
