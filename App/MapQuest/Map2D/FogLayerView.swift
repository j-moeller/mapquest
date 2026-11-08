import Accelerate
import MapKit
import MapQuestCore
import UIKit

/// The fog of war, drawn in the map view's own coordinate space so that it moves
/// in the same frame as the map.
///
/// An `MKOverlayRenderer` draws asynchronously, tile by tile, after MapKit has
/// shown the base map – when zooming out, newly exposed map appeared unfogged
/// for a moment. This view instead holds one vector path: a fog rectangle far
/// larger than the visible area with every discovered piece cut out (even-odd).
/// While the map moves, only the layer's affine transform changes; the path is
/// rebuilt when the discovered area changes or the map zoomed or panned far.
///
/// Pieces overlap their neighbours by a small margin (docs/02-architecture.md);
/// with even-odd filling, overlaps would be fogged again, so every piece is
/// clipped to its exact storage tile first (in the background).
///
/// Optional effects (`FogStyle`): a system blur under the fog, masked by the same
/// path, so undiscovered map is frosted as well as darkened; and soft edges – a
/// raster band inside the discovered areas, three screens wide, in which the fog
/// fades out over the chosen width (computed in the background, placed like the
/// heatmap; while it is rebuilt the edges are briefly sharp, never unfogged).
final class FogLayerView: UIView {
    enum Mode { case fog, heatmap }

    weak var map: MKMapView?

    private let fogLayer = CAShapeLayer()
    private let boundaryLayer = CAShapeLayer()
    private let positionLayer = CAShapeLayer()
    /// Soft edges: the fog fading out inside discovered areas.
    private let bandLayer = CALayer()
    /// Blur under the fog, masked by the fog's shape and soft band.
    private let blurView = UIVisualEffectView(effect: nil)
    private let blurMask = UIView()
    private let maskShape = CAShapeLayer()
    private let maskBand = CALayer()
    private var blurAnimator: UIViewPropertyAnimator?
    private(set) var style = FogStyle.default

    // Soft-edge band state: the raster and the map rectangle it covers.
    private var bandRect = MKMapRect.null
    private var bandScale: Double = 0
    private var bandNeedsRebuild = true
    private var isComputingBand = false
    /// Heatmap mode: the map is dimmed and the heat raster drawn on top.
    private let dimLayer = CALayer()
    private let heatLayer = CALayer()
    private(set) var mode = Mode.fog

    // Heatmap state: the raster and the map rectangle it covers.
    private var heatPoints: [WeightedPoint] = []
    private var heatVersion = -1
    private var heatRect = MKMapRect.null
    private var heatScale: Double = 0
    private var heatNeedsRebuild = false
    private var isComputingHeat = false

    /// Discovered area per storage tile, clipped to the exact tile.
    private var clipped: [TileKey: [WorldPolygon]] = [:]
    private var pendingSnapshot: DiscoveredAreaSnapshot?
    /// Tiles to re-clip with the pending snapshot (`nil`: all).
    private var pendingTiles: Set<TileKey>? = []
    private var isClipping = false
    private var boundary: [WorldPolygon] = []

    /// The path's coordinate system: path = (map point − origin) × scale.
    private var origin = MKMapPoint(x: 0, y: 0)
    private var scale: Double = 0
    /// The map rectangle the fog rectangle covers.
    private var covered = MKMapRect.null
    private var needsRebuild = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for shape in [fogLayer, boundaryLayer] {
            shape.anchorPoint = .zero
            shape.position = .zero
            shape.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
            layer.addSublayer(shape)
        }
        dimLayer.backgroundColor = UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0.35).cgColor
        dimLayer.isHidden = true
        layer.insertSublayer(dimLayer, at: 0)
        heatLayer.anchorPoint = .zero
        heatLayer.position = .zero
        heatLayer.magnificationFilter = .linear
        heatLayer.minificationFilter = .linear
        heatLayer.isHidden = true
        layer.insertSublayer(heatLayer, above: dimLayer)
        fogLayer.fillRule = .evenOdd
        fogLayer.fillColor = UIColor(red: FogStyle.red, green: FogStyle.green, blue: FogStyle.blue, alpha: 0.9).cgColor
        for raster in [bandLayer, maskBand] {
            raster.anchorPoint = .zero
            raster.position = .zero
            raster.magnificationFilter = .linear
            raster.minificationFilter = .linear
        }
        layer.insertSublayer(bandLayer, above: fogLayer)

        // The blur lies under everything else, masked like the fog.
        blurView.isUserInteractionEnabled = false
        blurView.isHidden = true
        addSubview(blurView)
        // Below the fog colour, band and heatmap layers, whatever UIKit's default order.
        layer.insertSublayer(blurView.layer, at: 0)
        maskShape.anchorPoint = .zero
        maskShape.position = .zero
        maskShape.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        maskShape.fillRule = .evenOdd
        maskShape.fillColor = UIColor.black.cgColor
        blurMask.layer.addSublayer(maskShape)
        blurMask.layer.addSublayer(maskBand)
        blurView.mask = blurMask
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        boundaryLayer.fillColor = nil
        boundaryLayer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.9).cgColor

        // "You are here": MapKit's own location dot lies below the fog.
        positionLayer.path = UIBezierPath(ovalIn: CGRect(x: -7, y: -7, width: 14, height: 14)).cgPath
        positionLayer.fillColor = UIColor.systemBlue.cgColor
        positionLayer.strokeColor = UIColor.white.cgColor
        positionLayer.lineWidth = 2.5
        positionLayer.shadowColor = UIColor.black.cgColor
        positionLayer.shadowOpacity = 0.3
        positionLayer.shadowRadius = 2
        positionLayer.shadowOffset = .zero
        positionLayer.isHidden = true
        layer.addSublayer(positionLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimLayer.frame = bounds.insetBy(dx: -bounds.width, dy: -bounds.height)
        blurView.frame = bounds
        blurMask.frame = blurView.bounds
        sync()
    }

    // A paused property animator must be stopped before it is released (and it
    // is removed with the view from the window anyway): stop it when leaving the
    // window, start it again when coming back.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopBlurAnimator() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyBlur() }
    }

    @objc private func applicationWillEnterForeground() {
        applyBlur()
    }

    // MARK: Style

    /// Applies opacity, blur and soft edges.
    func setStyle(_ newStyle: FogStyle) {
        let old = style
        style = newStyle
        let color = UIColor(red: FogStyle.red, green: FogStyle.green, blue: FogStyle.blue, alpha: CGFloat(newStyle.opacity)).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fogLayer.fillColor = color
        bandLayer.opacity = Float(newStyle.opacity)
        let soft = newStyle.softness > 0
        bandLayer.isHidden = !soft || mode != .fog
        maskBand.isHidden = !soft
        CATransaction.commit()
        if newStyle.blur != old.blur { applyBlur() }
        if newStyle.softness != old.softness {
            bandNeedsRebuild = true
            if !soft {
                bandLayer.contents = nil
                maskBand.contents = nil
            }
            sync()
        }
    }

    /// The blur strength is the progress of a paused animation from no effect to a system blur.
    private func applyBlur() {
        stopBlurAnimator()
        let fraction = mode == .fog ? style.blur : 0
        guard fraction > 0, window != nil else {
            blurView.isHidden = true
            return
        }
        blurView.isHidden = false
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [blurView] in
            // The dark style: its tint matches the fog (the light one would wash it out in light mode).
            blurView.effect = UIBlurEffect(style: .dark)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = CGFloat(min(max(fraction, 0), 1))
        blurAnimator = animator
    }

    private func stopBlurAnimator() {
        guard let animator = blurAnimator else { return }
        animator.stopAnimation(true)
        blurAnimator = nil
        blurView.effect = nil
    }

    // MARK: Heatmap

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fogLayer.isHidden = mode != .fog
        bandLayer.isHidden = mode != .fog || style.softness <= 0
        dimLayer.isHidden = mode != .heatmap
        heatLayer.isHidden = mode != .heatmap
        CATransaction.commit()
        heatNeedsRebuild = true
        applyBlur()
        sync()
    }

    func setHeatPoints(_ points: [WeightedPoint], version: Int) {
        guard version != heatVersion else { return }
        heatVersion = version
        heatPoints = points
        heatNeedsRebuild = true
        sync()
    }

    /// Rasterizes the heat of an area three screens wide in the background (cells of 2.5 points).
    private func rebuildHeat(visible: MKMapRect, scale: Double) {
        guard !isComputingHeat else {
            heatNeedsRebuild = true
            return
        }
        heatNeedsRebuild = false
        isComputingHeat = true
        let rect = visible.insetBy(dx: -visible.size.width, dy: -visible.size.height)
        let points = heatPoints
        let cellPoints = 2.5
        let cellSize = max(Int64((cellPoints / scale * MapPointConversion.worldUnitsPerMapPoint).rounded()), 1)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let area = MapPointConversion.worldRect(for: rect)
                var grid = HeatmapGrid(covering: area, cellSize: cellSize)
                grid.add(points.filter { area.contains($0.point) })
                // ≈ 6 points (σ) of smoothing on screen.
                return Self.image(of: grid.blurred(radius: 2))
            }.value
            guard let self else { return }
            self.isComputingHeat = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.heatLayer.contents = image
            self.heatLayer.bounds = CGRect(x: 0, y: 0, width: image?.width ?? 1, height: image?.height ?? 1)
            CATransaction.commit()
            self.heatRect = rect
            self.heatScale = scale
            self.sync()
        }
    }

    private nonisolated static func image(of grid: HeatmapGrid) -> CGImage? {
        guard grid.maximum > 0 else { return nil }
        let pixels = grid.rgba()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: grid.columns, height: grid.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: grid.columns * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Places the heat raster: its pixel grid mapped onto the map rectangle it covers.
    private func placeHeat(on map: MKMapView) {
        place(heatLayer, covering: heatRect, on: map)
    }

    /// Maps a raster layer's pixel grid onto the map rectangle it covers.
    private func place(_ raster: CALayer, covering rect: MKMapRect, on map: MKMapView) {
        guard !rect.isNull, raster.bounds.width > 0 else { return }
        let width = raster.bounds.width, height = raster.bounds.height
        let p0 = map.convert(MKMapPoint(x: rect.minX, y: rect.minY).coordinate, toPointTo: self)
        let px = map.convert(MKMapPoint(x: rect.maxX, y: rect.minY).coordinate, toPointTo: self)
        let py = map.convert(MKMapPoint(x: rect.minX, y: rect.maxY).coordinate, toPointTo: self)
        raster.setAffineTransform(CGAffineTransform(
            a: (px.x - p0.x) / width, b: (px.y - p0.y) / width,
            c: (py.x - p0.x) / height, d: (py.y - p0.y) / height,
            tx: p0.x, ty: p0.y
        ))
    }

    // MARK: Soft edges

    /// Rasterizes the soft band for an area three screens wide at one pixel per point.
    private func rebuildBand(visible: MKMapRect, scale: Double) {
        guard !isComputingBand else {
            bandNeedsRebuild = true
            return
        }
        bandNeedsRebuild = false
        isComputingBand = true
        let rect = visible.insetBy(dx: -visible.size.width, dy: -visible.size.height)
        let area = MapPointConversion.worldRect(for: rect)
        let polygons = clipped.filter { $0.key.worldRect.intersects(area) }.values.flatMap { $0 }.filter { $0.bounds.intersects(area) }
        let softness = style.softness
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                FogLayerView.band(polygons: polygons, rect: rect, scale: scale, softness: softness)
            }.value
            guard let self else { return }
            self.isComputingBand = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for raster in [self.bandLayer, self.maskBand] {
                raster.contents = image
                raster.bounds = CGRect(x: 0, y: 0, width: image?.width ?? 1, height: image?.height ?? 1)
            }
            CATransaction.commit()
            self.bandRect = rect
            self.bandScale = scale
            self.sync()
        }
    }

    /// The fog colour inside discovered areas, fading from full at their edges to
    /// nothing at `softness` points inside: with M the discovered mask and B its
    /// Gaussian blur (σ = softness / 2, three box blurs), the alpha is
    /// 1 − clamp(2 B − 1) inside, so it starts at the fog's own opacity at the edge.
    private nonisolated static func band(polygons: [WorldPolygon], rect: MKMapRect, scale: Double, softness: Double) -> CGImage? {
        let width = Int((rect.size.width * scale).rounded(.up)), height = Int((rect.size.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height < 12_000_000, !polygons.isEmpty else { return nil }
        guard let gray = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        // Pixel rows top to bottom like map points.
        gray.translateBy(x: 0, y: CGFloat(height))
        gray.scaleBy(x: 1, y: -1)
        gray.setFillColor(gray: 1, alpha: 1)
        let s = MapPointConversion.worldUnitsPerMapPoint
        for polygon in polygons {
            let path = CGMutablePath()
            for ring in polygon.rings {
                for (index, point) in ring.enumerated() {
                    let p = CGPoint(x: (Double(point.x) / s - rect.minX) * scale, y: (Double(point.y) / s - rect.minY) * scale)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
            }
            gray.addPath(path)
            gray.fillPath(using: .evenOdd)
        }
        guard let maskData = gray.data else { return nil }
        let mask = maskData.bindMemory(to: UInt8.self, capacity: width * height)

        // Three box blurs ≈ Gaussian with σ ≈ radius.
        let radius = max(1, Int((softness / 2).rounded()))
        var blurred = [UInt8](repeating: 0, count: width * height)
        var scratch = [UInt8](repeating: 0, count: width * height)
        blurred.withUnsafeMutableBytes { blurredBytes in
            scratch.withUnsafeMutableBytes { scratchBytes in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mask), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var a = vImage_Buffer(data: blurredBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var b = vImage_Buffer(data: scratchBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                let size = UInt32(2 * radius + 1)
                let flags = vImage_Flags(kvImageEdgeExtend)
                vImageBoxConvolve_Planar8(&source, &a, nil, 0, 0, size, size, 0, flags)
                vImageBoxConvolve_Planar8(&a, &b, nil, 0, 0, size, size, 0, flags)
                vImageBoxConvolve_Planar8(&b, &a, nil, 0, 0, size, size, 0, flags)
            }
        }

        let red = UInt8(FogStyle.red * 255), green = UInt8(FogStyle.green * 255), blue = UInt8(FogStyle.blue * 255)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) where mask[i] > 127 {
            let b = Double(blurred[i]) / 255
            let alpha = 1 - min(max(2 * b - 1, 0), 1)
            guard alpha > 0.01 else { continue }
            pixels[i * 4] = UInt8(Double(red) * alpha)
            pixels[i * 4 + 1] = UInt8(Double(green) * alpha)
            pixels[i * 4 + 2] = UInt8(Double(blue) * alpha)
            pixels[i * 4 + 3] = UInt8(255 * alpha)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: Inputs

    func setBoundary(_ polygons: [WorldPolygon]) {
        boundary = polygons
        needsRebuild = true
        sync()
    }

    /// Shows a new snapshot; `changedTiles` limits the work (`nil`: everything changed).
    func update(snapshot: DiscoveredAreaSnapshot, changedTiles: Set<TileKey>?) {
        pendingSnapshot = snapshot
        if let changedTiles, let tiles = pendingTiles {
            pendingTiles = tiles.union(changedTiles)
        } else {
            pendingTiles = nil
        }
        startClipping()
    }

    private func startClipping() {
        guard !isClipping, let snapshot = pendingSnapshot else { return }
        let tiles = pendingTiles
        pendingSnapshot = nil
        pendingTiles = []
        isClipping = true
        let base = clipped
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FogLayerView.clip(snapshot, tiles: tiles, base: base)
            }.value
            guard let self else { return }
            self.clipped = result
            self.isClipping = false
            self.needsRebuild = true
            self.bandNeedsRebuild = true
            self.sync()
            self.startClipping()
        }
    }

    private nonisolated static func clip(
        _ snapshot: DiscoveredAreaSnapshot, tiles: Set<TileKey>?, base: [TileKey: [WorldPolygon]]
    ) -> [TileKey: [WorldPolygon]] {
        var result = tiles == nil ? [:] : base
        for tile in tiles ?? Set(snapshot.piecesByTile.keys) {
            let rect = tile.worldRect
            var polygons: [WorldPolygon] = []
            for piece in snapshot.piecesByTile[tile] ?? [] {
                if rect.contains(piece.polygon.bounds) {
                    polygons.append(piece.polygon)
                } else {
                    polygons += PolygonOps.clip([piece.polygon], to: rect)
                }
            }
            result[tile] = polygons.isEmpty ? nil : polygons
        }
        return result
    }

    // MARK: Following the map

    /// Aligns the fog with the map; call whenever the visible region changes.
    func sync() {
        guard let map, bounds.width > 0, bounds.height > 0 else { return }
        let visible = map.visibleMapRect
        guard !visible.isNull, visible.size.width > 0, visible.size.height > 0 else { return }
        // View points per map point (approximate under rotation: only used for detail and coverage).
        let current = Double(bounds.width) / visible.size.width
        if needsRebuild || !covered.contains(visible) || current > scale * 1.5 || current < scale / 1.5 {
            rebuild(visible: visible, scale: current)
        }
        if mode == .heatmap,
           heatNeedsRebuild || !heatRect.contains(visible) || current > heatScale * 1.5 || current < heatScale / 1.5 {
            rebuildHeat(visible: visible, scale: current)
        }
        if mode == .fog, style.softness > 0,
           bandNeedsRebuild || !bandRect.contains(visible) || current > bandScale * 1.5 || current < bandScale / 1.5 {
            rebuildBand(visible: visible, scale: current)
        }

        // The affine transform path → view, from three points of the path's coordinate system.
        let step = 1_000.0
        let p0 = map.convert(origin.coordinate, toPointTo: self)
        let px = map.convert(MKMapPoint(x: origin.x + step / scale, y: origin.y).coordinate, toPointTo: self)
        let py = map.convert(MKMapPoint(x: origin.x, y: origin.y + step / scale).coordinate, toPointTo: self)
        let transform = CGAffineTransform(
            a: (px.x - p0.x) / step, b: (px.y - p0.y) / step,
            c: (py.x - p0.x) / step, d: (py.y - p0.y) / step,
            tx: p0.x, ty: p0.y
        )
        let magnification = max(sqrt(abs(transform.a * transform.d - transform.b * transform.c)), 1e-6)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fogLayer.setAffineTransform(transform)
        maskShape.setAffineTransform(transform)
        boundaryLayer.setAffineTransform(transform)
        if mode == .fog, style.softness > 0 {
            for raster in [bandLayer, maskBand] { place(raster, covering: bandRect, on: map) }
        }
        boundaryLayer.lineWidth = 2 / magnification
        boundaryLayer.lineDashPattern = [NSNumber(value: 6 / magnification), NSNumber(value: 4 / magnification)]
        if mode == .heatmap { placeHeat(on: map) }
        if map.showsUserLocation, let location = map.userLocation.location, location.horizontalAccuracy >= 0 {
            positionLayer.position = map.convert(location.coordinate, toPointTo: self)
            positionLayer.isHidden = false
        } else {
            positionLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Rebuilds the paths for the visible area at the current zoom.
    private func rebuild(visible: MKMapRect, scale: Double) {
        needsRebuild = false
        self.scale = scale
        // Generous coverage: the map can zoom out 1.5× or pan several screens before the next rebuild.
        covered = visible.insetBy(dx: -4 * visible.size.width, dy: -4 * visible.size.height)
        origin = MKMapPoint(x: covered.midX, y: covered.midY)

        let fog = CGMutablePath()
        fog.addRect(CGRect(
            x: (covered.minX - origin.x) * scale, y: (covered.minY - origin.y) * scale,
            width: covered.size.width * scale, height: covered.size.height * scale
        ))
        let area = MapPointConversion.worldRect(for: covered)
        let unitsPerMapPoint = MapPointConversion.worldUnitsPerMapPoint
        // Holes smaller than a quarter point are invisible; skip them when zoomed out.
        let minimumSize = Int64(0.25 / scale * unitsPerMapPoint)
        for (tile, polygons) in clipped where tile.worldRect.intersects(area) {
            for polygon in polygons {
                let bounds = polygon.bounds
                guard bounds.intersects(area), max(bounds.width, bounds.height) >= minimumSize else { continue }
                append(polygon.rings, to: fog)
            }
        }

        let outline = CGMutablePath()
        for polygon in boundary where polygon.bounds.intersects(area) {
            append([polygon.exterior], to: outline)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fogLayer.path = fog
        maskShape.path = fog
        boundaryLayer.path = outline
        CATransaction.commit()
    }

    /// Adds rings in path coordinates, skipping vertices closer than half a point.
    private func append(_ rings: [WorldRing], to path: CGMutablePath) {
        let s = MapPointConversion.worldUnitsPerMapPoint
        let minimumStepSquared = 0.25
        for ring in rings {
            var emitted = 0
            var last = CGPoint.zero
            for point in ring {
                let p = CGPoint(x: (Double(point.x) / s - origin.x) * scale, y: (Double(point.y) / s - origin.y) * scale)
                if emitted > 0 {
                    let dx = p.x - last.x, dy = p.y - last.y
                    if dx * dx + dy * dy < minimumStepSquared { continue }
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
}
