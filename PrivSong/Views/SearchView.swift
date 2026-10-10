import SwiftUI

struct SearchView: View {
    @Environment(AppStore.self) private var store
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var submittedSearchText = ""
    /// Matched once when the search is submitted, not on every render while results are shown.
    @State private var matchedAlbums: [MusicAlbum] = []
    @State private var matchedArtists: [MusicArtist] = []

    private var trimmedText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var submittedTerm: String {
        submittedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSongs: [EmbyAudioItem] {
        submittedTerm.isEmpty ? [] : store.searchResults
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
        ContentUnavailableView(
            "搜索音乐",
            systemImage: "magnifyingglass",
            description: Text("输入歌曲、专辑或艺术家名称")
        )
    }

    private var resultsContent: some View {
        let visibleArtists = matchedArtists
        let visibleAlbums = matchedAlbums
        let visibleSongs = self.visibleSongs

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
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
                        ForEach(visibleArtists) { artist in
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
                        ForEach(visibleAlbums) { album in
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
            .padding(.bottom, 16)
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

        matchedArtists = Array(store.artists.filter { $0.name.localizedCaseInsensitiveContains(term) }.prefix(6))
        matchedAlbums = Array(store.albums.filter {
            $0.title.localizedCaseInsensitiveContains(term) ||
                $0.artist.localizedCaseInsensitiveContains(term)
        }.prefix(8))

        searchTask = Task {
            await store.search(term)
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        submittedSearchText = ""
        matchedArtists = []
        matchedAlbums = []
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
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            LazyVStack(spacing: 0) {
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
                    .font(.callout.weight(.semibold))
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
                .accessibilityHidden(true)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
                    .font(.callout.weight(.semibold))
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
                .accessibilityHidden(true)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
