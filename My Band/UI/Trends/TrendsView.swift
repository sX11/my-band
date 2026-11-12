import SwiftUI
import Charts
import HealthKit

// MARK: - TrendsView
//
// The page left of the Dashboard (ADR 0010): seven days of sleep, resting heart rate, steps,
// SpO₂ and weight read back from Apple Health each time the page appears, and the night sheet's
// vitals with them. Nothing read here is stored.

struct TrendsView: View {

    /// Loads only while this is the selected page, so the paged TabView preloading it next to the
    /// Dashboard doesn't read Health, or raise its prompt, unseen.
    var isActive: Bool

    @State private var trends: Trends?
    @State private var errorText: String?
    @State private var openNight: OpenNight?
    private let navigation = AppNavigation.shared

    struct Trends {
        var sleep: [SleepTrend.Night] = []
        var vitals: [Date: NightVitals] = [:]
        var restingHR: [DayValue] = []
        var steps: [DayValue] = []
        var spo2: [DayValue] = []
        var weight: [DayValue] = []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MB.Space.x4) {
                    if let errorText {
                        MBCard { Text(errorText).font(.mbFootnote).foregroundStyle(MB.textTertiary) }
                    } else if let trends {
                        SleepTrendCard(nights: trends.sleep, vitals: trends.vitals) { openNight = OpenNight(day: $0) }
                        DayTrendCard(title: "Resting heart rate", icon: "heart.fill", tint: MB.hr,
                                     values: trends.restingHR, style: .line, format: { "\(Int($0.rounded()))" }, unit: "bpm")
                        DayTrendCard(title: "Steps", icon: "figure.walk", tint: MB.steps,
                                     values: trends.steps, style: .bar, format: { MBFormat.number(Int($0.rounded())) }, unit: "steps")
                        DayTrendCard(title: "SpO₂", icon: "drop.fill", tint: MB.spo2,
                                     values: trends.spo2, style: .line, format: { "\(Int($0.rounded()))" }, unit: "%")
                        DayTrendCard(title: "Weight", icon: "scalemass.fill", tint: MB.accent,
                                     values: trends.weight, style: .line,
                                     format: { $0.formatted(.number.precision(.fractionLength(1)).locale(MBFormat.locale)) }, unit: "kg")
                        Text("These are Apple Health's daily totals from every source, so steps include the iPhone's.")
                            .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, MB.Space.x6)
                    }
                }
                .padding(.horizontal, MB.Space.screenPad)
                .padding(.top, MB.Space.x2)
                .padding(.bottom, MB.Space.x10)
            }
            .background(MB.bgApp.ignoresSafeArea())
            .refreshable { await load() }
            .navigationTitle("Sleep & trends")
        }
        .task(id: isActive) {
            guard isActive else { return }
            await load()
        }
        // An inactive page loads, and so consumes the request, once RootView turns to it.
        .onChange(of: navigation.openNight) { _, night in
            if night != nil, isActive { Task { await load() } }
        }
        .sheet(item: $openNight) { opened in
            NightDetailSheet(nights: trends?.sleep ?? [], vitals: trends?.vitals ?? [:],
                             day: Binding(get: { openNight?.day ?? opened.day }, set: { openNight?.day = $0 }))
        }
    }

    /// A notification tap's night, opened by a load that began after the tap, so a night the sync
    /// just wrote is in. One Health doesn't hold yet opens the latest night instead.
    private func consumeOpenNight(_ request: Date?, in trends: Trends) {
        guard let request, navigation.openNight == request else { return }
        navigation.openNight = nil
        let day = trends.sleep.contains(where: { $0.day == request }) ? request : trends.sleep.last?.day
        if let day { openNight = OpenNight(day: day) }
    }

    private func load() async {
        let request = navigation.openNight
        let hk = HealthKitManager.shared
        do {
            // A no-op once answered; asks only if this page opens before any sync did.
            try await hk.requestAuthorization()
            async let sleep = hk.sleepTrend()
            async let resting = hk.dailyTrend(.restingHeartRate, unit: .count().unitDivided(by: .minute()))
            async let steps = hk.dailyTrend(.stepCount, unit: .count())
            async let spo2 = hk.dailyTrend(.oxygenSaturation, unit: .percent())
            async let weight = hk.dailyTrend(.bodyMass, unit: .gramUnit(with: .kilo))
            let nights = try await sleep
            // The spans come from the nights, so this waits on sleep while the other reads run on.
            let vitals = try await hk.nightVitals(spans: Dictionary(uniqueKeysWithValues: nights.map { ($0.day, $0.span) }))
            var t = Trends(sleep: nights, vitals: vitals, restingHR: try await resting, steps: try await steps,
                           spo2: try await spo2, weight: try await weight)
            t.spo2 = t.spo2.map { DayValue(day: $0.day, value: $0.value * 100) }
            trends = t
            errorText = nil
            consumeOpenNight(request, in: t)
        } catch is CancellationError {
            return
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            errorText = "Unlock your iPhone to read Apple Health."
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Its own id, so switching nights inside the sheet doesn't present it again.
private struct OpenNight: Identifiable {
    let id = UUID()
    var day: Date
}

// MARK: - Sleep trend

private struct SleepTrendCard: View {
    let nights: [SleepTrend.Night]
    let vitals: [Date: NightVitals]
    let onOpen: (Date) -> Void

    private struct Bar: Identifiable {
        let day: Date
        let stage: SleepTrend.Stage
        let hours: Double
        var id: String { "\(day.timeIntervalSince1970)-\(stage)" }
    }

    private var bars: [Bar] {
        nights.flatMap { n in
            SleepTrend.Stage.asleep.compactMap { s in
                n.minutes[s].map { Bar(day: n.day, stage: s, hours: Double($0) / 60) }
            }
        }
    }

    var body: some View {
        MBCard {
            VStack(alignment: .leading, spacing: MB.Space.x3) {
                TrendHeader(title: "Sleep", icon: "bed.double.fill", tint: MB.sleepLight)
                if nights.isEmpty {
                    TrendEmpty()
                } else {
                    let avg = Double(nights.map(\.total).reduce(0, +)) / Double(nights.count) * 60
                    TrendHeadline(value: MBFormat.hoursMinutes(avg), unit: "a night on average")
                    Chart(bars) { b in
                        BarMark(x: .value("Night", b.day, unit: .day), y: .value("Hours", b.hours))
                            .foregroundStyle(by: .value("Stage", b.stage.title))
                    }
                    .chartForegroundStyleScale([
                        SleepTrend.Stage.deep.title: SleepTrend.Stage.deep.color,
                        SleepTrend.Stage.rem.title: SleepTrend.Stage.rem.color,
                        SleepTrend.Stage.core.title: SleepTrend.Stage.core.color,
                        SleepTrend.Stage.unspecified.title: SleepTrend.Stage.unspecified.color,
                    ])
                    .chartXScale(domain: TrendFormat.weekDomain)
                    .trendAxes()
                    // A tap only, no drag, so a horizontal swipe still reaches the page view.
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { tap in
                                    guard let plot = proxy.plotFrame,
                                          let at: Date = proxy.value(atX: tap.location.x - geo[plot].origin.x)
                                    else { return }
                                    let day = Calendar.current.startOfDay(for: at)
                                    if nights.contains(where: { $0.day == day }) { onOpen(day) }
                                })
                        }
                    }
                    .frame(height: 140)
                    if let latest = nights.last {
                        Divider().overlay(MB.hairline)
                        Button { onOpen(latest.day) } label: {
                            HStack {
                                Text(latestLine(latest)).font(.mbFootnote).monospacedDigit().foregroundStyle(MB.textSecondary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(MB.textTertiary)
                            }
                            .frame(minHeight: MB.Space.rowMinHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the night's stages, vitals and rating")
                    }
                }
            }
        }
    }
}

private extension SleepTrendCard {
    /// "Tue 11 Nov · 6 h 16 m asleep · HRV 22 ms".
    func latestLine(_ night: SleepTrend.Night) -> String {
        var parts = [night.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(MBFormat.locale)),
                     "\(MBFormat.hoursMinutesShort(Double(night.mainAsleep) * 60)) asleep"]
        if let hrv = vitals[night.day]?.hrvMedian { parts.append("HRV \(Int(hrv.rounded())) ms") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Daily trend

private struct DayTrendCard: View {
    enum Style { case line, bar }

    let title: String
    let icon: String
    let tint: Color
    let values: [DayValue]
    let style: Style
    let format: (Double) -> String
    let unit: String

    var body: some View {
        MBCard {
            VStack(alignment: .leading, spacing: MB.Space.x3) {
                TrendHeader(title: title, icon: icon, tint: tint)
                if let latest = values.last {
                    // A cumulative day reads as the average of the finished days, since today is still
                    // counting; a measured one as the newest day's value.
                    if style == .bar {
                        let done = values.filter { !Calendar.current.isDateInToday($0.day) }
                        let days = done.isEmpty ? values : done
                        let avg = days.map(\.value).reduce(0, +) / Double(days.count)
                        TrendHeadline(value: format(avg), unit: "\(unit) a day on average")
                    } else {
                        TrendHeadline(value: format(latest.value), unit: "\(unit) · \(TrendFormat.day(latest.day))")
                    }
                    Chart(values) { v in
                        switch style {
                        case .bar:
                            BarMark(x: .value("Day", v.day, unit: .day), y: .value(title, v.value))
                                .foregroundStyle(tint)
                        case .line:
                            LineMark(x: .value("Day", v.day, unit: .day), y: .value(title, v.value))
                                .foregroundStyle(tint)
                            PointMark(x: .value("Day", v.day, unit: .day), y: .value(title, v.value))
                                .foregroundStyle(tint)
                        }
                    }
                    .chartXScale(domain: TrendFormat.weekDomain)
                    .chartYScale(domain: .automatic(includesZero: style == .bar))
                    .trendAxes()
                    .frame(height: 120)
                } else {
                    TrendEmpty()
                }
            }
        }
    }
}

// MARK: - Pieces

private struct TrendHeader: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: MB.Space.x2) {
            RoundedRectangle(cornerRadius: MB.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint))
            Text(title).font(.mbSubheadEmph).foregroundStyle(MB.textSecondary)
        }
    }
}

private struct TrendHeadline: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.mbTitle2).monospacedDigit().foregroundStyle(MB.textPrimary)
            Text(unit).font(.mbFootnote).foregroundStyle(MB.textTertiary)
        }
    }
}

private struct TrendEmpty: View {
    var body: some View {
        Text("Nothing in Apple Health for the last \(SleepTrend.days) days.").font(.mbFootnote).foregroundStyle(MB.textTertiary)
    }
}

private extension View {
    func trendAxes() -> some View {
        chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(MBFormat.locale)).foregroundStyle(MB.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(MB.hairline)
                AxisValueLabel().foregroundStyle(MB.textTertiary)
            }
        }
        .chartLegend(.hidden)
    }
}

enum TrendFormat {
    /// The calendar days of the window ending today, so a day with no data stays an empty slot.
    static var weekDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(SleepTrend.days - 1), to: today) ?? today
        let end = cal.date(byAdding: .day, value: 1, to: today) ?? today
        return start...end
    }

    static func day(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "today"
            : Calendar.current.isDateInYesterday(date) ? "yesterday"
            : date.formatted(.dateTime.weekday(.abbreviated).locale(MBFormat.locale))
    }
}
