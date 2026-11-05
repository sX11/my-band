import SwiftUI

// MARK: - HealthSyncSections
//
// The sync log at the foot of the Health sheet: what the last sync sent to Apple Health per type and
// the band files behind it, then every other type with the last time it was sent. Sync status, not
// health data.

struct HealthSyncSections: View {

    @Environment(HealthSyncLog.self) private var syncLog
    @Environment(BandSyncer.self) private var syncer

    let now: Date

    var body: some View {
        if let report = syncLog.last {
            lastSyncSection(report, now: now)
            filesSection(report)
            earlierSection(report, now: now)
        } else {
            Section("Apple Health sync") {
                Text(syncer.lastHealthSync == nil
                     ? "Nothing synced yet."
                     : "The next sync will list what it sends.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    private func lastSyncSection(_ r: HealthSyncReport, now: Date) -> some View {
        Section("Synced to Apple Health · \(MBFormat.ago(r.at, now: now))\(r.failed ? " · failed part-way" : "")") {
            if r.byType.isEmpty {
                Text("Nothing new to send.").font(.mbBody).foregroundStyle(MB.textSecondary)
            } else {
                ForEach(Self.sorted(r.byType), id: \.key) { type, count in
                    row(HealthSyncLog.name(type), MBFormat.number(count))
                }
                row("Total", MBFormat.number(r.total))
            }
            if r.failed, let error = r.error {
                Text("Stopped: \(error)").font(.mbFootnote).foregroundStyle(MB.textSecondary)
            }
        }
        .listRowBackground(MB.surfaceCard)
    }

    private func filesSection(_ r: HealthSyncReport) -> some View {
        Section("Band files in that sync") {
            row("Files fetched", "\(r.filesFetched)")
            if r.filesFailed > 0 { row("Files not delivered", "\(r.filesFailed)") }
            if r.sleepSessions > 0 { row("Sleep sessions", "\(r.sleepSessions)") }
            if r.dailySummaries > 0 { row("Daily summaries", "\(r.dailySummaries)") }
            if r.minuteSamples > 0 { row("Minute records", MBFormat.number(r.minuteSamples)) }
            if r.manualSamples > 0 { row("Spot measurements", "\(r.manualSamples)") }
            if r.workouts > 0 { row("Workouts", "\(r.workouts)") }
        }
        .listRowBackground(MB.surfaceCard)
    }

    @ViewBuilder private func earlierSection(_ r: HealthSyncReport, now: Date) -> some View {
        let earlier = syncLog.lastByType
            .filter { r.byType[$0.key] == nil }
            .sorted { $0.value.at > $1.value.at }
        if !earlier.isEmpty {
            Section("Sent earlier") {
                ForEach(earlier, id: \.key) { type, total in
                    row(HealthSyncLog.name(type), MBFormat.number(total.count), detail: MBFormat.ago(total.at, now: now))
                }
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    private func row(_ label: String, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.mbBody).foregroundStyle(MB.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.mbBody).monospacedDigit().foregroundStyle(MB.textPrimary)
                if let detail {
                    Text(detail).font(.mbFootnote).foregroundStyle(MB.textTertiary)
                }
            }
        }
    }

    // MARK: Formatting

    private static func sorted(_ byType: [String: Int]) -> [(key: String, value: Int)] {
        byType.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }

}
