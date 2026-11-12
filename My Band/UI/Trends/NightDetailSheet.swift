import SwiftUI
import Charts

// MARK: - NightDetailSheet
//
// One night of the Sleep & trends window (ADR 0010 addendum): its stages, the vitals Apple Health
// holds inside its main sleep, and how it felt. Everything but the rating is read, not stored.

struct NightDetailSheet: View {
    let nights: [SleepTrend.Night]
    let vitals: [Date: NightVitals]
    @Binding var day: Date

    private var night: SleepTrend.Night? { nights.first { $0.day == day } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MB.Space.x4) {
                NightDayStrip(nights: nights, day: $day)
                if let night {
                    NightHeader(night: night)
                    NightTiles(night: night, nights: nights, vitals: vitals)
                    NightRatingCard(day: night.day).id(night.day)
                    NightStagesCard(night: night)
                    NightVitalsCard(vitals: vitals[night.day] ?? NightVitals())
                    Text("Read from Apple Health, every source. The rating stays on this iPhone.")
                        .font(.mbCaption).foregroundStyle(MB.textTertiary)
                }
            }
            .padding(.horizontal, MB.Space.screenPad)
            .padding(.top, MB.Space.x6)
            .padding(.bottom, MB.Space.x8)
        }
        .background(MB.bgApp.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(MB.bgApp)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Day strip

private struct NightDayStrip: View {
    let nights: [SleepTrend.Night]
    @Binding var day: Date

    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0 ..< SleepTrend.days).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { d in
                let has = nights.contains { $0.day == d }
                let selected = d == day
                Button { day = d } label: {
                    VStack(spacing: 2) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated).locale(MBFormat.locale))).font(.system(size: 11))
                        Text(d.formatted(.dateTime.day().locale(MBFormat.locale))).font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(selected ? MB.textPrimary : has ? MB.textSecondary : MB.textDisabled)
                    .background(selected ? MB.accentSoft : MB.surfaceCard)
                    .overlay(RoundedRectangle(cornerRadius: MB.Radius.md, style: .continuous)
                        .strokeBorder(selected ? MB.accent : MB.hairline, lineWidth: 1))
                    .mbCornerRadius(MB.Radius.md)
                }
                .buttonStyle(.plain)
                .disabled(!has)
                .accessibilityLabel(d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(MBFormat.locale)))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Header

private struct NightHeader: View {
    let night: SleepTrend.Night

    var body: some View {
        let cal = Calendar.current
        let eve = cal.date(byAdding: .day, value: -1, to: night.day) ?? night.day
        let short = Date.FormatStyle.dateTime.weekday(.abbreviated).day().locale(MBFormat.locale)
        let time = Date.FormatStyle.dateTime.hour().minute().locale(MBFormat.locale)
        VStack(alignment: .leading, spacing: 2) {
            Text("Night of \(eve.formatted(short)) → \(night.day.formatted(short))")
                .font(.mbTitle1).foregroundStyle(MB.textPrimary)
            Text("\(night.start.formatted(time)) – \(night.end.formatted(time)) asleep")
                .font(.mbSubhead).monospacedDigit().foregroundStyle(MB.textSecondary)
        }
    }
}

// MARK: - Tiles

private struct NightTiles: View {
    let night: SleepTrend.Night
    let nights: [SleepTrend.Night]
    let vitals: [Date: NightVitals]

    private var others: [SleepTrend.Night] { nights.filter { $0.day != night.day } }
    private var own: NightVitals { vitals[night.day] ?? NightVitals() }

    var body: some View {
        let asleepDelta = NightVitals.delta(Double(night.mainAsleep), others: others.map { Double($0.mainAsleep) })
        let hrv = own.hrvMedian
        let hrvDelta = NightVitals.delta(hrv, others: others.compactMap { vitals[$0.day]?.hrvMedian })
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                NightTile(label: "Asleep", value: MBFormat.hoursMinutesShort(Double(night.mainAsleep) * 60), unit: nil,
                          tint: MB.textPrimary, foot: delta(asleepDelta) { MBFormat.hoursMinutesShort(abs($0) * 60) })
                NightTile(label: "HRV, median", value: number(hrv), unit: "ms", tint: MB.accent400,
                          foot: delta(hrvDelta) { "\(Int(abs($0).rounded())) ms" })
            }
            GridRow {
                NightTile(label: "Lowest heart rate", value: number(own.hrMin), unit: "bpm", tint: MB.hr,
                          foot: own.hrAvg.map { .plain("avg \(Int($0.rounded())) bpm") })
                NightTile(label: "Blood oxygen", value: number(own.spo2Avg), unit: "%", tint: MB.spo2,
                          foot: own.spo2Min.map { .plain("lowest \(Int($0.rounded()))%") })
            }
        }
    }

    private func number(_ v: Double?) -> String? { v.map { "\(Int($0.rounded()))" } }

    /// Up is mint and down amber for both tiles: more sleep and a higher HRV both read as better.
    private func delta(_ d: Double?, _ format: (Double) -> String) -> NightTile.Foot? {
        guard let d else { return nil }
        if format(d) == format(0) { return .plain("same as avg") }
        return d > 0 ? .tinted("▲ \(format(d)) vs avg", MB.ok) : .tinted("▼ \(format(d)) vs avg", MB.warn)
    }
}

private struct NightTile: View {
    enum Foot {
        case plain(String)
        case tinted(String, Color)
    }

    let label: String
    /// nil reads as a dash: Apple Health returns nothing for a denied read, so none and denied look alike.
    let value: String?
    let unit: String?
    let tint: Color
    let foot: Foot?

    var body: some View {
        VStack(alignment: .leading, spacing: MB.Space.x1) {
            Text(label).font(.mbCaption).foregroundStyle(MB.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—").font(.system(size: 26, weight: .bold)).monospacedDigit()
                    .foregroundStyle(value == nil ? MB.textTertiary : tint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit, value != nil {
                    Text(unit).font(.mbSubhead).foregroundStyle(MB.textSecondary)
                }
            }
            switch foot {
            case .plain(let text)?: Text(text).font(.mbCaption).foregroundStyle(MB.textSecondary)
            case .tinted(let text, let color)?: Text(text).font(.mbCaption).foregroundStyle(color)
            case nil: Text(" ").font(.mbCaption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MB.surfaceCard)
        .overlay(RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous).strokeBorder(MB.hairline, lineWidth: 1))
        .mbCornerRadius(MB.Radius.lg)
    }
}

// MARK: - Rating

private struct NightRatingCard: View {
    let day: Date
    @State private var value: Double = 0
    @State private var rated = false

    var body: some View {
        MBCard(padding: MB.Space.x4) {
            VStack(alignment: .leading, spacing: MB.Space.x2) {
                HStack {
                    Text("How did it feel?").font(.mbSubheadEmph).foregroundStyle(MB.textPrimary)
                    Spacer()
                    if rated {
                        Text("\(Int(value)) of \(NightRatings.range.upperBound)")
                            .font(.mbSubheadEmph).monospacedDigit().foregroundStyle(MB.accent400)
                        Button("Clear") {
                            NightRatings.set(nil, for: day)
                            rated = false
                            value = 0
                        }
                        .font(.mbSubhead).tint(MB.accent).padding(.leading, MB.Space.x2)
                    } else {
                        Text("Slide to rate").font(.mbSubhead).foregroundStyle(MB.textTertiary)
                    }
                }
                Slider(value: $value,
                       in: Double(NightRatings.range.lowerBound) ... Double(NightRatings.range.upperBound),
                       step: 1) { editing in
                    if !editing { save() }
                }
                .tint(MB.accent)
                .opacity(rated ? 1 : 0.45)
                .accessibilityLabel("Night rating")
                .accessibilityValue(rated ? "\(Int(value)) of \(NightRatings.range.upperBound)" : "Not rated")
                // VoiceOver's swipe adjusts without an editing callback, so it saves here.
                .accessibilityAdjustableAction { direction in
                    let range = NightRatings.range
                    switch direction {
                    case .increment: value = Double(min(Int(value) + 1, range.upperBound))
                    case .decrement: value = Double(max(Int(value) - 1, range.lowerBound))
                    @unknown default: return
                    }
                    save()
                }
            }
        }
        .onAppear {
            let stored = NightRatings.rating(for: day)
            rated = stored != nil
            value = Double(stored ?? 0)
        }
    }

    private func save() {
        NightRatings.set(Int(value), for: day)
        rated = true
    }
}

// MARK: - Stages

private struct NightStagesCard: View {
    let night: SleepTrend.Night

    private static let order: [SleepTrend.Stage] = [.deep, .core, .rem, .unspecified, .awake]

    private var rows: [(stage: SleepTrend.Stage, minutes: Int)] {
        var totals: [SleepTrend.Stage: TimeInterval] = [:]
        for s in night.segments { totals[s.stage, default: 0] += s.end.timeIntervalSince(s.start) }
        return Self.order.compactMap { stage in
            totals[stage].map { (stage, Int(($0 / 60).rounded())) }
        }
    }

    var body: some View {
        let time = Date.FormatStyle.dateTime.hour().minute().locale(MBFormat.locale)
        let longest = max(rows.map(\.minutes).max() ?? 1, 1)
        MBCard(padding: MB.Space.x4) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stages").font(.mbSubheadEmph).foregroundStyle(MB.textPrimary)
                GeometryReader { geo in
                    let span = night.end.timeIntervalSince(night.start)
                    ZStack(alignment: .leading) {
                        MB.surfaceRaised
                        ForEach(Array(night.segments.enumerated()), id: \.offset) { _, s in
                            s.stage.color
                                .frame(width: max(geo.size.width * s.end.timeIntervalSince(s.start) / span, 1))
                                .offset(x: geo.size.width * s.start.timeIntervalSince(night.start) / span)
                        }
                    }
                }
                .frame(height: 28)
                .mbCornerRadius(MB.Radius.sm)
                .accessibilityHidden(true)
                HStack {
                    Text(night.start.formatted(time))
                    Spacer()
                    Text(night.end.formatted(time))
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(MB.textSecondary)
                VStack(spacing: MB.Space.x2) {
                    ForEach(rows, id: \.stage) { row in
                        HStack(spacing: 10) {
                            Text(row.stage.title).font(.mbFootnote).foregroundStyle(MB.textSecondary)
                                .frame(width: 56, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(MB.surfaceRaised)
                                    Capsule().fill(row.stage.color)
                                        .frame(width: geo.size.width * Double(row.minutes) / Double(longest))
                                }
                            }
                            .frame(height: 8)
                            Text(MBFormat.hoursMinutesShort(Double(row.minutes) * 60))
                                .font(.mbFootnote).monospacedDigit().foregroundStyle(MB.textPrimary)
                                .frame(width: 60, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

// MARK: - Vitals

private struct NightVitalsCard: View {
    let vitals: NightVitals

    var body: some View {
        MBCard(padding: 0) {
            VStack(spacing: 0) {
                row("Heart rate", vitals.hr, tint: MB.hr) { "\(range($0)) bpm" }
                Divider().overlay(MB.hairline)
                row("HRV", vitals.hrv, tint: MB.accent) { "\(range($0)) ms · \($0.count) values" }
                Divider().overlay(MB.hairline)
                row("Blood oxygen", vitals.spo2, tint: MB.spo2) { "\(range($0))%" }
            }
            .padding(.horizontal, MB.Space.x4)
            .padding(.vertical, MB.Space.x1)
        }
    }

    private func range(_ points: [VitalPoint]) -> String {
        let values = points.map { Int($0.value.rounded()) }
        guard let lo = values.min(), let hi = values.max() else { return "" }
        return lo == hi ? "\(lo)" : "\(lo) – \(hi)"
    }

    private func row(_ title: String, _ points: [VitalPoint], tint: Color,
                     detail: ([VitalPoint]) -> String) -> some View {
        HStack(spacing: MB.Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mbSubhead).foregroundStyle(MB.textPrimary)
                Text(points.isEmpty ? "No readings" : detail(points))
                    .font(.mbCaption).monospacedDigit().foregroundStyle(MB.textSecondary)
            }
            Spacer(minLength: 0)
            if points.count > 1 {
                Chart(points, id: \.date) { p in
                    LineMark(x: .value("Time", p.date), y: .value(title, p.value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(width: 120, height: 32)
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stage colour

extension SleepTrend.Stage {
    var color: Color {
        switch self {
        case .deep: MB.sleepDeep
        case .core: MB.sleepLight
        case .rem: MB.sleepREM
        case .unspecified: MB.accent
        case .awake: MB.sleepAwake
        }
    }
}
