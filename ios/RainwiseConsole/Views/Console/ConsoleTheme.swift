import SwiftUI

enum ConsoleTheme {
    static let background = Color(white: 0.19)
    static let panel = Color(white: 0.17)
    static let border = Color(white: 0.86)
    static let led = Color(red: 1, green: 0.09, blue: 0.06)
    static let displayBackground = Color(red: 0.17, green: 0.0, blue: 0.0)

    /// Wide engraved-looking label face, close to the hardware console's.
    static func label(_ size: CGFloat) -> Font { .custom("Copperplate-Bold", size: size) }
}

private struct LEDBrightnessKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// 0...1, set by the BRIGHTNESS button.
    var ledBrightness: Double {
        get { self[LEDBrightnessKey.self] }
        set { self[LEDBrightnessKey.self] = newValue }
    }
}

/// Rounded panel with a light border, like each block on the console.
struct PanelBox<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 3).fill(ConsoleTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(ConsoleTheme.border, lineWidth: 1.5))
    }
}

struct PanelLabel: View {
    var text: String
    var size: CGFloat = 18

    init(_ text: String, size: CGFloat = 18) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(ConsoleTheme.label(size))
            .tracking(1)
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The dark red window behind the digits.
struct DisplayWindow: View {
    var text: String
    var cells: Int
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        SevenSegmentDisplay(text: text, cells: cells)
            .padding(.horizontal, width * 0.05)
            .padding(.vertical, height * 0.13)
            .frame(width: width, height: height)
            .background(ConsoleTheme.displayBackground)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
    }
}

/// Fixed-size layout scaled uniformly to fit, so the console keeps its
/// proportions on every screen size.
struct ScaledCanvas<Content: View>: View {
    var size: CGSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / size.width, geo.size.height / size.height)
            content()
                .frame(width: size.width, height: size.height)
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: size.width * s, height: size.height * s, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
    }
}
