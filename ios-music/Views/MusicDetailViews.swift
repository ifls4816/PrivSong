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
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(song.subtitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                Text(song.duration.musicDurationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                store.toggleFavorite(song)
            } label: {
                Label("喜欢", systemImage: store.isFavorite(song) ? "star.fill" : "star")
            }
            .tint(.musicRed)
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

    var body: some View {
        List {
            if songs.isEmpty {
                ContentUnavailableView("暂无内容", systemImage: "tray", description: Text(store.libraryStatus))
            } else {
                ForEach(songs) { song in
                    SongRow(song: song, imageURL: store.imageURL(for: song, size: 160), songs: songs)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var store: AppStore
    let album: MusicAlbum

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    ArtworkView(url: album.representativeSong.flatMap { store.imageURL(for: $0) }, cornerRadius: 10)
                        .frame(width: 210, height: 210)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                    Text(album.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(album.artist)
                        .foregroundStyle(Color.musicRed)
                    HStack(spacing: 12) {
                        Button {
                            play(album.songs.first)
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            play(album.songs.randomElement())
                        } label: {
                            Label("随机", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(album.songs) { song in
                    SongRow(song: song, imageURL: store.imageURL(for: song, size: 160), songs: album.songs)
                }
            }
        }
        .listStyle(.plain)
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
        List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    ArtworkView(url: artist.representativeSong.flatMap { store.imageURL(for: $0) }, cornerRadius: 72)
                        .frame(width: 144, height: 144)
                    Text(artist.name)
                        .font(.largeTitle.bold())
                    Button {
                        play(artist.songs.first)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }

            Section("热门歌曲") {
                ForEach(artist.songs.prefix(10)) { song in
                    SongRow(song: song, imageURL: store.imageURL(for: song, size: 160), songs: artist.songs)
                }
            }

            Section("专辑") {
                ForEach(artist.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: album.representativeSong.flatMap { store.imageURL(for: $0) }, cornerRadius: 6)
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading) {
                                Text(album.title)
                                Text(album.yearText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(artist.name)
    }

    private func play(_ song: EmbyAudioItem?) {
        guard let song else { return }
        store.play(song: song, in: artist.songs)
    }
}
