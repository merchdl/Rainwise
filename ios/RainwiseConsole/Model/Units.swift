import Foundation

enum UnitSystem: String, Codable, CaseIterable, Identifiable {
    case us, metric
    var id: Self { self }
    var title: String { self == .us ? "US (°F, inHg, mph, in)" : "Metric (°C, hPa, km/h, mm)" }
}

/// A physical quantity. Converts from the collector's US units for display.
enum Quantity {
    case temperature, humidity, pressure, rain, speed

    func convert(_ v: Double, _ u: UnitSystem) -> Double {
        guard u == .metric else { return v }
        switch self {
        case .temperature: return (v - 32) * 5 / 9
        case .pressure: return v * 33.8639
        case .rain: return v * 25.4
        case .speed: return v * 1.609344
        case .humidity: return v
        }
    }

    func convert(_ v: Double?, _ u: UnitSystem) -> Double? {
        v.map { convert($0, u) }
    }

    func symbol(_ u: UnitSystem) -> String {
        switch self {
        case .temperature: return u == .us ? "°F" : "°C"
        case .humidity: return "%"
        case .pressure: return u == .us ? "inHg" : "hPa"
        case .rain: return u == .us ? "in" : "mm"
        case .speed: return u == .us ? "mph" : "km/h"
        }
    }

    /// Decimals used on graph labels.
    func decimals(_ u: UnitSystem) -> Int {
        switch self {
        case .temperature: return 1
        case .humidity: return 0
        case .pressure: return u == .us ? 2 : 1
        case .rain: return u == .us ? 2 : 1
        case .speed: return 0
        }
    }

    /// Smallest y-axis span so a flat line doesn't look dramatic.
    func minimumSpan(_ u: UnitSystem) -> Double {
        switch self {
        case .temperature: return u == .us ? 5 : 3
        case .humidity: return 10
        case .pressure: return u == .us ? 0.1 : 3
        case .rain: return u == .us ? 0.1 : 2.5
        case .speed: return 5
        }
    }

    var floorsAtZero: Bool { self == .rain || self == .speed || self == .humidity }
}

/// The graph's metric buttons.
enum ChartMetric: String, CaseIterable, Identifiable, Codable {
    case humidity
    case pressure
    case rain
    case windSpeed = "wind_speed"
    case temperature
    case windChill = "wind_chill"
    case dewPoint = "dew_point"

    var id: Self { self }

    var title: String {
        switch self {
        case .humidity: return "Humidity"
        case .pressure: return "Pressure"
        case .rain: return "Rain"
        case .windSpeed: return "Wind Speed"
        case .temperature: return "Temperature"
        case .windChill: return "Wind Chill"
        case .dewPoint: return "Dew Point"
        }
    }

    var quantity: Quantity {
        switch self {
        case .humidity: return .humidity
        case .pressure: return .pressure
        case .rain: return .rain
        case .windSpeed: return .speed
        case .temperature, .windChill, .dewPoint: return .temperature
        }
    }
}

enum ChartRange: String, CaseIterable, Identifiable, Codable {
    case week
    case hours48 = "48h"
    case today

    var id: Self { self }

    var title: String {
        switch self {
        case .week: return "Week"
        case .hours48: return "48 Hours"
        case .today: return "Today"
        }
    }

    /// Days before today the graph starts (matches the collector).
    var daysBack: Int {
        switch self {
        case .today: return 0
        case .hours48: return 1
        case .week: return 6
        }
    }
}

extension Double {
    func formatted(decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", self)
        if s.hasPrefix("-"), Double(s) == 0 { s.removeFirst() }  // no "-0"
        return s
    }
}
