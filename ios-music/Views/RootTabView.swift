import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController
    @Namespace private var playerNamespace
    @State private var isPlayerExpanded = false
    @State private var playerCollapseProgress = 0.0

    var body: some View {
        ZStack {
            tabs

            if isPlayerExpanded, player.currentSong != nil {
                NowPlayingView(namespace: playerNamespace, collapseProgress: $playerCollapseProgress) {
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
            if store.session != nil, store.songs.isEmpty, store.isLoading {
                LaunchLoadingView(status: store.libraryStatus)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        baseTabs
            .tabViewBottomAccessory {
                MiniPlayerView(namespace: playerNamespace, visibility: miniPlayerVisibility) {
                    guard player.currentSong != nil else { return }
                    withAnimation(.interactiveSpring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.08)) {
                        playerCollapseProgress = 0
                        isPlayerExpanded = true
                    }
                }
            }
    }

    private var baseTabs: some View {
        TabView {
            Tab("主页", systemImage: "house.fill") {
                ListenNowView()
            }

            Tab("发现", systemImage: "safari.fill") {
                BrowseView()
            }

            Tab("设置", systemImage: "gearshape.fill") {
                SettingsView()
            }

            Tab("搜索", systemImage: "magnifyingglass", role: .search) {
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
}

private struct LaunchLoadingView: View {
    let status: String

    var body: some View {
        ZStack {
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

            VStack(spacing: 18) {
                Image(systemName: "music.note")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 82)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                    }

                VStack(spacing: 8) {
                    Text("Music Emby")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text(status == "Not connected" ? "正在加载资料库" : status)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                ProgressView()
                    .tint(.white)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 28)
        }
    }
}
