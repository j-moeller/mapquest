import Foundation
import MapQuestCore

/// Numbers, sizes, distances, durations and dates in the app's language
/// (`Localization.locale`: "1,25 km²" in German, "1.25 km²" in English).
enum Formatters {
    static var locale: Locale { Localization.locale }

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    static func area(_ squareMeters: Double) -> String {
        if squareMeters >= 100_000 {
            return decimal(squareMeters / 1_000_000, digits: 2) + " km²" // not localized
        }
        return decimal(squareMeters, digits: 0) + " m²" // not localized
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.001 {
            return "<" + decimal(0.1, digits: 1) + " %" // not localized
        }
        return decimal(fraction * 100, digits: 1) + " %" // not localized
    }

    static func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file).locale(locale))
    }

    static func distance(_ meters: Double) -> String {
        meters >= 1_000 ? decimal(meters / 1_000, digits: 1) + " km" : decimal(meters, digits: 0) + " m" // not localized
    }

    /// A distance to go, to 10 m below a kilometre: "120 m", "2.4 km" – e.g. `tr("{0} away", Formatters.away(meters))`.
    static func away(_ meters: Double) -> String {
        meters < 1_000 ? distance((meters / 10).rounded() * 10) : distance(meters)
    }

    /// "12 min", "1 h 05 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return tr("{0} min", minutes) }
        return tr("{0} h {1} min", minutes / 60, String(format: "%02d", minutes % 60))
    }

    /// "12,345 positions · 74 KB" (bytes only once something is written).
    static func track(_ summary: TrackSummary) -> String {
        // {1}: the count with grouping ("12,345"); {0} decides the form.
        let count = trn("{1} position", "{1} positions", summary.pointCount, number(summary.pointCount))
        guard summary.byteCount > 0 else { return count }
        return count + " · " + bytes(summary.byteCount)
    }

    /// A day: "12 Nov 2026" / "12. Nov. 2026".
    static func date(_ date: Date, _ style: Date.FormatStyle.DateStyle = .abbreviated) -> String {
        date.formatted(Date.FormatStyle(date: style, time: .omitted).locale(locale))
    }

    /// A day and time: "12 Nov 2026, 14:05".
    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}
