import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var submittedSearchText = ""

    private var trimmedText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var submittedTerm: String {
        submittedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSongs: [EmbyAudioItem] {
        submittedTerm.isEmpty ? [] : store.searchResults
    }

    private var visibleAlbums: [MusicAlbum] {
        guard !submittedTerm.isEmpty else { return [] }
        return store.albums.filter {
            $0.title.localizedCaseInsensitiveContains(submittedTerm) ||
                $0.artist.localizedCaseInsensitiveContains(submittedTerm)
        }
    }

    private var visibleArtists: [MusicArtist] {
        guard !submittedTerm.isEmpty else { return [] }
        return store.artists.filter { $0.name.localizedCaseInsensitiveContains(submittedTerm) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.musicPageBackground
                    .ignoresSafeArea()

                if submittedTerm.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    resultsContent
                }
            }
            .mainPageToolbar("搜索")
            .searchable(text: $searchText, placement: .automatic, prompt: "搜索")
            .submitLabel(.search)
            .onSubmit(of: .search) {
                submitSearch()
            }
            .onChange(of: searchText) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    clearSearch()
                }
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 76, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.42))
            Text("搜索音乐")
                .font(.system(size: 23, weight: .bold))
            Text("输入歌曲、专辑或艺术家名称")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.bottom, 70)
    }

    private var resultsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("搜索中")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                if !visibleArtists.isEmpty {
                    SearchResultSection(title: "艺人") {
                        ForEach(visibleArtists.prefix(6)) { artist in
                            NavigationLink {
                                ArtistDetailView(artist: artist)
                            } label: {
                                SearchPlainRow(title: artist.name, subtitle: "\(artist.songs.count) 首歌曲", icon: "music.mic")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !visibleAlbums.isEmpty {
                    SearchResultSection(title: "专辑") {
                        ForEach(visibleAlbums.prefix(8)) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                SearchArtworkRow(
                                    title: album.title,
                                    subtitle: album.artist,
                                    imageURL: album.representativeSong.flatMap { store.imageURL(for: $0, size: 160) }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !visibleSongs.isEmpty {
                    SearchResultSection(title: "歌曲") {
                        ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                            SongRow(song: song, imageURL: store.imageURL(for: song, size: 160), songs: visibleSongs)

                            if index < visibleSongs.count - 1 {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                }

                if !store.isSearching &&
                    visibleSongs.isEmpty &&
                    visibleAlbums.isEmpty &&
                    visibleArtists.isEmpty {
                    ContentUnavailableView.search(text: submittedTerm)
                        .padding(.top, 70)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 32)
            .padding(.bottom, 128)
        }
    }

    private func submitSearch() {
        let term = trimmedText
        searchTask?.cancel()
        submittedSearchText = term

        guard !term.isEmpty else {
            clearSearch()
            return
        }

        searchTask = Task {
            await store.search(term)
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        submittedSearchText = ""
        searchTask = Task {
            await store.search("")
        }
    }
}

private struct SearchResultSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 22, weight: .bold))

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct SearchArtworkRow: View {
    let title: String
    let subtitle: String
    let imageURL: AuthenticatedURL?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: imageURL, cornerRadius: 6)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SearchPlainRow: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.musicRed)
                .frame(width: 52, height: 52)
                .background(Color.musicRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
