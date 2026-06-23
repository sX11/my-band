import Foundation
import OSLog

// MARK: - WeatherSyncService
//
// Fetches weather from Open-Meteo (free, no API key) and pushes it to the band (app → band,
// encrypted), mirroring GadgetBridge XiaomiWeatherService:
//   1. CMD_ADD_LOCATION   (weather.location)  — register the location
//   2. CMD_SET_CURRENT_WEATHER (weather.current)
//   3. CMD_UPDATE_DAILY_FORECAST (weather.forecast)
//
// Default location is Guarapuava, PR. Best-effort: no network / decode failure just skips.

@MainActor
final class WeatherSyncService {

    /// Guarapuava, PR.
    private let latitude  = -25.3935
    private let longitude = -51.4562
    private let locationName = "Guarapuava"

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Weather")

    func setup(manager: BandManager) {
        bandManager = manager
        // The band pulls weather on its own schedule (on connect, when its weather screen opens). It's
        // the trigger the band's UI actually waits on, so respond to it — a proactive push alone won't
        // populate the widget. Echo the location the band asked for so it binds our data correctly.
        manager.onWeatherConditionsRequest = { [weak self] key, name in
            Task { await self?.pushWeather(requestedKey: key, requestedName: name) }
        }
    }

    // MARK: - Push entry point

    /// Pushes weather to the band. With no arguments it advertises the default location as the current
    /// one (proactive push at the end of a sync). When answering the band's request, the requested
    /// key/name are echoed back so the band associates the data with the location it asked about.
    func pushWeather(requestedKey: String = "", requestedName: String = "") async {
        guard bandManager?.connectionState.isConnected == true else { return }
        do {
            let data = try await fetch()
            sendToBand(data, requestedKey: requestedKey, requestedName: requestedName)
        } catch {
            log.error("Weather fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Open-Meteo fetch

    private func fetch() async throws -> OpenMeteoResponse {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude",  value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current",   value: "temperature_2m,relative_humidity_2m,weather_code,surface_pressure,wind_speed_10m,wind_direction_10m"),
            .init(name: "daily",     value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max"),
            .init(name: "timezone",  value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "wind_speed_unit", value: "kmh"),
            // 7 days: today + 6 ahead, matching GadgetBridge's entry coverage (today reconstructed
            // from current conditions, then 6 forecast days).
            .init(name: "forecast_days", value: "7"),
        ]
        let (bytes, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OpenMeteoResponse.self, from: bytes)
    }

    // MARK: - Build + send

    private func sendToBand(_ w: OpenMeteoResponse, requestedKey: String = "", requestedName: String = "") {
        guard let manager = bandManager else { return }
        let tz = TimeZone(secondsFromGMT: w.utcOffsetSeconds) ?? .current

        // Answering a request → mirror the band's key/name; proactive push → our default as current location.
        let name      = requestedName.isEmpty ? locationName : requestedName
        let code      = requestedKey.isEmpty ? locationKey(locationName) : requestedKey
        let isCurrent = requestedKey.isEmpty

        let metadata = makeMetadata(timestamp: w.current.time, tz: tz, name: name, code: code, isCurrent: isCurrent)

        // 1. Location
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.weatherAddLocationCommand(code: code, name: name))

        // 2. Current conditions
        var current = Xiaomi_WeatherCurrent()
        current.metadata         = metadata
        current.weatherCondition = UInt32(Self.xiaomiCondition(wmo: w.current.weatherCode))
        current.temperature = XiaomiProto.weatherUnit(Int32(w.current.temperature2M.rounded()), "℃")
        current.humidity    = XiaomiProto.weatherUnit(Int32(w.current.relativeHumidity2M.rounded()), "%")
        current.wind        = XiaomiProto.weatherUnit(Self.beaufort(kmh: w.current.windSpeed10M),
                                                      String(Int(w.current.windDirection10M.rounded())))
        current.uv          = XiaomiProto.weatherUnit(Int32((w.daily.uvIndexMax.first ?? 0).rounded()), "")
        current.aqi         = XiaomiProto.weatherUnit(0, "Unknown")
        current.warning     = Xiaomi_WeatherWarnings()
        current.pressure    = Float(w.current.surfacePressure) * 100   // hPa → Pa (GadgetBridge)
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.currentWeatherCommand(current))

        // 3. Daily forecast (today + up to 6 days ahead)
        var entries = Xiaomi_ForecastEntries()
        let days = min(7, w.daily.time.count)
        for i in 0..<days {
            var entry = Xiaomi_ForecastEntry()
            entry.aqi = XiaomiProto.weatherUnit(0, "Unknown")
            var condition = Xiaomi_WeatherRange()
            let c = Int32(Self.xiaomiCondition(wmo: w.daily.weatherCode[i]))
            condition.from = c; condition.to = c
            entry.conditionRange = condition
            var temp = Xiaomi_WeatherRange()
            temp.from = Int32(w.daily.temperature2MMax[i].rounded())   // GadgetBridge: from=max, to=min
            temp.to   = Int32(w.daily.temperature2MMin[i].rounded())
            entry.temperatureRange  = temp
            entry.temperatureSymbol = "℃"
            var sun = Xiaomi_WeatherSunriseSunset()
            sun.sunrise = iso(w.daily.sunrise[i], tz: tz)
            sun.sunset  = iso(w.daily.sunset[i], tz: tz)
            entry.sunriseSunset = sun
            entries.entry.append(entry)
        }
        var forecast = Xiaomi_WeatherForecast()
        forecast.metadata = metadata
        forecast.entries  = entries
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.dailyForecastCommand(forecast))

        log.info("Weather pushed: \(name), \(Int(w.current.temperature2M))℃, \(days)-day forecast")
    }

    private func makeMetadata(timestamp: Int, tz: TimeZone, name: String, code: String, isCurrent: Bool) -> Xiaomi_WeatherMetadata {
        var m = Xiaomi_WeatherMetadata()
        m.publicationTimestamp = iso(timestamp, tz: tz)
        m.cityName          = ""
        m.locationName      = name
        m.locationKey       = code
        m.isCurrentLocation = isCurrent
        return m
    }

    // MARK: - Helpers

    /// ISO 8601 with a colon in the timezone offset (e.g. "2026-06-21T07:12:00-03:00"), matching
    /// GadgetBridge's unixTimestampToISOWithColons.
    private func iso(_ unix: Int, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Location key in the band's "accu:<n>" form. The band only needs a stable key for the name;
    /// we replicate Java's String.hashCode so the value matches GadgetBridge's scheme.
    private func locationKey(_ name: String) -> String {
        var h: Int32 = 0
        for u in name.utf16 { h = h &* 31 &+ Int32(u) }
        let n = Int(h == Int32.min ? Int32.max : abs(h)) % 1_000_000
        return "accu:\(n)"
    }

    /// km/h → Beaufort scale (0–12).
    private static func beaufort(kmh: Double) -> Int32 {
        switch kmh {
        case ..<1:    return 0
        case ..<6:    return 1
        case ..<12:   return 2
        case ..<20:   return 3
        case ..<29:   return 4
        case ..<39:   return 5
        case ..<50:   return 6
        case ..<62:   return 7
        case ..<75:   return 8
        case ..<89:   return 9
        case ..<103:  return 10
        case ..<118:  return 11
        default:      return 12
        }
    }

    /// WMO weather code (Open-Meteo) → Xiaomi condition code (GadgetBridge XiaomiWeatherConditions).
    /// Unknown codes fall back to OVERCAST (2) — a safe, always-mappable icon.
    private static func xiaomiCondition(wmo: Int) -> Int {
        switch wmo {
        case 0:            return 0   // CLEAR_SKY
        case 1, 2:         return 1   // CLOUDY (mainly clear / partly cloudy)
        case 3:            return 2   // OVERCAST
        case 45, 48:       return 18  // MIST (fog)
        case 51, 53, 55:   return 3   // SHOWER (drizzle)
        case 56, 57:       return 19  // FREEZING_RAIN
        case 61:           return 7   // LIGHT_RAIN
        case 63:           return 8   // MODERATE_RAIN
        case 65:           return 9   // HEAVY_RAINFALL
        case 66, 67:       return 19  // FREEZING_RAIN
        case 71, 77:       return 14  // LIGHT_SNOW
        case 73:           return 15  // MODERATE_SNOW
        case 75:           return 16  // HEAVY_SNOW
        case 80, 81:       return 3   // SHOWER
        case 82:           return 9   // HEAVY_RAINFALL
        case 85, 86:       return 13  // SNOW_SHOWERS
        case 95, 96, 99:   return 4   // THUNDERSTORM
        default:           return 2   // OVERCAST
        }
    }
}

// MARK: - Open-Meteo response model

private struct OpenMeteoResponse: Decodable {
    let utcOffsetSeconds: Int
    let current: Current
    let daily: Daily

    struct Current: Decodable {
        let time: Int
        let temperature2M: Double
        let relativeHumidity2M: Double
        let weatherCode: Int
        let surfacePressure: Double
        let windSpeed10M: Double
        let windDirection10M: Double
    }

    struct Daily: Decodable {
        let time: [Int]
        let weatherCode: [Int]
        let temperature2MMax: [Double]
        let temperature2MMin: [Double]
        let sunrise: [Int]
        let sunset: [Int]
        let uvIndexMax: [Double]
    }
}
