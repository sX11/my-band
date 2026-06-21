import Foundation

// MARK: - WorkoutTrackPoint
//
// One GPS fix from a workout track. Longitude/latitude are decoded as IEEE-754 floats.

struct WorkoutTrackPoint {
    let date: Date
    let latitude: Double
    let longitude: Double
    let hdop: Double?
    let speed: Double?      // m/s — nil on V1 tracks (no speed field)
}

// MARK: - WorkoutGpsParser
//
// Port of GadgetBridge WorkoutGpsParser.java. Two on-wire layouts:
//   V1: 12-byte samples [ts: i32][lon: f32][lat: f32]                       (no speed)
//   V2: 18-byte samples [ts: i32][lon: f32][lat: f32][hdop: f32/4.8][speed: i16>>2 /10]
// All little-endian. Note Xiaomi stores longitude *before* latitude.

enum WorkoutGpsParser {

    static func parse(_ data: Data, meta: XiaomiActivityFileMeta) -> [WorkoutTrackPoint] {
        let headerSize: Int
        let sampleSize: Int
        switch meta.version {
        case 1: headerSize = 1; sampleSize = 12
        case 2: headerSize = 1; sampleSize = 18
        default: return []
        }
        guard data.count > 4 else { return [] }

        let r = LEReader(Data(data.dropLast(4)))   // strip trailing CRC-32
        r.skip(7)                                   // fileId
        guard r.u8() == 0 else { return [] }        // padding
        r.skip(headerSize)

        var points: [WorkoutTrackPoint] = []
        while r.remaining >= sampleSize {
            let ts  = r.i32()
            let lon = Double(r.f32())
            let lat = Double(r.f32())

            var hdop: Double?
            var speed: Double?
            if meta.version >= 2 {
                hdop  = Double(r.f32()) / 4.8
                speed = Double(Int(r.i16()) >> 2) / 10.0
            }

            // Drop obviously invalid fixes (0,0 / NaN) so they don't corrupt the route.
            guard lat.isFinite, lon.isFinite, lat != 0 || lon != 0 else { continue }
            points.append(WorkoutTrackPoint(
                date: Date(timeIntervalSince1970: TimeInterval(ts)),
                latitude: lat, longitude: lon, hdop: hdop, speed: speed
            ))
        }
        return points
    }
}
