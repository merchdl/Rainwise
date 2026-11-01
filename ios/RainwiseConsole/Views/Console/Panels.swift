import SwiftUI

// Each panel is laid out at a fixed reference size (330 × 115) and the whole
// console is scaled to the screen by `ScaledCanvas`.

enum PanelMetrics {
    static let width: CGFloat = 330
    static let height: CGFloat = 115
    static let displayWidth: CGFloat = 180
    static let displayHeight: CGFloat = 72
}

struct HumidityPanel: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        PanelBox(width: PanelMetrics.width, height: PanelMetrics.height) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 3) {
                    DisplayWindow(text: store.humidityText, cells: 3,
                                  width: PanelMetrics.displayWidth, height: PanelMetrics.displayHeight)
                    PanelLabel("HUMIDITY")
                }
                LEDOption(label: "THI", on: store.humidityMode == .thi) { store.toggleHumidityMode() }
                    .padding(.top, 24)
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggleHumidityMode() }
    }
}

struct BarometerPanel: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        PanelBox(width: PanelMetrics.width, height: PanelMetrics.height) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 3) {
                    DisplayWindow(text: store.barometerText, cells: store.barometerCells,
                                  width: PanelMetrics.displayWidth, height: PanelMetrics.displayHeight)
                    PanelLabel("BAROMETER")
                }
                VStack(alignment: .leading, spacing: 8) {
                    LEDOption(label: "RISE", on: store.pressureTrend == "rise")
                    LEDOption(label: "FALL", on: store.pressureTrend == "fall")
                }
                .padding(.top, 12)
                Spacer(minLength: 0)
            }
        }
    }
}

struct RainfallPanel: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        PanelBox(width: PanelMetrics.width, height: PanelMetrics.height) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 3) {
                    DisplayWindow(text: store.rainText, cells: 3,
                                  width: PanelMetrics.displayWidth, height: PanelMetrics.displayHeight)
                    PanelLabel("RAINFALL")
                }
                VStack(alignment: .leading, spacing: 3) {
                    option("HOUR", .hour)
                    option("DAY", .day)
                    option("MONTH", .month)
                    option("YEAR", .year)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.cycleRain() }
    }

    private func option(_ label: String, _ mode: RainMode) -> some View {
        LEDOption(label: label, on: store.rainMode == mode, ledSize: 16, fontSize: 15) { store.rainMode = mode }
    }
}

struct ClockPanel: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        PanelBox(width: PanelMetrics.width, height: PanelMetrics.height) {
            HStack(alignment: .top, spacing: 16) {
                Spacer(minLength: 0)
                LEDOption(label: "DATE", on: store.clockMode == .date, ledFirst: false) { store.toggleClockMode() }
                    .padding(.top, 24)
                VStack(spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        DisplayWindow(text: blinkColon(store.clockText(at: context.date), context.date), cells: 4,
                                      width: PanelMetrics.displayWidth, height: PanelMetrics.displayHeight)
                    }
                    PanelLabel(store.extremeMode == .none ? "TIME" : (store.extremeMode == .max ? "TIME OF MAX" : "TIME OF MIN"))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggleClockMode() }
    }

    /// The colon blinks once a second while showing the live time.
    private func blinkColon(_ s: String, _ date: Date) -> String {
        guard store.extremeMode == .none, s.contains(":") else { return s }
        let second = Calendar.current.component(.second, from: date)
        return second % 2 == 0 ? s : s.replacingOccurrences(of: ":", with: ";")  // ";" = unlit colon
    }
}

struct TemperaturePanel: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        PanelBox(width: PanelMetrics.width, height: PanelMetrics.height) {
            HStack(alignment: .top, spacing: 12) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    option("OUT", .outside)
                    option("IN", .inside)
                    option("CHILL", .chill)
                    option("DEW", .dew)
                }
                VStack(spacing: 3) {
                    DisplayWindow(text: store.temperatureText, cells: 3,
                                  width: PanelMetrics.displayWidth - 10, height: PanelMetrics.displayHeight)
                    PanelLabel("TEMPERATURE", size: 17)
                }
            }
        }
    }

    private func option(_ label: String, _ mode: TemperatureMode) -> some View {
        LEDOption(label: label, on: store.temperatureMode == mode, ledSize: 16, fontSize: 15, ledFirst: false) {
            store.temperatureMode = mode
        }
    }
}

// MARK: - Buttons

private struct Triangle: Shape {
    var pointingUp: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if pointingUp {
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

struct ExtremeButton: View {
    @Environment(StationStore.self) private var store
    var mode: ExtremeMode  // .max or .min

    var body: some View {
        Button { store.toggleExtreme(mode) } label: {
            PanelBox(width: 100, height: 52) {
                HStack(spacing: 8) {
                    LEDIndicator(on: store.extremeMode == mode, size: 16)
                    VStack(spacing: 1) {
                        if mode == .max {
                            Triangle(pointingUp: true).fill(.white).frame(width: 26, height: 16)
                            PanelLabel("MAX", size: 15)
                        } else {
                            Triangle(pointingUp: false).fill(.white).frame(width: 26, height: 16)
                            PanelLabel("MIN", size: 15)
                        }
                    }
                }
            }
        }
        .buttonStyle(ConsoleButtonStyle())
    }
}

struct BrightnessButton: View {
    @Environment(StationStore.self) private var store

    var body: some View {
        Button { store.cycleBrightness() } label: {
            PanelBox(width: 220, height: 52) { PanelLabel("BRIGHTNESS") }
        }
        .buttonStyle(ConsoleButtonStyle())
    }
}

struct SelectButton: View {
    @Environment(StationStore.self) private var store
    @State private var flash = false

    var body: some View {
        Button {
            store.cycleTemperature()
            flash = true
            Task { try? await Task.sleep(for: .milliseconds(250)); flash = false }
        } label: {
            PanelBox(width: 220, height: 52) {
                HStack(spacing: 30) {
                    LEDIndicator(on: flash, size: 16)
                    PanelLabel("SELECT")
                }
            }
        }
        .buttonStyle(ConsoleButtonStyle())
    }
}

struct ConsoleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
