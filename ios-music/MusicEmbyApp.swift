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
        UISlider.appearance().minimumTrackTintColor = .musicRed
        UISlider.appearance().thumbTintColor = .musicSliderThumb
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
    static let musicRed = Color(uiColor: .musicRed)
    static let musicPageBackground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor.systemGroupedBackground
        }
        return UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    })
    static let musicCardBackground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor.secondarySystemGroupedBackground
        }
        return UIColor.white
    })
    static let musicBrowseAccentBackground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor.secondarySystemGroupedBackground
        }
        return UIColor.white
    })
    static let musicMiniPlayerBackground = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.125, green: 0.125, blue: 0.145, alpha: 0.90)
        }
        return UIColor(white: 1, alpha: 0.86)
    })
    static let musicSeparatorStroke = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor.separator.withAlphaComponent(0.45)
        }
        return UIColor.separator.withAlphaComponent(0.18)
    })
}

extension UIColor {
    static let musicRed = UIColor(red: 1.0, green: 0.11, blue: 0.18, alpha: 1)
    static let musicSliderThumb = UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0.92, alpha: 1)
        }
        return UIColor.white
    }
}
