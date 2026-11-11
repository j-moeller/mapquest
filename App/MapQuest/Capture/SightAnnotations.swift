import MapKit
import MapQuestCore
import UIKit

/// A sight on the 2D map (above the fog, like all annotations). Captured
/// (photographed): a golden badge with its icon; discovered: an orange badge with a
/// camera mark (photograph it to capture it); not discovered (debug "show all"): a grey "?".
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
        } else if pin.isDiscovered {
            subtitle = "Discovered – photograph it to capture it"
        } else {
            subtitle = "Not discovered yet"
        }
    }
}

final class SightAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "Sight"
    private let icon = UIImageView()
    /// The camera mark of discovered, not yet captured sights.
    private let cameraMark = UIImageView()
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
        cameraMark.image = UIImage(systemName: "camera.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        cameraMark.preferredSymbolConfiguration = .init(paletteColors: [.white, .systemOrange])
        cameraMark.frame = CGRect(x: Self.size - 11, y: -3, width: 14, height: 14)
        addSubview(cameraMark)
        // The entry (locked until captured).
        rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
        configure()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        guard let sight = annotation as? SightAnnotation else { return }
        let captured = sight.pin.isCaptured, discovered = sight.pin.isDiscovered
        backgroundColor = captured ? .captureGold : discovered ? .systemOrange : UIColor.systemGray.withAlphaComponent(0.75)
        let symbol = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        icon.image = UIImage(systemName: discovered ? sight.pin.sight.category.symbol : "questionmark", withConfiguration: symbol)
        cameraMark.isHidden = !discovered || captured
        displayPriority = discovered ? .required : .defaultLow
        zPriority = discovered ? .max : .defaultUnselected
    }
}

/// Keeps the sight annotations of a map in step with the pins; sights discovered
/// while the map is shown are revealed with an animation.
@MainActor
final class SightAnnotationController {
    private var shown: [String: SightAnnotation] = [:]
    private var focusID: Int?
    /// Discovered sights known to the map (`nil` before the first update).
    private var knownDiscovered: Set<String>?
    /// Newly discovered sights whose badge has not appeared yet.
    private var revealing: Set<String> = []

    func update(_ pins: [SightPin], on map: MKMapView) {
        let discovered = Set(pins.filter(\.isDiscovered).map(\.id))
        if let knownDiscovered {
            revealing.formUnion(discovered.subtracting(knownDiscovered))
        }
        knownDiscovered = discovered
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

    /// Centres the map on a sight or station once per request and opens a sight's callout.
    func focus(_ focus: SightFocus?, on map: MKMapView) {
        guard let focus, focus.id != focusID else { return }
        focusID = focus.id
        let coordinate = CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude)
        map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800), animated: true)
        if let annotation = shown[focus.placeID] {
            map.selectAnnotation(annotation, animated: true)
        }
    }
}

extension SightAnnotationController {
    /// Plays the reveal for badges of newly captured sights as MapKit adds their views
    /// (now, or when they scroll into view): the badge springs up, rings pulse out.
    func reveal(_ views: [MKAnnotationView]) {
        for view in views {
            guard let sight = view.annotation as? SightAnnotation, revealing.remove(sight.pin.id) != nil else { continue }
            view.transform = CGAffineTransform(scaleX: 0.05, y: 0.05)
            UIView.animate(withDuration: 0.8, delay: 0.15, usingSpringWithDamping: 0.45, initialSpringVelocity: 0.8) {
                view.transform = .identity
            }
            for index in 0..<3 {
                let ring = CAShapeLayer()
                let size = view.bounds.size
                ring.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).cgPath
                ring.bounds = CGRect(origin: .zero, size: size)
                ring.position = CGPoint(x: size.width / 2, y: size.height / 2)
                ring.fillColor = UIColor.clear.cgColor
                ring.strokeColor = UIColor.orange.cgColor
                ring.lineWidth = 3
                ring.opacity = 0
                view.layer.insertSublayer(ring, at: 0)
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1
                scale.toValue = 4
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = 1.4
                group.beginTime = CACurrentMediaTime() + 0.3 + Double(index) * 0.45
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.fillMode = .backwards
                ring.add(group, forKey: "pulse")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(index) * 0.45 + 1.5) {
                    ring.removeFromSuperlayer()
                }
            }
        }
    }
}
