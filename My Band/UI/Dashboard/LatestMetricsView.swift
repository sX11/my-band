import SwiftUI
import SwiftData

// MARK: - LatestMetricsView
//
// The newest value of every health reading the app has from the band: the live one-shot from
// TodayActivityService, the last sync's snapshot (LatestMetricsStore), the last night from SwiftData
// and the scale's last weighing. Latest values only — trends and history belong to Apple Health.

struct LatestMetricsView: View {

    @Environment(TodayActivityService.self) private var today
    @Environment(LatestMetricsStore.self) private var store
    @Environment(ScaleManager.self) private var scale
    @Environment(\.dismiss) private var dismiss

    @Query private var recentSleep: [SleepSession]

    /// Forgetting a band keeps its sessions in SwiftData; only the paired band's nights belong here,
    /// filtered in the fetch so another band's sessions can't use up the limit.
    init(deviceID: UUID?) {
        _recentSleep = Query(Self.sleepDescriptor(deviceID: deviceID))
    }

    static func sleepDescriptor(deviceID: UUID?) -> FetchDescriptor<SleepSession> {
        let id = deviceID ?? UUID()
        var d = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.device?.id == id },
                                              sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        d.fetchLimit = 60
        return d
    }

    private var lastSleep: Night? { Self.lastNight(recentSleep) }

    struct Night: Equatable {
        let start: Date
        let end: Date
        let phases: [SleepPhase]

        func duration(_ type: SleepPhaseType) -> TimeInterval {
            phases.filter { $0.type == type }.reduce(0) { $0 + $1.duration }
        }
        var asleep: TimeInterval { duration(.light) + duration(.deep) + duration(.rem) }
        var efficiency: Double {
            let inBed = end.timeIntervalSince(start)
            return inBed > 0 ? min(asleep / inBed, 1) : 0
        }
    }

    /// One night arrives as several overlapping sessions (each resync of a night in progress, and
    /// the stages and details files), so it is merged and de-overlapped the way writeSleep does
    /// for Apple Health; the newest session alone is a fragment or double-counts.
    static func lastNight(_ sessions: [SleepSession]) -> Night? {
        guard let group = HealthKitManager.groupOverlapping(sessions).last,
              let start = group.map(\.startDate).min(), let end = group.map(\.endDate).max(),
              end > start else { return nil }
        return Night(start: start, end: end,
                     phases: SleepDetailsParser.sanitizeStages(group.flatMap(\.phases)))
    }

    private var m: LatestMetrics { store.metrics }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    liveSection(now: context.date)
                    summarySection(now: context.date)
                    readingsSection(now: context.date)
                    sleepSection
                    bodySection(now: context.date)
                    Section {
                    } footer: {
                        Text(footer(now: context.date)).font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(MB.bgApp.ignoresSafeArea())
            }
            .navigationTitle("Health")
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

    @ViewBuilder private func liveSection(now: Date) -> some View {
        if let at = today.updatedAt, Calendar.current.isDate(at, inSameDayAs: now) {
            Section("Live from the band · \(Self.time(at))") {
                if let steps = today.steps { row("Steps", steps.formatted(.number.locale(MBFormat.locale))) }
                if let kcal = today.calories { row("Active energy", "\(kcal) kcal") }
                if let bpm = today.heartRate {
                    row("Heart rate", "\(bpm) bpm")
                } else if today.reading {
                    row("Heart rate", "Measuring…")
                }
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    @ViewBuilder private func summarySection(now: Date) -> some View {
        if let day = m.summaryDay {
            Section(Self.dayLabel(day, now: now)) {
                if let hours = m.standingHours { row("Stood", "\(hours) h", detail: Self.standingDetail(m.standingMask)) }
                if let v = m.restingHR { row("Resting heart rate", "\(v) bpm") }
                if let v = m.avgHR { row("Average heart rate", "\(v) bpm") }
                if let r = m.maxHR { row("Highest heart rate", "\(Int(r.value)) bpm", detail: Self.time(r.at)) }
                if let r = m.minHR { row("Lowest heart rate", "\(Int(r.value)) bpm", detail: Self.time(r.at)) }
                if let v = m.spo2Avg { row("Average SpO₂", "\(v)%") }
                if let r = m.spo2Min { row("Lowest SpO₂", "\(Int(r.value))%", detail: Self.time(r.at)) }
                if let r = m.spo2Max { row("Highest SpO₂", "\(Int(r.value))%", detail: Self.time(r.at)) }
                if let v = m.avgStress { row("Average stress", "\(v)") }
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    @ViewBuilder private func readingsSection(now: Date) -> some View {
        if m.heartRate != nil || m.spo2 != nil || m.stress != nil || m.temperature != nil {
            Section("Latest readings") {
                if let r = m.heartRate { row("Heart rate", "\(Int(r.value)) bpm", detail: MBFormat.ago(r.at, now: now)) }
                if let r = m.spo2 { row("SpO₂", "\(Int(r.value))%", detail: MBFormat.ago(r.at, now: now)) }
                if let r = m.stress { row("Stress", "\(Int(r.value))", detail: MBFormat.ago(r.at, now: now)) }
                if let r = m.temperature {
                    row("Skin temperature", r.value.formatted(.number.precision(.fractionLength(1)).locale(MBFormat.locale)) + " °C",
                        detail: MBFormat.ago(r.at, now: now))
                }
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    @ViewBuilder private var sleepSection: some View {
        if let s = lastSleep {
            Section("Last sleep · \(s.end.formatted(.dateTime.weekday(.wide).locale(MBFormat.locale)))") {
                row("Asleep", Self.duration(s.asleep),
                    detail: "\(Self.time(s.start))–\(Self.time(s.end))")
                row("Deep", Self.duration(s.duration(.deep)))
                row("REM", Self.duration(s.duration(.rem)))
                row("Light", Self.duration(s.duration(.light)))
                row("Awake", Self.duration(s.duration(.awake)))
                row("Efficiency", "\(Int((s.efficiency * 100).rounded()))%")
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    @ViewBuilder private func bodySection(now: Date) -> some View {
        if let kg = scale.lastWeightKg {
            Section("Body") {
                row("Weight", kg.formatted(.number.precision(.fractionLength(1)).locale(MBFormat.locale)) + " kg",
                    detail: scale.lastWeightDate.map { MBFormat.ago($0, now: now) })
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

    private func footer(now: Date) -> String {
        guard !m.isEmpty || lastSleep != nil else {
            return "Nothing yet — sync the band to fill this in. Apple Health keeps the full history."
        }
        // The snapshot's own time: it is saved as files arrive, so a sync that fails later still moved it.
        let updated = store.updatedAt.map { "Readings updated \(MBFormat.ago($0, now: now))." } ?? ""
        return "\(updated) Apple Health keeps the full history.".trimmingCharacters(in: .whitespaces)
    }

    // MARK: Formatting

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(MBFormat.locale))
    }

    private static func dayLabel(_ day: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(day, inSameDayAs: now) { return "Today · as of last sync" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(MBFormat.locale))
    }

    private static func duration(_ seconds: TimeInterval) -> String { MBFormat.hoursMinutes(seconds) }

    /// "8:00–13:00, 14:00–15:00" — the set bits, merged into runs.
    static func standingDetail(_ mask: Int?) -> String? {
        guard let mask, mask != 0 else { return nil }
        let hours = (0..<24).filter { mask & (1 << $0) != 0 }
        var runs: [String] = []
        var start = hours[0], prev = hours[0]
        for h in hours.dropFirst() + [Int.max] {
            if h == prev + 1 { prev = h; continue }
            runs.append("\(start):00–\(prev + 1):00")
            start = h; prev = h
        }
        return runs.joined(separator: ", ")
    }
}
