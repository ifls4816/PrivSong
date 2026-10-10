import SwiftUI

struct ArtistLibraryView: View {
    @Environment(AppStore.self) private var store
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
    @Environment(AppStore.self) private var store
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
    @Environment(AppStore.self) private var store
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
                // System inset-grouped sections instead of hand-drawn rounded rows and dividers;
                // rows are identified by id so state stays attached to the right item on refresh.
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                row(item)
                                    .listRowInsets(EdgeInsets())
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 84 }
                            }
                        } header: {
                            Text(section.title)
                        }
                        .sectionIndexLabel(section.title)
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionIndexVisibility(.visible)
            }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.large)
    }
}

private struct ArtistIndexRow: View {
    @Environment(AppStore.self) private var store
    let artist: MusicArtist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: artist.representativeSong.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 12)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(artist.songs.count) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.musicRed)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AlbumIndexRow: View {
    @Environment(AppStore.self) private var store
    let album: MusicAlbum

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: album.representativeSong.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 12)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.callout.weight(.semibold))
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
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.musicRed)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AudiobookIndexRow: View {
    @Environment(AppStore.self) private var store
    let audiobook: Audiobook

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: audiobook.representativeEpisode.flatMap { store.imageURL(for: $0, size: 160) }, cornerRadius: 12)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(audiobook.title)
                    .font(.callout.weight(.semibold))
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
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.musicRed)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MusicFolderLibraryView: View {
    @Environment(AppStore.self) private var store

    @State private var folders: [MusicFolder] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading, folders.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.musicPageBackground.ignoresSafeArea())
            } else if let errorMessage, folders.isEmpty {
                RealtimeLoadErrorView(
                    title: "文件夹加载失败",
                    systemImage: "exclamationmark.triangle",
                    message: errorMessage
                ) {
                    Task { await loadFolders() }
                }
            } else if folders.isEmpty {
                ContentUnavailableView("暂无文件夹", systemImage: "folder")
                    .background(Color.musicPageBackground.ignoresSafeArea())
            } else {
                folderList
            }
        }
        .navigationTitle("文件夹")
        .toolbarTitleDisplayMode(.large)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task {
            await loadFolders()
        }
    }

    private var folderList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                    NavigationLink {
                        MusicFolderSongSelectionView(folder: folder)
                    } label: {
                        MusicFolderRow(folder: folder)
                    }
                    .buttonStyle(.plain)

                    if index < folders.count - 1 {
                        Divider()
                            .padding(.leading, 90)
                    }
                }
            }
            .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.musicPageBackground.ignoresSafeArea())
        .refreshable {
            await loadFolders()
        }
    }

    private func loadFolders() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        do {
            folders = try await store.fetchRealtimeMusicFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MusicFolderRow: View {
    let folder: MusicFolder

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.musicRed.opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.musicRed)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(folder.songCount.map { "\($0) 首歌曲" } ?? "文件夹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.musicRed)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MusicFolderSongSelectionView: View {
    @Environment(AppStore.self) private var store
    let folder: MusicFolder

    @State private var songs: [EmbyAudioItem] = []
    @State private var selectedSongIds: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingPlaylistWriter = false
    @State private var successMessage: String?
    @State private var isShowingSuccess = false

    private var selectedSongs: [EmbyAudioItem] {
        songs.filter { selectedSongIds.contains($0.id) }
    }

    private var isAllSelected: Bool {
        !songs.isEmpty && selectedSongIds.count == songs.count
    }

    var body: some View {
        Group {
            if isLoading, songs.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.musicPageBackground.ignoresSafeArea())
            } else if let errorMessage, songs.isEmpty {
                RealtimeLoadErrorView(
                    title: "歌曲加载失败",
                    systemImage: "exclamationmark.triangle",
                    message: errorMessage
                ) {
                    Task { await loadSongs() }
                }
            } else if songs.isEmpty {
                ContentUnavailableView("暂无歌曲", systemImage: "music.note")
                    .background(Color.musicPageBackground.ignoresSafeArea())
            } else {
                songSelectionContent
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task {
            await loadSongs()
        }
        .sheet(isPresented: $isShowingPlaylistWriter) {
            RealtimePlaylistWriterSheet(selectedSongs: selectedSongs) { message in
                successMessage = message
                isShowingSuccess = true
                selectedSongIds = []
            }
            .environment(store)
        }
        .alert("写入完成", isPresented: $isShowingSuccess) {
            Button("好", role: .cancel) {}
        } message: {
            Text(successMessage ?? "")
        }
    }

    private var songSelectionContent: some View {
        ScrollView {
            SelectableSongRowsCard(songs: songs, selectedSongIds: $selectedSongIds)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
        .background(Color.musicPageBackground.ignoresSafeArea())
        .refreshable {
            await loadSongs()
        }
        // A system bottom toolbar (the tab bar is hidden here) gets Liquid Glass for free,
        // instead of a hand-built bar layering custom glass, fills and shadows.
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(isAllSelected ? "取消全选" : "全选") {
                    toggleAllSelected()
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Text("已选 \(selectedSongIds.count) 首")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("写入歌单") {
                    isShowingPlaylistWriter = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSongIds.isEmpty)
            }
        }
    }

    private func loadSongs() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        do {
            songs = try await store.fetchRealtimeFolderSongs(folderId: folder.id)
            selectedSongIds.formIntersection(Set(songs.map(\.id)))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleAllSelected() {
        selectedSongIds = isAllSelected ? [] : Set(songs.map(\.id))
    }
}

private struct SelectableSongRowsCard: View {
    @Environment(AppStore.self) private var store
    let songs: [EmbyAudioItem]
    @Binding var selectedSongIds: Set<String>

    var body: some View {
        let lastSongId = songs.last?.id

        LazyVStack(spacing: 0) {
            // Iterate the songs directly: re-enumerating the whole folder on every selection
            // toggle copied the array each time.
            ForEach(songs) { song in
                SelectableSongRow(
                    song: song,
                    imageURL: store.imageURL(for: song, size: 160),
                    isSelected: selectedSongIds.contains(song.id)
                ) {
                    toggle(song)
                }

                if song.id != lastSongId {
                    Divider()
                        .padding(.leading, 94)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.musicCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func toggle(_ song: EmbyAudioItem) {
        if selectedSongIds.contains(song.id) {
            selectedSongIds.remove(song.id)
        } else {
            selectedSongIds.insert(song.id)
        }
    }
}

private struct SelectableSongRow: View {
    let song: EmbyAudioItem
    let imageURL: AuthenticatedURL?
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.musicRed : .secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                ArtworkView(url: imageURL, cornerRadius: 5)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(song.artistLine)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct RealtimePlaylistWriterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store

    let selectedSongs: [EmbyAudioItem]
    let onCompleted: (String) -> Void

    @State private var writeMode: RealtimePlaylistWriteMode = .existing
    @State private var playlists: [MusicPlaylist] = []
    @State private var selectedPlaylistId: String?
    @State private var newPlaylistName = ""
    @State private var isLoadingPlaylists = false
    @State private var isSaving = false
    @State private var loadErrorMessage: String?
    @State private var saveErrorMessage: String?

    private var trimmedNewPlaylistName: String {
        newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var editablePlaylists: [MusicPlaylist] {
        playlists.filter(\.isServerEditable)
    }

    private var selectedPlaylist: MusicPlaylist? {
        editablePlaylists.first { $0.id == selectedPlaylistId }
    }

    private var canSave: Bool {
        guard !selectedSongs.isEmpty, !isSaving else { return false }
        switch writeMode {
        case .existing:
            return selectedPlaylist != nil
        case .create:
            return !trimmedNewPlaylistName.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("写入方式", selection: $writeMode) {
                        ForEach(RealtimePlaylistWriteMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if writeMode == .existing {
                    existingPlaylistSection
                } else {
                    newPlaylistSection
                }

                Section {
                    Text(writeMode == .existing
                         ? "将用 \(selectedSongs.count) 首歌曲覆盖目标歌单"
                         : "将用 \(selectedSongs.count) 首歌曲创建新歌单")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let saveErrorMessage {
                    Section {
                        Text(saveErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("写入歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(role: .confirm) {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .task {
                await loadPlaylists()
            }
        }
    }

    @ViewBuilder
    private var existingPlaylistSection: some View {
        Section("目标歌单") {
            if isLoadingPlaylists, playlists.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("加载中")
                        .foregroundStyle(.secondary)
                }
            } else if let loadErrorMessage, playlists.isEmpty {
                Text(loadErrorMessage)
                    .foregroundStyle(.red)
                Button("重新加载") {
                    Task { await loadPlaylists() }
                }
            } else if editablePlaylists.isEmpty {
                Text("暂无可写入歌单")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(editablePlaylists) { playlist in
                    Button {
                        selectedPlaylistId = playlist.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedPlaylistId == playlist.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedPlaylistId == playlist.id ? Color.musicRed : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Text("\(playlist.displaySongCount) 首歌曲")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var newPlaylistSection: some View {
        Section("新建歌单") {
            TextField("歌单名称", text: $newPlaylistName)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
        }
    }

    private func loadPlaylists() async {
        guard !isLoadingPlaylists else { return }

        isLoadingPlaylists = true
        loadErrorMessage = nil
        do {
            playlists = try await store.fetchRealtimePlaylistSummaries()
            if selectedPlaylistId == nil || !editablePlaylists.contains(where: { $0.id == selectedPlaylistId }) {
                selectedPlaylistId = editablePlaylists.first?.id
            }
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        isLoadingPlaylists = false
    }

    private func save() async {
        guard canSave else { return }

        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }

        do {
            switch writeMode {
            case .existing:
                guard let selectedPlaylist else { return }
                try await store.replaceRealtimePlaylist(playlistId: selectedPlaylist.id, songs: selectedSongs)
                onCompleted("已写入「\(selectedPlaylist.name)」")
            case .create:
                let playlist = try await store.createRealtimePlaylist(name: trimmedNewPlaylistName, songs: selectedSongs)
                onCompleted("已创建「\(playlist.name)」")
            }
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

private enum RealtimePlaylistWriteMode: String, CaseIterable, Identifiable {
    case existing
    case create

    var id: String { rawValue }

    var title: String {
        switch self {
        case .existing:
            return "覆盖现有"
        case .create:
            return "新建"
        }
    }
}

private struct RealtimeLoadErrorView: View {
    let title: String
    let systemImage: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.55))
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button("重新加载", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.musicPageBackground.ignoresSafeArea())
    }
}
