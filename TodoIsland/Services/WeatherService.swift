import CoreLocation
import Foundation

struct WeatherService: Sendable {
  var session: URLSession = .shared

  static func request(for location: WeatherCoordinates) -> URLRequest {
    var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    url.queryItems = [
      URLQueryItem(name: "latitude", value: String(location.latitude)),
      URLQueryItem(name: "longitude", value: String(location.longitude)),
      URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
      URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
      URLQueryItem(name: "timezone", value: "auto"),
      URLQueryItem(name: "forecast_days", value: "1"),
      URLQueryItem(name: "timeformat", value: "unixtime")
    ]
    return URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
  }

  func fetch(location: WeatherCoordinates, city: String) async throws -> WeatherSnapshot {
    let (data, response) = try await session.data(for: Self.request(for: location))
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw WeatherIssue.network
    }
    return try Self.decode(data, city: city, now: Date())
  }

  static func decode(_ data: Data, city: String, now: Date) throws -> WeatherSnapshot {
    struct Response: Decodable {
      struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int
        let time: Double
      }
      struct Daily: Decodable {
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
      }
      let current: Current
      let daily: Daily
    }
    let payload = try JSONDecoder().decode(Response.self, from: data)
    let current = payload.current
    guard let high = payload.daily.temperature_2m_max.first,
      let low = payload.daily.temperature_2m_min.first,
      [current.temperature_2m, high, low].allSatisfy({ $0.isFinite && (-100...70).contains($0) }),
      high >= low, current.time.isFinite,
      abs(now.timeIntervalSince1970 - current.time) < 6 * 3600
    else { throw WeatherIssue.network }
    return WeatherSnapshot(city: city, temperature: current.temperature_2m, high: high, low: low,
      code: current.weather_code, isDay: current.is_day == 1,
      observedAt: Date(timeIntervalSince1970: current.time), fetchedAt: now)
  }
}

/// One location fix per refresh. No continuous tracking or stored coordinates.
@MainActor
final class WeatherLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var pending: CheckedContinuation<CLLocation, Error>?
  private var timeout: Task<Void, Never>?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
  }

  func locate() async throws -> (WeatherCoordinates, String) {
    let location: CLLocation = try await withCheckedThrowingContinuation { continuation in
      guard pending == nil else { continuation.resume(throwing: WeatherIssue.locationUnavailable); return }
      pending = continuation
      timeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(25))
        guard !Task.isCancelled else { return }
        self?.finish(.failure(WeatherIssue.locationUnavailable))
      }
      requestFix()
    }
    let coordinates = WeatherCoordinates(latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude)
    let coarseLocation = CLLocation(latitude: coordinates.latitude, longitude: coordinates.longitude)
    let places = try? await CLGeocoder().reverseGeocodeLocation(coarseLocation, preferredLocale: .current)
    let city = places?.first?.locality ?? places?.first?.administrativeArea ?? L10n.text("weather.current-location")
    return (coordinates, city)
  }

  private func requestFix() {
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
    case .denied, .restricted: finish(.failure(WeatherIssue.locationDenied))
    @unknown default: finish(.failure(WeatherIssue.locationUnavailable))
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard pending != nil, manager.authorizationStatus != .notDetermined else { return }
    requestFix()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let fix = locations.last, fix.horizontalAccuracy >= 0,
      abs(fix.timestamp.timeIntervalSinceNow) < 5 * 60 else {
      finish(.failure(WeatherIssue.locationUnavailable)); return
    }
    finish(.success(fix))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    finish(.failure((error as? CLError)?.code == .denied
      ? WeatherIssue.locationDenied : WeatherIssue.locationUnavailable))
  }

  private func finish(_ result: Result<CLLocation, Error>) {
    timeout?.cancel()
    timeout = nil
    manager.stopUpdatingLocation()
    let continuation = pending
    pending = nil
    continuation?.resume(with: result)
  }
}
