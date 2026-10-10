import SwiftUI
import UIKit

struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @State private var isPlayerExpanded = false
    @State private var selectedTab: AppTab = .home
    @State private var homePath: [HomeRoute] = []
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
            }    }

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
        selectedTab == .home && homePath.last?.hidesRootBottomChrome == true
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
