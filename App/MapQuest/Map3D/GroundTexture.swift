import MapKit
import MapQuestCore
import UIKit

/// Renders the ground of the 3D scene: an Apple Maps snapshot of the area with
/// the same fog as the 2D map (undiscovered parts darkened).
enum GroundTexture {
    static let pointSize = CGSize(width: 1_024, height: 1_024)

    /// A map image of exactly `rect` (Web Mercator, so it maps linearly onto the ground plane).
    static func mapImage(for rect: WorldRect) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = MapPointConversion.mapRect(for: rect)
        options.size = pointSize
        options.scale = 2
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { continuation in
            snapshotter.start { snapshot, _ in
                continuation.resume(returning: snapshot?.image)
            }
        }
    }

    /// The map image (or a plain background) with fog drawn over undiscovered areas.
    static func compose(map: UIImage?, rect: WorldRect, snapshot: DiscoveredAreaSnapshot) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let size = pointSize
        let fog = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0.62).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setBlendMode(.clear)
            let sx = Double(size.width) / Double(rect.width)
            let sy = Double(size.height) / Double(rect.height)
            for piece in snapshot.pieces(intersecting: rect) {
                let path = CGMutablePath()
                for ring in piece.polygon.rings {
                    for (index, point) in ring.enumerated() {
                        let p = CGPoint(x: Double(point.x - rect.minX) * sx, y: Double(point.y - rect.minY) * sy)
                        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                }
                cg.addPath(path)
                cg.fillPath(using: .evenOdd)
            }
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let map {
                map.draw(in: CGRect(origin: .zero, size: size))
            } else {
                UIColor(red: 0.90, green: 0.88, blue: 0.83, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            fog.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
