import SwiftUI

struct ListenNowView: View {
    @EnvironmentObject private var store: AppStore
    @State private var path: [HomeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.playlists.isEmpty {
                        ContentUnavailableView("暂无歌单", systemImage: "music.note.list", description: Text(store.libraryStatus))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    } else {
                        playlistSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 130)
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [
                        Color.musicPageBackground,
                        Color.musicRed.opacity(0.08),
                        Color.musicPageBackground
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .mainPageToolbar("主页")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .playlist(let id):
                    if let playlist = store.playlists.first(where: { $0.id == id }) {
                        SongListView(title: playlist.name, songs: playlist.songs)
                    } else {
                        ContentUnavailableView("歌单不可用", systemImage: "music.note.list")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await store.refreshLibrary() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable {
                await store.refreshLibrary()
            }
        }
    }

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的歌单")
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                Text("\(store.playlists.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                ForEach(Array(store.playlists.enumerated()), id: \.element.id) { index, playlist in
                    Button {
                        path.append(.playlist(playlist.id))
                    } label: {
                        HomePlaylistRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)

                    if index < store.playlists.count - 1 {
                        Divider()
                            .padding(.leading, 112)
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

private enum HomeRoute: Hashable {
    case playlist(String)
}

struct HomePlaylistRow: View {
    let playlist: MusicPlaylist

    var body: some View {
        HStack(spacing: 16) {
            PlaylistArtworkGrid(songs: playlist.songs)
                .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 6) {
                Text(playlist.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(playlist.description.isEmpty ? "\(playlist.songs.count) 首歌曲" : playlist.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(playlist.songs.count) 首歌曲")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary.opacity(0.86))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct PlaylistArtworkGrid: View {
    @EnvironmentObject private var store: AppStore
    let songs: [EmbyAudioItem]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let tile = (min(size.width, size.height) - 2) / 2

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.musicRed.opacity(0.14))

                LazyVGrid(columns: [
                    GridItem(.fixed(tile), spacing: 2),
                    GridItem(.fixed(tile), spacing: 2)
                ], spacing: 2) {
                    ForEach(0..<4, id: \.self) { index in
                        if songs.indices.contains(index) {
                            ArtworkView(url: store.imageURL(for: songs[index], size: 160), cornerRadius: 3)
                        } else {
                            ZStack {
                                Color.secondary.opacity(0.12)
                                Image(systemName: "music.note")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(width: tile * 2 + 2, height: tile * 2 + 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct BrowseView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if store.songs.isEmpty {
                        ContentUnavailableView("暂无发现内容", systemImage: "sparkles", description: Text(store.libraryStatus))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    } else {
                        dailyRecommendationCard
                        RecentAddedSection()
                        MostPlayedSection()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 130)
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [
                        Color.musicPageBackground,
                        Color(red: 0.88, green: 0.94, blue: 1.0),
                        Color.musicPageBackground
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .mainPageToolbar("发现")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshLibrary() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 17, weight: .bold))
                    }
                }
            }
            .refreshable {
                await store.refreshLibrary()
            }
        }
    }

    private var dailyRecommendationCard: some View {
        NavigationLink {
            SongListView(title: "每日推荐", songs: store.dailyRecommendedSongs)
        } label: {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(url: store.dailyRecommendedSongs.first.flatMap { store.imageURL(for: $0, size: 900) }, cornerRadius: 18)
                    .overlay {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.16), .black.opacity(0.68)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }

                VStack(alignment: .leading, spacing: 10) {
                    Text("每日推荐")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(store.dailyRecommendedSongs.first?.name ?? "每日推荐")
                        .font(.system(size: 31, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text("共 \(store.dailyRecommendedSongs.count) 首")
                        Text("查看全部")
                        Image(systemName: "arrow.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                }
                .padding(26)

                Image(systemName: "play.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.24), lineWidth: 1)
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 268)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.12, green: 0.16, blue: 0.24), Color.musicRed.opacity(0.74)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
        }
        .buttonStyle(.plain)
    }
}

struct RecentAddedSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "最近添加") {
                SongListView(title: "最近添加", songs: store.recentlyAddedSongs)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(store.recentlyAddedSongs.prefix(10)) { song in
                        CompactMusicCard(
                            title: song.name,
                            subtitle: song.artistLine,
                            imageURL: store.imageURL(for: song, size: 320)
                        ) {
                            store.play(song: song, in: store.songs)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollClipDisabled()
        }
    }
}

struct MostPlayedSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最常播放") {
                SongListView(title: "最常播放", songs: store.mostPlayedSongs)
            }

            VStack(spacing: 0) {
                ForEach(Array(store.mostPlayedSongs.prefix(6).enumerated()), id: \.element.id) { index, song in
                    Button {
                        store.play(song: song, in: store.songs)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: store.imageURL(for: song, size: 160), cornerRadius: 5)
                                .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(song.artistLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if let count = song.userData?.playCount, count > 0 {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }

                            Image(systemName: "heart")
                                .foregroundStyle(.secondary.opacity(0.7))
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    if index < min(store.mostPlayedSongs.count, 6) - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.52), lineWidth: 0.8)
            }
        }
    }
}

struct SectionHeader<Destination: View>: View {
    let title: String
    let destination: Destination

    init(title: String, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.destination = destination()
    }

    var body: some View {
        HStack {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
            Spacer()
            NavigationLink {
                destination
            } label: {
                HStack(spacing: 4) {
                    Text("查看全部")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.musicRed)
            }
        }
    }
}

struct CompactMusicCard: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(url: imageURL, cornerRadius: 6)
                    .frame(width: 138, height: 138)
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 138, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
