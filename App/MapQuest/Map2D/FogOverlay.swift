import MapKit
import MapQuestCore
import UIKit

/// MapKit's `MKMapPoint` is Web Mercator in a 2^28 world; MapQuest's world
/// coordinates use 2^32. One map point is 16 world units.
enum MapPointConversion {
    static let worldUnitsPerMapPoint: Double = Double(WebMercator.worldSize) / MKMapSize.world.width

    static func worldRect(for mapRect: MKMapRect) -> WorldRect {
        let s = worldUnitsPerMapPoint
        return WorldRect(
            minX: Int64((mapRect.minX * s).rounded(.down)), minY: Int64((mapRect.minY * s).rounded(.down)),
            maxX: Int64((mapRect.maxX * s).rounded(.up)), maxY: Int64((mapRect.maxY * s).rounded(.up))
        )
    }

    static func mapRect(for rect: WorldRect) -> MKMapRect {
        let s = worldUnitsPerMapPoint
        return MKMapRect(
            x: Double(rect.minX) / s, y: Double(rect.minY) / s,
            width: Double(rect.width) / s, height: Double(rect.height) / s
        )
    }
}

/// A single overlay covering the whole world; its renderer draws the fog.
final class FogOverlay: NSObject, MKOverlay {
    let boundingMapRect: MKMapRect = .world
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
}

/// Thread-safe holder for the snapshot the renderer draws (MapKit renders on
/// background threads, concurrently).
final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DiscoveredAreaSnapshot

    init(_ value: DiscoveredAreaSnapshot) { self.value = value }

    var snapshot: DiscoveredAreaSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Fills every requested map rectangle with translucent fog, then clears the
/// discovered pieces out of it, so discovered places show the plain map.
final class FogOverlayRenderer: MKOverlayRenderer {
    let box: SnapshotBox
    var fogColor = UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0.58)

    init(overlay: FogOverlay, snapshot: DiscoveredAreaSnapshot) {
        box = SnapshotBox(snapshot)
        super.init(overlay: overlay)
    }

    /// Replaces the drawn snapshot and redraws the affected area.
    func update(snapshot: DiscoveredAreaSnapshot, changedTiles: Set<TileKey>?) {
        box.snapshot = snapshot
        guard let changedTiles, changedTiles.count < 64 else {
            setNeedsDisplay()
            return
        }
        let margin = snapshot.maximumMarginUnits
        for tile in changedTiles {
            setNeedsDisplay(MapPointConversion.mapRect(for: tile.worldRect.expanded(by: margin)))
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let drawRect = rect(for: mapRect)
        context.setFillColor(fogColor.cgColor)
        context.fill(drawRect)

        let snapshot = box.snapshot
        let pieces = snapshot.pieces(intersecting: MapPointConversion.worldRect(for: mapRect))
        guard !pieces.isEmpty else { return }

        // Map points per screen point; vertices closer than half a point are skipped.
        let s = MapPointConversion.worldUnitsPerMapPoint
        let minStep = 0.5 / Double(zoomScale)
        let minStepSquared = minStep * minStep
        let origin = overlay.boundingMapRect.origin

        context.setBlendMode(.clear)
        for piece in pieces {
            let path = CGMutablePath()
            for ring in piece.polygon.rings {
                var emitted = 0
                var lastX = 0.0, lastY = 0.0
                for point in ring {
                    let x = Double(point.x) / s - origin.x
                    let y = Double(point.y) / s - origin.y
                    if emitted > 0 {
                        let dx = x - lastX, dy = y - lastY
                        if dx * dx + dy * dy < minStepSquared { continue }
                        path.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        path.move(to: CGPoint(x: x, y: y))
                    }
                    lastX = x
                    lastY = y
                    emitted += 1
                }
                if emitted > 0 { path.closeSubpath() }
            }
            context.addPath(path)
            // Even-odd per piece: holes are cut out regardless of ring orientation.
            context.fillPath(using: .evenOdd)
        }
        context.setBlendMode(.normal)
    }
}
