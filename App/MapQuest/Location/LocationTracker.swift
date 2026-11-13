import Combine
import CoreLocation
import Foundation
import MapQuestCore

/// Wraps `CLLocationManager`: asks for permission, delivers continuous position
/// updates (also in the background) and publishes the authorisation state.
///
/// The tracker does not decide what is stored – it forwards every fix to
/// `onLocations`; the `LocationRecorder` keeps only fixes that reveal new area.
///
/// Energy: while the phone moves, or while the app is open, positions come from
/// GPS at full accuracy, about once a second. Once the phone has stayed put for a
/// few minutes with the app in the background (at home, at a desk:
/// `StillnessDetector`), the tracker switches to coarse positions (Wi-Fi and cell,
/// no GPS) that arrive only after moving `lowPowerDistance`; the first move away
/// switches GPS back on. Views get `lastLocation` at most every few metres or seconds, never in
/// the background; `currentLocation` is always the latest fix.
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    /// The position for views: updated after moving `publishDistance` or after
    /// `publishInterval`, not in the background (so views are not redrawn every second).
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var isTracking = false
    @Published private(set) var lastErrorMessage: String?

    /// The latest fix (not published): for decisions made now, such as whether the camera may open.
    private(set) var currentLocation: CLLocation?

    /// Receives every position update, on the main thread.
    var onLocations: (([CLLocation]) -> Void)?

    private let manager: CLLocationManager
    private let defaults: UserDefaults
    private static let trackingEnabledKey = "LocationTracker.trackingEnabled"

    static let publishDistance: CLLocationDistance = 5
    static let publishInterval: TimeInterval = 15
    /// In low power, fixes arrive after moving this far (coarse positions jitter less than this).
    static let lowPowerDistance: CLLocationDistance = 40

    /// Whether the phone has stayed put long enough to switch GPS off (`StillnessDetector`).
    private var stillness = StillnessDetector()
    private var power = StillnessDetector.Power.full

    /// The app is in the background: views are not updated, and the phone may go to low power when still.
    var isInBackground = false {
        didSet {
            guard isInBackground != oldValue else { return }
            apply(stillness.setInBackground(isInBackground, now: Date()))
            if !isInBackground, let currentLocation, currentLocation !== lastLocation { lastLocation = currentLocation }
        }
    }

    /// Whether the data source shown records positions; when it does not (another
    /// user's data, the demo), GPS stays off.
    var isRecordingAllowed = true {
        didSet {
            guard isRecordingAllowed != oldValue else { return }
            if isRecordingAllowed { startIfAuthorized() } else { stop() }
        }
    }

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
        guard isAuthorized, isTrackingEnabled, isRecordingAllowed, !isTracking else { return }
        // Requires the `location` background mode (Info.plist).
        manager.allowsBackgroundLocationUpdates = true
        stillness.reset()
        apply(.full)
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
        guard let latest = locations.last else { return }
        currentLocation = latest
        if lastErrorMessage != nil { lastErrorMessage = nil }
        if !isInBackground, shouldPublish(latest) { lastLocation = latest }
        for location in locations {
            let coordinate = GeoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            apply(stillness.update(coordinate, accuracy: location.horizontalAccuracy, timestamp: location.timestamp))
        }
        onLocations?(locations)
    }

    // MARK: Energy

    private func shouldPublish(_ location: CLLocation) -> Bool {
        guard let shown = lastLocation else { return true }
        return location.distance(from: shown) >= Self.publishDistance
            || location.timestamp.timeIntervalSince(shown.timestamp) >= Self.publishInterval
            || (location.horizontalAccuracy >= 0 && location.horizontalAccuracy < shown.horizontalAccuracy / 2)
    }

    /// Full: GPS, every fix. Low: no GPS – Wi-Fi and cell positions, delivered only after moving.
    private func apply(_ newPower: StillnessDetector.Power) {
        guard newPower != power else { return }
        power = newPower
        switch newPower {
        case .full:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
        case .low:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = Self.lowPowerDistance
        }
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
