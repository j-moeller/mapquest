import Foundation

/// Parameters of the 2.5D ray-casting viewshed (see docs/01-literature-review.md, §4.4).
public struct ViewshedConfiguration: Hashable, Sendable {
    /// Number of rays (720 → 0.5°).
    public var rayCount: Int
    /// Eye height of a pedestrian, metres.
    public var streetEyeHeight: Double
    /// View distance at street level, metres.
    public var baseDistance: Double
    /// Additional view distance per metre of eye height above street level.
    public var distancePerMeterOfHeight: Double
    /// Upper bound of the view distance, metres.
    public var maximumDistance: Double
    /// Altitudes with a worse vertical accuracy are ignored (street level is assumed).
    public var maximumVerticalAccuracy: Double
    /// Heights up to this much above the ground (plus the vertical accuracy) count as
    /// street level, so that GNSS noise and terrain relief do not create phantom high points.
    public var elevatedThreshold: Double
    /// Upper bound for the eye height above ground, metres.
    public var maximumEyeHeight: Double
    /// Buildings starting at least this high (passages, bridges) do not block the view.
    public var nonBlockingMinHeight: Double
    /// Cell size of the spatial grid used to find buildings along a ray, metres.
    public var gridCellSize: Double
    /// Tolerance for simplifying the resulting polygons, metres.
    public var simplificationTolerance: Double

    public init(
        rayCount: Int = 720,
        streetEyeHeight: Double = 1.7,
        baseDistance: Double = 150,
        distancePerMeterOfHeight: Double = 15,
        maximumDistance: Double = 2_000,
        maximumVerticalAccuracy: Double = 15,
        elevatedThreshold: Double = 8,
        maximumEyeHeight: Double = 500,
        nonBlockingMinHeight: Double = 2.5,
        gridCellSize: Double = 25,
        simplificationTolerance: Double = 0.5
    ) {
        self.rayCount = rayCount
        self.streetEyeHeight = streetEyeHeight
        self.baseDistance = baseDistance
        self.distancePerMeterOfHeight = distancePerMeterOfHeight
        self.maximumDistance = maximumDistance
        self.maximumVerticalAccuracy = maximumVerticalAccuracy
        self.elevatedThreshold = elevatedThreshold
        self.maximumEyeHeight = maximumEyeHeight
        self.nonBlockingMinHeight = nonBlockingMinHeight
        self.gridCellSize = gridCellSize
        self.simplificationTolerance = simplificationTolerance
    }

    /// Eye height above ground for a fix: street level unless the altitude is
    /// reliably and clearly above the ground.
    public func eyeHeight(altitude: Double, verticalAccuracy: Double, groundElevation: Double) -> Double {
        guard verticalAccuracy >= 0, verticalAccuracy <= maximumVerticalAccuracy, altitude.isFinite else {
            return streetEyeHeight
        }
        let above = altitude - groundElevation - verticalAccuracy - elevatedThreshold
        return min(streetEyeHeight + max(0, above), maximumEyeHeight)
    }

    /// How far one can see from a given eye height.
    public func viewDistance(eyeHeight: Double) -> Double {
        min(baseDistance + distancePerMeterOfHeight * max(0, eyeHeight - streetEyeHeight), maximumDistance)
    }
}

/// The area visible from one position.
public struct ViewshedResult: Sendable {
    /// Visible ground plus the footprints of seen buildings (world coordinates).
    public var polygons: [WorldPolygon]
    /// Buildings of which some wall or roof is visible.
    public var seenBuildingIDs: Set<Int64>
    public var eyeHeight: Double
    public var viewDistance: Double
}

/// 2.5D ray casting on LoD1 buildings with slope-based occlusion.
///
/// From the eye, `rayCount` rays are cast. Along each ray the buildings it
/// crosses are found with a uniform grid and a voxel traversal (Amanatides &
/// Woo). Walking outwards, the steepest line of sight so far decides what is
/// visible: the ground at distance *t* is visible iff `−H / t ≥ maxSlope`
/// (flat ground, eye height *H*); a building is seen iff its wall top or roof
/// rises above `maxSlope`, and then raises it. A building taller than the eye
/// hides everything behind it except taller buildings; a lower building casts a
/// "shadow" that ends at `b · H / (H − h)`.
public enum Viewshed {
    /// A building crossing a ray: material from `entry` to `exit` (metres from the eye).
    struct Crossing {
        var entry: Double
        var exit: Double
        var top: Double
        var blocks: Bool
        var building: Int
    }

    struct Edge {
        var ax: Double, ay: Double, bx: Double, by: Double
    }

    struct LocalBuilding {
        var edges: [Edge]
        var top: Double
        var blocks: Bool
    }

    public static func compute(
        eye: WorldPoint,
        eyeHeight: Double,
        viewDistance: Double,
        buildings: [Building],
        configuration: ViewshedConfiguration = ViewshedConfiguration()
    ) -> ViewshedResult {
        let metersPerUnit = WebMercator.metersPerUnit(atWorldY: Double(eye.y))
        let unitsPerMeter = 1 / metersPerUnit
        let distance = viewDistance
        let reach = Int64((distance * unitsPerMeter).rounded(.up)) + 1
        let window = WorldRect(minX: eye.x - reach, minY: eye.y - reach, maxX: eye.x + reach, maxY: eye.y + reach)

        // 1. Local metric frame around the eye; the building the user is in (or on) is seen but not an obstacle.
        var seen = Set<Int>()
        var local: [LocalBuilding] = []
        var relevant: [Building] = []
        for building in buildings where building.bounds.intersects(window) {
            let index = relevant.count
            relevant.append(building)
            if building.footprint.contains(eye) {
                seen.insert(index)
                local.append(LocalBuilding(edges: [], top: building.height, blocks: false))
                continue
            }
            var edges: [Edge] = []
            for ring in building.footprint.rings where ring.count >= 3 {
                var previous = ring[ring.count - 1]
                for point in ring {
                    edges.append(Edge(
                        ax: Double(previous.x - eye.x) * metersPerUnit, ay: Double(previous.y - eye.y) * metersPerUnit,
                        bx: Double(point.x - eye.x) * metersPerUnit, by: Double(point.y - eye.y) * metersPerUnit
                    ))
                    previous = point
                }
            }
            local.append(LocalBuilding(
                edges: edges, top: building.height,
                blocks: building.minHeight < configuration.nonBlockingMinHeight
            ))
        }

        // 2. Uniform grid over [−D, D]² holding building indices.
        let grid = Grid(halfSize: distance, cellSize: configuration.gridCellSize)
        var cells = [[Int]](repeating: [], count: grid.count * grid.count)
        for (index, building) in local.enumerated() where !building.edges.isEmpty {
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for e in building.edges {
                minX = min(minX, e.ax, e.bx); maxX = max(maxX, e.ax, e.bx)
                minY = min(minY, e.ay, e.by); maxY = max(maxY, e.ay, e.by)
            }
            let (x0, y0) = grid.cell(minX, minY)
            let (x1, y1) = grid.cell(maxX, maxY)
            guard x1 >= 0, y1 >= 0, x0 < grid.count, y0 < grid.count else { continue }
            for cy in max(y0, 0)...min(y1, grid.count - 1) {
                for cx in max(x0, 0)...min(x1, grid.count - 1) {
                    cells[cy * grid.count + cx].append(index)
                }
            }
        }

        // 3. Cast rays.
        let rays = max(configuration.rayCount, 8)
        let step = 2 * Double.pi / Double(rays)
        let halfWidth = step / 2 * 1.05 // slight overlap so neighbouring wedges merge cleanly
        var stamp = [Int](repeating: -1, count: local.count)
        var wedges: [WorldPolygon] = []
        wedges.reserveCapacity(rays + 64)

        func world(_ r: Double, _ angle: Double) -> WorldPoint {
            WorldPoint(
                x: eye.x + Int64((cos(angle) * r * unitsPerMeter).rounded()),
                y: eye.y + Int64((sin(angle) * r * unitsPerMeter).rounded())
            )
        }

        for ray in 0..<rays {
            let angle = Double(ray) * step
            let dx = cos(angle), dy = sin(angle)
            var crossings: [Crossing] = []
            grid.traverse(dx: dx, dy: dy, length: distance) { cell in
                for index in cells[cell] where stamp[index] != ray {
                    stamp[index] = ray
                    crossings += Self.crossings(of: local[index], index: index, dx: dx, dy: dy, length: distance)
                }
            }
            var seenOnRay = Set<Int>()
            let visible = sweep(crossings, eyeHeight: eyeHeight, length: distance, seen: &seenOnRay)
            seen.formUnion(seenOnRay)
            let a0 = angle - halfWidth, a1 = angle + halfWidth
            for (start, end) in visible {
                if start < 0.05 {
                    wedges.append(WorldPolygon(exterior: [eye, world(end, a0), world(end, a1)]))
                } else {
                    wedges.append(WorldPolygon(exterior: [world(start, a0), world(end, a0), world(end, a1), world(start, a1)]))
                }
            }
        }

        // 4. Union visible ground and seen buildings.
        let seenFootprints = seen.map { relevant[$0].footprint }
        var polygons = PolygonOps.union(wedges + seenFootprints)
        if configuration.simplificationTolerance > 0 {
            polygons = PolygonOps.simplify(polygons, epsilon: configuration.simplificationTolerance * unitsPerMeter)
        }
        return ViewshedResult(
            polygons: polygons,
            seenBuildingIDs: Set(seen.map { relevant[$0].id }),
            eyeHeight: eyeHeight,
            viewDistance: distance
        )
    }

    /// Where a ray from the origin in direction (dx, dy) passes through a building's material.
    static func crossings(of building: LocalBuilding, index: Int, dx: Double, dy: Double, length: Double) -> [Crossing] {
        var ts: [Double] = []
        for e in building.edges {
            let ex = e.bx - e.ax, ey = e.by - e.ay
            let denominator = dx * ey - dy * ex
            if abs(denominator) < 1e-12 { continue } // parallel
            let t = (e.ax * ey - e.ay * ex) / denominator
            let u = (e.ax * dy - e.ay * dx) / denominator
            if t > 0, u >= 0, u < 1 { ts.append(t) }
        }
        guard ts.count >= 2 else { return [] }
        ts.sort()
        var result: [Crossing] = []
        var i = 0
        while i + 1 < ts.count {
            if ts[i] < length {
                result.append(Crossing(entry: ts[i], exit: ts[i + 1], top: building.top, blocks: building.blocks, building: index))
            }
            i += 2
        }
        return result
    }

    /// Walks along one ray and returns the visible ground intervals (metres).
    static func sweep(_ crossings: [Crossing], eyeHeight: Double, length: Double, seen: inout Set<Int>) -> [(Double, Double)] {
        let h = max(eyeHeight, 0.01)
        var visible: [(Double, Double)] = []
        var maxSlope = -Double.infinity
        var cursor = 0.0 // end of the material of blocking buildings passed so far
        var emittedUntil = 0.0

        func resume() -> Double {
            if maxSlope == -.infinity { return 0 }
            return maxSlope < 0 ? h / -maxSlope : .infinity
        }
        func emit(_ from: Double, _ to: Double) {
            let from = max(from, emittedUntil)
            guard to - from > 1e-6 else { return }
            emittedUntil = to
            if let last = visible.last, abs(last.1 - from) < 1e-6 {
                visible[visible.count - 1].1 = to
            } else {
                visible.append((from, to))
            }
        }

        for crossing in crossings.sorted(by: { $0.entry < $1.entry }) where crossing.entry < length {
            let from = max(cursor, resume())
            if from < crossing.entry { emit(from, crossing.entry) }
            let rise = crossing.top - h
            let nearSlope = rise / max(crossing.entry, 0.01)
            let farSlope = rise / max(crossing.exit, 0.01)
            if nearSlope > maxSlope || farSlope > maxSlope {
                seen.insert(crossing.building)
            }
            if crossing.blocks {
                maxSlope = max(maxSlope, nearSlope, farSlope)
                cursor = max(cursor, crossing.exit)
            }
        }
        let from = max(cursor, resume())
        if from < length { emit(from, length) }
        return visible
    }

    /// A square grid centred on the eye.
    struct Grid {
        let halfSize: Double
        let cellSize: Double
        let count: Int

        init(halfSize: Double, cellSize: Double) {
            self.halfSize = halfSize
            self.cellSize = cellSize
            count = max(1, Int((2 * halfSize / cellSize).rounded(.up)))
        }

        func cell(_ x: Double, _ y: Double) -> (Int, Int) {
            (Int(((x + halfSize) / cellSize).rounded(.down)), Int(((y + halfSize) / cellSize).rounded(.down)))
        }

        /// Visits the cells along a ray from the centre (Amanatides & Woo).
        func traverse(dx: Double, dy: Double, length: Double, visit: (Int) -> Void) {
            var (cx, cy) = cell(0, 0)
            let stepX = dx >= 0 ? 1 : -1
            let stepY = dy >= 0 ? 1 : -1
            let originX = halfSize, originY = halfSize // the eye in grid coordinates
            let nextBoundaryX = (Double(cx + (stepX > 0 ? 1 : 0))) * cellSize
            let nextBoundaryY = (Double(cy + (stepY > 0 ? 1 : 0))) * cellSize
            var tMaxX = abs(dx) < 1e-12 ? Double.infinity : (nextBoundaryX - originX) / dx
            var tMaxY = abs(dy) < 1e-12 ? Double.infinity : (nextBoundaryY - originY) / dy
            let tDeltaX = abs(dx) < 1e-12 ? Double.infinity : cellSize / abs(dx)
            let tDeltaY = abs(dy) < 1e-12 ? Double.infinity : cellSize / abs(dy)
            var t = 0.0
            while t <= length, cx >= 0, cy >= 0, cx < count, cy < count {
                visit(cy * count + cx)
                if tMaxX < tMaxY {
                    t = tMaxX
                    tMaxX += tDeltaX
                    cx += stepX
                } else {
                    t = tMaxY
                    tMaxY += tDeltaY
                    cy += stepY
                }
            }
        }
    }
}

/// The 3D discovery model: everything visible from the sample between the buildings.
public struct ViewshedDiscoveryModel: DiscoveryModel {
    public var buildings: any BuildingSource
    public var terrain: any TerrainModel
    public var configuration: ViewshedConfiguration

    public init(
        buildings: any BuildingSource,
        terrain: any TerrainModel = FlatTerrain.berlin,
        configuration: ViewshedConfiguration = ViewshedConfiguration()
    ) {
        self.buildings = buildings
        self.terrain = terrain
        self.configuration = configuration
    }

    public var layer: DiscoveryLayerID { "viewshed-v1" }

    public func revealedArea(for sample: LocationSample) async throws -> [WorldPolygon] {
        try await viewshed(for: sample).polygons
    }

    public func viewshed(for sample: LocationSample) async throws -> ViewshedResult {
        let eye = sample.worldPoint
        let height = configuration.eyeHeight(
            altitude: sample.altitude, verticalAccuracy: sample.verticalAccuracy,
            groundElevation: terrain.elevation(at: eye)
        )
        let distance = configuration.viewDistance(eyeHeight: height)
        let reach = Int64((distance / WebMercator.metersPerUnit(atLatitude: sample.latitude)).rounded(.up)) + 1
        let window = WorldRect(minX: eye.x - reach, minY: eye.y - reach, maxX: eye.x + reach, maxY: eye.y + reach)
        let nearby = try await buildings.buildings(in: window)
        return Viewshed.compute(eye: eye, eyeHeight: height, viewDistance: distance, buildings: nearby, configuration: configuration)
    }
}
