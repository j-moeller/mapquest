import CoreGraphics
import MapKit

/// The finished pieces of the map – base map with the fog of war – by map
/// rectangle and zoom. MapKit asks for the same pieces again whenever the map
/// returns to a zoom level it showed (zooming in and out, panning back); they are
/// then drawn from here instead of being composed, blurred and fogged again.
/// Least recently used pieces go first beyond `limit` bytes. Thread-safe.
final class PieceCache: @unchecked Sendable {
    struct Key: Hashable {
        let x: Double
        let y: Double
        let width: Double
        let zoomScale: Double

        init(_ mapRect: MKMapRect, zoomScale: MKZoomScale) {
            x = mapRect.origin.x
            y = mapRect.origin.y
            width = mapRect.size.width
            self.zoomScale = Double(zoomScale)
        }
    }

    private struct Entry {
        let image: CGImage
        let mapRect: MKMapRect
        let cost: Int
        var used: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var total = 0
    private var clock: UInt64 = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func image(for key: Key) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.used = clock
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: CGImage, for key: Key, mapRect: MKMapRect) {
        let cost = image.bytesPerRow * image.height
        guard cost < limit / 4 else { return }
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        if let old = entries[key] { total -= old.cost }
        entries[key] = Entry(image: image, mapRect: mapRect, cost: cost, used: clock)
        total += cost
        guard total > limit else { return }
        // Down to 80 %, least recently used first.
        for (key, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            entries[key] = nil
            total -= entry.cost
            if total <= limit * 8 / 10 { break }
        }
    }

    /// Forgets the pieces overlapping a map rectangle (its content changed).
    func remove(intersecting rect: MKMapRect) {
        lock.lock()
        defer { lock.unlock() }
        for (key, entry) in entries where entry.mapRect.intersects(rect) {
            entries[key] = nil
            total -= entry.cost
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        total = 0
    }
}
