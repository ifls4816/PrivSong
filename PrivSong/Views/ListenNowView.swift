import SwiftUI

struct ListenNowView: View {
    @Environment(AppStore.self) private var store
    @Binding private var path: [HomeRoute]
    @Binding private var pendingRoute: HomeRoute?
    @State private var visiblePlaylistCount = 30
    @State private var isLoadingNextPlaylistPage = false
    @State private var editingPlaylist: MusicPlaylist?
    @State private var playlistPendingDelete: MusicPlaylist?
    @State private var isDeleteConfirmationPresented = false
    @State private var playlistErrorMessage: String?
    @State private var isShowingPlaylistError = false

    private let playlistPageSize = 30

    init(path: Binding<[HomeRoute]> = .constant([]), pendingRoute: Binding<HomeRoute?> = .constant(nil)) {
        _path = path
        _pendingRoute = pendingRoute
    }

    private var showsLibraryCategorySkeleton: Bool {
        !store.hasLibraryCategoryContent && store.isLoadingContent
    }

    private var showsPlaylistSkeleton: Bool {
        store.playlists.isEmpty && store.isLoadingContent
    }

    private var showsHomeEmptyState: Bool {
        !store.hasHomeContent && !store.isLoadingContent
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if showsHomeEmptyState {
                        ContentUnavailableView("暂无资料库", systemImage: "music.note.list", description: Text(store.libraryStatus))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    } else {
                        if showsLibraryCategorySkeleton {
                            LibraryCategorySkeletonSection()
                        } else if store.hasLibraryCategoryContent {
                            libraryCategorySection
                        }

                        if showsPlaylistSkeleton {
                            PlaylistSkeletonSection()
                        } else if !store.playlists.isEmpty {
                            playlistSection
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 130)
            }
            .scrollContentBackground(.hidden)
            .background(Color.musicPageBackground.ignoresSafeArea())
            .mainPageToolbar("主页")
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .playlist(let id):
                    PlaylistDetailLoaderView(playlistID: id)
                case .artist(let id):
                    if let artist = store.artists.first(where: { $0.id == id }) {
                        ArtistDetailView(artist: artist)
                    } else {
                        ContentUnavailableView("艺术家不可用", systemImage: "music.mic")
                    }
                case .album(let id):
                    if let album = store.albums.first(where: { $0.id == id }) {
                        AlbumDetailView(album: album)
                    } else {
                        ContentUnavailableView("专辑不可用", systemImage: "square.stack")
                    }
                case .audiobook(let id):
                    if let audiobook = store.audiobooks.first(where: { $0.id == id }) {
                        AudiobookDetailView(audiobook: audiobook)
                    } else {
                        ContentUnavailableView("有声书不可用", systemImage: "book.closed")
                    }
                case .folderLibrary:
                    MusicFolderLibraryView()
                }
            }
            .onChange(of: pendingRoute) { _, route in
                guard let route else { return }
                path.append(route)
                pendingRoute = nil
            }
            .sheet(item: $editingPlaylist) { playlist in
                PlaylistEditSheet(playlist: playlist)
                    .environment(store)
            }
            .alert("删除歌单？", isPresented: $isDeleteConfirmationPresented) {
                Button("删除", role: .destructive) {
                    guard let playlist = playlistPendingDelete else { return }
                    Task { await deletePlaylist(playlist) }
                }
                Button("取消", role: .cancel) {
                    playlistPendingDelete = nil
                }
            } message: {
                Text(deleteConfirmationMessage)
            }
            .alert("歌单编辑失败", isPresented: $isShowingPlaylistError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(playlistErrorMessage ?? "")
            }
        }
        .toolbarVisibility(homeTabBarVisibility, for: .tabBar)
    }

    private var homeTabBarVisibility: Visibility {
        path.last?.hidesRootBottomChrome == true ? .hidden : .visible
    }

    private var deleteConfirmationMessage: String {
        if let playlistPendingDelete {
            return "确定要删除「\(playlistPendingDelete.name)」吗？删除后将从 Emby 服务器移除该歌单。"
        }
        return "删除后将从 Emby 服务器移除该歌单。"
    }

    private var libraryCategorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                NavigationLink {
                    PaginatedSongListView(title: "全部歌曲", songs: store.songs)
                } label: {
                    LibraryCategoryCard(
                        title: "全部歌曲",
                        subtitle: "\(store.songs.count) 首",
                        icon: "music.note.list",
                        color: Color(red: 0.12, green: 0.48, blue: 0.88)
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    SongListView(title: "我喜欢的", songs: store.favoriteSongs, showsEmptyStatus: false)
                } label: {
                    LibraryCategoryCard(
                        title: "我喜欢的",
                        subtitle: "\(store.favoriteSongs.count) 首",
                        icon: "heart.fill",
                        color: Color.musicRed
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ArtistLibraryView()
                } label: {
                    LibraryCategoryCard(
                        title: "艺术家",
                        subtitle: "\(store.artists.count) 位",
                        icon: "music.mic",
                        color: Color(red: 0.48, green: 0.22, blue: 0.82)
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    AudiobookLibraryView()
                } label: {
                    LibraryCategoryCard(
                        title: "有声书",
                        subtitle: "\(store.audiobooks.count) 本",
                        icon: "book.closed.fill",
                        color: Color(red: 0.12, green: 0.55, blue: 0.38)
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: HomeRoute.folderLibrary) {
                    LibraryCategoryCard(
                        title: "文件夹",
                        subtitle: "Emby 目录",
                        icon: "folder.fill",
                        color: Color.musicRed
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var visiblePlaylists: [MusicPlaylist] {
        Array(store.playlists.prefix(min(visiblePlaylistCount, store.playlists.count)))
    }

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我的歌单")
                .font(.system(size: 24, weight: .bold))

            LazyVStack(spacing: 0) {
                ForEach(Array(visiblePlaylists.enumerated()), id: \.element.id) { index, playlist in
                    LongPressHomePlaylistRow(
                        playlist: playlist,
                        open: {
                            path.append(.playlist(playlist.id))
                        },
                        edit: {
                            editingPlaylist = playlist
                        },
                        delete: {
                            playlistPendingDelete = playlist
                            isDeleteConfirmationPresented = true
                        }
                    )
                    .onAppear {
                        loadNextPlaylistPageIfNeeded(appearingIndex: index)
                    }

                    if index < visiblePlaylists.count - 1 {
                        Divider()
                            .padding(.leading, 90)
                    }
                }
            }
            .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: HomePlaylistRowLayout.cardCornerRadius, style: .continuous))
            .frame(maxWidth: .infinity)

            if visiblePlaylistCount < store.playlists.count {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            visiblePlaylistCount = min(max(visiblePlaylistCount, playlistPageSize), store.playlists.count)
        }
        .onChange(of: store.playlists.count) { _, count in
            visiblePlaylistCount = min(playlistPageSize, count)
        }
    }

    private func loadNextPlaylistPageIfNeeded(appearingIndex index: Int) {
        let preloadThreshold = max(visiblePlaylists.count - 6, 0)
        guard index >= preloadThreshold else { return }
        guard visiblePlaylistCount < store.playlists.count, !isLoadingNextPlaylistPage else { return }

        isLoadingNextPlaylistPage = true
        visiblePlaylistCount = min(visiblePlaylistCount + playlistPageSize, store.playlists.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            isLoadingNextPlaylistPage = false
        }
    }

    private func deletePlaylist(_ playlist: MusicPlaylist) async {
        playlistPendingDelete = nil
        do {
            try await store.deletePlaylist(playlistId: playlist.id)
        } catch {
            playlistErrorMessage = error.localizedDescription
            isShowingPlaylistError = true
        }
    }
}

enum HomeRoute: Hashable {
    case playlist(String)
    case artist(String)
    case album(String)
    case audiobook(String)
    case folderLibrary

    var hidesRootBottomChrome: Bool {
        switch self {
        case .folderLibrary:
            return true
        case .playlist, .artist, .album, .audiobook:
            return false
        }
    }
}

private enum HomePlaylistRowLayout {
    static let cardCornerRadius: CGFloat = 18
    static let contextPreviewCornerRadius: CGFloat = 18
}

struct HomePlaylistRow: View {
    let playlist: MusicPlaylist
    let artworkURLs: [AuthenticatedURL]

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtworkGrid(artworkURLs: artworkURLs)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(playlist.displaySongCount) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.musicRed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct LongPressHomePlaylistRow: View {
    @Environment(AppStore.self) private var store
    @State private var rowWidth: CGFloat?

    let playlist: MusicPlaylist
    let open: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    private var artworkURLs: [AuthenticatedURL] {
        playlist.songs
            .prefix(4)
            .compactMap { store.imageURL(for: $0, size: 160) }
    }

    var body: some View {
        if playlist.isServerEditable {
            editablePlaylistButton
        } else {
            plainPlaylistButton
        }
    }

    private var editablePlaylistButton: some View {
        Button(action: open) {
            HomePlaylistRow(playlist: playlist, artworkURLs: artworkURLs)
        }
        .buttonStyle(.plain)
        .contentShape(.interaction, Rectangle())
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: HomePlaylistRowLayout.contextPreviewCornerRadius, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { newWidth in
            rowWidth = newWidth
        }
        .contextMenu {
            Button {
                edit()
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Button(role: .destructive) {
                delete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        } preview: {
            HomePlaylistRowContextPreview(playlist: playlist, artworkURLs: artworkURLs, width: rowWidth)
        }
    }

    private var plainPlaylistButton: some View {
        Button(action: open) {
            HomePlaylistRow(playlist: playlist, artworkURLs: artworkURLs)
        }
        .buttonStyle(.plain)
        .contentShape(.interaction, Rectangle())
    }
}

private struct HomePlaylistRowContextPreview: View {
    let playlist: MusicPlaylist
    let artworkURLs: [AuthenticatedURL]
    let width: CGFloat?

    var body: some View {
        HomePlaylistRow(playlist: playlist, artworkURLs: artworkURLs)
            .frame(width: width, alignment: .leading)
            .liquidGlassContextPreview(cornerRadius: HomePlaylistRowLayout.contextPreviewCornerRadius)
    }
}

private struct PlaylistEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    let playlist: MusicPlaylist

    @State private var name: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(playlist: MusicPlaylist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName != playlist.name && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("歌单名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        guard canSave else { return }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await store.renamePlaylist(playlistId: playlist.id, name: trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PlaylistDetailLoaderView: View {
    @Environment(AppStore.self) private var store
    let playlistID: String

    @State private var loadedSongs: [EmbyAudioItem]?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var playlist: MusicPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    private var title: String {
        playlist?.name ?? "歌单"
    }

    var body: some View {
        Group {
            if let loadedSongs {
                PaginatedSongListView(title: title, songs: loadedSongs)
            } else if let playlist, playlist.hasCompleteSongList {
                PaginatedSongListView(title: playlist.name, songs: playlist.songs)
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.musicPageBackground.ignoresSafeArea())
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            } else if let errorMessage {
                ContentUnavailableView("歌单加载失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .background(Color.musicPageBackground.ignoresSafeArea())
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("歌单不可用", systemImage: "music.note.list")
                    .background(Color.musicPageBackground.ignoresSafeArea())
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: playlistID) {
            await loadSongsIfNeeded()
        }
    }

    private func loadSongsIfNeeded() async {
        guard loadedSongs == nil,
              let playlist,
              !playlist.hasCompleteSongList else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            loadedSongs = try await store.loadPlaylistSongsIfNeeded(playlistId: playlistID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct PlaylistArtworkGrid: View {
    let artworkURLs: [AuthenticatedURL]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let tile = (min(size.width, size.height) - 2) / 2

            ZStack {
                ArtworkView(url: artworkURLs.first, cornerRadius: 12)

                if artworkURLs.count > 1 {
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            artworkTile(at: 0, size: tile)
                            artworkTile(at: 1, size: tile)
                        }
                        HStack(spacing: 2) {
                            artworkTile(at: 2, size: tile)
                            artworkTile(at: 3, size: tile)
                        }
                    }
                    .frame(width: tile * 2 + 2, height: tile * 2 + 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func artworkTile(at index: Int, size: CGFloat) -> some View {
        if artworkURLs.indices.contains(index) {
            ArtworkView(url: artworkURLs[index], cornerRadius: 3, showsPlaceholder: false)
                .frame(width: size, height: size)
        } else {
            Color.clear
                .frame(width: size, height: size)
        }
    }
}

struct BrowseView: View {
    @Environment(AppStore.self) private var store

    private var showsBrowseSkeleton: Bool {
        !store.hasBrowseContent && store.isLoadingContent
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if showsBrowseSkeleton {
                        BrowseSkeletonContent()
                    } else if !store.hasBrowseContent {
                        ContentUnavailableView("暂无发现内容", systemImage: "sparkles", description: Text(store.libraryStatus))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    } else {
                        if !store.dailyRecommendedSongs.isEmpty {
                            dailyRecommendationCard
                        }
                        if !store.recentlyAddedSongs.isEmpty {
                            RecentAddedSection()
                        }
                        if !store.mostPlayedSongs.isEmpty {
                            MostPlayedSection()
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 130)
            }
            .scrollContentBackground(.hidden)
            .background(Color.musicPageBackground.ignoresSafeArea())
            .mainPageToolbar("发现")
        }
    }

    private var dailyRecommendationCard: some View {
        let songs = store.dailyRecommendedSongs
        let title = songs.first?.name ?? "每日推荐"

        return ZStack(alignment: .topTrailing) {
            NavigationLink {
                SongListView(title: "每日推荐", songs: songs)
            } label: {
                dailyRecommendationContent(songs: songs, title: title)
            }
            .buttonStyle(.plain)

            Button {
                guard let song = songs.first else { return }
                store.play(song: song, in: songs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(songs.isEmpty)
            .padding(18)
        }
    }

    private func dailyRecommendationContent(songs: [EmbyAudioItem], title: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.10, blue: 0.18),
                    Color(red: 0.40, green: 0.09, blue: 0.20),
                    Color(red: 0.11, green: 0.10, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("每日推荐")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.70))
                    Text(title)
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    HStack(spacing: 8) {
                        Text("查看全部")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.16), in: Capsule())
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
                        ArtworkView(url: store.imageURL(for: song, size: 500), cornerRadius: 14)
                            .frame(width: 116, height: 116)
                            .rotationEffect(.degrees(Double(index - 1) * 7))
                            .offset(x: CGFloat(index) * -18, y: CGFloat(index - 1) * 18)
                            .shadow(color: .black.opacity(0.24), radius: 16, y: 9)
                    }
                }
                .frame(width: 134, height: 178)
            }
            .padding(24)
        }
        .frame(height: 226)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: Color.musicRed.opacity(0.22), radius: 24, y: 14)
    }
}

private struct LibraryCategoryCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(color, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct LibraryCategorySkeletonSection: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                LibraryCategorySkeletonCard()
            }
        }
    }
}

private struct LibraryCategorySkeletonCard: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(cornerRadius: 13)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(cornerRadius: 5)
                    .frame(width: 74, height: 15)
                SkeletonBlock(cornerRadius: 4)
                    .frame(width: 46, height: 11)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PlaylistSkeletonSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我的歌单")
                .font(.system(size: 24, weight: .bold))

            LazyVStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    PlaylistSkeletonRow()

                    if index < 4 {
                        Divider()
                            .padding(.leading, 90)
                    }
                }
            }
            .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PlaylistSkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(cornerRadius: 12)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 9) {
                SkeletonBlock(cornerRadius: 5)
                    .frame(width: 132, height: 15)
                SkeletonBlock(cornerRadius: 4)
                    .frame(width: 70, height: 11)
            }

            Spacer(minLength: 8)

            SkeletonBlock(cornerRadius: 6)
                .frame(width: 18, height: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct BrowseSkeletonContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            DailyRecommendationSkeletonCard()
            HorizontalMusicSkeletonSection()
            MostPlayedSkeletonSection()
        }
    }
}

private struct DailyRecommendationSkeletonCard: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.musicCardBackground)

            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(cornerRadius: 4)
                        .frame(width: 72, height: 12)
                    SkeletonBlock(cornerRadius: 8)
                        .frame(width: 178, height: 30)
                    SkeletonBlock(cornerRadius: 8)
                        .frame(width: 128, height: 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    SkeletonBlock(cornerRadius: 14)
                        .frame(width: 116, height: 116)
                        .rotationEffect(.degrees(-7))
                        .offset(x: 18, y: -18)
                    SkeletonBlock(cornerRadius: 14)
                        .frame(width: 116, height: 116)
                        .rotationEffect(.degrees(7))
                        .offset(x: -10, y: 18)
                }
                .frame(width: 134, height: 178)
            }
            .padding(24)
        }
        .frame(height: 226)
    }
}

private struct HorizontalMusicSkeletonSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBlock(cornerRadius: 7)
                .frame(width: 112, height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonBlock(cornerRadius: 6)
                                .frame(width: 138, height: 138)
                            SkeletonBlock(cornerRadius: 5)
                                .frame(width: 116, height: 14)
                            SkeletonBlock(cornerRadius: 4)
                                .frame(width: 82, height: 11)
                        }
                        .frame(width: 138, alignment: .leading)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

private struct MostPlayedSkeletonSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(cornerRadius: 7)
                .frame(width: 112, height: 24)

            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    PlaylistSkeletonRow()

                    if index < 4 {
                        Divider()
                            .padding(.leading, 90)
                    }
                }
            }
            .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct SkeletonBlock: View {
    let cornerRadius: CGFloat
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.13))
                .overlay {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.34),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .rotationEffect(.degrees(18))
                    .frame(width: max(proxy.size.width * 0.72, 24), height: proxy.size.height * 2.4)
                    .offset(x: isAnimating ? proxy.size.width * 1.2 : -proxy.size.width * 1.2)
                }
                .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

struct RecentAddedSection: View {
    @Environment(AppStore.self) private var store

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
                            store.play(song: song, in: store.recentlyAddedSongs)
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
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最常播放") {
                SongListView(title: "最常播放", songs: store.mostPlayedSongs)
            }

            SongRowsCard(songs: store.mostPlayedSongs, limit: 5)
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
    let imageURL: AuthenticatedURL?
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
