import SwiftUI

/// A round glossy indicator LED. `intensity` < 1 gives the dim "trail" LEDs on the wind ring.
struct LEDIndicator: View {
    var on: Bool
    var intensity: Double = 1
    var size: CGFloat = 22
    @Environment(\.ledBrightness) private var brightness

    var body: some View {
        let level = on ? intensity * brightness : 0
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.3), Color(white: 0.04)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.6))
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.85), ConsoleTheme.led, Color(red: 0.45, green: 0, blue: 0)],
                                     center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: size * 0.62))
                .opacity(level)
                .shadow(color: ConsoleTheme.led.opacity(0.8 * level), radius: size * 0.35)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.25), value: level)
    }
}

/// LED + label, tappable.
struct LEDOption: View {
    var label: String
    var on: Bool
    var ledSize: CGFloat = 20
    var fontSize: CGFloat = 18
    var ledFirst = true
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 10) {
            if ledFirst {
                LEDIndicator(on: on, size: ledSize)
                PanelLabel(label, size: fontSize)
            } else {
                PanelLabel(label, size: fontSize)
                LEDIndicator(on: on, size: ledSize)
            }
        }
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}
