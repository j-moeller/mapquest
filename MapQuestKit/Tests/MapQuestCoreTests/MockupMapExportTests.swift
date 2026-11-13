import Foundation
import XCTest
@testable import MapQuestCore

/// Exports the map for the App Store mockups (Tools/screenshots/make_screenshots.sh):
/// central Berlin drawn by `MapRenderPlan` from cached OpenFreeMap tiles, as SVG, and
/// the area the demo explorer discovered (plus the script's traced walks) as found by
/// the discovery engine. Runs only when the script sets `MQ_MOCKUP_OUT`.
final class MockupMapExportTests: XCTestCase {
    private func hex(_ c: MapColor) -> String { String(format: "#%02x%02x%02x", c.red, c.green, c.blue) }
    private func f(_ v: Double) -> String { String(format: "%.1f", v) }

    func testExportMap() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["MQ_MOCKUP_OUT"] else { throw XCTSkip("only for Tools/screenshots/make_screenshots.sh") }
        let out = URL(fileURLWithPath: output)
        let tiles = URL(fileURLWithPath: env["MQ_TILES"] ?? "build-sights")
        // The frame: zoom-15 tiles of 512 pixels; the rectangle to draw, in its pixels.
        let minX = try XCTUnwrap(Double(env["MQ_MINX"] ?? "")), minY = try XCTUnwrap(Double(env["MQ_MINY"] ?? ""))
        let maxX = try XCTUnwrap(Double(env["MQ_MAXX"] ?? "")), maxY = try XCTUnwrap(Double(env["MQ_MAXY"] ?? ""))

        // The base map, tile by tile, as the app draws its tiles (streets palette).
        let palette = MapPalette.streets
        var svg = ""
        for tx in Int(minX / 512)...Int(maxX / 512) {
            for ty in Int(minY / 512)...Int(maxY / 512) {
                let target = TileKey(zoom: 15, x: tx, y: ty)
                let source = TileKey(zoom: 14, x: tx >> 1, y: ty >> 1)
                let file = tiles.appendingPathComponent("14_\(source.x)_\(source.y).mvt")
                guard let data = try? Data(contentsOf: file) else {
                    XCTFail("map data missing: \(file.path)")
                    continue
                }
                let tile = try VectorTile(data: data, only: MapRenderPlan.layers)
                svg += "<svg x=\"\(tx * 512)\" y=\"\(ty * 512)\" width=\"512\" height=\"512\" overflow=\"hidden\">"
                svg += "<rect width=\"512\" height=\"512\" fill=\"\(hex(palette.color(.land)))\"/>"
                for command in MapRenderPlan.commands(for: tile, source: source, target: target, size: 512) {
                    var d = ""
                    for shape in command.shapes {
                        for ring in shape where ring.count > 1 {
                            d += "M" + ring.map { "\(f($0.x)) \(f($0.y))" }.joined(separator: "L")
                            if case .fill = command.kind { d += "Z" }
                        }
                    }
                    guard !d.isEmpty else { continue }
                    let color = hex(palette.color(command.role))
                    switch command.kind {
                    case .fill:
                        svg += "<path d=\"\(d)\" fill=\"\(color)\" fill-rule=\"evenodd\"/>"
                    case let .stroke(width, dash):
                        let dashes = dash.map { " stroke-dasharray=\"\($0.map { f($0) }.joined(separator: " "))\"" } ?? ""
                        svg += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(f(width))\" "
                            + "stroke-linecap=\"\(dash == nil ? "round" : "butt")\" stroke-linejoin=\"round\"\(dashes)/>"
                    }
                }
                svg += "</svg>"
            }
        }
        try svg.write(to: out.appendingPathComponent("base.svgfrag"), atomically: true, encoding: .utf8)

        // The discovered area: the demo explorer's track and the traced walks (a position
        // every 4 m), through the radius layer (circles of 50 m), as the app imports them.
        let track = try TrackCodec.decode(Data(contentsOf: BraunschweigDataTests.root.appendingPathComponent("Berlin/demo-track.mqtrack")))
        var samples = CoverageSampler.reduce(track.map(\.sample), configuration: RecordingPolicy().sampling.offline)
        if let walks = env["MQ_WALKS"], let text = try? String(contentsOfFile: walks, encoding: .utf8) {
            var time = Date(timeIntervalSince1970: 1_790_000_000)
            for walk in text.components(separatedBy: "\n\n") {
                let points = walk.split(separator: "\n").compactMap { line -> GeoCoordinate? in
                    let parts = line.split(separator: " ").compactMap { Double($0) }
                    return parts.count == 2 ? GeoCoordinate(latitude: parts[0], longitude: parts[1]) : nil
                }
                for (a, b) in zip(points, points.dropFirst()) {
                    let meters = hypot((b.latitude - a.latitude) * 111_320, (b.longitude - a.longitude) * 67_800)
                    let steps = max(1, Int(meters / 4))
                    for step in 0...steps {
                        let t = Double(step) / Double(steps)
                        time += 3
                        samples.append(LocationSample(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                      longitude: a.longitude + (b.longitude - a.longitude) * t,
                                                      altitude: 35, timestamp: time))
                    }
                }
            }
        }
        let engine = DiscoveryEngine(model: CircleDiscoveryModel(radius: 50), store: InMemoryDataStore())
        _ = try await engine.rebuild(from: samples)
        let snapshot = await engine.snapshot()
        // World units to frame pixels: 2^32 world units are 2^15 tiles of 512 pixels.
        func pixels(_ v: Int64) -> Double { Double(v) / 256 }
        let rect = WorldRect(minX: Int64(minX * 256), minY: Int64(minY * 256), maxX: Int64(maxX * 256), maxY: Int64(maxY * 256))
        var pieces = ""
        for piece in snapshot.pieces(intersecting: rect) {
            for ring in [piece.polygon.exterior] + piece.polygon.holes where ring.count > 2 {
                pieces += "M" + ring.map { "\(f(pixels($0.x))) \(f(pixels($0.y)))" }.joined(separator: "L") + "Z"
            }
            pieces += "\n"  // one piece per line: drawn separately, so overlaps at tile edges stay filled
        }
        try pieces.write(to: out.appendingPathComponent("discovered.d"), atomically: true, encoding: .utf8)
    }
}
