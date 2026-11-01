import SwiftUI

/// Picks the layout:
/// - iPad (regular × regular): full console above the graph, like the original iPad app.
/// - iPhone portrait: compact two-column console above the graph, so both are visible at once.
/// - iPhone landscape: graph fills the screen with a one-line live readout.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        ZStack {
            ConsoleTheme.background.ignoresSafeArea()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
    }

    @ViewBuilder
    private var content: some View {
        if hSize == .regular && vSize == .regular {
            VStack(spacing: 16) {
                ScaledCanvas(size: WideConsole.size) { WideConsole() }
                    .layoutPriority(1)
                HistorySection(compact: false)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
        } else if vSize == .compact {
            VStack(spacing: 8) {
                LiveStrip()
                HistorySection(compact: true)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        } else {
            VStack(spacing: 10) {
                ScaledCanvas(size: CompactConsole.size) { CompactConsole() }
                    .layoutPriority(1)
                HistorySection(compact: true)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}
