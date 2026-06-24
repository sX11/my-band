import Foundation
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "WorkoutParser")

// MARK: - WorkoutHRSample

/// One intra-workout heart-rate reading: an absolute timestamp and a bpm value.
struct WorkoutHRSample {
    let date: Date
    let bpm: Int
}

// MARK: - WorkoutDetailsParser
//
// Parses the per-second sensor series the band records DURING a workout (file type=SPORTS,
// detail=DETAILS, subtype 0x08). GadgetBridge has no parser for this file — its
// XiaomiActivityParser.createForSports only handles SUMMARY/GPS_TRACK and discards the rest —
// so the layout below was reverse-engineered from a real Mi Band 10 capture (2026-06-23,
// strengthTraining, version 3) and is CRC-validated by the fixture test.
//
// Layout (little-endian), confirmed on that capture:
//   [0..6]   activity file id (its timestamp == the workout start)
//   [7]      padding (0)
//   [8..18]  11-byte header; bytes[10..11] = duration in seconds (== sample count)
//   [19..]   one 4-byte sample per second: [hr: u8][flag: u8][reserved: u16 = 0]
//   [last 4] CRC-32 (already validated by ActivityFileReceiver before we get here)
//
// The sample count equals the workout duration in seconds: the band emits exactly one HR reading
// per second, hr=0 for the first ~18 s while the optical sensor acquires a lock. `flag` is 1 on
// roughly every twelfth sample (a keyframe marker) and is not needed to reconstruct the series.
//
// Only version 3 is known. Other versions return an empty series (the file is still ACKed by the
// caller) rather than risk misreading an unconfirmed header.

enum WorkoutDetailsParser {

    private static let headerEnd = 19        // 7 (id) + 1 (pad) + 11 (header)
    private static let sampleSize = 4

    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> [WorkoutHRSample] {
        guard meta.isWorkoutDetails else { return [] }
        guard meta.version == 3 else {
            log.warning("WorkoutDetailsParser: unsupported version \(meta.version) — skipping HR series")
            return []
        }

        let base = data.startIndex
        // headerEnd samples + 4-byte CRC trailer must fit.
        guard data.count >= headerEnd + sampleSize + 4 else { return [] }
        guard data[base + 7] == 0 else { return [] }

        let durationSeconds = Int(data[base + 10]) | (Int(data[base + 11]) << 8)
        let sampleBytes = data.count - 4 - headerEnd          // exclude the trailing CRC-32
        let count = sampleBytes / sampleSize
        if count != durationSeconds {
            // Not fatal — we still parse `count` samples — but flags a layout drift worth a new fixture.
            log.warning("WorkoutDetailsParser: sample count \(count) != duration \(durationSeconds)")
        }

        var out: [WorkoutHRSample] = []
        out.reserveCapacity(count)
        let start = meta.timestamp
        for i in 0 ..< count {
            let bpm = Int(data[base + headerEnd + i * sampleSize])
            // hr=0 means the sensor had no reading that second; drop it. Clamp to a sane range so a
            // stray byte never becomes a bogus HKQuantitySample.
            guard (30 ... 250).contains(bpm) else { continue }
            out.append(WorkoutHRSample(date: start.addingTimeInterval(TimeInterval(i)), bpm: bpm))
        }
        return out
    }
}
