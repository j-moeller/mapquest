import Foundation

/// Places of remembrance as a short history and as walks (`<city>-remembrance.json`).
/// They are not part of the game: the guide only tells what each place remembers.
public struct RemembranceGuide: Codable, Sendable {
    /// A place of remembrance in a chapter.
    public struct Place: Codable, Hashable, Sendable {
        /// The sight's ID (a place of remembrance).
        public var sight: String
        /// What the place remembers, in a sentence.
        public var remembers: String
    }

    /// A chapter of history and the places that remember it.
    public struct Chapter: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        /// e.g. "1933–1945".
        public var years: String
        public var text: String
        public var places: [Place]
    }

    /// A walk between places of remembrance, stops in order.
    public struct Tour: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var text: String
        public var stops: [String]
    }

    public var chapters: [Chapter]
    public var tours: [Tour]

    public init(chapters: [Chapter] = [], tours: [Tour] = []) {
        self.chapters = chapters
        self.tours = tours
    }

    public static func decode(_ data: Data) throws -> RemembranceGuide {
        try JSONDecoder().decode(RemembranceGuide.self, from: data)
    }

    public static func merged(_ guides: [RemembranceGuide]) -> RemembranceGuide {
        RemembranceGuide(chapters: guides.flatMap(\.chapters), tours: guides.flatMap(\.tours))
    }

    /// The chapter a place belongs to.
    public func chapter(of sightID: String) -> Chapter? {
        chapters.first { $0.places.contains { $0.sight == sightID } }
    }

    /// What a place remembers.
    public func remembers(_ sightID: String) -> String? {
        chapters.lazy.flatMap(\.places).first { $0.sight == sightID }?.remembers
    }

    /// The length of a walk between its stops, as the crow flies, in metres.
    public static func length(of stops: [GeoCoordinate]) -> Double {
        zip(stops, stops.dropFirst()).reduce(0) { total, pair in
            let (a, b) = pair
            let dy = (b.latitude - a.latitude) * 111_320
            let dx = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * .pi / 180)
            return total + (dx * dx + dy * dy).squareRoot()
        }
    }
}
