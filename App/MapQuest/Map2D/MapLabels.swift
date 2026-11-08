import MapKit
import MapQuestCore
import UIKit

/// A city or district name on the map. The base map has no labels; these are the
/// only names shown, above the fog (annotation views lie above all overlays).
final class MapLabelAnnotation: NSObject, MKAnnotation {
    enum Kind { case city, district }

    let coordinate: CLLocationCoordinate2D
    let title: String?
    let kind: Kind
    /// The city has no districts: its name is shown at every zoom.
    let isAlone: Bool

    init(name: String, point: WorldPoint, kind: Kind, isAlone: Bool = false) {
        let geo = WebMercator.unproject(point)
        coordinate = CLLocationCoordinate2D(latitude: geo.latitude, longitude: geo.longitude)
        title = name
        self.kind = kind
        self.isAlone = isAlone
    }

    /// Labels for the cities and their districts (label points computed off the main thread).
    static func make(for cities: [PlayArea]) async -> [MapLabelAnnotation] {
        let places = await Task.detached(priority: .utility) { () -> [(name: String, point: WorldPoint, isCity: Bool, isAlone: Bool)] in
            var found: [(name: String, point: WorldPoint, isCity: Bool, isAlone: Bool)] = []
            for city in cities {
                if let point = city.labelPoint {
                    found.append((city.name, point, true, city.subdivisions.isEmpty))
                }
                for district in city.subdivisions {
                    if let point = district.labelPoint {
                        found.append((district.name, point, false, false))
                    }
                }
            }
            return found
        }.value
        return places.map { MapLabelAnnotation(name: $0.name, point: $0.point, kind: $0.isCity ? .city : .district, isAlone: $0.isAlone) }
    }

    /// Whether the label is shown when the visible map is `width` metres wide:
    /// city names from afar, district names closer in.
    func isVisible(atWidth width: Double) -> Bool {
        switch kind {
        case .city: return isAlone ? width < 120_000 : (width >= 9_000 && width < 400_000)
        case .district: return width < 18_000
        }
    }
}

/// White text with a dark halo, readable on the fog and on the map.
final class MapLabelView: MKAnnotationView {
    static let reuseIdentifier = "MapLabel"
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        isEnabled = false
        collisionMode = .rectangle
        backgroundColor = .clear
        label.textAlignment = .center
        label.numberOfLines = 2
        label.textColor = .white
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.95
        label.layer.shadowRadius = 2.5
        label.layer.shadowOffset = .zero
        addSubview(label)
        configure()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        guard let item = annotation as? MapLabelAnnotation else { return }
        let isCity = item.kind == .city
        label.font = isCity ? .systemFont(ofSize: 17, weight: .bold) : .systemFont(ofSize: 13, weight: .semibold)
        label.text = isCity ? item.title?.uppercased() : item.title
        // Cities always win; districts give way to each other when they would overlap.
        displayPriority = isCity ? .required : .defaultHigh
        let size = label.sizeThatFits(CGSize(width: 150, height: 60))
        label.frame = CGRect(origin: .zero, size: size)
        bounds = CGRect(origin: .zero, size: size)
    }
}
