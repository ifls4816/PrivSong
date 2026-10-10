import SwiftUI
import UIKit

struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @State private var isPlayerExpanded = false
    @State private var selectedTab: AppTab = .home
    @State private var homePath: [HomeRoute] = []
    @State private var settingsPath: [SettingsRoute] = []
    @State private var pendingHomeRoute: HomeRoute?
    @State private var routeAfterPlayerDismiss: HomeRoute?

    var body: some View {
        tabs
            .sheet(isPresented: $isPlayerExpanded, onDismiss: handlePlayerSheetDismiss) {
                // The player page paints its own opaque background, so the default sheet is kept.
                NowPlayingView(
                    onOpenAlbum: openAlbum,
                    onOpenArtist: openArtist
                ) {
                    isPlayerExpanded = false
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: isSignInPresented) {
                SignInView()
                    .interactiveDismissDisabled()
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
            }    }

    /// Sign-in covers the app whenever there's no session; it dismisses itself once connected.
    private var isSignInPresented: Binding<Bool> {
        Binding {
            store.session == nil
        } set: { _ in }
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
            .tabViewBottomAccessory(isEnabled: !hidesRootBottomChrome) {
                miniPlayerAccessory
            }
    }

    private var hidesRootBottomChrome: Bool {
        selectedTab == .settings && settingsPath.contains { $0.hidesRootBottomChrome }
    }

    private var miniPlayerAccessory: some View {
        MiniPlayerView {
            isPlayerExpanded = true
        }
    }

    private var baseTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) {
                ListenNowView(path: $homePath, pendingRoute: $pendingHomeRoute)
            }

            Tab("发现", systemImage: "safari.fill", value: AppTab.browse) {
                BrowseView()
            }

            Tab("设置", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView(path: $settingsPath)
            }

            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSearchActivation(.searchTabSelection)
    }

    private func openAlbum(for song: EmbyAudioItem) {
        guard song.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        openHomeRoute(.album(song.albumGroupId))
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
