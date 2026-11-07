import Combine
import CoreLocation
import Foundation
import MapQuestCore

/// Wraps `CLLocationManager`: asks for permission, delivers continuous position
/// updates (also in the background) and publishes the authorisation state.
///
/// The tracker does not decide what is stored – it forwards every fix to
/// `onLocations`; the `LocationRecorder` keeps only fixes that reveal new area.
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var isTracking = false
    @Published private(set) var lastErrorMessage: String?

    /// Receives every position update, on the main thread.
    var onLocations: (([CLLocation]) -> Void)?

    private let manager: CLLocationManager
    private let defaults: UserDefaults
    private static let trackingEnabledKey = "LocationTracker.trackingEnabled"

    /// Whether the user wants tracking to run (persisted).
    var isTrackingEnabled: Bool {
        get { defaults.object(forKey: Self.trackingEnabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.trackingEnabledKey)
            objectWillChange.send()
            if newValue {
                startIfAuthorized()
            } else {
                stop()
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        let manager = CLLocationManager()
        self.manager = manager
        self.defaults = defaults
        self.authorizationStatus = manager.authorizationStatus
        self.accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // No distance filter: climbing a tower changes only the altitude, which
        // matters for the line-of-sight layer. The recorder discards fixes that
        // reveal nothing new, so frequent updates cost no storage.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    // MARK: Permission

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var needsPermissionPrompt: Bool { authorizationStatus == .notDetermined }

    var isDenied: Bool { authorizationStatus == .denied || authorizationStatus == .restricted }

    /// First step: permission while the app is in use. Location updates that were
    /// started in the foreground continue in the background with this permission.
    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Upgrade to "Always", so tracking can resume after the app was terminated.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    // MARK: Tracking

    func startIfAuthorized() {
        guard isAuthorized, isTrackingEnabled, !isTracking else { return }
        // Requires the `location` background mode (Info.plist).
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        if authorizationStatus == .authorizedAlways {
            // Relaunches the app after termination when the user moves significantly.
            manager.startMonitoringSignificantLocationChanges()
        }
        isTracking = true
    }

    func stop() {
        guard isTracking else { return }
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if isAuthorized {
            startIfAuthorized()
        } else {
            stop()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
        lastErrorMessage = nil
        onLocations?(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown {
            return // transient; Core Location keeps trying
        }
        lastErrorMessage = error.localizedDescription
    }
}

extension LocationSample {
    /// Converts a Core Location fix into a storable sample.
    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            timestamp: location.timestamp
        )
    }
}
