import SwiftUI
import HealthKit
import MapKit

// MARK: - WorkoutsView
//
// The page right of the Dashboard: the newest workouts this app wrote to Apple Health, read
// back each time the page appears and never stored (ADR 0009). Totals and the GPS route; graphs
// and splits stay in Apple Health.

struct WorkoutsView: View {

    /// Loads only while this is the selected page, so the paged TabView preloading it next to the
    /// Dashboard doesn't read Health, or raise its prompt, unseen.
    var isActive: Bool

    @State private var months: [(month: Date, items: [WorkoutRecord])] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var selected: WorkoutRecord?

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    message(errorText)
                } else if !loaded {
                    Section {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    .listRowBackground(MB.surfaceCard)
                } else if months.isEmpty {
                    message("No workouts yet. A workout recorded on the band appears here after it syncs.")
                } else {
                    ForEach(months, id: \.month) { group in
                        Section(group.month.formatted(.dateTime.month(.wide).year().locale(MBFormat.locale))) {
                            ForEach(group.items) { w in
                                // A sheet, not a push: the page swipe would fight a pushed view's swipe back.
                                Button { selected = w } label: { WorkoutRow(workout: w) }
                                    .foregroundStyle(MB.textPrimary)
                            }
                        }
                        .listRowBackground(MB.surfaceCard)
                    }
                    Section {
                    } footer: {
                        Text("From Apple Health, only workouts My Band wrote. Open the Health app for the heart-rate graph.")
                            .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MB.bgApp.ignoresSafeArea())
            .refreshable { await load() }
            .navigationTitle("Workouts")
            .tint(MB.accent)
            .sheet(item: $selected) { w in
                NavigationStack {
                    WorkoutDetailView(workout: w)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { selected = nil }
                            }
                        }
                }
                .preferredColorScheme(.dark)
                .tint(MB.accent)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: isActive) {
            guard isActive else { return }
            await load()
        }
    }

    private func load() async {
        do {
            // A no-op once answered; asks only if this page opens before any sync did.
            try await HealthKitManager.shared.requestAuthorization()
            months = Self.byMonth(try await HealthKitManager.shared.recentWorkouts())
            errorText = nil
        } catch is CancellationError {
            return
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            errorText = "Unlock your iPhone to read Apple Health."
        } catch {
            errorText = error.localizedDescription
        }
        loaded = true
    }

    private func message(_ text: String) -> some View {
        Section {
            Text(text).font(.mbFootnote).foregroundStyle(MB.textTertiary)
        }
        .listRowBackground(MB.surfaceCard)
    }

    private static func byMonth(_ workouts: [WorkoutRecord]) -> [(month: Date, items: [WorkoutRecord])] {
        let cal = Calendar.current
        var groups: [(month: Date, items: [WorkoutRecord])] = []
        for w in workouts {
            let month = cal.dateInterval(of: .month, for: w.start)?.start ?? w.start
            if groups.last?.month == month {
                groups[groups.count - 1].items.append(w)
            } else {
                groups.append((month, [w]))
            }
        }
        return groups
    }
}

// MARK: - WorkoutRow

private struct WorkoutRow: View {
    let workout: WorkoutRecord

    var body: some View {
        HStack(spacing: MB.Space.x3) {
            RoundedRectangle(cornerRadius: MB.Radius.sm, style: .continuous)
                .fill(MB.accentSoft)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: workout.kind.symbol)
                    .font(.system(size: 18)).foregroundStyle(MB.accent))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(workout.kind.title).font(.mbHeadline).foregroundStyle(MB.textPrimary)
                    Spacer()
                    Text(WorkoutClockFormat.string(workout.duration))
                        .font(.mbHeadline).monospacedDigit().foregroundStyle(MB.textPrimary)
                }
                Text(WorkoutHistoryFormat.day(workout.start))
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                let stats = WorkoutHistoryFormat.stats(workout)
                if !stats.isEmpty {
                    Text(stats).font(.mbFootnote).monospacedDigit().foregroundStyle(MB.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - WorkoutRouteMap

private struct WorkoutRouteMap: View {
    let route: [CLLocationCoordinate2D]

    var body: some View {
        Map(initialPosition: .rect(Self.bounds(route)), interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: route)
                .stroke(MB.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = route.first {
                Annotation("Start", coordinate: start) { dot(MB.ok) }
            }
            if let end = route.last {
                Annotation("Finish", coordinate: end) { dot(MB.danger) }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .colorScheme(.dark)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .overlay(Circle().stroke(MB.textPrimary, lineWidth: 2))
    }

    /// The route's bounding box with a margin, so the line doesn't touch the edges.
    private static func bounds(_ route: [CLLocationCoordinate2D]) -> MKMapRect {
        let rect = route.map { MKMapPoint($0) }
            .reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0))) }
        let margin = max(rect.width, rect.height) * 0.15 + 200
        return rect.insetBy(dx: -margin, dy: -margin)
    }
}

// MARK: - WorkoutDetailView

struct WorkoutDetailView: View {
    let workout: WorkoutRecord

    @State private var route: [CLLocationCoordinate2D] = []

    var body: some View {
        List {
            if route.count >= 2 {
                Section {
                    WorkoutRouteMap(route: route)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                row("Sport", workout.kind.title)
                row("Date", workout.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(MBFormat.locale)))
                row("Time", "\(WorkoutHistoryFormat.time(workout.start)) – \(WorkoutHistoryFormat.time(workout.end))")
                row("Duration", WorkoutClockFormat.string(workout.duration))
            }
            .listRowBackground(MB.surfaceCard)
            Section("Totals") {
                row("Distance", workout.distanceMeters.map { WorkoutFormat.km($0) + " km" } ?? "—")
                if let meters = workout.distanceMeters,
                   let pace = WorkoutFormat.pace(meters: meters, seconds: workout.duration, kind: workout.kind) {
                    row(pace.label, pace.value)
                }
                row("Active energy", workout.activeKcal.map { "\(Int($0.rounded())) kcal" } ?? "—")
                if let met = workout.averageMETs {
                    row("Average intensity", met.formatted(.number.precision(.fractionLength(1)).locale(MBFormat.locale)) + " METs")
                }
            }
            .listRowBackground(MB.surfaceCard)
            if workout.hrAvg != nil || workout.hrMax != nil || workout.hrMin != nil {
                Section("Heart rate") {
                    if let v = workout.hrAvg { row("Average", "\(Int(v.rounded())) bpm") }
                    if let v = workout.hrMax { row("Highest", "\(Int(v.rounded())) bpm") }
                    if let v = workout.hrMin { row("Lowest", "\(Int(v.rounded())) bpm") }
                }
                .listRowBackground(MB.surfaceCard)
            }
            if let indoor = workout.indoor {
                Section("Conditions") {
                    row("Location", indoor ? "Indoor" : "Outdoor")
                }
                .listRowBackground(MB.surfaceCard)
            }
        }
        .scrollContentBackground(.hidden)
        .background(MB.bgApp.ignoresSafeArea())
        .navigationTitle(workout.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workout.id) {
            guard workout.indoor != true else { return }
            route = (try? await HealthKitManager.shared.route(ofWorkout: workout.id))?.map(\.coordinate) ?? []
        }
    }

    private func row(_ label: String, _ value: String) -> some View { MBListRow(label: label, value: value) }
}

// MARK: - Formatting

enum WorkoutHistoryFormat {
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(MBFormat.locale))
    }

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(date) ? "Today"
            : cal.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(MBFormat.locale))
        return "\(day) · \(time(date))"
    }

    static func stats(_ w: WorkoutRecord) -> String {
        var parts: [String] = []
        if let m = w.distanceMeters { parts.append(WorkoutFormat.km(m) + " km") }
        if let kcal = w.activeKcal { parts.append("\(Int(kcal.rounded())) kcal") }
        if let hr = w.hrAvg { parts.append("\(Int(hr.rounded())) bpm") }
        return parts.joined(separator: " · ")
    }
}
