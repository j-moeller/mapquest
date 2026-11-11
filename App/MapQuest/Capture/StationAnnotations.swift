import MapKit
import MapQuestCore
import SwiftUI
import UIKit

/// The signs of the two systems, in the colours of the real ones: a white "U"
/// on a blue square (#0065AE), a white "S" on a green circle (#008D4F).
extension TransitSystem {
    var signColor: UIColor {
        switch self {
        case .ubahn: return UIColor(red: 0x00 / 255, green: 0x65 / 255, blue: 0xAE / 255, alpha: 1)
        case .sbahn: return UIColor(red: 0x00 / 255, green: 0x8D / 255, blue: 0x4F / 255, alpha: 1)
        }
    }
}

/// A station on the 2D map: smaller than the sights, always in its system's
/// colour – collected ones solid with a white rim, the others (debug "show
/// all") paler.
final class StationAnnotation: NSObject, MKAnnotation {
    let pin: StationPin
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(_ pin: StationPin) {
        self.pin = pin
        coordinate = CLLocationCoordinate2D(latitude: pin.station.latitude, longitude: pin.station.longitude)
        title = "\(pin.station.system.rawValue) \(pin.station.name)"
        let lines = pin.station.lines.joined(separator: " · ")
        if let date = pin.collectedAt {
            subtitle = "\(lines) – collected \(date.formatted(date: .abbreviated, time: .omitted))"
        } else {
            subtitle = "\(lines) – not collected yet"
        }
    }
}

final class StationAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "Station"
    private static let size: CGFloat = 17
    private let letter = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = true
        collisionMode = .circle
        bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.cgColor
        letter.font = .systemFont(ofSize: 12, weight: .heavy)
        letter.textColor = .white
        letter.textAlignment = .center
        letter.frame = bounds
        addSubview(letter)
        configure()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        guard let station = annotation as? StationAnnotation else { return }
        let system = station.pin.station.system
        letter.text = system.rawValue
        layer.cornerRadius = system == .sbahn ? Self.size / 2 : 3
        let collected = station.pin.isCollected
        backgroundColor = system.signColor
        alpha = collected ? 1 : 0.45
        // Below the sights: where they overlap, the sight wins.
        displayPriority = collected ? .defaultHigh : .defaultLow
        zPriority = .defaultUnselected
    }
}

/// Keeps the station annotations of a map in step with the pins.
@MainActor
final class StationAnnotationController {
    private var shown: [String: StationAnnotation] = [:]
    private var focusID: Int?

    func update(_ pins: [StationPin], on map: MKMapView) {
        let wanted = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var remove: [StationAnnotation] = []
        var add: [StationAnnotation] = []
        for (id, annotation) in shown where wanted[id] != annotation.pin {
            remove.append(annotation)
            shown[id] = nil
        }
        for (id, pin) in wanted where shown[id] == nil {
            let annotation = StationAnnotation(pin)
            shown[id] = annotation
            add.append(annotation)
        }
        if !remove.isEmpty { map.removeAnnotations(remove) }
        if !add.isEmpty { map.addAnnotations(add) }
    }

    /// Opens the callout of a focused station (the sight controller centres the map).
    func select(_ focus: SightFocus?, on map: MKMapView) {
        guard let focus, focus.id != focusID else { return }
        focusID = focus.id
        if let annotation = shown[focus.placeID] {
            map.selectAnnotation(annotation, animated: true)
        }
    }
}

/// A station's sign in lists and notices.
struct StationBadge: View {
    let system: TransitSystem
    var collected = true
    var size: CGFloat = 22

    var body: some View {
        Text(system.rawValue)
            .font(.system(size: size * 0.66, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Color(uiColor: system.signColor).opacity(collected ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: system == .sbahn ? size / 2 : size * 0.18)
            )
            .accessibilityHidden(true)
    }
}

/// Stations just collected, over the map: one with its lines, or how many.
struct StationToastView: View {
    let toast: StationToast

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(Array(toast.stations.prefix(3).enumerated()), id: \.offset) { _, station in
                    StationBadge(system: station.system, size: 22)
                        .overlay(RoundedRectangle(cornerRadius: station.system == .sbahn ? 11 : 4).stroke(Color.white, lineWidth: 1.5))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                if toast.stations.count == 1, let station = toast.stations.first {
                    Text("\(station.name) collected")
                        .font(.subheadline.weight(.semibold))
                    Text(station.lines.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(toast.stations.count) stations collected")
                        .font(.subheadline.weight(.semibold))
                    Text(toast.stations.prefix(3).map(\.name).joined(separator: ", ") + (toast.stations.count > 3 ? " …" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }
}
