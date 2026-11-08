import CoreImage
import MapKit
import MapQuestCore
import UIKit

/// Renders the ground of the 3D scene: an Apple Maps snapshot of the area with
/// the same fog as the 2D map (undiscovered parts darkened).
enum GroundTexture {
    static let pointSize = CGSize(width: 1_024, height: 1_024)

    /// A map image of exactly `rect` (Web Mercator, so it maps linearly onto the ground plane),
    /// or `nil` if MapKit does not deliver one within `timeout` seconds.
    static func mapImage(for rect: WorldRect, timeout: TimeInterval = 20) async -> UIImage? {
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { await snapshot(for: rect) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func snapshot(for rect: WorldRect) async -> UIImage? {
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

    /// The map image (or a plain background) with fog drawn over undiscovered
    /// areas: the map blurred and darkened there, with soft edges (`FogStyle`).
    static func compose(map: UIImage?, rect: WorldRect, snapshot: DiscoveredAreaSnapshot, style: FogStyle) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let size = pointSize
        let pixels = (width: Int(size.width * format.scale), height: Int(size.height * format.scale))
        let mask = fogMask(rect: rect, snapshot: snapshot, pixels: pixels, softness: style.softness * Double(format.scale))
        let blurred = style.blur > 0 ? map.flatMap { blur($0, radius: style.blur * 20 * Double(format.scale)) } : nil
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let bounds = CGRect(origin: .zero, size: size)
            if let map {
                map.draw(in: bounds)
            } else {
                UIColor(red: 0.90, green: 0.88, blue: 0.83, alpha: 1).setFill()
                context.fill(bounds)
            }
            guard let mask else { return }
            cg.saveGState()
            // The mask image's first row is the top; UIKit's context is flipped already.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.clip(to: bounds, mask: mask)
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            blurred?.draw(in: bounds)
            cg.setFillColor(UIColor(red: FogStyle.red, green: FogStyle.green, blue: FogStyle.blue, alpha: CGFloat(style.opacity)).cgColor)
            cg.fill(bounds)
            cg.restoreGState()
        }
    }

    /// Grayscale mask, white where the fog lies, optionally softened (Gaussian, σ = softness / 2).
    private static func fogMask(rect: WorldRect, snapshot: DiscoveredAreaSnapshot, pixels: (width: Int, height: Int), softness: Double) -> CGImage? {
        guard let gray = CGContext(
            data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: pixels.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        gray.setFillColor(gray: 1, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        // Rows top to bottom like world coordinates.
        gray.translateBy(x: 0, y: CGFloat(pixels.height))
        gray.scaleBy(x: 1, y: -1)
        gray.setFillColor(gray: 0, alpha: 1)
        let sx = Double(pixels.width) / Double(rect.width)
        let sy = Double(pixels.height) / Double(rect.height)
        for piece in snapshot.pieces(intersecting: rect) {
            let path = CGMutablePath()
            for ring in piece.polygon.rings {
                for (index, point) in ring.enumerated() {
                    let p = CGPoint(x: Double(point.x - rect.minX) * sx, y: Double(point.y - rect.minY) * sy)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
            }
            gray.addPath(path)
            gray.fillPath(using: .evenOdd)
        }
        guard let sharp = gray.makeImage() else { return nil }
        guard softness > 0 else { return sharp }
        let input = CIImage(cgImage: sharp)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: softness / 2).cropped(to: input.extent)
        return CIContext().createCGImage(output, from: input.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    private static func blur(_ image: UIImage, radius: Double) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius / 2).cropped(to: input.extent)
        guard let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
    }
}
