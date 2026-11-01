import Foundation

/// Synthetic data so the app is usable before a collector is set up.
struct DemoSource: WeatherSource {

    struct Reading {
        var outTemp, inTemp, humidity, pressure, wind, direction, gust, rainDay: Double
    }

    static func reading(at date: Date) -> Reading {
        let ts = date.timeIntervalSince1970
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: date)
        let hour = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        let day = ts / 86400
        let diurnal = sin((hour - 9) / 24 * 2 * .pi)
        let jitter = sin(ts / 37) * 0.3
        let wind = max(0, 6 + 5 * sin(day * 2.1) + 2 * sin(ts / 23))
        let direction = (270 + 40 * sin(day * 1.3) + 15 * sin(ts / 61)).truncatingRemainder(dividingBy: 360)
        let rainRate = max(0, sin(day * 0.9) - 0.85) * 0.2
        return Reading(
            outTemp: 8 + 10 * diurnal + 6 * sin(day / 3) + jitter,
            inTemp: 69 + sin(ts / 300) * 0.4,
            humidity: min(100, max(15, 70 - 20 * diurnal)),
            pressure: 29.9 + 0.25 * sin(day * 0.7),
            wind: wind.rounded(),
            direction: direction < 0 ? direction + 360 : direction,
            gust: (wind + 3 + 2 * sin(ts / 7)).rounded(),
            rainDay: (rainRate * hour * 100).rounded() / 100
        )
    }

    private static func dewPoint(_ f: Double, _ rh: Double) -> Double {
        let t = (f - 32) * 5 / 9
        let g = log(rh / 100) + 17.625 * t / (243.04 + t)
        return (243.04 * g / (17.625 - g)) * 9 / 5 + 32
    }

    private static func windChill(_ f: Double, _ mph: Double) -> Double {
        guard f <= 50, mph >= 3 else { return f }
        let v = pow(mph, 0.16)
        return 35.74 + 0.6215 * f - 35.75 * v + 0.4275 * f * v
    }

    static func conditions(at date: Date) -> CurrentConditions {
        let r = reading(at: date)
        let ts = date.timeIntervalSince1970
        let sector = Int(((r.direction + 11.25) / 22.5)) % 16
        let midnight = Calendar.current.startOfDay(for: date)
        var today: [String: CurrentConditions.Extreme] = [:]
        // Sample the day so far for MAX/MIN.
        let samples = stride(from: midnight.timeIntervalSince1970, through: ts, by: 900).map {
            reading(at: Date(timeIntervalSince1970: $0))
        }
        func ext(_ key: String, _ f: (Reading) -> Double) {
            let pairs = samples.enumerated().map { (midnight.timeIntervalSince1970 + Double($0.offset) * 900, f($0.element)) }
            guard let lo = pairs.min(by: { $0.1 < $1.1 }), let hi = pairs.max(by: { $0.1 < $1.1 }) else { return }
            today[key] = .init(min: lo.1, minTime: lo.0, max: hi.1, maxTime: hi.0)
        }
        ext("temperature") { $0.outTemp }
        ext("inside_temperature") { $0.inTemp }
        ext("humidity") { $0.humidity }
        ext("pressure") { $0.pressure }
        ext("wind_speed") { $0.wind }
        ext("gust") { $0.gust }
        ext("wind_chill") { windChill($0.outTemp, $0.wind) }
        ext("dew_point") { dewPoint($0.outTemp, $0.humidity) }
        ext("thi") { $0.outTemp }
        let earlier = reading(at: date.addingTimeInterval(-3 * 3600)).pressure
        let trend = r.pressure - earlier > 0.02 ? "rise" : (r.pressure - earlier < -0.02 ? "fall" : "steady")
        return CurrentConditions(
            time: ts, updated: ts, online: true, error: nil,
            station: .init(signalOk: true, rssi: -78, signalQuality: 100, battery: 6.3),
            outside: .init(temperature: r.outTemp, humidity: r.humidity,
                           dewPoint: dewPoint(r.outTemp, r.humidity),
                           windChill: windChill(r.outTemp, r.wind), thi: r.outTemp, solar: nil),
            inside: .init(temperature: r.inTemp),
            pressure: .init(value: r.pressure, trend: trend),
            wind: .init(speed: r.wind, direction: r.direction, sector: sector, gust: r.gust,
                        gustDirection: r.direction,
                        recent: [.init(sector: (sector + 15) % 16, weight: 0.6), .init(sector: sector, weight: 1),
                                 .init(sector: (sector + 1) % 16, weight: 0.3)]),
            rain: .init(hour: 0, day: r.rainDay, month: r.rainDay + 1.42, year: r.rainDay + 31.07),
            today: today,
            timezone: TimeZone.current.identifier
        )
    }

    func live() -> AsyncThrowingStream<CurrentConditions, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(Self.conditions(at: .now))
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func history(metric: ChartMetric, range: ChartRange) async throws -> HistorySeries {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -range.daysBack, to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!
        let bucket: Double = range == .week ? 1800 : (range == .hours48 ? 600 : 300)
        var points: [HistorySeries.Point] = []
        var t = start.timeIntervalSince1970
        while t < Date.now.timeIntervalSince1970 {
            let r = Self.reading(at: Date(timeIntervalSince1970: t))
            let v: Double
            switch metric {
            case .temperature: v = r.outTemp
            case .humidity: v = r.humidity
            case .pressure: v = r.pressure
            case .rain: v = r.rainDay
            case .windSpeed: v = r.wind
            case .windChill: v = Self.windChill(r.outTemp, r.wind)
            case .dewPoint: v = Self.dewPoint(r.outTemp, r.humidity)
            }
            points.append(.init(t: t, v: v))
            t += bucket
        }
        return HistorySeries(
            metric: metric.rawValue, range: range.rawValue,
            start: start.timeIntervalSince1970, end: end.timeIntervalSince1970, bucket: bucket,
            points: points,
            min: points.min(by: { $0.v < $1.v }), max: points.max(by: { $0.v < $1.v })
        )
    }
}
