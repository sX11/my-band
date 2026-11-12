import Foundation

// One SDNN value per ~10-minute block of sleep beat intervals, from its cleanest minute: a value per minute
// (~260 a night) would outweigh every other source in Health's daily average, and SDNN grows with the
// window, so a minute keeps the values comparable to the Apple Watch's.

/// One block of beat-to-beat intervals: the first beat at `start`, each following beat one interval
/// after the previous one.
struct BeatWindow: Equatable {
    var start: Date
    var intervalsMs: [Int]

    /// The last beat.
    var end: Date { start.addingTimeInterval(TimeInterval(intervalsMs.reduce(0, +)) / 1000) }
}

enum HeartRateVariability {

    /// 30–200 bpm. Outside it an interval is a missed or a spurious beat, not a heartbeat.
    static let plausibleIntervalMs = 300 ... 2000
    /// An interval more than 20% off the median of its neighbourhood (5 each side) is an artifact —
    /// the usual ectopic/artifact rule.
    static let maxDeviationFromLocalMedian = 0.2
    static let neighbours = 5

    static let minute: TimeInterval = 60
    /// A minute counts only if its intervals cover at least this much of it…
    static let minCoverage: TimeInterval = 50
    /// …and at least this share of them survive the artifact filter.
    static let minAcceptedShare = 0.8

    /// The band's beat times sit on a 40 ms grid (intervals telescope to the block's length), so each
    /// interval carries two rounding errors: 2 · q²/12 = q²/6 of variance, removed in quadrature.
    static let intervalStepMs = 40.0

    static func correctedForQuantization(_ sdnnMs: Double) -> Double {
        max(0, sdnnMs * sdnnMs - intervalStepMs * intervalStepMs / 6).squareRoot()
    }

    /// Whether each interval is a clean beat-to-beat interval.
    static func accepted(_ intervals: [Int]) -> [Bool] {
        intervals.indices.map { i in
            let value = intervals[i]
            guard plausibleIntervalMs.contains(value) else { return false }
            let lo = max(0, i - neighbours), hi = min(intervals.count, i + neighbours + 1)
            let around = intervals[lo ..< hi].sorted()
            let median = Double(around[around.count / 2])
            return abs(Double(value) - median) <= maxDeviationFromLocalMedian * median
        }
    }

    struct MinuteValue: Equatable {
        var start: Date
        var end: Date
        var sdnnMs: Double
        /// Clean intervals the value was computed from.
        var intervals: Int
        /// Every interval ending in the minute, clean or not.
        var total: Int

        var acceptedShare: Double { total > 0 ? Double(intervals) / Double(total) : 0 }
    }

    /// SDNN of each full, clean minute of the block. An interval belongs to the minute in which the
    /// beat that ends it falls.
    static func minuteSDNN(_ window: BeatWindow) -> [MinuteValue] {
        let clean = accepted(window.intervalsMs)
        var byMinute: [Int: (all: [Int], kept: [Int])] = [:]
        var elapsedMs = 0
        for (i, interval) in window.intervalsMs.enumerated() {
            elapsedMs += interval
            let index = Int(Double(elapsedMs) / 1000 / minute)
            var bucket = byMinute[index] ?? ([], [])
            bucket.all.append(interval)
            if clean[i] { bucket.kept.append(interval) }
            byMinute[index] = bucket
        }
        return byMinute.keys.sorted().compactMap { index in
            guard let bucket = byMinute[index], bucket.kept.count >= 2,
                  TimeInterval(bucket.all.reduce(0, +)) / 1000 >= minCoverage,
                  Double(bucket.kept.count) >= minAcceptedShare * Double(bucket.all.count) else { return nil }
            let start = window.start.addingTimeInterval(TimeInterval(index) * minute)
            return MinuteValue(start: start, end: start.addingTimeInterval(minute),
                               sdnnMs: correctedForQuantization(standardDeviation(bucket.kept)),
                               intervals: bucket.kept.count, total: bucket.all.count)
        }
    }

    struct BlockValue: Equatable {
        /// The block's first beat: the value's identity in Health, whichever minute it came from.
        var blockStart: Date
        var minute: MinuteValue
    }

    /// The block's cleanest minute: the highest share of clean intervals, the earliest on a tie. Not
    /// the most intervals: that is the fastest-beating minute, which biases SDNN low.
    static func blockSDNN(_ window: BeatWindow) -> BlockValue? {
        var best: MinuteValue?
        for value in minuteSDNN(window) where value.acceptedShare > (best?.acceptedShare ?? -1) {
            best = value
        }
        return best.map { BlockValue(blockStart: window.start, minute: $0) }
    }

    /// Sample standard deviation (n − 1), the usual SDNN estimator.
    static func standardDeviation(_ values: [Int]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        let squares = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
        return (squares / Double(values.count - 1)).squareRoot()
    }

    /// Every report of a night repeats the blocks of the reports before it, so one block per start,
    /// taken from the report reaching furthest into the night (`reach`, as in `mergeReports`).
    static func nightBlocks(_ reports: [(reach: Date, windows: [BeatWindow])]) -> [BeatWindow] {
        var byStart: [Date: BeatWindow] = [:]
        let ordered = reports.enumerated().sorted { ($0.element.reach, $0.offset) < ($1.element.reach, $1.offset) }
        for report in ordered {
            for window in report.element.windows { byStart[window.start] = window }
        }
        return byStart.values.sorted { $0.start < $1.start }
    }

    /// Blocks further apart than this belong to different nights: clearing one span across both would
    /// erase the values of a night in between that the write doesn't carry.
    static let nightGap: TimeInterval = 3 * 3600

    /// From each night's first beat to its last. A value's minute starts inside its block, so the
    /// overlap delete still reaches one running past the last beat; padding the end would reach the
    /// next block's value, which a write without that block doesn't put back.
    static func nightSpans(_ blocks: [BeatWindow]) -> [ClosedRange<Date>] {
        var spans: [ClosedRange<Date>] = []
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            let end = block.end
            if let last = spans.last, block.start.timeIntervalSince(last.upperBound) <= nightGap {
                spans[spans.count - 1] = last.lowerBound ... max(last.upperBound, end)
            } else {
                spans.append(block.start ... end)
            }
        }
        return spans
    }
}
