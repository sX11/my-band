import Foundation

// MARK: - MBFormat
//
// The app's shared number and relative-time wording. The UI is English, so both pin en_US
// rather than following the device locale.

enum MBFormat {

    static let locale = Locale(identifier: "en_US")

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return f
    }()

    /// "5 min. ago"; under a minute the formatter would say "in 0 sec." / "0 sec. ago".
    static func ago(_ date: Date, now: Date, justNow: String = "just now") -> String {
        if now.timeIntervalSince(date) < 60 { return justNow }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }
}
