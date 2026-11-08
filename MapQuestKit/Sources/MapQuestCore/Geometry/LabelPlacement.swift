import Foundation

/// Where to put an area's name on the map: a point well inside the area, far
/// from its boundary (an approximate "pole of inaccessibility"; the centroid can
/// lie outside concave or ring-shaped areas).
public extension WorldPolygon {
    /// Distance from a point to the nearest edge of any ring, in world units.
    func distanceToBoundary(_ point: WorldPoint) -> Double {
        var best = Double.infinity
        let px = Double(point.x), py = Double(point.y)
        for ring in rings where ring.count >= 2 {
            var previous = ring[ring.count - 1]
            for current in ring {
                let ax = Double(previous.x), ay = Double(previous.y)
                let dx = Double(current.x) - ax, dy = Double(current.y) - ay
                let lengthSquared = dx * dx + dy * dy
                var t = lengthSquared > 0 ? ((px - ax) * dx + (py - ay) * dy) / lengthSquared : 0
                t = min(1, max(0, t))
                let ex = ax + t * dx - px, ey = ay + t * dy - py
                best = min(best, ex * ex + ey * ey)
                previous = current
            }
        }
        return best.squareRoot()
    }

    /// A point inside the polygon, as far from its boundary as a two-stage grid search finds.
    func labelPoint(gridSize: Int = 12) -> WorldPoint {
        let bounds = self.bounds
        var best: (point: WorldPoint, distance: Double)?
        func consider(_ point: WorldPoint) {
            guard contains(point) else { return }
            let distance = distanceToBoundary(point)
            if distance > (best?.distance ?? -1) { best = (point, distance) }
        }
        func search(minX: Double, minY: Double, width: Double, height: Double) {
            let n = max(gridSize, 2)
            for i in 0..<n {
                for j in 0..<n {
                    consider(WorldPoint(
                        x: Int64(minX + (Double(i) + 0.5) * width / Double(n)),
                        y: Int64(minY + (Double(j) + 0.5) * height / Double(n))
                    ))
                }
            }
        }
        let width = Double(bounds.width), height = Double(bounds.height)
        search(minX: Double(bounds.minX), minY: Double(bounds.minY), width: width, height: height)
        // Refine around the best cell.
        if let coarse = best {
            let cellWidth = width / Double(max(gridSize, 2)), cellHeight = height / Double(max(gridSize, 2))
            search(
                minX: Double(coarse.point.x) - cellWidth, minY: Double(coarse.point.y) - cellHeight,
                width: 2 * cellWidth, height: 2 * cellHeight
            )
        }
        // Degenerate shapes: any vertex.
        return best?.point ?? exterior.first ?? bounds.center
    }
}

public extension PlayArea {
    /// Where to write the area's name: inside its largest polygon.
    var labelPoint: WorldPoint? {
        polygons.max { $0.area < $1.area }?.labelPoint()
    }
}
