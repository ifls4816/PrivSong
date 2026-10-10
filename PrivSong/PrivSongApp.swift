import SwiftUI
import UIKit

@main
struct PrivSongApp: App {
    @State private var store = SharedAppEnvironment.shared.store
    @StateObject private var player = SharedAppEnvironment.shared.player
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Artwork bytes already persist in ArtworkDiskCache, so the shared HTTP cache only needs to
        // absorb short-term repeats (player backdrop color extraction, API responses).
        URLCache.shared = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environmentObject(player)
                .tint(.musicRed)
                .onAppear {
                    store.player = player
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Writes are batched while active; persist what's pending before the app may be suspended.
            guard phase == .background else { return }
            player.savePlaybackStateNow()
            store.flushAudiobookProgress()
        }
    }
}

@MainActor
final class SharedAppEnvironment {
    static let shared = SharedAppEnvironment()

    let store: AppStore
    let player: PlayerController

    private init() {
        store = AppStore()
        player = PlayerController()
        store.player = player
    }
}

extension Color {
    static let musicRed = Color(uiColor: .musicRed)
    /// System grouped colors keep their elevated and increased-contrast variants.
    static let musicPageBackground = Color(uiColor: .systemGroupedBackground)
    static let musicCardBackground = Color(uiColor: .secondarySystemGroupedBackground)
}

extension UIColor {
    /// The app's red, tuned per appearance so small text on it meets the 4.5:1 contrast
    /// guideline, with stronger variants when Increase Contrast is on.
    static let musicRed = UIColor { traits in
        let isDark = traits.userInterfaceStyle == .dark
        let isHighContrast = traits.accessibilityContrast == .high
        switch (isDark, isHighContrast) {
        case (false, false):
            return UIColor(red: 0.84, green: 0.05, blue: 0.14, alpha: 1)
        case (false, true):
            return UIColor(red: 0.70, green: 0.02, blue: 0.10, alpha: 1)
        case (true, false):
            return UIColor(red: 1.0, green: 0.27, blue: 0.33, alpha: 1)
        case (true, true):
            return UIColor(red: 1.0, green: 0.45, blue: 0.49, alpha: 1)
        }
    }
}
