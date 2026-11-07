import Foundation

/// Turns OpenStreetMap building tags into LoD1 heights.
///
/// Rules (in order): `height` → `building:levels` (+ roof levels/height) → an
/// estimate by building type. `min_height` / `building:min_level` give the
/// bottom of overhangs, passages and bridges.
public enum OSMBuildingHeights {
    public static let metersPerLevel = 3.0

    /// Parses OSM length values: "12", "12.5 m", "12,5", "40'", "40 ft", "12'6\"".
    public static func parseLength(_ raw: String?) -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: ",", with: ".")
        if let semicolon = text.firstIndex(of: ";") { text = String(text[..<semicolon]) }
        // Feet and inches: 12'6"
        if let foot = text.firstIndex(of: "'") {
            let feet = Double(text[..<foot].trimmingCharacters(in: .whitespaces)) ?? 0
            let rest = text[text.index(after: foot)...].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            let inches = Double(rest) ?? 0
            let value = feet * 0.3048 + inches * 0.0254
            return value > 0 ? value : nil
        }
        var factor = 1.0
        for (suffix, f) in [("meters", 1.0), ("metres", 1.0), ("m", 1.0), ("feet", 0.3048), ("ft", 0.3048)] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            factor = f
            break
        }
        guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
        return value * factor
    }

    static func parseLevels(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let first = raw.split(separator: ";").first.map(String.init) ?? raw
        guard let value = Double(first.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value >= 0, value < 200
        else { return nil }
        return value
    }

    /// Height estimate (metres) for a building type without height information.
    public static func estimatedHeight(buildingType: String?) -> Double {
        switch buildingType ?? "yes" {
        case "garage", "garages", "carport", "shed", "hut", "kiosk", "toilets", "service", "roof", "container", "bunker":
            return 3
        case "house", "detached", "semidetached_house", "terrace", "bungalow", "farm", "cabin", "allotment_house":
            return 8
        case "residential", "apartments", "dormitory", "hotel":
            return 17
        case "commercial", "office", "retail", "civic", "public", "government", "hospital", "school",
             "university", "college", "kindergarten", "train_station", "transportation":
            return 15
        case "industrial", "warehouse", "manufacture", "supermarket", "hangar":
            return 10
        case "church", "cathedral", "mosque", "synagogue", "temple", "chapel":
            return 25
        default:
            return 12
        }
    }

    public static func heights(tags: [String: String]) -> (height: Double, minHeight: Double, source: Building.HeightSource) {
        var minHeight = parseLength(tags["min_height"])
            ?? parseLevels(tags["building:min_level"]).map { $0 * metersPerLevel }
            ?? 0
        var height: Double
        var source: Building.HeightSource
        if let tagged = parseLength(tags["height"]) ?? parseLength(tags["building:height"]), tagged > 0 {
            height = tagged
            source = .tagged
        } else if let levels = parseLevels(tags["building:levels"]) {
            let roof = parseLength(tags["roof:height"]) ?? (parseLevels(tags["roof:levels"]).map { $0 * metersPerLevel } ?? 0)
            height = levels * metersPerLevel + roof
            source = .levels
        } else {
            height = estimatedHeight(buildingType: tags["building"])
            source = .estimated
        }
        if tags["building"] == "roof", minHeight == 0 {
            minHeight = max(height - 1, 2.5) // canopies (petrol stations, platforms) do not block the view
        }
        height = min(max(height, 2), 1_000)
        if minHeight >= height { minHeight = 0 }
        return (height, minHeight, source)
    }

    /// Whether an element with these tags is an extrudable building outline.
    public static func isBuilding(tags: [String: String]) -> Bool {
        if let building = tags["building"] { return building != "no" }
        // Towers such as the Berliner Fernsehturm are often mapped without `building`.
        return tags["man_made"] == "tower" && tags["height"] != nil
    }

    /// A `Building` from tags and rings (WGS84), or `nil` if the geometry is unusable.
    public static func building(id: Int64, tags: [String: String], outer: [GeoCoordinate], inner: [[GeoCoordinate]] = []) -> Building? {
        guard isBuilding(tags: tags) else { return nil }
        func ring(_ coordinates: [GeoCoordinate]) -> WorldRing {
            var points = coordinates.map(WebMercator.project)
            if points.count > 1, points.first == points.last { points.removeLast() }
            return points
        }
        let exterior = ring(outer)
        guard exterior.count >= 3, WorldPolygon.signedArea(of: exterior) != 0 else { return nil }
        let (height, minHeight, source) = heights(tags: tags)
        return Building(
            id: id,
            footprint: WorldPolygon(exterior: exterior, holes: inner.map(ring).filter { $0.count >= 3 }),
            height: height, minHeight: minHeight, heightSource: source, name: tags["name"]
        )
    }
}

/// Parses Overpass API JSON (`out tags geom;`) into buildings.
public enum OverpassBuildingParser {
    struct Response: Decodable {
        var elements: [Element]
    }

    struct Element: Decodable {
        var type: String
        var id: Int64
        var tags: [String: String]?
        var geometry: [Point?]?
        var members: [Member]?
    }

    struct Member: Decodable {
        var type: String
        var role: String?
        var geometry: [Point?]?
    }

    struct Point: Decodable {
        var lat: Double
        var lon: Double
    }

    public static func buildings(from data: Data) throws -> [Building] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var result: [Building] = []
        for element in response.elements {
            let tags = element.tags ?? [:]
            switch element.type {
            case "way":
                let outer = (element.geometry ?? []).compactMap { $0.map { GeoCoordinate(latitude: $0.lat, longitude: $0.lon) } }
                if let building = OSMBuildingHeights.building(id: element.id, tags: tags, outer: outer) {
                    result.append(building)
                }
            case "relation":
                guard tags["type"] == "multipolygon" || tags["type"] == nil else { continue }
                var outers: [[GeoCoordinate]] = []
                var inners: [[GeoCoordinate]] = []
                for member in element.members ?? [] where member.type == "way" {
                    let line = (member.geometry ?? []).compactMap { $0.map { GeoCoordinate(latitude: $0.lat, longitude: $0.lon) } }
                    guard line.count >= 2 else { continue }
                    if member.role == "inner" { inners.append(line) } else { outers.append(line) }
                }
                let outerRings = RingAssembler.rings(from: outers)
                let innerRings = RingAssembler.rings(from: inners)
                for (index, outer) in outerRings.enumerated() {
                    let outerWorld = outer.map(WebMercator.project)
                    let holes = innerRings.filter { hole in
                        guard let first = hole.first else { return false }
                        return WorldPolygon.ring(outerWorld, contains: WebMercator.project(first))
                    }
                    // Relations are stored with negative IDs; multiple outers get distinct IDs.
                    let id = -(element.id * 16 + Int64(index % 16))
                    if let building = OSMBuildingHeights.building(id: id, tags: tags, outer: outer, inner: holes) {
                        result.append(building)
                    }
                }
            default:
                continue
            }
        }
        return result
    }
}

/// Joins open ways into closed rings (for OSM multipolygon relations).
public enum RingAssembler {
    public static func rings(from ways: [[GeoCoordinate]]) -> [[GeoCoordinate]] {
        var remaining = ways.filter { $0.count >= 2 }
        var rings: [[GeoCoordinate]] = []
        while !remaining.isEmpty {
            var ring = remaining.removeFirst()
            var extended = true
            while ring.first != ring.last, extended {
                extended = false
                guard let end = ring.last else { break }
                for (index, way) in remaining.enumerated() {
                    if way.first == end {
                        ring += way.dropFirst()
                    } else if way.last == end {
                        ring += way.reversed().dropFirst()
                    } else {
                        continue
                    }
                    remaining.remove(at: index)
                    extended = true
                    break
                }
            }
            if ring.count >= 4, ring.first == ring.last {
                rings.append(ring)
            }
        }
        return rings
    }
}
