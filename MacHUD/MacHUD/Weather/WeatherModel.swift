import Foundation

/// Backdrop style for the weather screen.
enum WeatherTheme: Equatable {
    case clearDay, clearNight, cloudy, rain, snow, storm, fog
}

/// Small summary drawn on the dashboard.
struct WeatherChip: Equatable {
    var symbol: String
    var temperature: Int
}

/// Everything the weather screen shows.
struct WeatherCard: Equatable {
    var symbol: String
    var temperature: Int
    var feelsLike: Int
    var high: Int
    var low: Int
    var condition: String
    var place: String
    var theme: WeatherTheme
}

struct WeatherSnapshot: Equatable {
    var temperature: Int
    var feelsLike: Int
    var high: Int
    var low: Int
    var code: Int
    var isDay: Bool
    var place: String = ""
    var fetched: Date = Date()

    private var description: WeatherCondition.Description { WeatherCondition.describe(code: code, isDay: isDay) }
    var chip: WeatherChip { WeatherChip(symbol: description.symbol, temperature: temperature) }
    var card: WeatherCard {
        let d = description
        return WeatherCard(symbol: d.symbol, temperature: temperature, feelsLike: feelsLike, high: high,
                           low: low, condition: d.text, place: place, theme: d.theme)
    }
}

/// WMO weather interpretation codes, as used by Open-Meteo.
enum WeatherCondition {
    struct Description {
        var symbol: String   // SF Symbol name
        var text: String
        var theme: WeatherTheme
    }

    static func describe(code: Int, isDay: Bool) -> Description {
        let clear: WeatherTheme = isDay ? .clearDay : .clearNight
        switch code {
        case 0: return .init(symbol: isDay ? "sun.max.fill" : "moon.stars.fill", text: "Clear", theme: clear)
        case 1: return .init(symbol: isDay ? "sun.max.fill" : "moon.stars.fill", text: "Mostly Clear", theme: clear)
        case 2: return .init(symbol: isDay ? "cloud.sun.fill" : "cloud.moon.fill", text: "Partly Cloudy", theme: clear)
        case 3: return .init(symbol: "cloud.fill", text: "Overcast", theme: .cloudy)
        case 45, 48: return .init(symbol: "cloud.fog.fill", text: "Fog", theme: .fog)
        case 51, 53, 55: return .init(symbol: "cloud.drizzle.fill", text: "Drizzle", theme: .rain)
        case 56, 57: return .init(symbol: "cloud.sleet.fill", text: "Freezing Drizzle", theme: .rain)
        case 61, 63: return .init(symbol: "cloud.rain.fill", text: "Rain", theme: .rain)
        case 65: return .init(symbol: "cloud.heavyrain.fill", text: "Heavy Rain", theme: .rain)
        case 66, 67: return .init(symbol: "cloud.sleet.fill", text: "Freezing Rain", theme: .rain)
        case 71, 73, 75, 77: return .init(symbol: "cloud.snow.fill", text: "Snow", theme: .snow)
        case 80, 81: return .init(symbol: "cloud.rain.fill", text: "Showers", theme: .rain)
        case 82: return .init(symbol: "cloud.heavyrain.fill", text: "Heavy Showers", theme: .rain)
        case 85, 86: return .init(symbol: "cloud.snow.fill", text: "Snow Showers", theme: .snow)
        case 95: return .init(symbol: "cloud.bolt.rain.fill", text: "Thunderstorm", theme: .storm)
        case 96, 99: return .init(symbol: "cloud.bolt.rain.fill", text: "Thunderstorm, Hail", theme: .storm)
        default: return .init(symbol: "cloud.fill", text: "Cloudy", theme: .cloudy)
        }
    }
}

/// Open-Meteo client (https://open-meteo.com, free, no API key).
enum OpenMeteo {
    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }

    enum Failure: Error { case badURL, noData }

    /// Coordinates are rounded to 0.1° (about 11 km) before they leave the Mac. That is plenty
    /// for weather and keeps the exact location private.
    static func fetch(latitude: Double, longitude: Double, fahrenheit: Bool,
                      session: URLSession = .shared) async throws -> WeatherSnapshot {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { throw Failure.badURL }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noData }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let hi = r.daily.temperature_2m_max.first, let lo = r.daily.temperature_2m_min.first
        else { throw Failure.noData }
        return WeatherSnapshot(temperature: Int(r.current.temperature_2m.rounded()),
                               feelsLike: Int(r.current.apparent_temperature.rounded()),
                               high: Int(hi.rounded()), low: Int(lo.rounded()),
                               code: r.current.weather_code, isDay: r.current.is_day == 1)
    }
}
