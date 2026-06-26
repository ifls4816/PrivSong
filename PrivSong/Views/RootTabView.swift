import SwiftUI
import UIKit

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isPlayerExpanded = false
    @State private var selectedTab: AppTab = .home
    @State private var pendingHomeRoute: HomeRoute?
    @State private var routeAfterPlayerDismiss: HomeRoute?

    var body: some View {
        tabs
            .sheet(isPresented: $isPlayerExpanded, onDismiss: handlePlayerSheetDismiss) {
                NowPlayingView(
                    onOpenAlbum: openAlbum,
                    onOpenArtist: openArtist
                ) {
                    isPlayerExpanded = false
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
            }
            .overlay {
                if store.session == nil {
                    SignInView()
                        .transition(.opacity)
                }
            }
            .onAppear {
                selectedTab = store.startsOnBrowse ? .browse : .home
            }
            .alert("收藏同步失败", isPresented: favoriteErrorBinding) {
                Button("好") {
                    store.favoriteErrorMessage = nil
                }
            } message: {
                Text(store.favoriteErrorMessage ?? "")
            }
            .overlay {
                if store.prefersHighRefreshRate {
                    HighRefreshRateView()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
    }

    private var favoriteErrorBinding: Binding<Bool> {
        Binding {
            store.favoriteErrorMessage != nil
        } set: { isPresented in
            if !isPresented {
                store.favoriteErrorMessage = nil
            }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        baseTabs
            .tabViewBottomAccessory {
                MiniPlayerView {
                    isPlayerExpanded = true
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
        routeAfterPlayerDismiss = route
        isPlayerExpanded = false
    }

    private func handlePlayerSheetDismiss() {
        guard let route = routeAfterPlayerDismiss else { return }
        routeAfterPlayerDismiss = nil
        selectedTab = .home
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
