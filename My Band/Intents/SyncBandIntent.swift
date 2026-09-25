import AppIntents

// MARK: - SyncBandIntent
//
// "Sincronizar pulseira" — Shortcuts / Siri trigger that runs an Apple Health sync on demand.
// Reuses BackgroundSyncManager.syncNow(), which is foreground-aware: it syncs over the live link
// if the app is already connected, otherwise connects, syncs, and disconnects.

struct SyncBandIntent: AppIntent {

    static var title: LocalizedStringResource = "Sincronizar pulseira"
    static var description = IntentDescription(
        "Conecta à Mi Band 10 e sincroniza os dados de saúde com o Apple Health."
    )

    // Runs in the background without bringing the app to the foreground.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let outcome = try await BackgroundSyncManager.shared.syncNow(retryStaleLink: false)
            return .result(dialog: IntentDialog(stringLiteral: Self.summary(outcome)))
        } catch SyncError.noDeviceRecord {
            return .result(dialog: "Nenhuma pulseira pareada. Abra o My Band para configurar.")
        } catch SyncError.notConnected, SyncError.timeout {
            return .result(dialog: "Não foi possível conectar à pulseira. Verifique se ela está por perto.")
        } catch {
            return .result(dialog: "Falha na sincronização: \(error.localizedDescription)")
        }
    }

    private static func summary(_ o: BandSyncer.HealthSyncOutcome) -> String {
        if o.healthSamplesWritten == 0 {
            return "Tudo já estava sincronizado. Nenhum dado novo."
        }
        var parts: [String] = []
        if o.sleepSessions  > 0 { parts.append(o.sleepSessions  == 1 ? "1 sessão de sono"   : "\(o.sleepSessions) sessões de sono") }
        if o.workouts       > 0 { parts.append(o.workouts       == 1 ? "1 treino"            : "\(o.workouts) treinos") }
        if o.dailySummaries > 0 { parts.append(o.dailySummaries == 1 ? "1 resumo diário"     : "\(o.dailySummaries) resumos diários") }
        if o.manualSamples  > 0 { parts.append(o.manualSamples  == 1 ? "1 medição manual"    : "\(o.manualSamples) medições manuais") }

        let detail = parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
        return "Sincronizado com o Apple Health\(detail)."
    }
}
