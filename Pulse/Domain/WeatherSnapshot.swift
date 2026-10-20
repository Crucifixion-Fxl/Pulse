import Foundation

struct WeatherSnapshot: Codable, Equatable, Sendable {
  let city: String
  let temperature: Double
  let high: Double
  let low: Double
  let code: Int
  let isDay: Bool
  let observedAt: Date
  let fetchedAt: Date

  var temperatureText: String { "\(Int(temperature.rounded()))°" }

  var symbol: String {
    switch code {
    case 0, 1: isDay ? "sun.max.fill" : "moon.stars.fill"
    case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
    case 3: "cloud.fill"
    case 45, 48: "cloud.fog.fill"
    case 51...57: "cloud.drizzle.fill"
    case 61...67, 80...82: "cloud.rain.fill"
    case 71...77, 85, 86: "cloud.snow.fill"
    case 95...99: "cloud.bolt.rain.fill"
    default: "cloud.fill"
    }
  }

  var conditionKey: String {
    switch code {
    case 0, 1: "weather.clear"
    case 2: "weather.partly-cloudy"
    case 3: "weather.overcast"
    case 45, 48: "weather.fog"
    case 51...57: "weather.drizzle"
    case 61...67, 80...82: "weather.rain"
    case 71...77, 85, 86: "weather.snow"
    case 95...99: "weather.thunderstorm"
    default: "weather.unknown"
    }
  }
}

enum WeatherIssue: Error, Equatable {
  case locationDenied, locationUnavailable, network

  var messageKey: String {
    switch self {
    case .locationDenied: "weather.location-denied"
    case .locationUnavailable: "weather.location-unavailable"
    case .network: "weather.unavailable"
    }
  }
}

/// City-scale coordinates, never the precise device fix, go to the API.
struct WeatherCoordinates: Equatable, Sendable {
  let latitude: Double
  let longitude: Double

  init(latitude: Double, longitude: Double) {
    self.latitude = (latitude * 10).rounded() / 10
    self.longitude = (longitude * 10).rounded() / 10
  }
}
