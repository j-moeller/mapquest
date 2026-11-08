import MapKit
import MapQuestCore
import SwiftUI

/// The 2D map: Apple Maps with the fog of war and the play-area outline on top
/// (`FogLayerView`, which moves with the map frame by frame).
struct FogMapView: UIViewRepresentable {
    var snapshot: DiscoveredAreaSnapshot
    /// Increments whenever `snapshot` changes.
    var version: Int
    var changedTiles: Set<TileKey>?
    var playArea: PlayArea
    /// Opacity of the fog over undiscovered areas (0…1).
    var fogOpacity: Double = 0.9
    /// Called with the coordinate of a long press (debug: place a test position); `nil` disables it.
    var onLongPress: ((GeoCoordinate) -> Void)?

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
        // The fog follows the map with an affine transform, which cannot express a
        // perspective camera; the 3D mode shows the city in perspective.
        map.isPitchEnabled = false
        map.setRegion(Self.berlin, animated: false)
        // Directly above the map content (tiles and labels, so unexplored street names
        // are darkened too), below MapKit's compass, scale and legal notice.
        let fog = context.coordinator.fogView
        fog.frame = map.bounds
        fog.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fog.map = map
        if let content = map.subviews.first {
            map.insertSubview(fog, aboveSubview: content)
        } else {
            map.addSubview(fog)
        }

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
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        map.addGestureRecognizer(press)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        context.coordinator.updateFog(opacity: fogOpacity)
        context.coordinator.update(snapshot: snapshot, version: version, changedTiles: changedTiles)
        context.coordinator.updatePlayArea(playArea, on: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let fogView = FogLayerView(frame: .zero)
        private var drawnVersion = -1
        private var drawnLayer: DiscoveryLayerID?
        private var drawnPlayAreaName: String?
        private var fogOpacity: Double = -1
        weak var map: MKMapView?
        var onLongPress: ((GeoCoordinate) -> Void)?
        private var hasCenteredOnUser = false

        /// The fog moves with the map in the same frame (no asynchronous tile rendering).
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            fogView.sync()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            fogView.sync()
        }

        /// Zooms to the user once, at the first position fix.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            fogView.sync()
            guard !hasCenteredOnUser, let location = userLocation.location, location.horizontalAccuracy >= 0 else { return }
            hasCenteredOnUser = true
            mapView.setRegion(
                MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500),
                animated: true
            )
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map, let onLongPress else { return }
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            onLongPress(GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        func updateFog(opacity: Double) {
            guard abs(fogOpacity - opacity) > 0.001 else { return }
            fogOpacity = opacity
            fogView.setFogOpacity(opacity)
        }

        init(snapshot: DiscoveredAreaSnapshot) {
            super.init()
            fogView.update(snapshot: snapshot, changedTiles: nil)
        }

        func update(snapshot: DiscoveredAreaSnapshot, version: Int, changedTiles: Set<TileKey>?) {
            guard version != drawnVersion || snapshot.layer != drawnLayer else { return }
            // Only consecutive versions of the same layer may be redrawn partially.
            let partial = version == drawnVersion + 1 && snapshot.layer == drawnLayer ? changedTiles : nil
            drawnVersion = version
            drawnLayer = snapshot.layer
            fogView.update(snapshot: snapshot, changedTiles: partial)
        }

        func updatePlayArea(_ playArea: PlayArea, on map: MKMapView) {
            guard drawnPlayAreaName != playArea.name else { return }
            drawnPlayAreaName = playArea.name
            fogView.setBoundary(playArea.polygons)
        }
    }
}
