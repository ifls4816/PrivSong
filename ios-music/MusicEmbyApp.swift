import SwiftUI
import UIKit

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
    static let musicPageBackground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.045, green: 0.047, blue: 0.058, alpha: 1)
        }
        return UIColor(red: 0.955, green: 0.965, blue: 0.985, alpha: 1)
    })
    static let musicBrowseAccentBackground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.075, green: 0.095, blue: 0.125, alpha: 1)
        }
        return UIColor(red: 0.88, green: 0.94, blue: 1.0, alpha: 1)
    })
    static let musicMiniPlayerBackground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.125, green: 0.125, blue: 0.145, alpha: 0.90)
        }
        return UIColor(white: 1, alpha: 0.86)
    })
    static let musicSeparatorStroke = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 1, alpha: 0.16)
        }
        return UIColor(white: 1, alpha: 0.54)
    })
}
