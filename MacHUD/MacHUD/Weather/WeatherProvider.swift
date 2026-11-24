import AppKit
import CoreLocation
import MapKit

/// Gets the Mac's (coarse) location from macOS and keeps a current Open-Meteo forecast.
@MainActor
final class WeatherProvider: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case locating
        case needsPermission
        case denied
        case ok(place: String, temperature: Int)
        case error(String)
    }

    private(set) var status: Status = .locating
    /// The latest forecast, or nil if there is none or it is older than `maxAge`.
    var current: WeatherSnapshot? {
        guard let snapshot, Date().timeIntervalSince(snapshot.fetched) < maxAge else { return nil }
        return snapshot
    }
    var onChange: (() -> Void)?

    private var snapshot: WeatherSnapshot?
    private let manager = CLLocationManager()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var placeCache: (key: String, name: String)?
    private var fetching = false

    private let refreshInterval: TimeInterval = 15 * 60
    private let maxAge: TimeInterval = 3 * 3600
    private var fahrenheit: Bool { Locale.current.measurementSystem == .us }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // weather needs no more

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Network and location usually need a few seconds after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        handleAuthorization()
    }

    /// Shows the macOS location prompt (if it hasn't been answered yet).
    func requestAccess() {
        if manager.authorizationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)   // menu bar apps need to be active to show the prompt
            manager.requestWhenInUseAuthorization()
        } else {
            handleAuthorization()
        }
    }

    func refresh() {
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized
        else { return handleAuthorization() }
        manager.requestLocation()
    }

    // MARK: - Authorization

    private func handleAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            set(.needsPermission)
            requestAccess()
        case .denied, .restricted:
            set(.denied)
        default:
            if snapshot == nil { set(.locating) }
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.handleAuthorization() }
    }

    // MARK: - Location -> forecast

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await self.update(for: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = (error as NSError).code == CLError.denied.rawValue ? nil : error.localizedDescription
        Task { @MainActor in
            if message == nil { self.set(.denied) }
            else if self.snapshot == nil { self.set(.error(message ?? "Location unavailable")) }
        }
    }

    private func update(for location: CLLocation) async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        do {
            async let place = placeName(for: location)
            var result = try await OpenMeteo.fetch(latitude: location.coordinate.latitude,
                                                    longitude: location.coordinate.longitude,
                                                    fahrenheit: fahrenheit)
            result.place = await place
            snapshot = result
            set(.ok(place: result.place, temperature: result.temperature))
        } catch {
            if snapshot == nil { set(.error("Weather unavailable")) }
        }
    }

    /// City name via Apple's geocoder. Cached per ~11 km cell so it isn't looked up every refresh.
    private func placeName(for location: CLLocation) async -> String {
        let key = String(format: "%.1f,%.1f", location.coordinate.latitude, location.coordinate.longitude)
        if let placeCache, placeCache.key == key { return placeCache.name }
        let name = await Self.reverseGeocode(location)
        if !name.isEmpty { placeCache = (key, name) }
        return name
    }

    /// MapKit's geocoder on macOS 26+, Core Location's (deprecated there) on older systems.
    private static func reverseGeocode(_ location: CLLocation) async -> String {
        if #available(macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else { return "" }
            let items = try? await request.mapItems
            return items?.first?.addressRepresentations?.cityName ?? ""
        }
        return await legacyReverseGeocode(location)
    }

    @available(macOS, deprecated: 26.0, message: "Fallback for macOS < 26")
    private static func legacyReverseGeocode(_ location: CLLocation) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        return marks?.first?.locality ?? marks?.first?.administrativeArea ?? ""
    }

    private func set(_ new: Status) {
        status = new
        onChange?()
    }
}
