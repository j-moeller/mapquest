import Foundation

/// The length of a time-based view.
public enum PeriodKind: String, CaseIterable, Codable, Sendable {
    case day, week, month, year

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

/// A calendar day, week, month or year: the half-open interval [start, end).
public struct Period: Hashable, Sendable {
    public let kind: PeriodKind
    public let start: Date
    public let end: Date

    public init(kind: PeriodKind, start: Date, end: Date) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// The period of `kind` that contains `date` in `calendar` (time zone and first weekday).
    public init(_ kind: PeriodKind, containing date: Date, calendar: Calendar) {
        let interval = calendar.dateInterval(of: kind.component, for: date) ?? DateInterval(start: date, duration: 86_400)
        self.init(kind: kind, start: interval.start, end: interval.end)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// The neighbouring period `offset` steps away (−1: previous, +1: next).
    public func shifted(by offset: Int, calendar: Calendar) -> Period {
        let anchor = calendar.date(byAdding: kind.component, value: offset, to: start) ?? start
        return Period(kind, containing: anchor.addingTimeInterval(1), calendar: calendar)
    }

    /// The days of the period.
    public func days(calendar: Calendar) -> [Period] {
        var days: [Period] = []
        var day = Period(.day, containing: start, calendar: calendar)
        while day.start < end {
            days.append(day)
            day = day.shifted(by: 1, calendar: calendar)
        }
        return days
    }

    /// A stable key: 2026-11-08, 2026-W45, 2026-11, 2026.
    public func key(calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .weekOfYear, .yearForWeekOfYear], from: start)
        switch kind {
        case .day: return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        case .week: return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        case .month: return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        case .year: return String(format: "%04d", c.year ?? 0)
        }
    }
}
