import MapKit
import MapQuestCore
import UIKit

/// A sight on the 2D map. Captured: a golden badge with its icon (above the fog,
/// like all annotations); not captured (debug "show all sights"): a grey "?".
final class SightAnnotation: NSObject, MKAnnotation {
    let pin: SightPin
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(_ pin: SightPin) {
        self.pin = pin
        coordinate = CLLocationCoordinate2D(latitude: pin.sight.latitude, longitude: pin.sight.longitude)
        title = pin.sight.name
        if let date = pin.capturedAt {
            subtitle = "Captured \(date.formatted(date: .abbreviated, time: .omitted))"
        } else {
            subtitle = "Not captured yet"
        }
    }
}

final class SightAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "Sight"
    private let icon = UIImageView()
    private static let size: CGFloat = 30

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = true
        collisionMode = .circle
        bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        layer.cornerRadius = Self.size / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
        icon.contentMode = .center
        icon.tintColor = .white
        icon.frame = bounds
        addSubview(icon)
        configure()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        guard let sight = annotation as? SightAnnotation else { return }
        let captured = sight.pin.isCaptured
        backgroundColor = captured ? .captureGold : UIColor.systemGray.withAlphaComponent(0.75)
        let symbol = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        icon.image = UIImage(systemName: captured ? sight.pin.sight.category.symbol : "questionmark", withConfiguration: symbol)
        displayPriority = captured ? .required : .defaultLow
        zPriority = captured ? .max : .defaultUnselected
    }
}

/// Keeps the sight annotations of a map in step with the pins.
@MainActor
final class SightAnnotationController {
    private var shown: [String: SightAnnotation] = [:]
    private var focusID: Int?

    func update(_ pins: [SightPin], on map: MKMapView) {
        let wanted = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var remove: [SightAnnotation] = []
        var add: [SightAnnotation] = []
        for (id, annotation) in shown where wanted[id] != annotation.pin {
            remove.append(annotation)
            shown[id] = nil
        }
        for (id, pin) in wanted where shown[id] == nil {
            let annotation = SightAnnotation(pin)
            shown[id] = annotation
            add.append(annotation)
        }
        if !remove.isEmpty { map.removeAnnotations(remove) }
        if !add.isEmpty { map.addAnnotations(add) }
    }

    /// Centres the map on a sight once per request and opens its callout.
    func focus(_ focus: SightFocus?, on map: MKMapView) {
        guard let focus, focus.id != focusID else { return }
        focusID = focus.id
        let coordinate = CLLocationCoordinate2D(latitude: focus.sight.latitude, longitude: focus.sight.longitude)
        map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800), animated: true)
        if let annotation = shown[focus.sight.id] {
            map.selectAnnotation(annotation, animated: true)
        }
    }
}
