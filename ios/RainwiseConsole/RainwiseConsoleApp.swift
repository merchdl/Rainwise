import SwiftUI

@main
struct RainwiseConsoleApp: App {
    @State private var store = StationStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: store.start()
                    case .background: store.stop()
                    default: break
                    }
                }
        }
    }
}
