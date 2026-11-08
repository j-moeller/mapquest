import MapKit
import MapQuestCore
import SwiftUI

/// The 2D map: a label-free base map with the fog of war drawn into it
/// (`FogMapRenderer`, part of MapKit's own rendering, so it moves exactly with the
/// map), the outlines of the cities, and city and district names above the fog.
struct FogMapView: UIViewRepresentable {
    var snapshot: DiscoveredAreaSnapshot
    /// What the snapshot shows (layer, or layer and period); partial redraws only within one identity.
    var identity: String
    /// Increments whenever `snapshot` changes.
    var version: Int
    var changedTiles: Set<TileKey>?
    /// Fog of war, or a heatmap of `heatPoints`.
    var aggregate: MapAggregate = .fog
    var heatPoints = HeatPoints()
    /// The cities with bundled 3D data (outlined and named, with their districts).
    var cities: [PlayArea]
    /// Opacity, blur and edge softness of the fog over undiscovered areas.
    var fogStyle = FogStyle.default
    var baseMap = BaseMapStyle.streets
    /// Called with the coordinate of a long press (debug: place a test position); `nil` disables it.
    var onLongPress: ((GeoCoordinate) -> Void)?

    static let berlin = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050),
        latitudinalMeters: 12_000, longitudinalMeters: 12_000
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(content: FogMapRenderer.Content(tiles: BaseMapTiles.shared(baseMap), snapshot: snapshot, style: fogStyle))
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.showsBuildings = false
        map.showsTraffic = false
        // MapKit's own compass sits top right, behind the debug button: our own one goes below the tracking button.
        map.showsCompass = false
        map.showsScale = true
        // The 3D mode shows the city in perspective.
        map.isPitchEnabled = false
        map.setRegion(Self.berlin, animated: false)
        map.register(MapLabelView.self, forAnnotationViewWithReuseIdentifier: MapLabelView.reuseIdentifier)

        // Apple's map is replaced by a dark ground; the base map and the fog lie on it.
        map.addOverlay(GroundTileOverlay(color: UIColor(white: 0.1, alpha: 1)), level: .aboveLabels)
        map.addOverlay(context.coordinator.fogOverlay, level: .aboveLabels)

        // The heatmap view lies directly above the map content.
        let heat = context.coordinator.heatView
        heat.frame = map.bounds
        heat.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        heat.map = map
        if let content = map.subviews.first {
            map.insertSubview(heat, aboveSubview: content)
        } else {
            map.addSubview(heat)
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
        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive
        compass.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(compass)
        NSLayoutConstraint.activate([
            compass.centerXAnchor.constraint(equalTo: trackingButton.centerXAnchor),
            compass.topAnchor.constraint(equalTo: trackingButton.bottomAnchor, constant: 10),
        ])
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        map.addGestureRecognizer(press)
        context.coordinator.map = map
        context.coordinator.updateCities(cities, on: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLongPress = onLongPress
        coordinator.update(style: fogStyle, baseMap: baseMap)
        coordinator.update(
            snapshot: snapshot, identity: identity, version: version, changedTiles: changedTiles,
            showsFog: aggregate == .fog
        )
        coordinator.heatView.setActive(aggregate == .heatmap)
        if aggregate == .heatmap {
            coordinator.heatView.setHeatPoints(heatPoints.points, version: heatPoints.version)
        }
        coordinator.updateCities(cities, on: map)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let fogOverlay = FogMapOverlay()
        let heatView = HeatmapLayerView(frame: .zero)
        /// What the fog renderer shows (kept here as well: MapKit creates the renderer lazily).
        private var content: FogMapRenderer.Content
        private var renderer: FogMapRenderer?
        private var drawnVersion = -1
        private var drawnIdentity: String?
        private var showsFog = true
        private var cityNames: [String]?
        private var outlines: [MKPolyline] = []
        private var labels: [MapLabelAnnotation] = []
        weak var map: MKMapView?
        var onLongPress: ((GeoCoordinate) -> Void)?
        private var hasCenteredOnUser = false

        init(content: FogMapRenderer.Content) {
            self.content = content
            super.init()
        }

        // MARK: Map delegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let ground = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: ground)
            }
            if let fog = overlay as? FogMapOverlay {
                let renderer = FogMapRenderer(overlay: fog, content: content)
                self.renderer = renderer
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.9)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [6, 4]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MapLabelAnnotation else { return nil }
            return mapView.dequeueReusableAnnotationView(withIdentifier: MapLabelView.reuseIdentifier, for: annotation)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            heatView.sync()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            heatView.sync()
            updateLabelVisibility(on: mapView)
        }

        /// Zooms to the user once, at the first position fix.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            heatView.sync()
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

        // MARK: Inputs

        func update(style: FogStyle, baseMap: BaseMapStyle) {
            if style != content.style {
                content.style = style
                renderer?.setStyle(style)
            }
            if baseMap != content.tiles.style {
                content.tiles = BaseMapTiles.shared(baseMap)
                renderer?.setTiles(content.tiles)
            }
        }

        func update(snapshot: DiscoveredAreaSnapshot, identity: String, version: Int, changedTiles: Set<TileKey>?, showsFog: Bool) {
            let modeChanged = showsFog != self.showsFog
            guard version != drawnVersion || identity != drawnIdentity || modeChanged else { return }
            // Only the next version of the same layer (and period) may be redrawn partially.
            let partial = version == drawnVersion + 1 && identity == drawnIdentity && !modeChanged ? changedTiles : nil
            drawnVersion = version
            drawnIdentity = identity
            self.showsFog = showsFog
            content.snapshot = showsFog ? snapshot : nil
            renderer?.setSnapshot(content.snapshot, changedTiles: partial)
        }

        /// Outlines and name labels of the cities (once per set of cities).
        func updateCities(_ cities: [PlayArea], on map: MKMapView) {
            let names = cities.map(\.name)
            guard names != cityNames else { return }
            cityNames = names
            map.removeOverlays(outlines)
            outlines = cities.flatMap(\.polygons).map { polygon in
                let s = MapPointConversion.worldUnitsPerMapPoint
                let points = polygon.exterior.map { MKMapPoint(x: Double($0.x) / s, y: Double($0.y) / s) }
                return MKPolyline(points: points, count: points.count)
            }
            map.addOverlays(outlines, level: .aboveLabels)
            Task { [weak self, weak map] in
                let labels = await MapLabelAnnotation.make(for: cities)
                guard let self, let map, self.cityNames == names else { return }
                map.removeAnnotations(self.labels)
                self.labels = labels
                self.updateLabelVisibility(on: map)
            }
        }

        /// City names from afar, district names closer in.
        private func updateLabelVisibility(on map: MKMapView) {
            let latitude = map.region.center.latitude
            let width = map.visibleMapRect.size.width / MKMapPointsPerMeterAtLatitude(latitude)
            let shown = Set(map.annotations.compactMap { $0 as? MapLabelAnnotation })
            let wanted = labels.filter { $0.isVisible(atWidth: width) }
            let remove = shown.filter { label in !wanted.contains { $0 === label } }
            let add = wanted.filter { !shown.contains($0) }
            if !remove.isEmpty { map.removeAnnotations(Array(remove)) }
            if !add.isEmpty { map.addAnnotations(add) }
        }
    }
}
