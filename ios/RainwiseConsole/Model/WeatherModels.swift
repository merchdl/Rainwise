import Foundation

/// Live conditions as served by the collector's `/api/current` and `/api/stream`.
/// All values are US units (°F, inHg, mph, in); convert with `Quantity` for display.
struct CurrentConditions: Decodable, Equatable {
    var time: Double
    var updated: Double?
    var online: Bool
    var error: String?
    var station: Station
    var outside: Outside
    var inside: Inside
    var pressure: Pressure
    var wind: Wind
    var rain: Rain
    var today: [String: Extreme]
    var timezone: String?

    struct Station: Decodable, Equatable {
        var signalOk: Bool
        var rssi: Double?
        var signalQuality: Double?
        var battery: Double?
    }

    struct Outside: Decodable, Equatable {
        var temperature: Double?
        var humidity: Double?
        var dewPoint: Double?
        var windChill: Double?
        var thi: Double?
        var solar: Double?
    }

    struct Inside: Decodable, Equatable {
        var temperature: Double?
    }

    struct Pressure: Decodable, Equatable {
        var value: Double?
        var trend: String  // "rise" | "fall" | "steady"
    }

    struct Wind: Decodable, Equatable {
        var speed: Double?
        var direction: Double?
        var sector: Int?
        var gust: Double?
        var gustDirection: Double?
        var recent: [Trail]

        struct Trail: Decodable, Equatable {
            var sector: Int
            var weight: Double
        }
    }

    struct Rain: Decodable, Equatable {
        var hour: Double?
        var day: Double?
        var month: Double?
        var year: Double?
    }

    struct Extreme: Decodable, Equatable {
        var min: Double
        var minTime: Double
        var max: Double
        var maxTime: Double
    }

    var updatedDate: Date? { updated.map { Date(timeIntervalSince1970: $0) } }

    /// True when the numbers can be trusted: collector reachable and the
    /// IP-100 actually hearing the station.
    var isLive: Bool { online && station.signalOk }
}

/// `/api/history` response.
struct HistorySeries: Decodable, Equatable {
    var metric: String
    var range: String
    var start: Double
    var end: Double
    var bucket: Double
    var points: [Point]
    var min: Point?
    var max: Point?

    struct Point: Decodable, Equatable, Hashable, Identifiable {
        var t: Double
        var v: Double
        var id: Double { t }
        var date: Date { Date(timeIntervalSince1970: t) }
    }

    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date { Date(timeIntervalSince1970: end) }
}

extension JSONDecoder {
    static let collector: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
