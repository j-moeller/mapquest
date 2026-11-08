import Foundation
import MapQuestCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `MapQuestDataStore` backed by the MapQuest REST API (Server/mapquest_server.py,
/// PostgreSQL). Every protocol call is one HTTP request; change sets are applied
/// atomically by the server. See docs/04-remote-store.md for the wire format.
public final class RemoteDataStore: MapQuestDataStore, @unchecked Sendable {
    public enum RemoteError: Error, Equatable, CustomStringConvertible {
        case http(status: Int, message: String)
        case invalidResponse

        public var description: String {
            switch self {
            case .http(let status, let message): return "HTTP \(status): \(message)"
            case .invalidResponse: return "invalid response"
            }
        }
    }

    public let descriptor: DataSourceDescriptor
    public let baseURL: URL
    private let token: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(descriptor: DataSourceDescriptor, baseURL: URL, token: String, session: URLSession = .shared) {
        self.descriptor = descriptor
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// The account behind the token (also a cheap connectivity check).
    public func whoAmI() async throws -> (id: String, displayName: String) {
        let me: Me = try await request("GET", "v1/me")
        return (me.id, me.displayName)
    }

    // MARK: LocationStore

    public func addSamples(_ samples: [LocationSample]) async throws {
        guard !samples.isEmpty else { return }
        let _: Ignored = try await request("PUT", "v1/samples", body: samples.map(SampleDTO.init))
    }

    public func samples(matching query: LocationQuery) async throws -> [LocationSample] {
        var items: [URLQueryItem] = []
        if let tiles = query.tiles {
            items += Self.tileItems(tiles)
        }
        if let box = query.boundingBox {
            items += [
                URLQueryItem(name: "minLatitude", value: "\(box.minLatitude)"), URLQueryItem(name: "maxLatitude", value: "\(box.maxLatitude)"),
                URLQueryItem(name: "minLongitude", value: "\(box.minLongitude)"), URLQueryItem(name: "maxLongitude", value: "\(box.maxLongitude)"),
            ]
        }
        if let from = query.from { items.append(URLQueryItem(name: "from", value: "\(from.timeIntervalSince1970)")) }
        if let to = query.to { items.append(URLQueryItem(name: "to", value: "\(to.timeIntervalSince1970)")) }
        items.append(URLQueryItem(name: "order", value: query.order == .chronological ? "asc" : "desc"))
        if let limit = query.limit { items.append(URLQueryItem(name: "limit", value: "\(limit)")) }
        let rows: [SampleDTO] = try await request("GET", "v1/samples", query: items)
        return rows.compactMap(\.sample)
    }

    public func sampleCount() async throws -> Int {
        let count: Count = try await request("GET", "v1/samples/count")
        return count.count
    }

    public func removeAllSamples() async throws {
        let _: Ignored = try await request("DELETE", "v1/samples")
    }

    // MARK: DiscoveredAreaStore

    public func pieces(layer: DiscoveryLayerID, tiles: TileRange?) async throws -> [DiscoveredPiece] {
        var items = [URLQueryItem(name: "layer", value: layer.rawValue)]
        if let tiles {
            items += Self.tileItems(tiles) + [URLQueryItem(name: "zoom", value: "\(tiles.zoom)")]
        }
        let rows: [PieceDTO] = try await request("GET", "v1/pieces", query: items)
        return try rows.map { try $0.piece() }
    }

    public func apply(_ changes: DiscoveredAreaChangeSet) async throws {
        guard !changes.isEmpty else { return }
        let _: Ignored = try await request("POST", "v1/changes", body: ChangeSetDTO(changes))
    }

    public func removeAllPieces(layer: DiscoveryLayerID) async throws {
        let _: Ignored = try await request("DELETE", "v1/pieces", query: [URLQueryItem(name: "layer", value: layer.rawValue)])
    }

    public func layers() async throws -> [DiscoveryLayerID] {
        let names: [String] = try await request("GET", "v1/layers")
        return names.map(DiscoveryLayerID.init(rawValue:))
    }

    public func dataVersions(layer: DiscoveryLayerID) async throws -> DataVersions {
        let rows: [DataVersionDTO] = try await request("GET", "v1/data-versions", query: [URLQueryItem(name: "layer", value: layer.rawValue)])
        return Dictionary(rows.map { (TileKey(zoom: $0.zoom, x: $0.x, y: $0.y), $0.version) }) { _, last in last }
    }

    // MARK: HTTP

    private static func tileItems(_ tiles: TileRange) -> [URLQueryItem] {
        [
            URLQueryItem(name: "minTileX", value: "\(tiles.minX)"), URLQueryItem(name: "maxTileX", value: "\(tiles.maxX)"),
            URLQueryItem(name: "minTileY", value: "\(tiles.minY)"), URLQueryItem(name: "maxTileY", value: "\(tiles.maxY)"),
        ]
    }

    private func request<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send(method, path, query: query, body: Optional<Ignored>.none)
    }

    private func request<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body) async throws -> Response {
        try await send(method, path, query: [], body: body)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem], body: Body?) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw RemoteError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, status) = try await perform(request)
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(ErrorBody.self, from: data))?.error ?? String(decoding: data, as: UTF8.self)
            throw RemoteError.http(status: status, message: message)
        }
        if Response.self == Ignored.self { return Ignored() as! Response }
        return try decoder.decode(Response.self, from: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http.statusCode))
                } else {
                    continuation.resume(throwing: RemoteError.invalidResponse)
                }
            }.resume()
        }
    }
}

// MARK: Wire format

private struct Ignored: Codable {}
private struct Count: Decodable { var count: Int }
private struct ErrorBody: Decodable { var error: String }
private struct Me: Decodable { var id: String; var displayName: String }

/// Timestamps are Unix seconds, UUIDs upper-case strings, geometry base64 (PolygonCodec v1).
struct SampleDTO: Codable {
    var id: String
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var timestamp: Double
    var tileX: Int
    var tileY: Int

    init(_ sample: LocationSample) {
        id = sample.id.uuidString
        latitude = sample.latitude
        longitude = sample.longitude
        altitude = sample.altitude
        horizontalAccuracy = sample.horizontalAccuracy
        verticalAccuracy = sample.verticalAccuracy
        timestamp = sample.timestamp.timeIntervalSince1970
        tileX = sample.tile.x
        tileY = sample.tile.y
    }

    var sample: LocationSample? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return LocationSample(
            id: uuid, latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }
}

struct PieceDTO: Codable {
    var id: String
    var layer: String
    var regionID: String
    var tileZoom: Int
    var tileX: Int
    var tileY: Int
    var geometry: String
    var areaSquareMeters: Double
    var firstDiscovered: Double
    var lastUpdated: Double

    init(_ piece: DiscoveredPiece) {
        id = piece.id.uuidString
        layer = piece.layer.rawValue
        regionID = piece.regionID.uuidString
        tileZoom = piece.tile.zoom
        tileX = piece.tile.x
        tileY = piece.tile.y
        geometry = PolygonCodec.encode(piece.polygon, origin: piece.tile.origin).base64EncodedString()
        areaSquareMeters = piece.areaSquareMeters
        firstDiscovered = piece.firstDiscovered.timeIntervalSince1970
        lastUpdated = piece.lastUpdated.timeIntervalSince1970
    }

    func piece() throws -> DiscoveredPiece {
        guard let uuid = UUID(uuidString: id), let region = UUID(uuidString: regionID), let data = Data(base64Encoded: geometry) else {
            throw RemoteDataStore.RemoteError.invalidResponse
        }
        let tile = TileKey(zoom: tileZoom, x: tileX, y: tileY)
        return DiscoveredPiece(
            id: uuid, layer: DiscoveryLayerID(layer), regionID: region, tile: tile,
            polygon: try PolygonCodec.decodePolygon(data, origin: tile.origin),
            areaSquareMeters: areaSquareMeters,
            firstDiscovered: Date(timeIntervalSince1970: firstDiscovered),
            lastUpdated: Date(timeIntervalSince1970: lastUpdated)
        )
    }
}

struct DataVersionDTO: Codable {
    var zoom: Int
    var x: Int
    var y: Int
    var version: String
}

struct ChangeSetDTO: Encodable {
    struct Merge: Encodable { var sources: [String]; var target: String }

    var layer: String
    var regionMerges: [Merge]
    var removedPieceIDs: [String]
    var upsertedPieces: [PieceDTO]
    var dataVersions: [DataVersionDTO]

    init(_ changes: DiscoveredAreaChangeSet) {
        layer = changes.layer.rawValue
        regionMerges = changes.regionMerges.map { Merge(sources: $0.sources.map(\.uuidString), target: $0.target.uuidString) }
        removedPieceIDs = changes.removedPieceIDs.map(\.uuidString)
        upsertedPieces = changes.upsertedPieces.map(PieceDTO.init)
        dataVersions = changes.dataVersions.sorted { $0.key < $1.key }.map {
            DataVersionDTO(zoom: $0.key.zoom, x: $0.key.x, y: $0.key.y, version: $0.value)
        }
    }
}
