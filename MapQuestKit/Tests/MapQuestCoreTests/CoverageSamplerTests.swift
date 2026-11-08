import XCTest
@testable import MapQuestCore

final class CoverageSamplerTests: XCTestCase {
    /// 1 Hz fixes along a polyline (metres east/north of `Walk.origin`) at `speed`, with GNSS noise.
    func track(
        _ route: [(Double, Double)], speed: Double = 1.4, noise: Double = 1.5, accuracy: Double = 5,
        start: Double = 0, seed: UInt64 = 1
    ) -> [LocationSample] {
        var random = SplitMix(seed: seed)
        var samples: [LocationSample] = []
        var t = start
        for (a, b) in zip(route, route.dropFirst()) {
            let length = ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot()
            let steps = max(Int(length / speed), 1)
            for i in 0..<steps {
                let f = Double(i) / Double(steps)
                var sample = Walk.sample(
                    east: a.0 + (b.0 - a.0) * f + random.noise(noise), north: a.1 + (b.1 - a.1) * f + random.noise(noise),
                    second: t, accuracy: accuracy + random.noise(1)
                )
                sample.altitude = 40 + random.noise(1)
                samples.append(sample)
                t += 1
            }
        }
        return samples
    }

    /// Standing still for `seconds` with jitter.
    func stay(at east: Double, _ north: Double, seconds: Int, start: Double, accuracy: Double = 8, seed: UInt64 = 2) -> [LocationSample] {
        var random = SplitMix(seed: seed)
        return (0..<seconds).map { i in
            var sample = Walk.sample(
                east: east + random.noise(accuracy * 0.6), north: north + random.noise(accuracy * 0.6),
                second: start + Double(i), accuracy: accuracy + random.noise(2)
            )
            sample.altitude = 40 + random.noise(2)
            return sample
        }
    }

    func testADayAtOneHertzShrinksToAFewHundredFixes() {
        // Home 4 h, walk 1.5 km to work, work 4 h, walk back the same way.
        let route = [(0.0, 0.0), (600.0, 0.0), (600.0, 500.0), (1_000.0, 500.0)]
        var day = stay(at: 0, 0, seconds: 4 * 3_600, start: 0)
        day += track(route, start: Double(day.count))
        day += stay(at: 1_000, 500, seconds: 4 * 3_600, start: Double(day.count), seed: 3)
        day += track(route.reversed(), start: Double(day.count), seed: 4)
        let configuration = CoverageSampler.Configuration()
        let online = CoverageSampler.reduce(day, configuration: configuration)
        let offline = CoverageSampler.reduce(day, configuration: configuration.offline)
        print("coverage sampler: \(day.count) fixes → \(online.count) (online) → \(offline.count) (with revisits merged)")
        XCTAssertGreaterThan(day.count, 30_000)
        // ≈ 2 × 1.5 km at one fix per ≤ 10 m plus corners; 8 h of jitter cost a few hundred more.
        XCTAssertGreaterThan(online.count, 2 * 1_500 / 10 - 20)
        XCTAssertLessThan(Double(online.count) / Double(day.count), 0.03)
        XCTAssertLessThan(offline.count, online.count / 2, "the way back revisits the way there")
        XCTAssertLessThan(Double(offline.count) / Double(day.count), 0.01, "a drastic reduction")
    }

    func testStandingStillWithJitterIsOneFix() {
        let samples = stay(at: 0, 0, seconds: 3_600, start: 0, accuracy: 12)
        let kept = CoverageSampler.reduce(samples, configuration: CoverageSampler.Configuration())
        XCTAssertLessThanOrEqual(kept.count, 3)
    }

    func testCirclesAreCoveredWithinTheBound() {
        let route = [(0.0, 0.0), (300.0, 0.0), (300.0, 200.0), (100.0, 260.0)]
        let samples = track(route)
        let model = CircleDiscoveryModel(radius: 50)
        let kept = CoverageSampler.reduce(samples, configuration: CoverageSampler.Configuration())
        let all = PolygonOps.union(samples.flatMap { model.revealedArea(for: $0) })
        let reduced = PolygonOps.union(kept.flatMap { model.revealedArea(for: $0) })
        let allArea = all.reduce(0) { $0 + $1.areaSquareMeters }
        let missed = PolygonOps.difference(all, reduced).reduce(0) { $0 + $1.areaSquareMeters }
        XCTAssertLessThan(Double(kept.count), Double(samples.count) / 5)
        // Bound: tolerance (1.5 × accuracy ≈ 7.5 m) + scallops (0.25 m) along the outline only.
        // GNSS noise makes the full union slightly ragged; the slivers are below 2 %.
        XCTAssertLessThan(missed / allArea, 0.02, "\(missed) of \(allArea) m² missed")
        // No point of the full coverage is further than the bound from the reduced one.
        let grown = PolygonOps.inflate(reduced, by: 8 / WebMercator.metersPerUnit(atLatitude: Walk.origin.latitude))
        let outside = PolygonOps.difference(all, grown).reduce(0) { $0 + $1.areaSquareMeters }
        XCTAssertLessThan(outside, 1)
    }

    func testViewshedsLoseAlmostNothing() async throws {
        // Streets every 100 m between 80 m blocks: side streets open up for 20 m.
        var blocks: [Building] = []
        for i in -8...8 {
            for j in -8...8 {
                let e = Double(i) * 100 + 10, n = Double(j) * 100 + 10
                let corners = [
                    Walk.coordinate(east: e, north: n), Walk.coordinate(east: e + 80, north: n),
                    Walk.coordinate(east: e + 80, north: n + 80), Walk.coordinate(east: e, north: n + 80),
                ].map(WebMercator.project)
                blocks.append(Building(id: Int64(blocks.count + 1), footprint: WorldPolygon(exterior: corners), height: 20))
            }
        }
        let model = ViewshedDiscoveryModel(buildings: InMemoryBuildingSource(blocks))
        let samples = track([(-300.0, 0.0), (300.0, 0.0), (300.0, 200.0)], noise: 1)
        let kept = CoverageSampler.reduce(samples, configuration: CoverageSampler.Configuration())
        var all: [WorldPolygon] = []
        var reduced: [WorldPolygon] = []
        let keptIDs = Set(kept.map(\.id))
        for sample in samples {
            let area = try await model.revealedArea(for: sample)
            all = PolygonOps.union(all + area)
            if keptIDs.contains(sample.id) { reduced = PolygonOps.union(reduced + area) }
        }
        let allArea = all.reduce(0) { $0 + $1.areaSquareMeters }
        let missed = PolygonOps.difference(all, reduced).reduce(0) { $0 + $1.areaSquareMeters }
        print("viewsheds: \(samples.count) fixes → \(kept.count); missed \(Int(missed)) of \(Int(allArea)) m²")
        XCTAssertLessThan(Double(kept.count), Double(samples.count) / 5)
        XCTAssertLessThan(missed / allArea, 0.03)
    }

    func testCornersAndClimbsAreKept() {
        var sampler = CoverageSampler(configuration: CoverageSampler.Configuration(spacing: 50))
        // An L: 40 m east, then 40 m north, without noise, accuracy 3 m (tolerance 4.5 m).
        var path: [LocationSample] = (0...40).map { Walk.sample(east: Double($0), north: 0, second: Double($0), accuracy: 3) }
        path += (1...40).map { Walk.sample(east: 40, north: Double($0), second: 40 + Double($0), accuracy: 3) }
        var kept: [LocationSample] = []
        for sample in path { kept += sampler.add(sample) }
        kept += sampler.finish()
        XCTAssertLessThanOrEqual(kept.count, 6)
        // The guarantee: every fix lies within its tolerance of the polyline of kept fixes.
        func local(_ s: LocationSample) -> (Double, Double) {
            ((s.longitude - Walk.origin.longitude) * 111_320 * cos(Walk.origin.latitude * .pi / 180), (s.latitude - Walk.origin.latitude) * 111_320)
        }
        func distanceToPolyline(_ s: LocationSample) -> Double {
            let p = local(s)
            return zip(kept, kept.dropFirst()).map { a, b -> Double in
                let (ax, ay) = local(a), (bx, by) = local(b)
                let (dx, dy) = (bx - ax, by - ay)
                let t = max(0, min(1, ((p.0 - ax) * dx + (p.1 - ay) * dy) / max(dx * dx + dy * dy, 1e-12)))
                return hypot(p.0 - ax - t * dx, p.1 - ay - t * dy)
            }.min() ?? .infinity
        }
        for sample in path {
            XCTAssertLessThanOrEqual(distanceToPolyline(sample), 4.5 + 1e-6)
        }

        // Climbing stairs in place: every few metres of height counts.
        var stairs = CoverageSampler(configuration: CoverageSampler.Configuration())
        var climbs: [LocationSample] = []
        for i in 0..<60 {
            var sample = Walk.sample(east: 0, north: 0, second: Double(i), accuracy: 3)
            sample.altitude = 40 + Double(i) * 0.5
            sample.verticalAccuracy = 2
            climbs += stairs.add(sample)
        }
        XCTAssertGreaterThanOrEqual(climbs.count, 8, "30 m of height in ≈ 3 m steps")
    }

    func testInaccurateFixesAreIgnored() {
        var sampler = CoverageSampler(configuration: CoverageSampler.Configuration(maximumAccuracy: 50))
        XCTAssertTrue(sampler.add(Walk.sample(east: 0, north: 0, second: 0, accuracy: 80)).isEmpty)
        XCTAssertEqual(sampler.add(Walk.sample(east: 0, north: 0, second: 1, accuracy: 5)).count, 1)
    }
}
