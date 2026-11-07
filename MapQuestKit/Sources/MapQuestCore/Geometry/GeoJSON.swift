import Foundation

/// Minimal GeoJSON (RFC 7946) support: reading polygon features, and exporting
/// samples and discovered area for interchange and debugging.
public enum GeoJSON {
    public enum Error: Swift.Error, Equatable {
        case notAnObject
        case unsupportedType(String)
        case malformedCoordinates
    }

    /// A polygonal feature converted to world coordinates.
    public struct Feature: Sendable {
        public var properties: [String: String]
        public var polygons: [WorldPolygon]
    }

    // MARK: Reading

    /// Reads all Polygon/MultiPolygon features of a FeatureCollection, Feature or bare geometry.
    /// Other geometry types are skipped.
    public static func polygonFeatures(from data: Data) throws -> [Feature] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.notAnObject
        }
        switch object["type"] as? String {
        case "FeatureCollection":
            let features = object["features"] as? [[String: Any]] ?? []
            return try features.compactMap(feature)
        case "Feature":
            return try feature(object).map { [$0] } ?? []
        case "Polygon", "MultiPolygon":
            return [Feature(properties: [:], polygons: try polygons(fromGeometry: object))]
        case let other:
            throw Error.unsupportedType(other ?? "nil")
        }
    }

    /// Reads a play area: the union of all polygons in `data`.
    public static func playArea(named name: String, from data: Data) throws -> PlayArea {
        PlayArea(name: name, polygons: PolygonOps.union(try polygonFeatures(from: data).flatMap(\.polygons)))
    }

    private static func feature(_ object: [String: Any]) throws -> Feature? {
        guard let geometry = object["geometry"] as? [String: Any],
              let type = geometry["type"] as? String,
              type == "Polygon" || type == "MultiPolygon"
        else { return nil }
        var properties: [String: String] = [:]
        for (key, value) in object["properties"] as? [String: Any] ?? [:] {
            if let string = value as? String {
                properties[key] = string
            } else if let number = value as? NSNumber {
                properties[key] = number.stringValue
            }
        }
        return Feature(properties: properties, polygons: try polygons(fromGeometry: geometry))
    }

    private static func polygons(fromGeometry geometry: [String: Any]) throws -> [WorldPolygon] {
        switch geometry["type"] as? String {
        case "Polygon":
            guard let rings = geometry["coordinates"] as? [Any] else { throw Error.malformedCoordinates }
            return [try polygon(fromRings: rings)]
        case "MultiPolygon":
            guard let polygons = geometry["coordinates"] as? [Any] else { throw Error.malformedCoordinates }
            return try polygons.map { item in
                guard let rings = item as? [Any] else { throw Error.malformedCoordinates }
                return try polygon(fromRings: rings)
            }
        case let other:
            throw Error.unsupportedType(other ?? "nil")
        }
    }

    private static func polygon(fromRings rings: [Any]) throws -> WorldPolygon {
        let converted: [WorldRing] = try rings.map { ring in
            guard let positions = ring as? [Any] else { throw Error.malformedCoordinates }
            var points: WorldRing = try positions.map { position in
                guard let pair = position as? [Any], pair.count >= 2,
                      let lon = (pair[0] as? NSNumber)?.doubleValue,
                      let lat = (pair[1] as? NSNumber)?.doubleValue
                else { throw Error.malformedCoordinates }
                return WebMercator.project(GeoCoordinate(latitude: lat, longitude: lon))
            }
            if points.count > 1, points.first == points.last { points.removeLast() }
            return points
        }
        guard let exterior = converted.first, exterior.count >= 3 else { throw Error.malformedCoordinates }
        return WorldPolygon(exterior: exterior, holes: Array(converted.dropFirst()).filter { $0.count >= 3 })
    }

    // MARK: Writing

    /// Location samples as Point features (with altitude as third coordinate).
    public static func featureCollection(samples: [LocationSample]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let features: [[String: Any]] = samples.map { sample in
            [
                "type": "Feature",
                "id": sample.id.uuidString,
                "geometry": ["type": "Point", "coordinates": [sample.longitude, sample.latitude, sample.altitude]],
                "properties": [
                    "timestamp": formatter.string(from: sample.timestamp),
                    "horizontalAccuracy": sample.horizontalAccuracy,
                    "verticalAccuracy": sample.verticalAccuracy,
                ] as [String: Any],
            ]
        }
        return encode(["type": "FeatureCollection", "features": features])
    }

    /// Discovered-area pieces as Polygon features (pieces include their tile overlap margin).
    public static func featureCollection(pieces: [DiscoveredPiece]) -> Data {
        let formatter = ISO8601DateFormatter()
        let features: [[String: Any]] = pieces.map { piece in
            [
                "type": "Feature",
                "id": piece.id.uuidString,
                "geometry": ["type": "Polygon", "coordinates": coordinates(of: piece.polygon)],
                "properties": [
                    "layer": piece.layer.rawValue,
                    "region": piece.regionID.uuidString,
                    "tile": piece.tile.description,
                    "areaSquareMeters": piece.areaSquareMeters,
                    "firstDiscovered": formatter.string(from: piece.firstDiscovered),
                    "lastUpdated": formatter.string(from: piece.lastUpdated),
                ] as [String: Any],
            ]
        }
        return encode(["type": "FeatureCollection", "features": features])
    }

    /// Polygon coordinates in GeoJSON order ([lon, lat], closed rings, exterior counter-clockwise).
    public static func coordinates(of polygon: WorldPolygon) -> [[[Double]]] {
        polygon.rings.enumerated().map { index, ring in
            // RFC 7946: exteriors counter-clockwise, holes clockwise (in lon/lat, i.e. y-up).
            // World y grows southwards, so a positive world signed area is clockwise in lon/lat.
            let clockwiseInLonLat = WorldPolygon.signedArea(of: ring) > 0
            let wantsClockwise = index > 0
            let ordered = clockwiseInLonLat == wantsClockwise ? ring : Array(ring.reversed())
            var positions = ordered.map { point -> [Double] in
                let c = WebMercator.unproject(point)
                return [(c.longitude * 1e7).rounded() / 1e7, (c.latitude * 1e7).rounded() / 1e7]
            }
            if let first = positions.first { positions.append(first) }
            return positions
        }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
