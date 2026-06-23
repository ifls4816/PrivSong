import SwiftUI

struct SongRow: View {
    @EnvironmentObject private var store: AppStore

    let song: EmbyAudioItem
    let imageURL: URL?
    var songs: [EmbyAudioItem]?

    var body: some View {
        Button {
            play(song)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: imageURL, cornerRadius: 5)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if let tagText = song.audioInfoTagText {
                            Text(tagText)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Color.musicRed)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.musicRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color.musicRed.opacity(0.32), lineWidth: 0.8)
                                }
                        }

                        Text(song.artistLine)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Text(song.duration.musicDurationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                store.addToQueueEnd(song)
            } label: {
                Label("加入队列", systemImage: "text.badge.plus")
            }
            .tint(.blue)

            Button {
                store.playNext(song)
            } label: {
                Label("下一首", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.green)

            Button {
                store.toggleFavorite(song)
            } label: {
                Label("喜欢", systemImage: store.isFavorite(song) ? "star.fill" : "star")
            }
            .tint(.musicRed)
        }
        .contextMenu {
            Button {
                store.playNext(song)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                store.addToQueueEnd(song)
            } label: {
                Label("加入队列末尾", systemImage: "text.badge.plus")
            }

            Button {
                store.toggleFavorite(song)
            } label: {
                Label(store.isFavorite(song) ? "取消喜欢" : "喜欢", systemImage: store.isFavorite(song) ? "star.slash" : "star")
            }
        }
    }

    private func play(_ song: EmbyAudioItem) {
        store.play(song: song, in: songs ?? store.songs)
    }
}

struct SongListView: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let songs: [EmbyAudioItem]
    var showsEmptyStatus = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if songs.isEmpty {
                    emptyState
                } else {
                    SongRowsCard(songs: songs)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 130)
        }
        .scrollContentBackground(.hidden)
        .background(Color.musicPageBackground.ignoresSafeArea())
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private var emptyState: some View {
        if showsEmptyStatus {
            ContentUnavailableView("暂无内容", systemImage: "tray", description: Text(store.localizedLibraryStatus))
                .frame(maxWidth: .infinity)
                .padding(.top, 90)
        } else {
            ContentUnavailableView("暂无内容", systemImage: "tray")
                .frame(maxWidth: .infinity)
                .padding(.top, 90)
        }
    }
}

struct PaginatedSongListView: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let songs: [EmbyAudioItem]
    let pageSize: Int

    @State private var visibleCount: Int
    @State private var isLoadingNextPage = false

    init(title: String, songs: [EmbyAudioItem], pageSize: Int = 80) {
        self.title = title
        self.songs = songs
        self.pageSize = pageSize
        _visibleCount = State(initialValue: pageSize)
    }

    private var visibleSongs: [EmbyAudioItem] {
        Array(songs.prefix(min(visibleCount, songs.count)))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if songs.isEmpty {
                    ContentUnavailableView("暂无内容", systemImage: "tray", description: Text(store.libraryStatus))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                } else {
                    SongRowsCard(songs: visibleSongs, playbackSongs: songs) { index in
                        loadNextPageIfNeeded(appearingIndex: index)
                    }

                    if visibleCount < songs.count {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 10)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 130)
        }
        .scrollContentBackground(.hidden)
        .background(Color.musicPageBackground.ignoresSafeArea())
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.large)
        .onAppear {
            visibleCount = min(max(visibleCount, pageSize), songs.count)
        }
        .onChange(of: songs.count) { _, count in
            visibleCount = min(pageSize, count)
        }
    }

    private func loadNextPage() {
        guard visibleCount < songs.count else { return }
        visibleCount = min(visibleCount + pageSize, songs.count)
    }

    private func loadNextPageIfNeeded(appearingIndex index: Int) {
        let preloadThreshold = max(visibleSongs.count - 12, 0)
        guard index >= preloadThreshold else { return }
        guard visibleCount < songs.count, !isLoadingNextPage else { return }

        isLoadingNextPage = true
        loadNextPage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            isLoadingNextPage = false
        }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var store: AppStore
    let album: MusicAlbum

    var body: some View {
        MusicCollectionDetailView(
            title: album.title,
            subtitle: album.artist,
            artworkURL: album.representativeSong.flatMap { store.imageURL(for: $0) },
            songs: album.songs,
            play: play
        )
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func play(_ song: EmbyAudioItem?) {
        guard let song else { return }
        store.play(song: song, in: album.songs)
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var store: AppStore
    let artist: MusicArtist

    var body: some View {
        MusicCollectionDetailView(
            title: artist.name,
            subtitle: "\(artist.songs.count) 首歌曲",
            artworkURL: artist.representativeSong.flatMap { store.imageURL(for: $0) },
            songs: artist.songs,
            play: play
        )
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func play(_ song: EmbyAudioItem?) {
        guard let song else { return }
        store.play(song: song, in: artist.songs)
    }
}

private struct MusicCollectionDetailView: View {
    @EnvironmentObject private var store: AppStore
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let songs: [EmbyAudioItem]
    let play: (EmbyAudioItem?) -> Void

    @State private var visibleCount = 80
    @State private var isLoadingNextPage = false

    private var visibleSongs: [EmbyAudioItem] {
        Array(songs.prefix(min(visibleCount, songs.count)))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                songList

                if visibleCount < songs.count {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 130)
        }
        .scrollContentBackground(.hidden)
        .background(Color.musicPageBackground.ignoresSafeArea())
        .onAppear {
            visibleCount = min(max(visibleCount, 80), songs.count)
        }
        .onChange(of: songs.count) { _, count in
            visibleCount = min(80, count)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(url: artworkURL, cornerRadius: 12)
                .frame(width: 218, height: 218)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

            VStack(spacing: 5) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.musicRed)
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Button {
                    play(songs.first)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                        Text("播放")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(songs.isEmpty)

                Button {
                    play(songs.randomElement())
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "shuffle")
                        Text("随机")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(songs.isEmpty)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var songList: some View {
        SongRowsCard(songs: visibleSongs, playbackSongs: songs) { index in
            loadNextPageIfNeeded(appearingIndex: index)
        }
    }

    private func loadNextPageIfNeeded(appearingIndex index: Int) {
        let preloadThreshold = max(visibleSongs.count - 12, 0)
        guard index >= preloadThreshold else { return }
        guard visibleCount < songs.count, !isLoadingNextPage else { return }

        isLoadingNextPage = true
        visibleCount = min(visibleCount + 80, songs.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            isLoadingNextPage = false
        }
    }
}

struct SongRowsCard: View {
    @EnvironmentObject private var store: AppStore
    let songs: [EmbyAudioItem]
    var playbackSongs: [EmbyAudioItem]?
    var limit: Int?
    var onSongAppear: ((Int) -> Void)?

    private var visibleSongs: [EmbyAudioItem] {
        if let limit {
            return Array(songs.prefix(limit))
        }
        return songs
    }

    private var playbackQueue: [EmbyAudioItem] {
        playbackSongs ?? songs
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                SongRow(song: song, imageURL: store.imageURL(for: song, size: 160), songs: playbackQueue)
                    .onAppear {
                        onSongAppear?(index)
                    }

                if index < visibleSongs.count - 1 {
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
                .strokeBorder(Color.musicSeparatorStroke, lineWidth: 0.8)
        }
    }
}
