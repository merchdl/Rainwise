import Foundation
import Observation
import UIKit

struct AppSettings: Codable, Equatable {
    var collectorAddress: String = ""
    var token: String = ""
    var units: UnitSystem = .us
    var demo: Bool = true
    var stationName: String = "MK III"
    var keepScreenOn: Bool = false
    var brightness: Int = 0

    private static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum ConnectionState: Equatable {
    case idle, connecting, live
    case failed(String)
}

enum HumidityMode { case humidity, thi }
enum TemperatureMode: CaseIterable { case outside, inside, chill, dew }
enum RainMode: CaseIterable { case hour, day, month, year }
enum ClockMode { case time, date }
enum ExtremeMode { case none, max, min }

/// Owns the connection, the latest conditions, graph history and the
/// console's button state.
@MainActor
@Observable
final class StationStore {
    // Data
    private(set) var current: CurrentConditions?
    private(set) var connection: ConnectionState = .idle
    private(set) var lastReceived: Date?
    private(set) var history: HistorySeries?
    private(set) var historyError: String?
    private(set) var settings: AppSettings

    // Console state
    var humidityMode: HumidityMode = .humidity
    var temperatureMode: TemperatureMode = .outside
    var rainMode: RainMode = .day
    var clockMode: ClockMode = .time
    private(set) var extremeMode: ExtremeMode = .none
    var chartMetric: ChartMetric = .temperature { didSet { if chartMetric != oldValue { reloadHistory() } } }
    var chartRange: ChartRange = .today { didSet { if chartRange != oldValue { reloadHistory() } } }

    private var source: WeatherSource = DemoSource()
    private var liveTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var extremeResetTask: Task<Void, Never>?

    init() {
        settings = AppSettings.load()
        source = Self.makeSource(settings)
    }

    var units: UnitSystem { settings.units }
    var brightnessLevel: Double { [1.0, 0.72, 0.48][min(max(settings.brightness, 0), 2)] }

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        if liveTask == nil {
            liveTask = Task { await runLive() }
        }
        if historyTask == nil { reloadHistory() }
    }

    func stop() {
        liveTask?.cancel(); liveTask = nil
        historyTask?.cancel(); historyTask = nil
        connection = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func apply(_ new: AppSettings) {
        let reconnect = new.collectorAddress != settings.collectorAddress || new.token != settings.token || new.demo != settings.demo
        settings = new
        settings.save()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        if reconnect {
            source = Self.makeSource(settings)
            current = nil
            history = nil
            stop()
            start()
        }
    }

    private static func makeSource(_ s: AppSettings) -> WeatherSource {
        if s.demo || s.collectorAddress.isEmpty { return DemoSource() }
        return (try? CollectorSource(address: s.collectorAddress, token: s.token)) ?? DemoSource()
    }

    var isDemo: Bool { source is DemoSource }

    private func runLive() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            connection = .connecting
            do {
                for try await c in source.live() {
                    current = c
                    lastReceived = .now
                    connection = .live
                    backoff = 1
                }
                if Task.isCancelled { return }
                connection = .failed("Connection closed")
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                connection = .failed(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
    }

    func reloadHistory() {
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadHistory()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func loadHistory() async {
        let metric = chartMetric, range = chartRange
        do {
            let h = try await source.history(metric: metric, range: range)
            guard metric == chartMetric, range == chartRange else { return }
            history = h
            historyError = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            historyError = error.localizedDescription
        }
    }

    // MARK: Buttons

    func toggleHumidityMode() { humidityMode = humidityMode == .humidity ? .thi : .humidity }
    func toggleClockMode() { clockMode = clockMode == .time ? .date : .time }

    func cycleRain() {
        let all = RainMode.allCases
        rainMode = all[(all.firstIndex(of: rainMode)! + 1) % all.count]
    }

    func cycleTemperature() {
        let all = TemperatureMode.allCases
        temperatureMode = all[(all.firstIndex(of: temperatureMode)! + 1) % all.count]
    }

    func cycleBrightness() {
        var s = settings
        s.brightness = (s.brightness + 1) % 3
        apply(s)
    }

    /// MAX / MIN show today's extremes, then return to live after 15 s like the console.
    func toggleExtreme(_ mode: ExtremeMode) {
        extremeMode = extremeMode == mode ? .none : mode
        extremeResetTask?.cancel()
        guard extremeMode != .none else { return }
        extremeResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.extremeMode = .none
        }
    }
}

// MARK: - Display text for the seven-segment windows

extension StationStore {
    private var live: CurrentConditions? {
        guard let c = current, c.isLive else { return nil }
        return c
    }

    private func pick(_ key: String, _ liveValue: Double?) -> Double? {
        switch extremeMode {
        case .none: return liveValue
        case .max: return live?.today[key]?.max
        case .min: return live?.today[key]?.min
        }
    }

    private func text(_ v: Double?, _ q: Quantity, decimals: Int, placeholder: String = "---") -> String {
        guard let v = q.convert(v, units) else { return placeholder }
        return v.formatted(decimals: decimals)
    }

    var humidityText: String {
        switch humidityMode {
        case .humidity: return text(pick("humidity", live?.outside.humidity), .humidity, decimals: 0)
        case .thi: return text(pick("thi", live?.outside.thi), .temperature, decimals: 0)
        }
    }

    var barometerText: String {
        text(pick("pressure", live?.pressure.value), .pressure, decimals: units == .us ? 2 : 1, placeholder: "--.--")
    }

    var barometerCells: Int { units == .us ? 4 : 5 }
    var pressureTrend: String { live?.pressure.trend ?? "steady" }

    var rainText: String {
        let r = live?.rain
        let v: Double?
        switch rainMode {
        case .hour: v = r?.hour
        case .day: v = r?.day
        case .month: v = r?.month
        case .year: v = r?.year
        }
        // Totals can outgrow the window: drop a decimal when needed.
        if let inches = v {
            let shown = Quantity.rain.convert(inches, units)
            let d = units == .us ? (shown >= 10 ? 1 : 2) : (shown >= 100 ? 0 : 1)
            return shown.formatted(decimals: d)
        }
        return "-.--"
    }

    private var temperatureKey: (String, Double?) {
        switch temperatureMode {
        case .outside: return ("temperature", live?.outside.temperature)
        case .inside: return ("inside_temperature", live?.inside.temperature)
        case .chill: return ("wind_chill", live?.outside.windChill)
        case .dew: return ("dew_point", live?.outside.dewPoint)
        }
    }

    var temperatureText: String {
        let (key, value) = temperatureKey
        return text(pick(key, value), .temperature, decimals: 0)
    }

    var windText: String {
        let v: Double?
        switch extremeMode {
        case .none: v = live?.wind.speed
        case .max: v = live?.today["gust"]?.max
        case .min: v = live?.today["wind_speed"]?.min
        }
        return text(v, .speed, decimals: 0, placeholder: "--")
    }

    var windSector: Int? { live?.wind.sector }
    var windTrail: [CurrentConditions.Wind.Trail] { live?.wind.recent ?? [] }

    /// Clock window. During MAX/MIN it shows when the selected temperature extreme happened.
    func clockText(at date: Date) -> String {
        var shown = date
        if extremeMode != .none {
            let (key, _) = temperatureKey
            guard let e = live?.today[key] else { return "--:--" }
            shown = Date(timeIntervalSince1970: extremeMode == .max ? e.maxTime : e.minTime)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if clockMode == .date && extremeMode == .none {
            f.dateFormat = units == .us ? "MM.dd" : "dd.MM"
        } else {
            f.dateFormat = units == .us ? "hh:mm" : "HH:mm"
        }
        return f.string(from: shown)
    }
}
