import SwiftUI

@main
struct MusicEmbyApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var player = PlayerController()

    init() {
        // Keep enough shared response cache for artwork and player backdrop color extraction.
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(player)
                .tint(.musicRed)
                .onAppear {
                    store.player = player
                }
        }
    }
}

extension Color {
    static let musicRed = Color(red: 1.0, green: 0.11, blue: 0.18)
    static let musicPageBackground = Color(red: 0.955, green: 0.965, blue: 0.985)
}
