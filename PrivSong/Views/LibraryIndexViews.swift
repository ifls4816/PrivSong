import SwiftUI

struct ArtistLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedArtist: MusicArtist?

    var body: some View {
        IndexedLibraryView(
            title: "艺术家",
            emptyTitle: "暂无艺术家",
            emptyIcon: "music.mic",
            sections: store.artistSections
        ) { artist in
            Button {
                selectedArtist = artist
            } label: {
                ArtistIndexRow(artist: artist)
            }
            .buttonStyle(.plain)
        }
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(artist: artist)
        }
    }
}

struct AlbumLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedAlbum: MusicAlbum?

    var body: some View {
        IndexedLibraryView(
            title: "专辑",
            emptyTitle: "暂无专辑",
            emptyIcon: "square.stack",
            sections: store.albumSections
        ) { album in
            Button {
                selectedAlbum = album
            } label: {
                AlbumIndexRow(album: album)
            }
            .buttonStyle(.plain)
        }
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
    }
}

struct AudiobookLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedAudiobook: Audiobook?

    var body: some View {
        IndexedLibraryView(
            title: "有声书",
            emptyTitle: "暂无有声书",
            emptyIcon: "book.closed",
            sections: store.audiobookSections
        ) { audiobook in
            Button {
                selectedAudiobook = audiobook
            } label: {
                AudiobookIndexRow(audiobook: audiobook)
            }
            .buttonStyle(.plain)
        }
        .navigationDestination(item: $selectedAudiobook) { audiobook in
            AudiobookDetailView(audiobook: audiobook)
        }
    }
}

private struct IndexedLibraryView<Item: Identifiable, Row: View>: View {
    let title: String
    let emptyTitle: String
    let emptyIcon: String
    let sections: [IndexedSection<Item>]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        Group {
            if sections.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items.indices, id: \.self) { index in
                                let item = section.items[index]
                                let isFirst = index == 0
                                let isLast = index == section.items.count - 1

                                row(item)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        Color.musicCardBackground,
                                        in: IndexedSectionRowShape(isFirst: isFirst, isLast: isLast)
                                    )
                                    .overlay(alignment: .bottom) {
                                        if !isLast {
                                            Divider()
                                                .padding(.leading, 90)
                                        }
                                    }
                                    .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text(section.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.leading, 2)
                        }
                        .sectionIndexLabel(section.title)
                    }
                }
                .listStyle(.plain)
                .listSectionIndexVisibility(.visible)
                .scrollContentBackground(.hidden)
                .safeAreaPadding(.bottom, 112)
                .background(Color.musicPageBackground.ignoresSafeArea())
            }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.large)
    }
}

private struct IndexedSectionRowShape: Shape {
    let isFirst: Bool
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: isFirst ? radius : 0,
                bottomLeading: isLast ? radius : 0,
                bottomTrailing: isLast ? radius : 0,
                topTrailing: isFirst ? radius : 0
            ),
            style: .continuous
        )
        .path(in: rect)
    }
}

private struct ArtistIndexRow: View {
    @EnvironmentObject private var store: AppStore
    let artist: MusicArtist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: artist.representativeSong.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 12)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(artist.songs.count) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private struct AlbumIndexRow: View {
    @EnvironmentObject private var store: AppStore
    let album: MusicAlbum

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: album.representativeSong.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 12)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text([album.artist, album.yearText].filter { !$0.isEmpty }.joined(separator: " - "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(album.songs.count) 首歌曲")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary.opacity(0.84))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private struct AudiobookIndexRow: View {
    @EnvironmentObject private var store: AppStore
    let audiobook: Audiobook

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: audiobook.representativeEpisode.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 12)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(audiobook.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(audiobook.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(store.audiobookListSubtitle(for: audiobook))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.musicRed)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
