import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MyBandWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
    }
}

// MARK: - WorkoutLiveActivity
//
// The workout running on the band, on the Lock Screen and in the Dynamic Island. The widget has no
// access to the app's design system, so the few midnight-palette colours it needs are repeated here.

private enum Palette {
    static let card   = Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1F / 255)
    static let accent = Color(red: 0x7C / 255, green: 0x7F / 255, blue: 0xFF / 255)
    static let hr     = Color(red: 0xFF / 255, green: 0x5C / 255, blue: 0x7A / 255)
    static let steps  = Color(red: 0x46 / 255, green: 0xE0 / 255, blue: 0xA0 / 255)
    static let gps    = Color(red: 0x5B / 255, green: 0xC0 / 255, blue: 0xF8 / 255)
    static let energy = Color(red: 0xFF / 255, green: 0x9A / 255, blue: 0x4C / 255)
    static let warn   = Color(red: 0xF6 / 255, green: 0xC5 / 255, blue: 0x52 / 255)
    static let dim    = Color(red: 0x9A / 255, green: 0xA0 / 255, blue: 0xB0 / 255)
}

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenWorkout(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Palette.card)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.sportTitle, systemImage: context.attributes.sportSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let bpm = context.state.heartRate {
                        Label("\(bpm)", systemImage: "heart.fill")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Palette.hr)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        WorkoutClock(state: context.state)
                            .font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        WorkoutStats(state: context.state, showHR: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.attributes.sportSymbol).foregroundStyle(Palette.accent)
            } compactTrailing: {
                WorkoutClock(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : context.attributes.sportSymbol)
                    .foregroundStyle(context.state.paused ? Palette.warn : Palette.accent)
            }
        }
    }
}

private struct LockScreenWorkout: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    /// Past the staleDate the app stopped updating (killed or suspended), so the numbers may be old.
    let isStale: Bool

    private var statusText: String { isStale ? "Not updating" : state.paused ? "Paused" : "Running" }
    private var statusColor: Color { isStale ? Palette.dim : state.paused ? Palette.warn : Palette.steps }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.sportTitle, systemImage: attributes.sportSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                Spacer()
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            WorkoutClock(state: state)
                .font(.system(size: 40, weight: .semibold)).monospacedDigit()
                .foregroundStyle(state.paused || isStale ? Palette.dim : .white)
            WorkoutStats(state: state, showHR: true)
        }
        .padding(16)
        .opacity(isStale ? 0.6 : 1)
    }
}

private struct WorkoutClock: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if state.paused {
            Text(WorkoutClockFormat.string(state.pausedElapsed))
        } else {
            Text(timerInterval: state.clockStart...Date.distantFuture, countsDown: false)
        }
    }
}

private struct WorkoutStats: View {
    let state: WorkoutActivityAttributes.ContentState
    let showHR: Bool

    var body: some View {
        HStack(spacing: 14) {
            if showHR, let bpm = state.heartRate { stat("\(bpm)", "bpm", Palette.hr) }
            if let m = state.distanceMeters {
                stat((m / 1000).formatted(.number.precision(.fractionLength(2))), "km", Palette.gps)
            }
            if let steps = state.steps { stat(steps.formatted(), "steps", Palette.steps) }
            if let kcal = state.calories { stat("\(kcal)", "kcal", Palette.energy) }
        }
    }

    private func stat(_ value: String, _ unit: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.headline).monospacedDigit().foregroundStyle(.white)
            Text(unit).font(.caption).foregroundStyle(tint)
        }
    }
}
