import Foundation
import Observation
import Security

/// Serializes snapshot writes and deletes off the main thread while keeping them in order.
private let persistenceQueue = DispatchQueue(label: "PrivSong.persistence", qos: .utility)

@MainActor
@Observable
final class AppStore {
    var session: EmbySession?
    /// Set through `applySongs(_:)` so derived data (albums, artists, index sections) is
    /// computed off the main thread and published together with the songs.
    private(set) var songs: [EmbyAudioItem] = []
    var searchResults: [EmbyAudioItem] = []
    var isLoading = false
    /// True while cached content is being read at launch, so pages show their skeletons
    /// instead of an empty "暂无资料库" state for that moment.
    private(set) var isRestoringCachedContent = false

    /// Whether content is on its way, from the cache or from Emby. Drives skeleton screens.
    var isLoadingContent: Bool {
        isLoading || isRestoringCachedContent
    }
    var isSearching = false
    private(set) var hasLoadedInitialContent = false
    var errorMessage: String?
    var favoriteErrorMessage: String?
    var libraryStatus = "Not connected"
    var favoriteSongIds: Set<String> = [] {
        didSet { refreshFavoriteSongs() }
    }
    private(set) var favoriteSongs: [EmbyAudioItem] = []
    /// Songs deleted from the server this session. Detail screens hold their own copies of song
    /// lists, so lists filter these out to drop a deleted row everywhere at once.
    private(set) var deletedSongIds: Set<String> = []
    var recentSongIds: [String] = []
    var cellularOnlineQuality: OnlinePlaybackQuality = .standard {
        didSet {
            UserDefaults.standard.set(cellularOnlineQuality.rawValue, forKey: cellularOnlineQualityKey)
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
        }
    }
    var wifiOnlineQuality: OnlinePlaybackQuality = .lossless {
        didSet {
            UserDefaults.standard.set(wifiOnlineQuality.rawValue, forKey: wifiOnlineQualityKey)
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
        }
    }
    var startsOnBrowse = false {
        didSet { UserDefaults.standard.set(startsOnBrowse, forKey: startsOnBrowseKey) }
    }
    var keepsScreenAwakeOnPlayerPage = false {
        didSet { UserDefaults.standard.set(keepsScreenAwakeOnPlayerPage, forKey: keepsScreenAwakeKey) }
    }
    var audioCacheLimit: AudioCacheLimit = .defaultValue {
        didSet {
            UserDefaults.standard.set(audioCacheLimit.rawValue, forKey: audioCacheLimitKey)
            PlaybackAudioCache.setLimit(audioCacheLimit)
            if audioCacheLimit == .off {
                player?.cancelAudioCaching()
            }
            Task {
                await Task.detached(priority: .utility) {
                    PlaybackAudioCache.trimToLimit()
                }.value
                await refreshCacheUsage()
            }
        }
    }
    private(set) var cacheUsageBytes: Int64?
    private(set) var isClearingCache = false

    // Cached derived data — recomputed only when source media changes
    private(set) var albums: [MusicAlbum] = []
    private(set) var artists: [MusicArtist] = []
    private(set) var albumSections: [IndexedSection<MusicAlbum>] = []
    private(set) var artistSections: [IndexedSection<MusicArtist>] = []
    private(set) var playlists: [MusicPlaylist] = []
    /// Set through `applyAudiobookEpisodes(_:)` so grouping and indexing run off the main thread.
    private(set) var audiobookEpisodes: [EmbyAudioItem] = []
    private(set) var audiobooks: [Audiobook] = []
    private(set) var audiobookSections: [IndexedSection<Audiobook>] = []
    private(set) var audiobookProgress: [String: AudiobookPlaybackProgress] = [:]
    private(set) var recentSongs: [EmbyAudioItem] = []
    private(set) var serverFavoriteSongs: [EmbyAudioItem] = [] {
        didSet { refreshFavoriteSongs() }
    }
    private(set) var dailyRecommendedSongs: [EmbyAudioItem] = []
    private(set) var recentlyAddedSongs: [EmbyAudioItem] = []
    private(set) var mostPlayedSongs: [EmbyAudioItem] = []

    private let client = EmbyClient()
    private let snapshotStore = LibrarySnapshotStore()
    private let initialHomeSnapshotStore = InitialHomeContentSnapshotStore()
    private let audiobookProgressStore = AudiobookProgressStore()
    private let sessionTokenStore = KeychainSessionTokenStore()
    private let sessionKey = "EmbySession"
    private let favoritesKey = "FavoriteSongIds"
    private let recentKey = "RecentSongIds"
    private let cellularOnlineQualityKey = "CellularOnlinePlaybackQuality"
    private let wifiOnlineQualityKey = "WiFiOnlinePlaybackQuality"
    private let startsOnBrowseKey = "StartsOnBrowse"
    private let keepsScreenAwakeKey = "KeepsScreenAwakeOnPlayerPage"
    private let highRefreshRateKey = "PrefersHighRefreshRate"
    private let audioCacheLimitKey = "AudioCacheLimitMB"
    private let searchResultLimit = 100
    @ObservationIgnored private var activeSearchToken: UUID?
    @ObservationIgnored private var libraryCacheSavedAt: Date?
    @ObservationIgnored private var dailyRecommendationDay: Int?
    private var audiobookEpisodeBookIds: [String: String] = [:]
    @ObservationIgnored private var pendingFavoriteSongIds: Set<String> = []
    @ObservationIgnored private var songsById: [String: EmbyAudioItem] = [:]
    @ObservationIgnored private var derivedDataGeneration = 0
    @ObservationIgnored private var audiobookDataGeneration = 0
    /// Latest position of the audiobook episode that is playing. Ignored by observation so the
    /// periodic progress reports don't re-render the views that show audiobook progress.
    @ObservationIgnored private var liveAudiobookProgress: (episodeId: String, progress: AudiobookPlaybackProgress)?
    @ObservationIgnored private var lastAudiobookProgressPublish = Date.distantPast

    @ObservationIgnored weak var player: PlayerController? {
        didSet {
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
            player?.setSession(session)
            player?.onPlaybackPositionChanged = { [weak self] item, position, duration, isFinished, isCheckpoint in
                self?.recordAudiobookPlayback(
                    item: item,
                    position: position,
                    duration: duration,
                    isFinished: isFinished,
                    isCheckpoint: isCheckpoint
                )
            }
        }
    }

    var lastPlayedSong: EmbyAudioItem? {
        recentSongs.first
    }

    var hasHomeContent: Bool {
        !songs.isEmpty || !playlists.isEmpty || !audiobooks.isEmpty
    }

    var hasLibraryCategoryContent: Bool {
        !songs.isEmpty || !audiobooks.isEmpty
    }

    var hasBrowseContent: Bool {
        !dailyRecommendedSongs.isEmpty || !recentlyAddedSongs.isEmpty || !mostPlayedSongs.isEmpty
    }

    /// Rebuilds `favoriteSongs`. Stored rather than computed because the home page reads it on
    /// every render and computing it scans the whole library.
    private func refreshFavoriteSongs() {
        var seen = Set<String>()
        var merged: [EmbyAudioItem] = []

        for song in songs where favoriteSongIds.contains(song.id) && !song.isAudiobookAudio {
            guard seen.insert(song.id).inserted else { continue }
            merged.append(song)
        }

        for song in serverFavoriteSongs where favoriteSongIds.contains(song.id) && !song.isAudiobookAudio {
            guard seen.insert(song.id).inserted else { continue }
            merged.append(song)
        }

        if merged != favoriteSongs {
            favoriteSongs = merged
        }
    }

    var playbackQualityPreferences: PlaybackQualityPreferences {
        PlaybackQualityPreferences(
            cellularQuality: cellularOnlineQuality,
            wifiQuality: wifiOnlineQuality
        )
    }

    var playbackQualitySummary: String {
        "\(cellularOnlineQuality.title) / \(wifiOnlineQuality.title)"
    }

    var localizedLibraryStatus: String {
        if libraryStatus == "Not connected" {
            return "未连接"
        }
        if libraryStatus == "Connected, but Emby returned 0 audio items." {
            return "已连接，但 Emby 未返回音频内容"
        }
        if let counts = loadedCounts(
            from: libraryStatus,
            middle: " songs and ",
            suffix: " audiobooks."
        ) {
            return "已加载 \(counts.left) 首歌曲和 \(counts.right) 本有声书"
        }
        if let counts = loadedCounts(
            from: libraryStatus,
            middle: " songs and ",
            suffix: " audiobooks from cache."
        ) {
            return "已从缓存加载 \(counts.left) 首歌曲和 \(counts.right) 本有声书"
        }
        if let count = loadedSongCount(from: libraryStatus, suffix: " songs.") {
            return "已加载 \(count) 首歌曲"
        }
        if let count = loadedSongCount(from: libraryStatus, suffix: " songs from cache.") {
            return "已从缓存加载 \(count) 首歌曲"
        }
        if let count = loadedSongCount(from: libraryStatus, suffix: " audiobooks.") {
            return "已加载 \(count) 本有声书"
        }
        if let count = loadedSongCount(from: libraryStatus, suffix: " audiobooks from cache.") {
            return "已从缓存加载 \(count) 本有声书"
        }
        return libraryStatus
    }

    func play(
        song: EmbyAudioItem,
        in songs: [EmbyAudioItem],
        startPosition: TimeInterval = 0,
        durationOverride: TimeInterval? = nil,
        shuffle: Bool? = nil
    ) {
        guard let session else { return }
        registerPlayback(song: song)
        player?.play(
            song: song,
            in: songs,
            session: session,
            startPosition: startPosition,
            durationOverride: durationOverride,
            shuffle: shuffle
        )
    }

    func playAudiobook(_ audiobook: Audiobook) {
        guard let target = audiobookResumeTarget(for: audiobook) else { return }
        play(
            song: target.episode,
            in: audiobook.episodes,
            startPosition: target.position,
            durationOverride: target.duration,
            shuffle: false
        )
    }

    func restartAudiobook(_ audiobook: Audiobook) {
        guard let firstEpisode = audiobook.episodes.first else { return }
        play(song: firstEpisode, in: audiobook.episodes, startPosition: 0)
    }

    func playAudiobookEpisode(_ episode: EmbyAudioItem, in audiobook: Audiobook) {
        let position = audiobookResumePosition(for: episode)
        play(
            song: episode,
            in: audiobook.episodes,
            startPosition: position,
            durationOverride: audiobookResumeDuration(for: episode)
        )
    }

    func playNext(_ song: EmbyAudioItem) {
        player?.playNext(song)
    }

    func addToQueueEnd(_ song: EmbyAudioItem) {
        player?.addToQueueEnd(song)
    }

    init() {
        restoreLocalState()
        restoreSession()
        Task.detached(priority: .utility) {
            DiskCacheMaintenance.removeOrphanedFiles()
            PlaybackAudioCache.trimToLimit()
            ArtworkDiskCache.trimToLimit()
        }
    }

    func signIn(server: String, username: String, password: String) async {
        await perform {
            let session = try await client.authenticate(server: server, username: username, password: password)
            self.session = session
            self.player?.setSession(session)
            self.persist(session)
            try await self.fetchAndApplyInitialHomeContent(session: session)
        }

        if session != nil {
            Task {
                await refreshLibrary()
            }
        }
    }

    private func fetchAndApplyInitialHomeContent(session: EmbySession) async throws {
        let content = try await client.fetchInitialHomeContent(session: session)
        guard self.session == session else { return }
        await applyInitialHomeContent(content)
        await refreshFavoritesFromServer(session: session)
    }

    private func loadInitialHomeContent(session: EmbySession) async {
        await perform {
            try await self.fetchAndApplyInitialHomeContent(session: session)
        }
    }

    private func applyInitialHomeContent(
        _ content: InitialHomeContent,
        savedAt: Date = Date(),
        savesSnapshot: Bool = true
    ) async {
        // Group audiobooks first so all home content is published together.
        guard await applyAudiobookEpisodes(content.audiobookEpisodes) else { return }
        playlists = content.playlists
        recentlyAddedSongs = content.recentlyAddedSongs
        mostPlayedSongs = content.mostPlayedSongs

        let day = currentRecommendationDay()
        let dailySeed = firstNonEmptySongList(
            content.dailySeedSongs,
            content.recentlyAddedSongs,
            content.mostPlayedSongs
        )
        dailyRecommendationDay = day
        dailyRecommendedSongs = DerivedLibraryData.dailyRecommendation(from: dailySeed, day: day, limit: 50)
        hasLoadedInitialContent = true
        libraryStatus = "Loaded home content."

        if savesSnapshot {
            let store = initialHomeSnapshotStore
            persistenceQueue.async {
                store.save(content)
            }
        }
    }

    private func firstNonEmptySongList(_ candidates: [EmbyAudioItem]...) -> [EmbyAudioItem] {
        candidates.first { !$0.isEmpty } ?? []
    }

    func loadPlaylistSongsIfNeeded(playlistId: String) async throws -> [EmbyAudioItem] {
        guard let session,
              let index = playlists.firstIndex(where: { $0.id == playlistId }) else {
            return []
        }

        let playlist = playlists[index]
        guard !playlist.hasCompleteSongList else {
            return playlist.songs
        }

        let songs = try await client.fetchPlaylistSongs(playlistId: playlistId, session: session)
        let updatedPlaylist = MusicPlaylist(
            id: playlist.id,
            name: playlist.name,
            description: "\(songs.count) 首歌曲",
            songs: songs,
            songCount: songs.count
        )
        var updatedPlaylists = playlists
        updatedPlaylists[index] = updatedPlaylist
        playlists = updatedPlaylists
        return songs
    }

    func fetchRealtimeMusicFolders() async throws -> [MusicFolder] {
        guard let session else { return [] }
        return try await client.fetchMusicFolders(session: session)
    }

    func fetchRealtimeFolderSongs(folderId: String) async throws -> [EmbyAudioItem] {
        guard let session else { return [] }
        return try await client.fetchFolderSongs(folderId: folderId, session: session)
    }

    func fetchRealtimePlaylistSummaries() async throws -> [MusicPlaylist] {
        guard let session else { return [] }
        return try await client.fetchPlaylistSummaries(session: session)
    }

    func createRealtimePlaylist(name: String, songs: [EmbyAudioItem]) async throws -> MusicPlaylist {
        guard let session else { throw EmbyError.invalidResponse }
        let playlist = try await client.createPlaylist(name: name, songs: songs, session: session)
        try await refreshPlaylistsFromServer(session: session)
        return playlist
    }

    func replaceRealtimePlaylist(playlistId: String, songs: [EmbyAudioItem]) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        try await client.replacePlaylistSongs(playlistId: playlistId, songs: songs, session: session)
        try await refreshPlaylistsFromServer(session: session, updatedPlaylistId: playlistId, updatedSongs: songs)
    }

    func deletePlaylist(playlistId: String) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        try await client.deletePlaylist(playlistId: playlistId, session: session)
        try await refreshPlaylistsFromServer(session: session)
    }

    func renamePlaylist(playlistId: String, name: String) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        try await client.renamePlaylist(playlistId: playlistId, name: name, session: session)
        try await refreshPlaylistsFromServer(session: session)
    }

    /// Deletes the song on the Emby server — its audio file is removed from disk — and then
    /// drops it from everything held locally. Irreversible.
    func deleteSong(_ song: EmbyAudioItem) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        try await client.deleteSong(itemId: song.id, session: session)

        let id = song.id
        deletedSongIds.insert(id)
        player?.removeDeletedSong(song)

        playlists = playlists.map { playlist in
            guard playlist.songs.contains(where: { $0.id == id }) else { return playlist }
            let remaining = playlist.songs.filter { $0.id != id }
            let count = playlist.songCount.map { max($0 - 1, 0) }
            return MusicPlaylist(
                id: playlist.id,
                name: playlist.name,
                description: "\(count ?? remaining.count) 首歌曲",
                songs: remaining,
                songCount: count
            )
        }
        searchResults.removeAll { $0.id == id }
        mostPlayedSongs.removeAll { $0.id == id }
        serverFavoriteSongs.removeAll { $0.id == id }
        if favoriteSongIds.contains(id) {
            favoriteSongIds.remove(id)
            persistFavoriteSongIds()
        }
        if recentSongIds.contains(id) {
            recentSongIds.removeAll { $0 == id }
            UserDefaults.standard.set(recentSongIds, forKey: recentKey)
        }

        if songs.contains(where: { $0.id == id }) {
            // Rebuilds albums, artists, recommendations and recents without the song.
            await applySongs(songs.filter { $0.id != id })
        } else {
            dailyRecommendedSongs.removeAll { $0.id == id }
            recentlyAddedSongs.removeAll { $0.id == id }
            refreshRecentSongs()
        }
        saveLibrarySnapshot()
    }

    func refreshAudiobookProgress(for audiobook: Audiobook) async {
        guard let session else { return }
        let episodeIds = audiobook.episodes.map(\.id)
        guard !episodeIds.isEmpty else { return }

        do {
            let refreshedEpisodes = try await client.fetchItems(itemIds: episodeIds, session: session)
            mergeServerAudiobookProgress(
                from: refreshedEpisodes,
                updatesExisting: true,
                refreshedAt: Date()
            )
        } catch is CancellationError {
        } catch {
            print("[AppStore] Failed to refresh audiobook progress: \(error.localizedDescription)")
        }
    }

    private func applyFullLibrary(
        songs: [EmbyAudioItem],
        playlists: [MusicPlaylist],
        audiobookEpisodes: [EmbyAudioItem],
        mostPlayedSongs: [EmbyAudioItem]? = nil
    ) async -> Bool {
        guard await applySongs(songs),
              await applyAudiobookEpisodes(audiobookEpisodes) else { return false }
        self.playlists = playlists.isEmpty ? songs.generatedPlaylists : playlists
        if let mostPlayedSongs {
            self.mostPlayedSongs = mostPlayedSongs
        }
        self.hasLoadedInitialContent = true
        self.libraryCacheSavedAt = Date()
        self.saveLibrarySnapshot()
        self.updateLibraryStatus()
        return true
    }

    private func fetchAndApplyFullLibrary(session: EmbySession) async throws {
        async let songs = client.fetchSongs(session: session)
        async let playlists = client.fetchPlaylistSummaries(session: session)
        async let audiobookEpisodes = client.fetchAudiobookEpisodes(session: session)
        async let mostPlayedSongs = client.fetchMostPlayedSongs(session: session, limit: 50)

        let loadedSongs = try await songs
        let loadedPlaylists = (try? await playlists) ?? []
        let loadedAudiobookEpisodes = (try? await audiobookEpisodes) ?? []
        let loadedMostPlayedSongs = (try? await mostPlayedSongs) ?? self.mostPlayedSongs
        let mergedPlaylists = await playlistsKeepingLoadedSongs(loadedPlaylists, session: session)

        // Signed out or switched servers while this refresh was in flight.
        guard self.session == session else { return }
        let applied = await applyFullLibrary(
            songs: loadedSongs,
            playlists: mergedPlaylists,
            audiobookEpisodes: loadedAudiobookEpisodes,
            mostPlayedSongs: loadedMostPlayedSongs
        )
        guard applied, self.session == session else { return }
        await refreshFavoritesFromServer(session: session)
    }

    /// Playlist summaries come without songs. Reuse songs already loaded for playlists whose
    /// track count is unchanged, and fetch a few cover songs for the rest, instead of
    /// downloading every playlist's full track list on each refresh.
    private func playlistsKeepingLoadedSongs(
        _ summaries: [MusicPlaylist],
        session: EmbySession,
        discardingSongsOf editedPlaylistId: String? = nil
    ) async -> [MusicPlaylist] {
        let existingById = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = summaries.map { summary -> MusicPlaylist in
            // An edited playlist can keep its track count while its contents changed.
            guard summary.id != editedPlaylistId,
                  let existing = existingById[summary.id],
                  !existing.songs.isEmpty,
                  existing.songs.count == summary.songCount else {
                return summary
            }
            return MusicPlaylist(
                id: summary.id,
                name: summary.name,
                description: summary.description,
                songs: existing.songs,
                songCount: summary.songCount
            )
        }

        let idsNeedingCovers = merged
            .filter { $0.songs.isEmpty && $0.displaySongCount > 0 }
            .map(\.id)
        guard !idsNeedingCovers.isEmpty else { return merged }

        let covers = await client.fetchPlaylistCoverSongs(playlistIds: idsNeedingCovers, session: session)
        merged = merged.map { playlist in
            guard playlist.songs.isEmpty, let coverSongs = covers[playlist.id], !coverSongs.isEmpty else {
                return playlist
            }
            return MusicPlaylist(
                id: playlist.id,
                name: playlist.name,
                description: playlist.description,
                songs: coverSongs,
                songCount: playlist.songCount
            )
        }
        return merged
    }

    func refreshLibrary() async {
        guard let session else { return }
        await perform {
            try await self.fetchAndApplyFullLibrary(session: session)
        }
    }

    private func refreshPlaylistsFromServer(
        session: EmbySession,
        updatedPlaylistId: String? = nil,
        updatedSongs: [EmbyAudioItem]? = nil
    ) async throws {
        let summaries = try await client.fetchPlaylistSummaries(session: session)
        var refreshedPlaylists = await playlistsKeepingLoadedSongs(
            summaries,
            session: session,
            discardingSongsOf: updatedPlaylistId
        )
        if let updatedPlaylistId, let updatedSongs,
           let index = refreshedPlaylists.firstIndex(where: { $0.id == updatedPlaylistId }) {
            let playlist = refreshedPlaylists[index]
            refreshedPlaylists[index] = MusicPlaylist(
                id: playlist.id,
                name: playlist.name,
                description: "\(updatedSongs.count) 首歌曲",
                songs: updatedSongs,
                songCount: updatedSongs.count
            )
        }
        playlists = refreshedPlaylists.isEmpty ? songs.generatedPlaylists : refreshedPlaylists
        saveLibrarySnapshot()
        updateLibraryStatus()
    }

    private func refreshFavoritesFromServer(session: EmbySession) async {
        do {
            let favoriteSongs = try await client.fetchFavoriteSongs(session: session)
            applyServerFavoriteSongs(favoriteSongs)
        } catch is CancellationError {
        } catch {
            print("[AppStore] Failed to refresh favorite songs: \(error.localizedDescription)")
        }
    }

    private func refreshFavoritesFromServer() async {
        guard let session else { return }
        await refreshFavoritesFromServer(session: session)
    }

    private func applyServerFavoriteSongs(_ songs: [EmbyAudioItem]) {
        var seen = Set<String>()
        let musicFavorites = songs.filter { song in
            song.isAudio && !song.isAudiobookAudio && seen.insert(song.id).inserted
        }
        serverFavoriteSongs = musicFavorites
        favoriteSongIds = Set(musicFavorites.map(\.id))
        persistFavoriteSongIds()
    }

    func search(_ term: String) async {
        guard let session else {
            searchResults = []
            return
        }
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            activeSearchToken = nil
            isSearching = false
            searchResults = []
            return
        }

        let token = UUID()
        activeSearchToken = token
        isSearching = true

        do {
            let serverMatches = try await client.searchSongs(
                session: session,
                searchTerm: normalized,
                limit: searchResultLimit
            )
            guard activeSearchToken == token, !Task.isCancelled else { return }

            // Emby's SearchTerm only matches song titles; album and artist matches come from
            // the library already in memory instead of extra server round trips.
            let library = songs
            let limit = searchResultLimit
            let results = await Task.detached(priority: .userInitiated) {
                var seen = Set(serverMatches.map(\.id))
                var merged = serverMatches
                for song in library {
                    if merged.count >= limit { break }
                    guard !song.isAudiobookAudio,
                          song.matchesSearch(normalized),
                          seen.insert(song.id).inserted else { continue }
                    merged.append(song)
                }
                return merged
            }.value
            guard activeSearchToken == token, !Task.isCancelled else { return }
            searchResults = results
        } catch is CancellationError {
            // A newer search superseded this request.
        } catch {
            if activeSearchToken == token {
                errorMessage = error.localizedDescription
            }
        }

        if activeSearchToken == token {
            isSearching = false
            activeSearchToken = nil
        }
    }

    func imageURL(for song: EmbyAudioItem, size: Int = 600) -> AuthenticatedURL? {
        guard let session else { return nil }
        return client.imageURL(for: song, session: session, size: size)
    }

    func currentEpisodeIndex(for audiobook: Audiobook) -> Int? {
        if let currentSong = player?.currentSong,
           let index = audiobook.episodes.firstIndex(where: { $0.id == currentSong.id }) {
            return index
        }

        return latestRecordedEpisodeIndex(for: audiobook)
    }

    func audiobookListSubtitle(for audiobook: Audiobook) -> String {
        if let index = currentEpisodeIndex(for: audiobook) {
            return "听到第 \(index + 1)/\(audiobook.episodeCount) 集"
        }
        return "\(audiobook.episodeCount) 集"
    }

    func audiobookProgressText(for episode: EmbyAudioItem) -> String? {
        guard let progress = audiobookMergedProgress(for: episode) else { return nil }
        if progress.isFinished {
            return "已听完"
        }
        guard progress.position > 5 else { return nil }
        return "上次 \(progress.position.musicDurationText)"
    }

    func registerPlayback(song: EmbyAudioItem) {
        recentSongIds.removeAll { $0 == song.id }
        recentSongIds.insert(song.id, at: 0)
        recentSongIds = Array(recentSongIds.prefix(50))
        UserDefaults.standard.set(recentSongIds, forKey: recentKey)
        refreshRecentSongs()
    }

    func isFavorite(_ song: EmbyAudioItem) -> Bool {
        favoriteSongIds.contains(song.id)
    }

    func toggleFavorite(_ song: EmbyAudioItem) {
        guard !pendingFavoriteSongIds.contains(song.id) else { return }

        favoriteErrorMessage = nil
        let shouldFavorite = !favoriteSongIds.contains(song.id)
        let previousServerSong = serverFavoriteSongs.first { $0.id == song.id }
        pendingFavoriteSongIds.insert(song.id)
        applyFavorite(song: song, isFavorite: shouldFavorite)

        Task {
            guard let session else {
                rollbackFavorite(song: song, previousServerSong: previousServerSong, wasFavorite: !shouldFavorite)
                favoriteErrorMessage = "收藏同步失败：未连接到 Emby"
                return
            }

            do {
                try await client.setFavorite(itemId: song.id, isFavorite: shouldFavorite, session: session)
                pendingFavoriteSongIds.remove(song.id)
            } catch is CancellationError {
                pendingFavoriteSongIds.remove(song.id)
            } catch {
                rollbackFavorite(song: song, previousServerSong: previousServerSong, wasFavorite: !shouldFavorite)
                favoriteErrorMessage = "收藏同步失败：\(error.localizedDescription)"
            }
        }
    }

    private func applyFavorite(song: EmbyAudioItem, isFavorite: Bool) {
        if isFavorite {
            favoriteSongIds.insert(song.id)
            if !song.isAudiobookAudio,
               !serverFavoriteSongs.contains(where: { $0.id == song.id }) {
                serverFavoriteSongs.append(song)
            }
        } else {
            favoriteSongIds.remove(song.id)
            serverFavoriteSongs.removeAll { $0.id == song.id }
        }
        persistFavoriteSongIds()
    }

    private func rollbackFavorite(
        song: EmbyAudioItem,
        previousServerSong: EmbyAudioItem?,
        wasFavorite: Bool
    ) {
        pendingFavoriteSongIds.remove(song.id)
        if wasFavorite {
            favoriteSongIds.insert(song.id)
            if !song.isAudiobookAudio,
               !serverFavoriteSongs.contains(where: { $0.id == song.id }) {
                serverFavoriteSongs.append(previousServerSong ?? song)
            }
        } else {
            favoriteSongIds.remove(song.id)
            serverFavoriteSongs.removeAll { $0.id == song.id }
        }
        persistFavoriteSongIds()
    }

    private func audiobookResumeTarget(
        for audiobook: Audiobook
    ) -> (episode: EmbyAudioItem, position: TimeInterval, duration: TimeInterval?)? {
        let episodes = audiobook.episodes
        guard !episodes.isEmpty else { return nil }

        let entries = audiobookProgressEntries(for: audiobook)
        if let active = entries
            .filter({ !$0.progress.isFinished })
            .max(by: { $0.progress.updatedAt < $1.progress.updatedAt }) {
            let episode = episodes[active.index]
            return (
                episode,
                audiobookResumePosition(for: episode),
                audiobookResumeDuration(for: episode)
            )
        }

        if let lastFinishedIndex = entries
            .filter({ $0.progress.isFinished })
            .map(\.index)
            .max(),
           episodes.indices.contains(lastFinishedIndex + 1) {
            return (episodes[lastFinishedIndex + 1], 0, nil)
        }

        return (episodes[0], 0, nil)
    }

    private func latestRecordedEpisodeIndex(for audiobook: Audiobook) -> Int? {
        let entries = audiobookProgressEntries(for: audiobook)
        if let active = entries
            .filter({ !$0.progress.isFinished })
            .max(by: { $0.progress.updatedAt < $1.progress.updatedAt }) {
            return active.index
        }

        if let lastFinishedIndex = entries
            .filter({ $0.progress.isFinished })
            .map(\.index)
            .max() {
            return min(lastFinishedIndex + 1, max(audiobook.episodeCount - 1, 0))
        }

        return nil
    }

    private func audiobookProgressEntries(
        for audiobook: Audiobook
    ) -> [(index: Int, progress: AudiobookPlaybackProgress)] {
        audiobook.episodes.enumerated().compactMap { index, episode in
            guard let progress = audiobookMergedProgress(for: episode) else { return nil }
            return (index, progress)
        }
    }

    private func audiobookResumePosition(for episode: EmbyAudioItem) -> TimeInterval {
        guard let progress = audiobookMergedProgress(for: episode),
              !progress.isFinished else {
            return 0
        }

        let duration = max(progress.duration, episode.duration)
        guard progress.position > 5 else { return 0 }
        if duration > progress.position,
           progress.position >= max(duration - 30, duration * 0.98) {
            return 0
        }
        return max(0, duration > progress.position ? min(progress.position, duration) : progress.position)
    }

    private func audiobookResumeDuration(for episode: EmbyAudioItem) -> TimeInterval? {
        guard let progress = audiobookMergedProgress(for: episode),
              !progress.isFinished else { return nil }

        let duration = max(progress.duration, episode.duration)
        return duration > progress.position ? duration : nil
    }

    private func audiobookMergedProgress(for episode: EmbyAudioItem) -> AudiobookPlaybackProgress? {
        if let liveAudiobookProgress, liveAudiobookProgress.episodeId == episode.id {
            return liveAudiobookProgress.progress
        }
        if let localProgress = audiobookProgress[episode.id] {
            return localProgress
        }

        let serverPosition = episode.userData?.playbackPosition ?? 0
        let serverPlayed = episode.userData?.played == true
        guard serverPosition > 1 || serverPlayed else { return nil }

        let duration = episode.duration
        return AudiobookPlaybackProgress(
            position: serverPlayed ? duration : serverPosition,
            duration: duration,
            updatedAt: .distantPast,
            isFinished: serverPlayed
        )
    }

    private func recordAudiobookPlayback(
        item: EmbyAudioItem,
        position: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool,
        isCheckpoint: Bool
    ) {
        guard audiobookEpisodeBookIds[item.id] != nil else { return }

        let effectiveDuration = max(duration, item.duration)
        let clampedPosition = max(0, min(position, effectiveDuration > 0 ? effectiveDuration : position))
        let finished = isFinished ||
            (effectiveDuration > 0 && clampedPosition >= max(effectiveDuration - 10, effectiveDuration * 0.98))
        let progress = AudiobookPlaybackProgress(
            position: finished ? effectiveDuration : clampedPosition,
            duration: effectiveDuration,
            updatedAt: Date(),
            isFinished: finished
        )

        if let previous = liveAudiobookProgress, previous.episodeId != item.id {
            // Switched episodes: make sure the previous one's latest position is published.
            commitAudiobookProgress(previous.progress, for: previous.episodeId)
        }
        liveAudiobookProgress = (item.id, progress)

        let now = Date()
        guard isCheckpoint || finished || now.timeIntervalSince(lastAudiobookProgressPublish) >= 30 else {
            return
        }
        commitAudiobookProgress(progress, for: item.id)
    }

    /// Publishes and persists progress. Called on pause, seek, stop, episode change, finish,
    /// and at most every 30 s otherwise.
    private func commitAudiobookProgress(_ progress: AudiobookPlaybackProgress, for episodeId: String) {
        lastAudiobookProgressPublish = Date()
        // Once committed, the stored entry is authoritative; a lingering live value would
        // otherwise shadow later server updates for this episode.
        if liveAudiobookProgress?.episodeId == episodeId {
            liveAudiobookProgress = nil
        }
        guard audiobookProgress[episodeId] != progress else { return }
        var updatedProgress = audiobookProgress
        updatedProgress[episodeId] = progress
        audiobookProgress = updatedProgress
        saveAudiobookProgress()
    }

    private func mergeServerAudiobookProgress(from episodes: [EmbyAudioItem]) {
        mergeServerAudiobookProgress(from: episodes, updatesExisting: false, refreshedAt: nil)
    }

    private func mergeServerAudiobookProgress(
        from episodes: [EmbyAudioItem],
        updatesExisting: Bool,
        refreshedAt: Date?
    ) {
        var updatedProgress = audiobookProgress
        var hasChanges = false
        let currentSongId = player?.currentSong?.id

        for episode in episodes {
            guard let serverProgress = serverAudiobookProgress(for: episode, refreshedAt: refreshedAt) else {
                continue
            }
            if let existingProgress = updatedProgress[episode.id] {
                guard updatesExisting,
                      episode.id != currentSongId,
                      shouldReplaceAudiobookProgress(existingProgress, with: serverProgress) else {
                    continue
                }
            }
            guard updatedProgress[episode.id] != serverProgress else { continue }

            updatedProgress[episode.id] = serverProgress
            if liveAudiobookProgress?.episodeId == episode.id {
                liveAudiobookProgress = nil
            }
            hasChanges = true
        }

        guard hasChanges else { return }
        audiobookProgress = updatedProgress
        saveAudiobookProgress()
    }

    private func serverAudiobookProgress(
        for episode: EmbyAudioItem,
        refreshedAt: Date?
    ) -> AudiobookPlaybackProgress? {
        let serverPosition = episode.userData?.playbackPosition ?? 0
        let serverPlayed = episode.userData?.played == true
        guard serverPosition > 1 || serverPlayed else { return nil }

        return AudiobookPlaybackProgress(
            position: serverPlayed ? episode.duration : serverPosition,
            duration: episode.duration,
            updatedAt: refreshedAt ?? episode.userData?.lastPlayedDate ?? .distantPast,
            isFinished: serverPlayed
        )
    }

    private func shouldReplaceAudiobookProgress(
        _ existingProgress: AudiobookPlaybackProgress,
        with serverProgress: AudiobookPlaybackProgress
    ) -> Bool {
        if existingProgress.updatedAt == .distantPast {
            return true
        }
        if serverProgress.isFinished, !existingProgress.isFinished {
            return true
        }
        return serverProgress.updatedAt >= existingProgress.updatedAt
    }

    private func saveAudiobookProgress() {
        let store = audiobookProgressStore
        let progress = audiobookProgress
        persistenceQueue.async {
            store.save(progress)
        }
    }

    /// Writes the in-flight audiobook position, e.g. when the app moves to the background.
    func flushAudiobookProgress() {
        guard let liveAudiobookProgress else { return }
        commitAudiobookProgress(liveAudiobookProgress.progress, for: liveAudiobookProgress.episodeId)
    }

    func signOut() {
        session = nil
        player?.setSession(nil)
        player?.clearPersistedQueue()
        clearSongs()
        liveAudiobookProgress = nil
        playlists = []
        clearAudiobooks()
        audiobookProgress = [:]
        searchResults = []
        favoriteSongIds = []
        deletedSongIds = []
        serverFavoriteSongs = []
        pendingFavoriteSongIds = []
        dailyRecommendedSongs = []
        recentlyAddedSongs = []
        mostPlayedSongs = []
        dailyRecommendationDay = nil
        hasLoadedInitialContent = false
        libraryCacheSavedAt = nil
        errorMessage = nil
        favoriteErrorMessage = nil
        libraryStatus = "Not connected"
        UserDefaults.standard.removeObject(forKey: sessionKey)
        do {
            try sessionTokenStore.deleteAllTokens()
        } catch {
            print("[AppStore] Failed to clear Emby session token: \(error.localizedDescription)")
        }
        clearPersistedSnapshots()
        ArtworkImageCache.shared.clear()
        player?.cancelAudioCaching()
        ArtworkDiskCache.clear()
        PlaybackAudioCache.clearAll()
        URLCache.shared.removeAllCachedResponses()
        cacheUsageBytes = nil
    }

    func clearCaches() {
        guard !isClearingCache else { return }
        isClearingCache = true
        // Only cached song audio. The library snapshot and artwork stay so the app doesn't
        // have to resync from Emby afterwards.
        player?.cancelAudioCaching()

        Task {
            // Deleting hundreds of MB of audio can take a moment; keep it off the main thread.
            await Task.detached(priority: .userInitiated) {
                PlaybackAudioCache.clearAll()
                DiskCacheMaintenance.removeOrphanedFiles()
            }.value
            isClearingCache = false
            await refreshCacheUsage()
        }
    }

    /// Queued behind any pending snapshot write so a late save can't resurrect the file.
    private func clearPersistedSnapshots() {
        let librarySnapshots = snapshotStore
        let homeSnapshots = initialHomeSnapshotStore
        let progressStore = audiobookProgressStore
        persistenceQueue.async {
            librarySnapshots.clear()
            homeSnapshots.clear()
            progressStore.clear()
        }
    }

    /// Size of the song audio cache, which is what "清除歌曲缓存" removes.
    func refreshCacheUsage() async {
        cacheUsageBytes = await Task.detached(priority: .utility) {
            PlaybackAudioCache.totalSize()
        }.value
    }

    private func updateLibraryStatus() {
        if songs.isEmpty, audiobooks.isEmpty {
            libraryStatus = "Connected, but Emby returned 0 audio items."
        } else if songs.isEmpty {
            libraryStatus = "Loaded \(audiobooks.count) audiobooks."
        } else if audiobooks.isEmpty {
            libraryStatus = "Loaded \(songs.count) songs."
        } else {
            libraryStatus = "Loaded \(songs.count) songs and \(audiobooks.count) audiobooks."
        }
    }

    private func loadedSongCount(from status: String, suffix: String) -> Int? {
        guard status.hasPrefix("Loaded "), status.hasSuffix(suffix) else { return nil }
        let start = status.index(status.startIndex, offsetBy: "Loaded ".count)
        let end = status.index(status.endIndex, offsetBy: -suffix.count)
        return Int(status[start..<end])
    }

    private func loadedCounts(from status: String, middle: String, suffix: String) -> (left: Int, right: Int)? {
        guard status.hasPrefix("Loaded "), status.hasSuffix(suffix) else { return nil }
        let start = status.index(status.startIndex, offsetBy: "Loaded ".count)
        let end = status.index(status.endIndex, offsetBy: -suffix.count)
        let body = String(status[start..<end])
        let parts = body.components(separatedBy: middle)
        guard parts.count == 2,
              let left = Int(parts[0]),
              let right = Int(parts[1]) else {
            return nil
        }
        return (left, right)
    }

    private func perform(_ operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await operation()
        } catch is CancellationError {
            // Cancellations are expected for superseded async UI work.
        } catch {
            errorMessage = error.localizedDescription
            if songs.isEmpty, audiobookEpisodes.isEmpty {
                libraryStatus = error.localizedDescription
            }
        }
    }

    private func persist(_ session: EmbySession) {
        do {
            try sessionTokenStore.saveToken(session.accessToken, for: session)
            let metadata = StoredEmbySession(session: session)
            let data = try JSONEncoder().encode(metadata)
            UserDefaults.standard.set(data, forKey: sessionKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: sessionKey)
            print("[AppStore] Failed to persist Emby session securely: \(error.localizedDescription)")
        }
    }

    /// Replaces the song library. Grouping, pinyin indexing and sorting run off the main thread;
    /// the songs and everything derived from them are then published together.
    /// Returns false when a newer library (or a sign-out) superseded this one while it was being
    /// processed; callers must then stop applying the rest of their now-stale content.
    @discardableResult
    private func applySongs(_ newSongs: [EmbyAudioItem]) async -> Bool {
        guard !newSongs.isEmpty else {
            clearSongs()
            return true
        }

        derivedDataGeneration += 1
        let generation = derivedDataGeneration
        let day = currentRecommendationDay()
        let derived = await Task.detached(priority: .userInitiated) {
            DerivedLibraryData(songs: newSongs, day: day)
        }.value
        guard generation == derivedDataGeneration else { return false }

        songs = newSongs
        songsById = derived.songsById
        albums = derived.albums
        artists = derived.artists
        albumSections = derived.albumSections
        artistSections = derived.artistSections
        dailyRecommendationDay = day
        dailyRecommendedSongs = derived.dailyRecommendedSongs
        recentlyAddedSongs = derived.recentlyAddedSongs
        if playlists.isEmpty {
            playlists = derived.generatedPlaylists
        }
        refreshRecentSongs()
        refreshFavoriteSongs()
        return true
    }

    private func clearSongs() {
        derivedDataGeneration += 1
        songs = []
        songsById = [:]
        favoriteSongs = []
        albums = []
        artists = []
        albumSections = []
        artistSections = []
        recentSongs = []
        dailyRecommendedSongs = []
        recentlyAddedSongs = []
        mostPlayedSongs = []
        dailyRecommendationDay = nil
    }

    private func refreshRecentSongs() {
        guard !songs.isEmpty else {
            recentSongs = []
            return
        }

        let ordered = recentSongIds.compactMap { songsById[$0] }
        recentSongs = ordered.isEmpty ? Array(songs.prefix(20)) : ordered
    }

    /// Replaces the audiobook episodes; grouping into books and pinyin indexing run off the
    /// main thread. Returns false when superseded by a newer call while processing.
    @discardableResult
    private func applyAudiobookEpisodes(_ episodes: [EmbyAudioItem]) async -> Bool {
        guard !episodes.isEmpty else {
            clearAudiobooks()
            return true
        }

        audiobookDataGeneration += 1
        let generation = audiobookDataGeneration
        let derived = await Task.detached(priority: .userInitiated) {
            DerivedAudiobookData(episodes: episodes)
        }.value
        guard generation == audiobookDataGeneration else { return false }

        audiobookEpisodes = episodes
        audiobooks = derived.audiobooks
        audiobookSections = derived.sections
        audiobookEpisodeBookIds = derived.episodeBookIds
        mergeServerAudiobookProgress(from: episodes)
        return true
    }

    private func clearAudiobooks() {
        audiobookDataGeneration += 1
        audiobookEpisodes = []
        audiobooks = []
        audiobookSections = []
        audiobookEpisodeBookIds = [:]
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let restored = restoredSession(from: data) else {
            return
        }
        session = restored
        player?.setSession(restored)

        // Snapshot decoding and library indexing run off the main thread so they don't hold
        // up the first frame; the UI fills in as soon as the cached content is ready.
        isRestoringCachedContent = true
        Task {
            if await restoreLibrarySnapshot(for: restored) {
                isRestoringCachedContent = false
                return
            }

            if await restoreInitialHomeSnapshot(for: restored) {
                isRestoringCachedContent = false
                guard session == restored else { return }
                await refreshFavoritesFromServer(session: restored)
                await refreshLibraryIfNeededForToday()
                return
            }

            // No usable cache. `perform` sets `isLoading` synchronously on entry, so the
            // skeleton stays up without a gap while content loads from Emby.
            isRestoringCachedContent = false
            await loadInitialHomeContent(session: restored)
            await refreshLibraryIfNeededForToday()
        }
    }

    private func restoredSession(from data: Data) -> EmbySession? {
        let decoder = JSONDecoder()
        if let legacySession = try? decoder.decode(EmbySession.self, from: data) {
            persist(legacySession)
            return legacySession
        }

        if let metadata = try? decoder.decode(StoredEmbySession.self, from: data) {
            do {
                guard let token = try sessionTokenStore.token(for: metadata),
                      !token.isEmpty else {
                    UserDefaults.standard.removeObject(forKey: sessionKey)
                    return nil
                }
                return metadata.session(accessToken: token)
            } catch {
                print("[AppStore] Failed to restore Emby session token: \(error.localizedDescription)")
                return nil
            }
        }

        return nil
    }

    private func restoreLibrarySnapshot(for restoredSession: EmbySession) async -> Bool {
        let store = snapshotStore
        let loaded = await Task.detached(priority: .userInitiated, operation: { store.load() }).value
        // Signed out while the snapshot was loading.
        guard session == restoredSession else { return true }
        guard let snapshot = loaded,
              (!snapshot.songs.isEmpty || !snapshot.audiobookEpisodes.isEmpty),
              Calendar.current.isDateInToday(snapshot.savedAt) else {
            return false
        }

        // A sign-out or a fresher library won the race; don't mix stale snapshot content in.
        guard await applySongs(snapshot.songs),
              await applyAudiobookEpisodes(snapshot.audiobookEpisodes) else { return true }
        playlists = snapshot.playlists.isEmpty ? snapshot.songs.generatedPlaylists : snapshot.playlists
        hasLoadedInitialContent = true
        libraryCacheSavedAt = snapshot.savedAt
        updateLibraryStatusFromCache()
        Task {
            await refreshMostPlayedSongsFromServer()
            await refreshFavoritesFromServer()
        }
        return true
    }

    private func updateLibraryStatusFromCache() {
        if songs.isEmpty, audiobooks.isEmpty {
            libraryStatus = "Loaded 0 songs from cache."
        } else if songs.isEmpty {
            libraryStatus = "Loaded \(audiobooks.count) audiobooks from cache."
        } else if audiobooks.isEmpty {
            libraryStatus = "Loaded \(songs.count) songs from cache."
        } else {
            libraryStatus = "Loaded \(songs.count) songs and \(audiobooks.count) audiobooks from cache."
        }
    }

    private func shouldRefreshCachedLibrary() -> Bool {
        guard let libraryCacheSavedAt else { return true }
        return !Calendar.current.isDateInToday(libraryCacheSavedAt)
    }

    private func refreshLibraryIfNeededForToday() async {
        guard shouldRefreshCachedLibrary() else { return }
        await refreshLibrary()
    }

    private func restoreInitialHomeSnapshot(for restoredSession: EmbySession) async -> Bool {
        let store = initialHomeSnapshotStore
        let loaded = await Task.detached(priority: .userInitiated, operation: { store.load() }).value
        guard session == restoredSession else { return true }
        guard let snapshot = loaded,
              Calendar.current.isDateInToday(snapshot.savedAt) else {
            return false
        }

        await applyInitialHomeContent(snapshot.content, savedAt: snapshot.savedAt, savesSnapshot: false)
        libraryStatus = "Loaded home content from cache."
        return true
    }

    private func saveLibrarySnapshot() {
        guard !songs.isEmpty || !audiobookEpisodes.isEmpty else { return }
        let store = snapshotStore
        let savedSongs = songs
        let savedPlaylists = playlists
        let savedAudiobookEpisodes = audiobookEpisodes
        persistenceQueue.async {
            store.save(songs: savedSongs, playlists: savedPlaylists, audiobookEpisodes: savedAudiobookEpisodes)
        }
    }

    private func persistFavoriteSongIds() {
        UserDefaults.standard.set(Array(favoriteSongIds).sorted(), forKey: favoritesKey)
    }

    private func restoreLocalState() {
        favoriteSongIds = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        recentSongIds = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        if let rawValue = UserDefaults.standard.string(forKey: cellularOnlineQualityKey),
           let quality = OnlinePlaybackQuality(rawValue: rawValue) {
            cellularOnlineQuality = quality
        }
        if let rawValue = UserDefaults.standard.string(forKey: wifiOnlineQualityKey),
           let quality = OnlinePlaybackQuality(rawValue: rawValue) {
            wifiOnlineQuality = quality
        }
        audiobookProgress = audiobookProgressStore.load()
        startsOnBrowse = UserDefaults.standard.bool(forKey: startsOnBrowseKey)
        keepsScreenAwakeOnPlayerPage = UserDefaults.standard.bool(forKey: keepsScreenAwakeKey)
        // The 120Hz toggle was removed: the Info.plist key already enables ProMotion everywhere.
        UserDefaults.standard.removeObject(forKey: highRefreshRateKey)
        if UserDefaults.standard.object(forKey: audioCacheLimitKey) != nil {
            audioCacheLimit = AudioCacheLimit(rawValue: UserDefaults.standard.integer(forKey: audioCacheLimitKey)) ?? .defaultValue
        }
    }

    private func refreshMostPlayedSongsFromServer() async {
        guard let session else { return }
        do {
            mostPlayedSongs = try await client.fetchMostPlayedSongs(session: session, limit: 50)
        } catch is CancellationError {
        } catch {
            print("[AppStore] Failed to refresh most played songs: \(error.localizedDescription)")
        }
    }

    private func currentRecommendationDay() -> Int {
        Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    }
}

/// Audiobooks grouped from their episodes. Pure and nonisolated so it can be built off the main thread.
private struct DerivedAudiobookData: Sendable {
    let audiobooks: [Audiobook]
    let sections: [IndexedSection<Audiobook>]
    let episodeBookIds: [String: String]

    init(episodes: [EmbyAudioItem]) {
        audiobooks = episodes.audiobooks
        sections = PinyinIndexer.sections(for: audiobooks, title: \.title)
        var episodeBookIds: [String: String] = [:]
        for audiobook in audiobooks {
            for episode in audiobook.episodes {
                episodeBookIds[episode.id] = audiobook.id
            }
        }
        self.episodeBookIds = episodeBookIds
    }
}

/// Everything computed from the song library. Pure and nonisolated so it can be built off the main thread.
private struct DerivedLibraryData: Sendable {
    let songsById: [String: EmbyAudioItem]
    let albums: [MusicAlbum]
    let artists: [MusicArtist]
    let albumSections: [IndexedSection<MusicAlbum>]
    let artistSections: [IndexedSection<MusicArtist>]
    let dailyRecommendedSongs: [EmbyAudioItem]
    let recentlyAddedSongs: [EmbyAudioItem]
    let generatedPlaylists: [MusicPlaylist]

    init(songs: [EmbyAudioItem], day: Int) {
        // Servers can return the same item twice; keep the first instead of trapping.
        songsById = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albums = songs.musicAlbums
        artists = songs.musicArtists
        albumSections = PinyinIndexer.sections(for: albums, title: \.title)
        artistSections = PinyinIndexer.sections(for: artists, title: \.name)
        dailyRecommendedSongs = Self.dailyRecommendation(from: songs, day: day, limit: 50)
        recentlyAddedSongs = Self.recentlyAdded(from: songs, limit: 50)
        generatedPlaylists = songs.generatedPlaylists
    }

    static func dailyRecommendation(from songs: [EmbyAudioItem], day: Int, limit: Int) -> [EmbyAudioItem] {
        // Hash each id once rather than inside the sort comparator.
        songs
            .map { (score: deterministicScore(for: $0.id, day: day), song: $0) }
            .sorted { $0.score < $1.score }
            .prefix(limit)
            .map(\.song)
    }

    private static func recentlyAdded(from songs: [EmbyAudioItem], limit: Int) -> [EmbyAudioItem] {
        let sorted = songs.sorted {
            ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast)
        }
        if sorted.first?.dateCreated != nil {
            return Array(sorted.prefix(limit))
        }
        return Array(songs.prefix(limit))
    }

    private static func deterministicScore(for id: String, day: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for scalar in id.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }
        hash ^= UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15
        return avalanche(hash)
    }

    private static func avalanche(_ value: UInt64) -> UInt64 {
        var hash = value
        hash = (hash ^ (hash >> 30)) &* 0xBF58_476D_1CE4_E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D0_49BB_1331_11EB
        return hash ^ (hash >> 31)
    }
}

private struct LibrarySnapshot: Codable {
    let version: Int
    let savedAt: Date
    let songs: [EmbyAudioItem]
    let playlists: [MusicPlaylist]
    let audiobookEpisodes: [EmbyAudioItem]
}

private struct StoredEmbySession: Codable {
    let serverURL: URL
    let userId: String
    let username: String

    init(session: EmbySession) {
        serverURL = session.serverURL
        userId = session.userId
        username = session.username
    }

    func session(accessToken: String) -> EmbySession {
        EmbySession(
            serverURL: serverURL,
            userId: userId,
            username: username,
            accessToken: accessToken
        )
    }
}

private struct KeychainSessionTokenStore {
    private let service = "PrivSong.EmbySession"

    func saveToken(_ token: String, for session: EmbySession) throws {
        try saveToken(token, account: account(serverURL: session.serverURL, userId: session.userId))
    }

    func token(for metadata: StoredEmbySession) throws -> String? {
        try token(account: account(serverURL: metadata.serverURL, userId: metadata.userId))
    }

    func deleteAllTokens() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSessionTokenError.unhandledStatus(status)
        }
    }

    private func saveToken(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainSessionTokenError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSessionTokenError.unhandledStatus(addStatus)
        }
    }

    private func token(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainSessionTokenError.unhandledStatus(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainSessionTokenError.invalidData
        }
        return token
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func account(serverURL: URL, userId: String) -> String {
        "\(serverURL.absoluteString)#\(userId)"
    }
}

private enum KeychainSessionTokenError: LocalizedError {
    case invalidData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Keychain returned invalid token data."
        case .unhandledStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

private struct LibrarySnapshotStore {
    private let version = 2
    private let fileName = "library-snapshot.json"

    func load() -> LibrarySnapshot? {
        let url = snapshotURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(LibrarySnapshot.self, from: data),
              snapshot.version == version else {
            return nil
        }
        return snapshot
    }

    func save(songs: [EmbyAudioItem], playlists: [MusicPlaylist], audiobookEpisodes: [EmbyAudioItem]) {
        let snapshot = LibrarySnapshot(
            version: version,
            savedAt: Date(),
            songs: songs,
            playlists: playlists,
            audiobookEpisodes: audiobookEpisodes
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let directory = applicationSupportDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL, options: [.atomic])
        } catch {
            print("[LibrarySnapshotStore] Failed to save snapshot: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private var snapshotURL: URL {
        applicationSupportDirectory.appendingPathComponent(fileName)
    }

    private var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PrivSong", isDirectory: true)
    }
}

private struct InitialHomeContentSnapshot: Codable {
    let version: Int
    let savedAt: Date
    let content: InitialHomeContent
}

private struct InitialHomeContentSnapshotStore {
    private let version = 2
    private let fileName = "initial-home-snapshot.json"

    func load() -> InitialHomeContentSnapshot? {
        let url = snapshotURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(InitialHomeContentSnapshot.self, from: data),
              snapshot.version == version else {
            return nil
        }
        return snapshot
    }

    func save(_ content: InitialHomeContent) {
        let snapshot = InitialHomeContentSnapshot(
            version: version,
            savedAt: Date(),
            content: content
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let directory = applicationSupportDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL, options: [.atomic])
        } catch {
            print("[InitialHomeContentSnapshotStore] Failed to save snapshot: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private var snapshotURL: URL {
        applicationSupportDirectory.appendingPathComponent(fileName)
    }

    private var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PrivSong", isDirectory: true)
    }
}

struct AudiobookPlaybackProgress: Codable, Hashable {
    let position: TimeInterval
    let duration: TimeInterval
    let updatedAt: Date
    let isFinished: Bool
}

private struct AudiobookProgressStore {
    private let version = 1
    private let fileName = "audiobook-progress.json"

    func load() -> [String: AudiobookPlaybackProgress] {
        let url = progressURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.version == version else {
            return [:]
        }
        return snapshot.progress
    }

    func save(_ progress: [String: AudiobookPlaybackProgress]) {
        let snapshot = Snapshot(version: version, progress: progress)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let directory = applicationSupportDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: progressURL, options: [.atomic])
        } catch {
            print("[AudiobookProgressStore] Failed to save progress: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: progressURL)
    }

    private var progressURL: URL {
        applicationSupportDirectory.appendingPathComponent(fileName)
    }

    private var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PrivSong", isDirectory: true)
    }

    private struct Snapshot: Codable {
        let version: Int
        let progress: [String: AudiobookPlaybackProgress]
    }
}
