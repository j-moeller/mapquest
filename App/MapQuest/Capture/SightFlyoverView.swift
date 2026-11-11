import MapKit
import MapQuestCore
import SwiftUI

/// A photorealistic 3D view of a sight: Apple's 3D city model (satellite imagery
/// on 3D buildings and terrain), looking at the sight from above at an angle.
/// Drag to move, pinch to zoom, rotate and tilt with two fingers – like the map.
/// Only used where Apple has photorealistic 3D coverage (`City.hasPhotorealistic3D`);
/// elsewhere the entry shows its photo.
struct SightFlyoverView: UIViewRepresentable {
    let sight: Sight

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        let center = CLLocationCoordinate2D(latitude: sight.latitude, longitude: sight.longitude)
        // Stay around the sight.
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 60, maxCenterCoordinateDistance: 4_000)
        map.cameraBoundary = MKMapView.CameraBoundary(
            coordinateRegion: MKCoordinateRegion(center: center, latitudinalMeters: 3_000, longitudinalMeters: 3_000)
        )
        map.camera = MKMapCamera(lookingAtCenter: center, fromDistance: max(280, sight.radius * 7), pitch: 60, heading: 25)
        let pin = MKPointAnnotation()
        pin.coordinate = center
        pin.title = sight.name
        map.addAnnotation(pin)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// An orange marker on the sight, without its title (the entry shows it).
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "sight")
            view.markerTintColor = .orange
            view.glyphImage = UIImage(systemName: "star.fill")
            view.titleVisibility = .hidden
            return view
        }
    }
}
