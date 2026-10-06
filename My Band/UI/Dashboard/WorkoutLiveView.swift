import SwiftUI

// MARK: - WorkoutLiveCard
//
// The workout running on the band, at the top of the Dashboard while one is (ADR 0008). Hidden
// otherwise: the band can't be told to start one, so there is nothing to offer when idle.

struct WorkoutLiveCard: View {
    let workout: WorkoutLiveService.Workout

    var body: some View {
        MBCard {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: MB.Space.x3) {
                    HStack(spacing: MB.Space.x2) {
                        RoundedRectangle(cornerRadius: MB.Radius.sm, style: .continuous)
                            .fill(MB.accentSoft)
                            .frame(width: 28, height: 28)
                            .overlay(Image(systemName: workout.kind.symbol)
                                .font(.system(size: 16)).foregroundStyle(MB.accent))
                        Text(workout.kind.title).font(.mbSubheadEmph).foregroundStyle(MB.textSecondary)
                        Spacer()
                        WorkoutStatePill(state: workout.state)
                    }
                    Text(WorkoutClockFormat.string(workout.elapsed(at: context.date)))
                        .font(.mbDataLG)
                        .tracking(-0.02 * 48)
                        .monospacedDigit()
                        .foregroundStyle(workout.state == .paused ? MB.textTertiary : MB.textPrimary)
                    HStack(spacing: MB.Space.x4) {
                        stat(workout.heartRate.map(String.init), "bpm", tint: MB.hr)
                        stat(workout.distanceMeters.map(WorkoutFormat.km), "km", tint: MB.spo2)
                        stat(workout.steps.map(MBFormat.number), "steps", tint: MB.steps)
                        stat(workout.calories.map(String.init), "kcal", tint: MB.energy)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func stat(_ value: String?, _ unit: String, tint: Color) -> some View {
        if let value {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.mbHeadline).monospacedDigit().foregroundStyle(MB.textPrimary)
                Text(unit).font(.mbFootnote).foregroundStyle(tint)
            }
        }
    }
}

struct WorkoutStatePill: View {
    let state: WorkoutLiveService.State

    var body: some View {
        switch state {
        case .running: MBStatusPill(text: "Running", tone: .ok, pulse: true)
        case .paused:  MBStatusPill(text: "Paused", tone: .warn, icon: "pause.fill")
        }
    }
}

// MARK: - WorkoutLiveView

struct WorkoutLiveView: View {

    @Environment(WorkoutLiveService.self) private var live
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List {
                    if let w = live.current {
                        Section {
                            row("Sport", w.kind.title)
                            row("State", w.state == .running ? "Running" : "Paused")
                            row("Started", w.startedAt.formatted(.dateTime.hour().minute().locale(MBFormat.locale)))
                            row("Elapsed", WorkoutClockFormat.string(w.elapsed(at: context.date)))
                        }
                        .listRowBackground(MB.surfaceCard)
                        Section("Live from the band") {
                            row("Heart rate", w.heartRate.map { "\($0) bpm" } ?? "Measuring…")
                            row("Steps", w.steps.map(MBFormat.number) ?? "—")
                            row("Active energy", w.calories.map { "\($0) kcal" } ?? "—")
                        }
                        .listRowBackground(MB.surfaceCard)
                        if w.kind?.usesGps == true {
                            Section("Phone GPS") {
                                row("Distance", w.distanceMeters.map { WorkoutFormat.km($0) + " km" } ?? "Waiting for a fix")
                                if let pace = WorkoutFormat.pace(w) { row(pace.label, pace.value) }
                            }
                            .listRowBackground(MB.surfaceCard)
                        }
                        Section {
                        } footer: {
                            Text(footer(w)).font(.mbFootnote).foregroundStyle(MB.textTertiary)
                        }
                    } else {
                        Section {
                        } footer: {
                            Text("The workout ended. It reaches Apple Health with the band's own file.")
                                .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(MB.bgApp.ignoresSafeArea())
            }
            .navigationTitle("Workout")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(MB.accent)
        }
        .preferredColorScheme(.dark)
    }

    private func footer(_ w: WorkoutLiveService.Workout) -> String {
        var lines: [String] = []
        if w.joinedLate { lines.append("The app joined after the workout started, so steps and energy count from then.") }
        lines.append("Shown while it runs, never stored. The band's own totals reach Apple Health after the workout ends.")
        return lines.joined(separator: " ")
    }

    private func row(_ label: String, _ value: String) -> some View { MBListRow(label: label, value: value) }
}

// MARK: - Formatting

enum WorkoutFormat {
    static func km(_ meters: Double) -> String {
        (meters / 1000).formatted(.number.precision(.fractionLength(2)).locale(MBFormat.locale))
    }

    static func pace(_ w: WorkoutLiveService.Workout) -> (label: String, value: String)? {
        w.distanceMeters.flatMap { pace(meters: $0, seconds: w.movingSeconds, kind: w.kind) }
    }

    /// Cycling reads as speed, foot sports as pace, anything else as neither; nothing until there
    /// is 100 m to divide by.
    static func pace(meters: Double, seconds: TimeInterval, kind: WorkoutKind?) -> (label: String, value: String)? {
        guard meters >= 100, seconds > 0 else { return nil }
        switch kind {
        case .outdoorCycling, .indoorCycling, .skating, .downhillSkiing, .snowboarding, .snowSports,
             .paddleSports, .sailing, .surfing:
            let kmh = meters / seconds * 3.6
            return ("Average speed", kmh.formatted(.number.precision(.fractionLength(1)).locale(MBFormat.locale)) + " km/h")
        case .running, .trailRun, .treadmill, .walking, .hiking, .trekking:
            let perKm = Int(seconds / (meters / 1000))
            return ("Average pace", String(format: "%d:%02d /km", perKm / 60, perKm % 60))
        default:
            return nil
        }
    }
}

extension Optional where Wrapped == WorkoutKind {
    var title: String { self?.title ?? "Workout" }
    var symbol: String { self?.symbol ?? "figure.mixed.cardio" }
}

extension WorkoutKind {
    var title: String {
        switch self {
        case .running: "Outdoor run"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .trekking: "Trek"
        case .trailRun: "Trail run"
        case .treadmill: "Treadmill"
        case .outdoorCycling: "Outdoor cycling"
        case .indoorCycling: "Indoor cycling"
        case .freeTraining: "Free training"
        case .hiit: "HIIT"
        case .yoga: "Yoga"
        case .strengthTraining: "Strength training"
        case .poolSwim: "Pool swim"
        case .openWaterSwim: "Open water swim"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .rowingMachine: "Rowing machine"
        case .jumpRoping: "Jump rope"
        case .triathlon: "Triathlon"
        case .sailing: "Sailing"
        case .paddleSports: "Paddling"
        case .waterPolo: "Water polo"
        case .waterSports: "Water sports"
        case .diving: "Diving"
        case .surfing: "Surfing"
        case .climbing: "Climbing"
        case .skating: "Skating"
        case .stairClimbing: "Stair climber"
        case .stairs: "Stairs"
        case .stepTraining: "Step training"
        case .coreTraining: "Core training"
        case .flexibility: "Flexibility"
        case .pilates: "Pilates"
        case .gymnastics: "Gymnastics"
        case .crossTraining: "Cross training"
        case .mixedCardio: "Cardio"
        case .functionalStrength: "Functional training"
        case .dance: "Dance"
        case .boxing: "Boxing"
        case .wrestling: "Wrestling"
        case .martialArts: "Martial arts"
        case .taiChi: "Tai chi"
        case .kickboxing: "Kickboxing"
        case .fencing: "Fencing"
        case .soccer: "Soccer"
        case .basketball: "Basketball"
        case .volleyball: "Volleyball"
        case .baseball: "Baseball"
        case .softball: "Softball"
        case .americanFootball: "American football"
        case .hockey: "Hockey"
        case .tableTennis: "Table tennis"
        case .badminton: "Badminton"
        case .tennis: "Tennis"
        case .cricket: "Cricket"
        case .handball: "Handball"
        case .bowling: "Bowling"
        case .squash: "Squash"
        case .golf: "Golf"
        case .curling: "Curling"
        case .snowSports: "Snow sports"
        case .snowboarding: "Snowboarding"
        case .downhillSkiing: "Skiing"
        case .archery: "Archery"
        case .equestrian: "Horse riding"
        case .fishing: "Fishing"
        case .discSports: "Frisbee"
        case .other: "Workout"
        }
    }

    var symbol: String {
        switch self {
        case .running, .treadmill: "figure.run"
        case .walking: "figure.walk"
        case .hiking, .trekking: "figure.hiking"
        case .trailRun: "figure.run"
        case .outdoorCycling: "figure.outdoor.cycle"
        case .indoorCycling: "figure.indoor.cycle"
        case .freeTraining, .other: "figure.mixed.cardio"
        case .hiit: "figure.highintensity.intervaltraining"
        case .yoga: "figure.yoga"
        case .strengthTraining: "figure.strengthtraining.traditional"
        case .poolSwim, .openWaterSwim: "figure.pool.swim"
        case .elliptical: "figure.elliptical"
        case .rowing, .rowingMachine: "figure.rower"
        case .jumpRoping: "figure.jumprope"
        case .triathlon: "figure.open.water.swim"
        case .sailing: "figure.sailing"
        case .paddleSports: "oar.2.crossed"
        case .waterPolo: "figure.waterpolo"
        case .waterSports: "figure.water.fitness"
        case .diving: "figure.pool.swim"
        case .surfing: "figure.surfing"
        case .climbing: "figure.climbing"
        case .skating: "figure.skating"
        case .stairClimbing: "figure.stair.stepper"
        case .stairs: "figure.stairs"
        case .stepTraining: "figure.step.training"
        case .coreTraining: "figure.core.training"
        case .flexibility: "figure.flexibility"
        case .pilates: "figure.pilates"
        case .gymnastics: "figure.gymnastics"
        case .crossTraining: "figure.cross.training"
        case .mixedCardio: "figure.mixed.cardio"
        case .functionalStrength: "figure.strengthtraining.functional"
        case .dance: "figure.dance"
        case .boxing: "figure.boxing"
        case .wrestling: "figure.wrestling"
        case .martialArts: "figure.martial.arts"
        case .taiChi: "figure.taichi"
        case .kickboxing: "figure.kickboxing"
        case .fencing: "figure.fencing"
        case .soccer: "figure.soccer"
        case .basketball: "figure.basketball"
        case .volleyball: "figure.volleyball"
        case .baseball: "figure.baseball"
        case .softball: "figure.softball"
        case .americanFootball: "figure.american.football"
        case .hockey: "figure.hockey"
        case .tableTennis: "figure.table.tennis"
        case .badminton: "figure.badminton"
        case .tennis: "figure.tennis"
        case .cricket: "figure.cricket"
        case .handball: "figure.handball"
        case .bowling: "figure.bowling"
        case .squash: "figure.squash"
        case .golf: "figure.golf"
        case .curling: "figure.curling"
        case .snowSports: "figure.skiing.crosscountry"
        case .snowboarding: "figure.snowboarding"
        case .downhillSkiing: "figure.skiing.downhill"
        case .archery: "figure.archery"
        case .equestrian: "figure.equestrian.sports"
        case .fishing: "figure.fishing"
        case .discSports: "figure.disc.sports"
        }
    }
}
