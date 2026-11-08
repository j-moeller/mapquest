import Accelerate
import MapKit
import MapQuestCore
import UIKit

/// Covers the whole world: the base map with the fog of war, drawn by `FogMapRenderer`.
final class FogMapOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// Replaces Apple's map (and its labels) with a plain dark ground, visible only
/// where `FogMapRenderer` has not drawn yet – so no unfogged map ever shows.
final class GroundTileOverlay: MKTileOverlay {
    private let tile: Data

    init(color: UIColor) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 256, height: 256)
        tile = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        result(tile, nil)
    }
}

/// Draws the base map and the fog of war in one pass, piece by piece, as part of
/// MapKit's own rendering: the fog cannot lag behind or glide over the map while
/// it pans, zooms or decelerates, and map content never appears without its fog.
///
/// For every piece MapKit asks for, the base map tiles (`BaseMapTiles`) are
/// composed into a bitmap with a margin; where the fog lies, that bitmap is drawn
/// blurred and darkened (`FogStyle`), with a soft fade at the edges of discovered
/// areas. Missing tiles are loaded and the piece is redrawn when they arrive
/// (meanwhile a cached coarser tile is enlarged). When the discovered area
/// changes, only the affected map rectangles are redrawn.
final class FogMapRenderer: MKOverlayRenderer {
    /// What to draw; replaced under the lock, read once per drawn piece.
    struct Content {
        var tiles: BaseMapTiles
        /// `nil`: the plain base map without fog (heatmap view).
        var snapshot: DiscoveredAreaSnapshot?
        var style: FogStyle
    }

    /// Blur radius (σ, points) at 100 % "blur under the fog".
    static let maximumBlurPoints = 16.0

    private let lock = NSLock()
    private var content: Content

    init(overlay: FogMapOverlay, content: Content) {
        self.content = content
        super.init(overlay: overlay)
    }

    private var current: Content {
        lock.lock()
        defer { lock.unlock() }
        return content
    }

    // MARK: Updates (main thread)

    func setTiles(_ tiles: BaseMapTiles) {
        lock.lock()
        let changed = content.tiles !== tiles
        content.tiles = tiles
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    func setStyle(_ style: FogStyle) {
        lock.lock()
        let changed = content.style != style
        content.style = style
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    /// Shows another discovered area; `changedTiles` (storage tiles) limits the
    /// redraw, `nil` redraws everything.
    func setSnapshot(_ snapshot: DiscoveredAreaSnapshot?, changedTiles: Set<TileKey>?) {
        lock.lock()
        let wasPlain = content.snapshot == nil
        content.snapshot = snapshot
        let softness = content.style.softness
        lock.unlock()
        guard let snapshot, let changedTiles, !wasPlain, changedTiles.count <= 400 else {
            setNeedsDisplay()
            return
        }
        for tile in changedTiles {
            // Pieces reach beyond their tile by a margin, the soft edge further still.
            let margin = snapshot.maximumMarginUnits + Int64((2 * softness + 20) / tile.metersPerUnit)
            setNeedsDisplay(MapPointConversion.mapRect(for: tile.worldRect.expanded(by: margin)))
        }
    }

    // MARK: Drawing (MapKit's drawing threads)

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let content = current
        let pixelsPerMapPoint = Double(zoomScale) * Double(contentScaleFactor)
        let width = Int((mapRect.size.width * pixelsPerMapPoint).rounded(.up))
        let height = Int((mapRect.size.height * pixelsPerMapPoint).rounded(.up))
        guard width > 0, height > 0, width <= 4_096, height <= 4_096 else { return }

        // Blur and soft edges reach across the piece's edges: compose a larger area.
        var blurRadius = 0, softRadius = 0
        if content.snapshot != nil {
            let latitude = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate.latitude
            let pixelsPerMeter = pixelsPerMapPoint * MKMapPointsPerMeterAtLatitude(latitude)
            blurRadius = Int((content.style.blur * Self.maximumBlurPoints * Double(contentScaleFactor)).rounded())
            softRadius = min(Int((content.style.softness * pixelsPerMeter / 2).rounded()), 120)
        }
        let area = Area(
            mapRect: mapRect, pixelsPerMapPoint: pixelsPerMapPoint,
            width: width, height: height, margin: 3 * max(blurRadius, softRadius) + 2
        )
        guard let base = composeBase(area, zoomScale: zoomScale, tiles: content.tiles),
              var image = base.makeImage() else { return }
        if let snapshot = content.snapshot,
           let fogged = Self.fog(over: base, image: image, area: area, snapshot: snapshot, style: content.style,
                                 blurRadius: blurRadius, softRadius: softRadius) {
            image = fogged
        }
        guard let piece = image.cropping(to: CGRect(x: area.margin, y: area.margin, width: width, height: height)) else { return }
        UIGraphicsPushContext(context)
        UIImage(cgImage: piece).draw(in: rect(for: mapRect))
        UIGraphicsPopContext()
    }

    /// The pixel grid of one drawn piece plus its margin (bitmap coordinates, y up).
    private struct Area {
        let mapRect: MKMapRect
        let pixelsPerMapPoint: Double
        let width: Int
        let height: Int
        let margin: Int

        var fullWidth: Int { width + 2 * margin }
        var fullHeight: Int { height + 2 * margin }
        var fullRect: CGRect { CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight) }
        var fullMapRect: MKMapRect {
            let inset = -Double(margin) / pixelsPerMapPoint
            return mapRect.insetBy(dx: inset, dy: inset)
        }

        func pixelRect(_ rect: MKMapRect) -> CGRect {
            let origin = fullMapRect.origin
            let x = (rect.minX - origin.x) * pixelsPerMapPoint
            let top = (rect.minY - origin.y) * pixelsPerMapPoint
            let w = rect.size.width * pixelsPerMapPoint, h = rect.size.height * pixelsPerMapPoint
            return CGRect(x: x, y: Double(fullHeight) - top - h, width: w, height: h)
        }

        func pixel(_ point: WorldPoint) -> CGPoint {
            let s = MapPointConversion.worldUnitsPerMapPoint
            let origin = fullMapRect.origin
            let x = (Double(point.x) / s - origin.x) * pixelsPerMapPoint
            let top = (Double(point.y) / s - origin.y) * pixelsPerMapPoint
            return CGPoint(x: x, y: Double(fullHeight) - top)
        }

        /// Adds a ring, skipping vertices closer than half a pixel.
        func add(_ ring: WorldRing, to path: CGMutablePath) {
            var emitted = 0
            var last = CGPoint.zero
            for point in ring {
                let p = pixel(point)
                if emitted > 0 {
                    let dx = p.x - last.x, dy = p.y - last.y
                    if dx * dx + dy * dy < 0.25 { continue }
                    path.addLine(to: p)
                } else {
                    path.move(to: p)
                }
                last = p
                emitted += 1
            }
            if emitted > 2 { path.closeSubpath() }
        }
    }

    /// 256-point tiles: at zoom 20 one map point is one point on screen.
    private static func tileZoom(_ zoomScale: MKZoomScale) -> Int {
        let zoom = 20 + log2(Double(zoomScale))
        return max(0, min(BaseMapStyle.maximumZoom, Int(zoom.rounded())))
    }

    /// The base map tiles of the area; missing ones are requested and redrawn later.
    private func composeBase(_ area: Area, zoomScale: MKZoomScale, tiles: BaseMapTiles) -> CGContext? {
        guard let context = Self.rgbaContext(area.fullWidth, area.fullHeight) else { return nil }
        context.interpolationQuality = .high
        let zoom = Self.tileZoom(zoomScale)
        let world = MapPointConversion.worldRect(for: area.fullMapRect)
        for tile in TileRange(covering: world, zoom: zoom) {
            let tileRect = MapPointConversion.mapRect(for: tile.worldRect)
            let best = tiles.bestImage(for: tile)
            if let best {
                let image: CGImage? = best.exact ? best.image : best.image.cropping(to: best.crop)
                if let image { context.draw(image, in: area.pixelRect(tileRect)) }
                if best.exact { continue }
            }
            tiles.load(tile) { [weak self] success in
                guard success else { return }
                DispatchQueue.main.async { self?.setNeedsDisplay(tileRect, zoomScale: zoomScale) }
            }
        }
        return context
    }

    /// The base map with the fog drawn over undiscovered areas: the map blurred
    /// there and darkened by the fog colour, fading out inside discovered areas.
    private static func fog(
        over base: CGContext, image: CGImage, area: Area, snapshot: DiscoveredAreaSnapshot, style: FogStyle,
        blurRadius: Int, softRadius: Int
    ) -> CGImage? {
        guard let mask = fogMask(area: area, snapshot: snapshot, softRadius: softRadius),
              let context = rgbaContext(area.fullWidth, area.fullHeight) else { return nil }
        let under = blurRadius > 0 ? (blurred(base, radius: blurRadius) ?? image) : image
        let full = area.fullRect
        context.draw(image, in: full)
        context.clip(to: full, mask: mask)
        context.draw(under, in: full)
        context.setFillColor(CGColor(red: FogStyle.red, green: FogStyle.green, blue: FogStyle.blue, alpha: CGFloat(style.opacity)))
        context.fill(full)
        return context.makeImage()
    }

    /// Grey mask, white where the fog lies: 1 outside discovered areas, fading to 0
    /// inside them over `softRadius` pixels (1 − clamp(2B − 1) of the blurred
    /// discovered mask B, as in the 3D ground texture).
    private static func fogMask(area: Area, snapshot: DiscoveredAreaSnapshot, softRadius: Int) -> CGImage? {
        let w = area.fullWidth, h = area.fullHeight
        guard let discovered = grayContext(w, h), let result = grayContext(w, h),
              let discoveredData = discovered.data, let resultData = result.data else { return nil }
        discovered.setFillColor(gray: 1, alpha: 1)
        let world = MapPointConversion.worldRect(for: area.fullMapRect)
        // Pieces smaller than half a pixel are invisible.
        let minimumSize = 0.5 / area.pixelsPerMapPoint * MapPointConversion.worldUnitsPerMapPoint
        for piece in snapshot.pieces(intersecting: world) {
            let bounds = piece.polygon.bounds
            guard Double(max(bounds.width, bounds.height)) >= minimumSize else { continue }
            // Each piece on its own: overlapping neighbours simply add up.
            let path = CGMutablePath()
            for ring in piece.polygon.rings { area.add(ring, to: path) }
            discovered.addPath(path)
            discovered.fillPath(using: .evenOdd)
        }
        var source = vImage_Buffer(data: discoveredData, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: discovered.bytesPerRow)
        var destination = vImage_Buffer(data: resultData, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: result.bytesPerRow)
        let flags = vImage_Flags(kvImageNoFlags)
        if softRadius >= 1 {
            var first = [UInt8](repeating: 0, count: w * h)
            var second = [UInt8](repeating: 0, count: w * h)
            first.withUnsafeMutableBytes { firstBytes in
                second.withUnsafeMutableBytes { secondBytes in
                    var a = vImage_Buffer(data: firstBytes.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    var b = vImage_Buffer(data: secondBytes.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    // Three box blurs ≈ Gaussian with σ ≈ radius.
                    let size = UInt32(2 * softRadius + 1)
                    let edge = vImage_Flags(kvImageEdgeExtend)
                    vImageBoxConvolve_Planar8(&source, &a, nil, 0, 0, size, size, 0, edge)
                    vImageBoxConvolve_Planar8(&a, &b, nil, 0, 0, size, size, 0, edge)
                    vImageBoxConvolve_Planar8(&b, &a, nil, 0, 0, size, size, 0, edge)
                    vImageTableLookUp_Planar8(&a, &destination, softTable, flags)
                }
            }
        } else {
            vImageTableLookUp_Planar8(&source, &destination, hardTable, flags)
        }
        return result.makeImage()
    }

    /// Fog alpha from the blurred discovered mask: 1 − clamp(2B − 1).
    private static let softTable: [UInt8] = (0..<256).map { value in
        let fog = 1 - min(max(2 * Double(value) / 255 - 1, 0), 1)
        return UInt8((fog * 255).rounded())
    }

    /// Fog where nothing was discovered.
    private static let hardTable: [UInt8] = (0..<256).map { UInt8(255 - $0) }

    /// The base map blurred (three box blurs ≈ Gaussian with σ ≈ radius).
    private static func blurred(_ base: CGContext, radius: Int) -> CGImage? {
        let w = base.width, h = base.height
        guard let output = rgbaContext(w, h), let baseData = base.data, let outputData = output.data else { return nil }
        var scratch = [UInt8](repeating: 0, count: w * h * 4)
        scratch.withUnsafeMutableBytes { scratchBytes in
            var source = vImage_Buffer(data: baseData, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: base.bytesPerRow)
            var a = vImage_Buffer(data: outputData, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: output.bytesPerRow)
            var b = vImage_Buffer(data: scratchBytes.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            let size = UInt32(2 * radius + 1)
            let flags = vImage_Flags(kvImageEdgeExtend)
            vImageBoxConvolve_ARGB8888(&source, &a, nil, 0, 0, size, size, nil, flags)
            vImageBoxConvolve_ARGB8888(&a, &b, nil, 0, 0, size, size, nil, flags)
            vImageBoxConvolve_ARGB8888(&b, &a, nil, 0, 0, size, size, nil, flags)
        }
        return output.makeImage()
    }

    private static func rgbaContext(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func grayContext(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }
}
