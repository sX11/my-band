import SwiftUI

// MARK: - HealthSyncView
//
// What the syncs sent to Apple Health: the last sync's samples per type and the band files behind
// them, then every other type with the last time it was sent. Sync status, not health data.

struct HealthSyncView: View {

    @Environment(HealthSyncLog.self) private var syncLog
    @Environment(BandSyncer.self) private var syncer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    if let report = syncLog.last {
                        lastSyncSection(report, now: context.date)
                        filesSection(report)
                        earlierSection(report, now: context.date)
                    } else {
                        Section {
                            Text(syncer.lastHealthSync == nil
                                 ? "Nothing synced yet."
                                 : "The next sync will list what it sends.")
                                .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                        }
                        .listRowBackground(MB.surfaceCard)
                    }
                    Section {
                    } footer: {
                        Text("Counts are samples sent. Apple Health replaces a sample it already has, so a resent one isn't duplicated.")
                            .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(MB.bgApp.ignoresSafeArea())
            }
            .navigationTitle("Apple Health")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(MB.accent)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private func lastSyncSection(_ r: HealthSyncReport, now: Date) -> some View {
        Section("Last sync · \(MBFormat.ago(r.at, now: now))\(r.failed ? " · failed part-way" : "")") {
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
            if r.waitingForUnlock {
                Text("The phone was locked, so steps, distance and energy wait for a sync after it's unlocked. Apple Health can't be read while locked, and they are matched against the iPhone's own counts.")
                    .font(.mbFootnote).foregroundStyle(MB.textSecondary)
            }
        }
        .listRowBackground(MB.surfaceCard)
    }

    private func filesSection(_ r: HealthSyncReport) -> some View {
        Section("From the band") {
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
