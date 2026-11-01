import SwiftUI

/// 16 LEDs around the wind speed display. The current direction is lit fully;
/// directions seen in the last 10 minutes glow dimly, like the console's trail.
struct WindRose: View {
    @Environment(StationStore.self) private var store
    var size: CGFloat

    var body: some View {
        let inset = size * 0.04
        let radius = size * 0.37
        let center = CGPoint(x: size / 2, y: size / 2)
        let trail = Dictionary(store.windTrail.map { ($0.sector, $0.weight) }, uniquingKeysWith: { Swift.max($0, $1) })
        let current = store.windSector

        ZStack {
            Rectangle()
                .stroke(ConsoleTheme.border, lineWidth: 1.5)
                .padding(inset)

            ForEach(0..<16, id: \.self) { i in
                let angle = Double(i) * 22.5 * .pi / 180
                let isCurrent = i == current
                LEDIndicator(on: isCurrent || trail[i] != nil,
                             intensity: isCurrent ? 1 : (trail[i] ?? 0) * 0.45,
                             size: size * 0.072)
                    .position(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
            }

            compassLabel("N").position(x: center.x, y: inset)
            compassLabel("S").position(x: center.x, y: size - inset)
            compassLabel("E").position(x: size - inset, y: center.y)
            compassLabel("W").position(x: inset, y: center.y)

            PanelBox(width: size * 0.42, height: size * 0.42) {
                VStack(spacing: size * 0.03) {
                    DisplayWindow(text: store.windText, cells: 2, width: size * 0.34, height: size * 0.2)
                    PanelLabel(windLabel, size: size * 0.05)
                }
            }
            .position(center)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wind \(store.windText) \(Quantity.speed.symbol(store.units))")
    }

    private var windLabel: String {
        switch store.extremeMode {
        case .none: return "WIND"
        case .max: return "GUST"
        case .min: return "WIND"
        }
    }

    private func compassLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: size * 0.075, weight: .regular))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.015)
            .background(ConsoleTheme.background)
    }
}

/// iPad / large layout: 1000 × 380, three columns like the hardware console.
struct WideConsole: View {
    @Environment(StationStore.self) private var store
    static let size = CGSize(width: 1000, height: 380)

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 17.5) {
                HumidityPanel()
                BarometerPanel()
                RainfallPanel()
            }
            VStack(spacing: 2) {
                Text("WEATHER STATION")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .frame(height: 36)
                WindRose(size: 300)
                    .frame(height: 300)
                HStack(alignment: .firstTextBaseline) {
                    Text("Weather Console")
                        .font(.system(size: 25, weight: .bold, design: .serif).italic())
                    Spacer()
                    Text(store.settings.stationName)
                        .font(.system(size: 30, weight: .heavy).italic())
                }
                .foregroundStyle(.white)
                .frame(height: 38)
            }
            .frame(width: 300)
            VStack(spacing: 17.5) {
                ClockPanel()
                TemperaturePanel()
                ButtonCluster()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.ledBrightness, store.brightnessLevel)
    }
}

/// iPhone portrait layout: 670 × 495, two columns, scaled to the screen width.
struct CompactConsole: View {
    @Environment(StationStore.self) private var store
    static let size = CGSize(width: 670, height: 495)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                TemperaturePanel()
                HumidityPanel()
                BarometerPanel()
                RainfallPanel()
            }
            VStack(spacing: 10) {
                ClockPanel()
                WindRose(size: 246)
                ButtonCluster()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.ledBrightness, store.brightnessLevel)
    }
}

struct ButtonCluster: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ExtremeButton(mode: .max)
                BrightnessButton()
            }
            HStack(spacing: 10) {
                ExtremeButton(mode: .min)
                SelectButton()
            }
        }
    }
}
