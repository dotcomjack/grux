import Foundation
import CoreLocation

// Sends significant-change location updates to the Mac while streaming is
// active. Requests "always" authorization if the user opts in so background
// streaming can keep tagging frames; falls back to when-in-use otherwise.
// Zero recovery logic, if location is denied, we simply skip location
// frames. Audio streaming is independent.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var lastUpdate: Date = .distantPast

    private let manager = CLLocationManager()

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false  // opt-in later
        authorization = manager.authorizationStatus
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async { self.authorization = status }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.authorization = manager.authorizationStatus }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async { self.lastUpdate = Date() }
        let payload = LocationPayload(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            unixSeconds: loc.timestamp.timeIntervalSince1970
        )
        Task { @MainActor in TransportService.shared.sendLocation(payload) }
    }
}
