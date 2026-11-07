import MapKit
import MapQuestCore
import SwiftUI

/// The 2D map: Apple Maps with the fog-of-war overlay and the play-area outline.
struct FogMapView: UIViewRepresentable {
    var snapshot: DiscoveredAreaSnapshot
    /// Increments whenever `snapshot` changes.
    var version: Int
    var changedTiles: Set<TileKey>?
    var playArea: PlayArea

    static let berlin = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050),
        latitudinalMeters: 12_000, longitudinalMeters: 12_000
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(snapshot: snapshot)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = true
        map.setRegion(Self.berlin, animated: false)
        // Above labels, so unexplored street names are darkened as well.
        map.addOverlay(context.coordinator.fogOverlay, level: .aboveLabels)

        let trackingButton = MKUserTrackingButton(mapView: map)
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        trackingButton.backgroundColor = .secondarySystemBackground
        trackingButton.layer.cornerRadius = 8
        trackingButton.clipsToBounds = true
        map.addSubview(trackingButton)
        NSLayoutConstraint.activate([
            trackingButton.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            trackingButton.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 64),
        ])
        context.coordinator.updatePlayArea(playArea, on: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(snapshot: snapshot, version: version, changedTiles: changedTiles)
        context.coordinator.updatePlayArea(playArea, on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let fogOverlay = FogOverlay()
        private(set) var fogRenderer: FogOverlayRenderer
        private var drawnVersion = -1
        private var drawnLayer: DiscoveryLayerID?
        private var boundaryOverlays: [MKPolyline] = []
        private var drawnPlayAreaName: String?

        init(snapshot: DiscoveredAreaSnapshot) {
            fogRenderer = FogOverlayRenderer(overlay: fogOverlay, snapshot: snapshot)
        }

        func update(snapshot: DiscoveredAreaSnapshot, version: Int, changedTiles: Set<TileKey>?) {
            guard version != drawnVersion || snapshot.layer != drawnLayer else { return }
            // Only consecutive versions of the same layer may be redrawn partially.
            let partial = version == drawnVersion + 1 && snapshot.layer == drawnLayer ? changedTiles : nil
            drawnVersion = version
            drawnLayer = snapshot.layer
            fogRenderer.update(snapshot: snapshot, changedTiles: partial)
        }

        func updatePlayArea(_ playArea: PlayArea, on map: MKMapView) {
            guard drawnPlayAreaName != playArea.name else { return }
            drawnPlayAreaName = playArea.name
            map.removeOverlays(boundaryOverlays)
            boundaryOverlays = playArea.polygons.map { polygon in
                var coordinates = polygon.exterior.map { point -> CLLocationCoordinate2D in
                    let c = WebMercator.unproject(point)
                    return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
                }
                if let first = coordinates.first { coordinates.append(first) }
                return MKPolyline(coordinates: coordinates, count: coordinates.count)
            }
            map.addOverlays(boundaryOverlays, level: .aboveLabels)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay === fogOverlay {
                return fogRenderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.9)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
