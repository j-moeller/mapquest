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
