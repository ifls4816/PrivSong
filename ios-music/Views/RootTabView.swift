import SwiftUI
import UIKit

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController
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
            .overlay {
                if store.session != nil, !store.hasLoadedInitialContent, store.isLoading {
                    LaunchLoadingView()
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
                MiniPlayerView {
                    guard player.currentSong != nil || store.lastPlayedSong != nil else { return }
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

private struct LaunchLoadingView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            LaunchLoadingBackground()

            VStack(spacing: 18) {
                Spacer(minLength: 44)

                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 104, height: 104)
                            .overlay {
                                RoundedRectangle(cornerRadius: 30, style: .continuous)
                                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 24, y: 16)

                        Image(systemName: "music.note.list")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white, .white.opacity(0.72))
                            .symbolEffect(.pulse, value: isAnimating)
                    }
                    .scaleEffect(isAnimating ? 1.03 : 0.98)

                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                Spacer(minLength: 80)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 34)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct LaunchLoadingBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.07, blue: 0.09),
                    Color(red: 0.42, green: 0.06, blue: 0.13),
                    Color(red: 0.07, green: 0.12, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.musicRed.opacity(0.72),
                        Color(red: 1.0, green: 0.36, blue: 0.28).opacity(0.30),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 310)

                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(.black.opacity(0.12))
        }
    }
}
