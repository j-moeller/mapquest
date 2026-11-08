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
final class FogLayerView: UIView {
    enum Mode { case fog, heatmap }

    weak var map: MKMapView?

    private let fogLayer = CAShapeLayer()
    private let boundaryLayer = CAShapeLayer()
    private let positionLayer = CAShapeLayer()
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
        fogLayer.fillColor = UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0.9).cgColor
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
        sync()
    }

    // MARK: Heatmap

    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fogLayer.isHidden = mode != .fog
        dimLayer.isHidden = mode != .heatmap
        heatLayer.isHidden = mode != .heatmap
        CATransaction.commit()
        heatNeedsRebuild = true
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
                // ≈ 12 points of smoothing on screen.
                return Self.image(of: grid.blurred(radius: 5))
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
        guard !heatRect.isNull, heatLayer.bounds.width > 0 else { return }
        let width = heatLayer.bounds.width, height = heatLayer.bounds.height
        let p0 = map.convert(MKMapPoint(x: heatRect.minX, y: heatRect.minY).coordinate, toPointTo: self)
        let px = map.convert(MKMapPoint(x: heatRect.maxX, y: heatRect.minY).coordinate, toPointTo: self)
        let py = map.convert(MKMapPoint(x: heatRect.minX, y: heatRect.maxY).coordinate, toPointTo: self)
        heatLayer.setAffineTransform(CGAffineTransform(
            a: (px.x - p0.x) / width, b: (px.y - p0.y) / width,
            c: (py.x - p0.x) / height, d: (py.y - p0.y) / height,
            tx: p0.x, ty: p0.y
        ))
    }

    // MARK: Inputs

    func setFogOpacity(_ opacity: Double) {
        let color = UIColor(red: 0.04, green: 0.06, blue: 0.12, alpha: CGFloat(opacity)).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fogLayer.fillColor = color
        CATransaction.commit()
    }

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
        boundaryLayer.setAffineTransform(transform)
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
