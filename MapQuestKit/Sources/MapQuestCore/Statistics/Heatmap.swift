import Foundation

/// A position with the time spent there (seconds), ready for binning.
public struct WeightedPoint: Hashable, Sendable {
    public var point: WorldPoint
    public var weight: Float

    public init(point: WorldPoint, weight: Float) {
        self.point = point
        self.weight = weight
    }

    /// Accurate fixes of chronologically sorted track points, weighted by the time
    /// until the next fix (at most `maximumWeight` seconds).
    public static func timeSpent(_ points: [TrackPoint], maximumAccuracy: Double = 50, maximumWeight: Double = 5) -> [WeightedPoint] {
        var result: [WeightedPoint] = []
        result.reserveCapacity(points.count)
        for (index, point) in points.enumerated() where point.hasValidPosition && point.horizontalAccuracy <= maximumAccuracy {
            let next = index + 1 < points.count ? points[index + 1].time : point.time + 10
            result.append(WeightedPoint(point: point.worldPoint, weight: Float(min(max(Double(next - point.time) / 10, 0), maximumWeight))))
        }
        return result
    }
}

/// Time spent per place, on a regular grid of world coordinates, for heatmaps.
///
/// Every fix adds the time until the next fix (at most `maximumWeight` seconds),
/// so the value of a cell is roughly the time spent there. The grid is smoothed
/// with three box blurs (≈ Gaussian kernel density estimate, cf. Silverman 1986)
/// and drawn with a logarithmic colour scale, so that both a daily commute and a
/// single walk stay visible.
public struct HeatmapGrid: Sendable {
    /// Top-left corner (world coordinates; y grows southwards, row 0 is the top).
    public let origin: WorldPoint
    /// Edge length of a cell in world units.
    public let cellSize: Int64
    public let columns: Int
    public let rows: Int
    public private(set) var values: [Float]

    public init(covering rect: WorldRect, cellSize: Int64) {
        precondition(cellSize > 0, "cell size must be positive")
        origin = WorldPoint(x: rect.minX, y: rect.minY)
        self.cellSize = cellSize
        columns = max(1, Int((rect.width + cellSize - 1) / cellSize))
        rows = max(1, Int((rect.height + cellSize - 1) / cellSize))
        values = [Float](repeating: 0, count: columns * rows)
    }

    public var bounds: WorldRect {
        WorldRect(minX: origin.x, minY: origin.y, maxX: origin.x + Int64(columns) * cellSize, maxY: origin.y + Int64(rows) * cellSize)
    }

    public subscript(column: Int, row: Int) -> Float { values[row * columns + column] }

    public mutating func add(_ point: WorldPoint, weight: Float = 1) {
        let column = (point.x - origin.x) / cellSize
        let row = (point.y - origin.y) / cellSize
        guard point.x >= origin.x, point.y >= origin.y, column < Int64(columns), row < Int64(rows) else { return }
        values[Int(row) * columns + Int(column)] += weight
    }

    /// Adds chronologically sorted track points weighted by the time spent at them.
    public mutating func add(_ points: [TrackPoint], maximumAccuracy: Double = 50, maximumWeight: Double = 5) {
        add(WeightedPoint.timeSpent(points, maximumAccuracy: maximumAccuracy, maximumWeight: maximumWeight))
    }

    public mutating func add(_ points: [WeightedPoint]) {
        for point in points { add(point.point, weight: point.weight) }
    }

    public var maximum: Float { values.max() ?? 0 }
    public var total: Float { values.reduce(0, +) }

    /// Three passes of a box blur of `radius` cells (approximately Gaussian).
    public func blurred(radius: Int) -> HeatmapGrid {
        guard radius > 0 else { return self }
        var grid = self
        for _ in 0..<3 {
            grid.values = Self.boxBlur(grid.values, columns: columns, rows: rows, radius: radius, horizontal: true)
            grid.values = Self.boxBlur(grid.values, columns: columns, rows: rows, radius: radius, horizontal: false)
        }
        return grid
    }

    private static func boxBlur(_ input: [Float], columns: Int, rows: Int, radius: Int, horizontal: Bool) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        let (lines, length) = horizontal ? (rows, columns) : (columns, rows)
        let scale = 1 / Float(2 * radius + 1)
        for line in 0..<lines {
            func index(_ i: Int) -> Int { horizontal ? line * columns + i : i * columns + line }
            var sum: Float = 0
            for i in -radius...radius where i >= 0 && i < length { sum += input[index(i)] }
            for i in 0..<length {
                output[index(i)] = sum * scale
                let leaving = i - radius, entering = i + radius + 1
                if leaving >= 0 { sum -= input[index(leaving)] }
                if entering < length { sum += input[index(entering)] }
            }
        }
        return output
    }

    /// The value treated as "hot": the 99th percentile of non-empty cells (robust to outliers).
    public var reference: Float {
        let filled = values.filter { $0 > 0 }.sorted()
        guard !filled.isEmpty else { return 0 }
        return filled[min(filled.count - 1, Int(Double(filled.count) * 0.99))]
    }

    /// Premultiplied RGBA pixels (row 0 = top), logarithmic scale up to `reference`.
    public func rgba(reference: Float? = nil) -> [UInt8] {
        let top = max(reference ?? self.reference, 1e-6)
        let scale = 1 / log1p(top)
        var pixels = [UInt8](repeating: 0, count: values.count * 4)
        for (i, value) in values.enumerated() where value > 0 {
            let t = min(1, log1p(value) * scale)
            let (r, g, b, a) = HeatmapPalette.color(t)
            pixels[i * 4] = r
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = b
            pixels[i * 4 + 3] = a
        }
        return pixels
    }
}

/// Transparent → blue → cyan → green → yellow → red, opacity rising with intensity.
public enum HeatmapPalette {
    private static let stops: [(t: Float, r: Float, g: Float, b: Float, a: Float)] = [
        (0.00, 0.00, 0.20, 1.00, 0.00),
        (0.15, 0.00, 0.35, 1.00, 0.45),
        (0.35, 0.00, 0.85, 1.00, 0.65),
        (0.55, 0.20, 1.00, 0.30, 0.75),
        (0.75, 1.00, 0.90, 0.00, 0.85),
        (1.00, 1.00, 0.15, 0.00, 0.92),
    ]

    /// Premultiplied 8-bit colour for an intensity in 0…1.
    public static func color(_ t: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        let t = max(0, min(1, t))
        var upper = 1
        while upper < stops.count - 1, stops[upper].t < t { upper += 1 }
        let a = stops[upper - 1], b = stops[upper]
        let f = (t - a.t) / max(b.t - a.t, 1e-6)
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * f }
        let alpha = mix(a.a, b.a)
        func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * alpha * 255).rounded()))) }
        return (byte(mix(a.r, b.r)), byte(mix(a.g, b.g)), byte(mix(a.b, b.b)), UInt8(max(0, min(255, (alpha * 255).rounded()))))
    }
}
