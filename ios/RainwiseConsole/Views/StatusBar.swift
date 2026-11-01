import SwiftUI

/// Bottom bar: connection state, data age, station warnings, settings button.
struct StatusBar: View {
    @Environment(StationStore.self) private var store
    @State private var showSettings = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = status(at: context.date)
            HStack(spacing: 12) {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                    .font(.title3)
                Text(status.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(store.chartMetric.title)
                    .font(.title3)
                    .foregroundStyle(.white)
                Button { showSettings = true } label: {
                    Image(systemName: "info.circle").font(.title2).foregroundStyle(.white)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(initial: store.settings)
        }
    }

    private struct Status {
        var icon: String
        var color: Color
        var message: String
    }

    private func status(at now: Date) -> Status {
        if store.isDemo {
            return Status(icon: "play.circle", color: .yellow, message: "Demo data. Tap ⓘ to connect your collector.")
        }
        switch store.connection {
        case .idle, .connecting:
            return Status(icon: "antenna.radiowaves.left.and.right", color: .gray, message: "Connecting to collector…")
        case .failed(let msg):
            return Status(icon: "wifi.exclamationmark", color: .red, message: "Can't reach collector: \(msg)")
        case .live:
            break
        }
        guard let c = store.current else {
            return Status(icon: "antenna.radiowaves.left.and.right", color: .gray, message: "Waiting for data…")
        }
        if !c.online {
            return Status(icon: "exclamationmark.triangle.fill", color: .red,
                          message: "Collector can't reach the IP-100" + (c.error.map { ": \($0)" } ?? ""))
        }
        if !c.station.signalOk {
            let rssi = c.station.rssi.map { " (\(Int($0)) dBm)" } ?? ""
            return Status(icon: "antenna.radiowaves.left.and.right.slash", color: .orange,
                          message: "IP-100 isn't hearing the station\(rssi). Check the station's battery and antenna.")
        }
        var msg = "IP-100"
        if let updated = c.updatedDate {
            let age = max(0, Int(now.timeIntervalSince(updated)))
            msg += age < 5 ? " · just now" : " · \(age) s ago"
        }
        if let v = c.station.battery, v < 5.6 {
            return Status(icon: "battery.25", color: .orange, message: msg + String(format: " · station battery low (%.1f V)", v))
        }
        return Status(icon: "antenna.radiowaves.left.and.right", color: .green, message: msg)
    }
}

/// Phone landscape: the graph fills the screen, with live values in one line above it.
struct LiveStrip: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        let u = store.units
        HStack(spacing: 22) {
            item(store.temperatureText + Quantity.temperature.symbol(u), "TEMP")
            item(store.humidityText + "%", "HUMIDITY")
            item(store.windText + " " + Quantity.speed.symbol(u), "WIND")
            item(store.barometerText + trendArrow, "BAROMETER")
            item(store.rainText + " " + Quantity.rain.symbol(u), "RAIN")
        }
        .frame(maxWidth: .infinity)
    }

    private var trendArrow: String {
        switch store.pressureTrend {
        case "rise": return " ↑"
        case "fall": return " ↓"
        default: return ""
        }
    }

    private func item(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(ConsoleTheme.led)
            Text(label).font(ConsoleTheme.label(11)).foregroundStyle(.white)
        }
    }
}
