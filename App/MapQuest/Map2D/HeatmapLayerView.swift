import MapKit
import MapQuestCore
import UIKit

/// The heatmap view: the map dimmed and the heat raster on top, placed over the
/// map with an affine transform on every map change. (The fog of war is drawn
/// into the map itself, `FogMapRenderer`.)
final class HeatmapLayerView: UIView {
    weak var map: MKMapView?

    private let dimLayer = CALayer()
    private let heatLayer = CALayer()
    private let positionLayer = CAShapeLayer()

    // The raster and the map rectangle it covers.
    private var heatPoints: [WeightedPoint] = []
    private var heatVersion = -1
    private var heatRect = MKMapRect.null
    private var heatScale: Double = 0
    private var needsRebuild = true
    private var isComputing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isHidden = true
        dimLayer.backgroundColor = UIColor(red: FogStyle.red, green: FogStyle.green, blue: FogStyle.blue, alpha: 0.35).cgColor
        layer.addSublayer(dimLayer)
        heatLayer.anchorPoint = .zero
        heatLayer.position = .zero
        heatLayer.magnificationFilter = .linear
        heatLayer.minificationFilter = .linear
        layer.addSublayer(heatLayer)

        // "You are here": MapKit's own location dot lies below this view.
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

    /// Shows or hides the heatmap.
    func setActive(_ active: Bool) {
        guard active == isHidden else { return }
        isHidden = !active
        needsRebuild = true
        sync()
    }

    func setHeatPoints(_ points: [WeightedPoint], version: Int) {
        guard version != heatVersion else { return }
        heatVersion = version
        heatPoints = points
        needsRebuild = true
        sync()
    }

    /// Aligns the raster with the map; call whenever the visible region changes.
    func sync() {
        guard !isHidden, let map, bounds.width > 0, bounds.height > 0 else { return }
        let visible = map.visibleMapRect
        guard !visible.isNull, visible.size.width > 0, visible.size.height > 0 else { return }
        let current = Double(bounds.width) / visible.size.width
        if needsRebuild || !heatRect.contains(visible) || current > heatScale * 1.5 || current < heatScale / 1.5 {
            rebuild(visible: visible, scale: current)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(heatLayer, covering: heatRect, on: map)
        if map.showsUserLocation, let location = map.userLocation.location, location.horizontalAccuracy >= 0 {
            positionLayer.position = map.convert(location.coordinate, toPointTo: self)
            positionLayer.isHidden = false
        } else {
            positionLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// Rasterizes the heat of an area three screens wide in the background (cells of 2.5 points).
    private func rebuild(visible: MKMapRect, scale: Double) {
        guard !isComputing else {
            needsRebuild = true
            return
        }
        needsRebuild = false
        isComputing = true
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
            self.isComputing = false
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
}
