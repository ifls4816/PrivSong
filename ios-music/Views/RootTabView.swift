import SwiftUI
import UIKit

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController
    @Namespace private var playerNamespace
    @State private var isPlayerExpanded = false
    @State private var playerCollapseProgress = 0.0
    @State private var selectedTab: AppTab = .home
    @State private var pendingHomeRoute: HomeRoute?

    var body: some View {
        ZStack {
            tabs

            if isPlayerExpanded, player.currentSong != nil || store.lastPlayedSong != nil {
                NowPlayingView(
                    namespace: playerNamespace,
                    collapseProgress: $playerCollapseProgress,
                    onOpenAlbum: openAlbum,
                    onOpenArtist: openArtist
                ) {
                    // Dismiss without animation — NowPlayingView handles its own fly-out
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        playerCollapseProgress = 1
                        isPlayerExpanded = false
                    }
                }
                .zIndex(20)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
            }
        }
        .overlay {
            if store.session == nil {
                SignInView()
                    .transition(.opacity)
            }
        }
        .overlay {
            if store.session != nil, !store.hasLibraryCache, store.songs.isEmpty, store.isLoading {
                LaunchLoadingView(status: store.libraryStatus)
                    .transition(.opacity)
            }
        }
        .onAppear {
            selectedTab = store.startsOnBrowse ? .browse : .home
        }
        .overlay {
            if store.prefersHighRefreshRate {
                HighRefreshRateView()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        baseTabs
            .tabViewBottomAccessory {
                MiniPlayerView(namespace: playerNamespace, visibility: miniPlayerVisibility) {
                    guard player.currentSong != nil || store.lastPlayedSong != nil else { return }
                    withAnimation(.interactiveSpring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.08)) {
                        playerCollapseProgress = 0
                        isPlayerExpanded = true
                    }
                }
            }
    }

    private var baseTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) {
                ListenNowView(pendingRoute: $pendingHomeRoute)
            }

            Tab("发现", systemImage: "safari.fill", value: AppTab.browse) {
                BrowseView()
            }

            Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }

            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSearchActivation(.searchTabSelection)
    }

    private var miniPlayerVisibility: Double {
        guard isPlayerExpanded else { return 1 }
        return min(max((playerCollapseProgress - 0.42) / 0.42, 0), 1)
    }

    private func openAlbum(for song: EmbyAudioItem) {
        guard let album = song.album?.trimmingCharacters(in: .whitespacesAndNewlines),
              !album.isEmpty else { return }
        openHomeRoute(.album(album))
    }

    private func openArtist(for song: EmbyAudioItem) {
        let artist = song.artists?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? song.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard !artist.isEmpty else { return }
        openHomeRoute(.artist(artist))
    }

    private func openHomeRoute(_ route: HomeRoute) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPlayerExpanded = false
            playerCollapseProgress = 1
            selectedTab = .home
        }
        DispatchQueue.main.async {
            pendingHomeRoute = route
        }
    }
}

private enum AppTab: Hashable {
    case home
    case browse
    case settings
    case search
}

private struct HighRefreshRateView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.start()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var displayLink: CADisplayLink?

        @objc private func tick() {}

        func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}

private struct LaunchLoadingView: View {
    let status: String

    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.08, blue: 0.16),
                Color(red: 0.48, green: 0.08, blue: 0.18),
                Color(red: 0.08, green: 0.07, blue: 0.09)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
