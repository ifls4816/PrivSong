import Foundation
import Observation
import os
import Security

/// Serializes snapshot writes and deletes off the main thread while keeping them in order.
private let persistenceQueue = DispatchQueue(label: "PrivSong.persistence", qos: .utility)

@MainActor
@Observable
final class AppStore {
    private(set) var session: EmbySession?
    /// Set through `applySongs(_:)` so derived data (albums, artists, index sections) is
    /// computed off the main thread and published together with the songs.
    private(set) var songs: [EmbyAudioItem] = []
    var searchResults: [EmbyAudioItem] = []
    private var isConnecting = false
    private var isRefreshingLibrary = false
    var isLoading: Bool { isConnecting || isRefreshingLibrary }
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
    private(set) var cacheUsageBytes: Int64?
    private(set) var isClearingCache = false

    // Cached derived data — recomputed only when source media changes
    private(set) var albums: [MusicAlbum] = []
    private(set) var artists: [MusicArtist] = []
    private(set) var albumSections: [IndexedSection<MusicAlbum>] = []
    private(set) var artistSections: [IndexedSection<MusicArtist>] = []
    private(set) var playlists: [MusicPlaylist] = []
    @ObservationIgnored private var generatedPlaylists: [MusicPlaylist] = []
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

    private let client: EmbyClient
    private let sessionTokenStore = KeychainSessionTokenStore()
    private let sessionKey = "EmbySession"
    private let favoritesKey = "FavoriteSongIds"
    private let recentKey = "RecentSongIds"
    private let legacyAccountKey = "LegacyEmbyAccount"
    private let cellularOnlineQualityKey = "CellularOnlinePlaybackQuality"
    private let wifiOnlineQualityKey = "WiFiOnlinePlaybackQuality"
    private let startsOnBrowseKey = "StartsOnBrowse"
    private let keepsScreenAwakeKey = "KeepsScreenAwakeOnPlayerPage"
    private let highRefreshRateKey = "PrefersHighRefreshRate"
    private let audioCacheLimitKey = "AudioCacheLimitMB"
    private let searchResultLimit = 100
    @ObservationIgnored private var activeSearchToken: UUID?
    @ObservationIgnored private var sessionGeneration = UUID()
    @ObservationIgnored private var signInAttempt: UUID?
    @ObservationIgnored private var libraryRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var playlistRevision = 0
    @ObservationIgnored private var favoriteRevision = 0
    @ObservationIgnored private var libraryCacheSavedAt: Date?
    @ObservationIgnored private var dailyRecommendationDay: Int?
    private var audiobookEpisodeBookIds: [String: String] = [:]
    @ObservationIgnored private var pendingFavoriteSongIds: Set<String> = []
    @ObservationIgnored private var songsById: [String: EmbyAudioItem] = [:]
    @ObservationIgnored private var derivedDataGeneration = 0
    /// When home content was last fetched from the server; a full refresh shortly after reuses it.
    @ObservationIgnored private var homeContentFetchedAt: Date?
    @ObservationIgnored private var audiobookDataGeneration = 0
    /// Latest position of the audiobook episode that is playing. Ignored by observation so the
    /// periodic progress reports don't re-render the views that show audiobook progress.
    @ObservationIgnored private var liveAudiobookProgress: (episodeId: String, progress: AudiobookPlaybackProgress)?
    @ObservationIgnored private var lastAudiobookProgressPublish = Date.distantPast

    @ObservationIgnored weak var player: PlayerController? {
        didSet {
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
            player?.setSession(session, migratesLegacy: session.map { ownsLegacyData($0.account) } ?? false)
            player?.isAudiobookEpisode = { [weak self] item in
                self?.audiobookEpisodeBookIds[item.id] != nil
            }
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

    init(client: EmbyClient = EmbyClient(), restoresSession: Bool = true) {
        self.client = client
        restoreLocalState()
        if restoresSession { restoreSession() }
        Task.detached(priority: .utility) {
            DiskCacheMaintenance.removeOrphanedFiles()
            ArtworkDiskCache.trimToLimit()
        }
    }

    func signIn(server: String, username: String, password: String) async {
        let attempt = UUID()
        signInAttempt = attempt
        isConnecting = true
        errorMessage = nil
        defer {
            if signInAttempt == attempt {
                signInAttempt = nil
                isConnecting = false
            }
        }
        do {
            let authenticated = try await client.authenticate(server: server, username: username, password: password)
            guard signInAttempt == attempt, !Task.isCancelled else { return }
            let accountChanged = session?.account != authenticated.account
            activateSession(authenticated)
            persist(authenticated)
            let generation = sessionGeneration
            if accountChanged || !hasLoadedInitialContent {
                await restoreAccountContent(for: authenticated, generation: generation)
            }
            guard sessionGeneration == generation else { return }
            if !hasLoadedInitialContent {
                await loadInitialHomeContent(session: authenticated, generation: generation)
            }
            guard sessionGeneration == generation else { return }
            Task {
                guard sessionGeneration == generation else { return }
                await refreshLibrary()
            }
        } catch is CancellationError {
        } catch {
            guard signInAttempt == attempt else { return }
            let message = await Self.connectionError(error, server: server)
            guard signInAttempt == attempt else { return }
            errorMessage = message
        }
    }

    private static func connectionError(_ error: Error, server: String) async -> String {
        guard let urlError = error as? URLError,
              let url = try? EmbyClient.normalizedServerURL(server), let host = url.host,
              isLocalHost(host) else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut:
            if await EmbyClient.localNetworkAccessDenied(for: url) {
                return "本地网络访问被拒绝。请在系统设置中允许私音访问本地网络后重试。"
            }
            return "无法连接到局域网 Emby。请检查服务器是否运行、地址是否正确，以及设备是否在同一网络。"
        default:
            return error.localizedDescription
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.contains(":") {
            return name == "::1" || name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd")
        }
        if name.hasSuffix(".local") || !name.contains(".") || name.hasPrefix("192.168.") ||
            name.hasPrefix("10.") || name.hasPrefix("127.") || name.hasPrefix("169.254.") {
            return true
        }
        let parts = name.split(separator: ".")
        return parts.first == "172" && parts.count == 4 && Int(parts[1]).map { (16...31).contains($0) } == true
    }

    private func loadInitialHomeContent(session: EmbySession, generation: UUID) async {
        do {
            let content = try await client.fetchInitialHomeContent(session: session)
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            guard await applyInitialHomeContent(content, session: session, generation: generation) else { return }
            if content.playlists != nil, content.audiobookEpisodes != nil, content.mostPlayedSongs != nil {
                homeContentFetchedAt = Date()
            }
        } catch is CancellationError {
        } catch {
            guard sessionGeneration == generation else { return }
            errorMessage = error.localizedDescription
            libraryStatus = error.localizedDescription
        }
    }

    @discardableResult
    private func applyInitialHomeContent(
        _ content: InitialHomeContent,
        session: EmbySession,
        generation: UUID,
        savesSnapshot: Bool = true
    ) async -> Bool {
        if let episodes = content.audiobookEpisodes, !(await applyAudiobookEpisodes(episodes)) { return false }
        guard sessionGeneration == generation, !Task.isCancelled else { return false }
        if let loaded = content.playlists { playlists = loaded }
        if let loaded = content.recentlyAddedSongs { recentlyAddedSongs = loaded }
        if let loaded = content.mostPlayedSongs { mostPlayedSongs = loaded }

        let day = currentRecommendationDay()
        let dailySeed = firstNonEmptySongList(
            content.dailySeedSongs ?? [],
            recentlyAddedSongs,
            mostPlayedSongs
        )
        if !dailySeed.isEmpty || !hasLoadedInitialContent {
            dailyRecommendationDay = day
            dailyRecommendedSongs = DerivedLibraryData.dailyRecommendation(from: dailySeed, day: day, limit: 50)
        }
        hasLoadedInitialContent = true
        libraryStatus = "Loaded home content."

        if savesSnapshot {
            let store = InitialHomeContentSnapshotStore(directory: session.account.directory)
            persistenceQueue.async {
                store.save(content)
            }
        }
        return true
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
        guard playlist.isServerEditable else {
            return playlist.songs
        }

        let generation = sessionGeneration
        let revision = playlistRevision
        let loaded: [EmbyAudioItem]
        do {
            loaded = try await client.fetchPlaylistSongs(playlistId: playlistId, session: session)
        } catch {
            try checkSession(generation)
            if playlist.hasCompleteSongList { return playlist.songs }
            throw error
        }
        try checkSession(generation)
        guard let currentIndex = playlists.firstIndex(where: { $0.id == playlistId }) else { return [] }
        let current = playlists[currentIndex]
        guard playlistRevision == revision else { return current.songs }
        guard current.songs != loaded || current.songCount != loaded.count else { return loaded }
        playlistRevision += 1
        let updatedPlaylist = MusicPlaylist(
            id: current.id,
            name: current.name,
            description: "\(loaded.count) 首歌曲",
            songs: loaded,
            songCount: loaded.count
        )
        playlists[currentIndex] = updatedPlaylist
        saveLibrarySnapshot()
        return loaded
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
        let generation = sessionGeneration
        let playlist = try await client.createPlaylist(name: name, songs: songs, session: session)
        try checkSession(generation)
        playlistRevision += 1
        playlists.removeAll { !$0.isServerEditable }
        playlists.append(playlist)
        saveLibrarySnapshot()
        return playlist
    }

    func replaceRealtimePlaylist(playlistId: String, songs: [EmbyAudioItem]) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        let generation = sessionGeneration
        do {
            try await client.replacePlaylistSongs(playlistId: playlistId, songs: songs, session: session)
        } catch let error as EmbyError {
            try checkSession(generation)
            if case .playlistReplacementFailed(_, false) = error {
                _ = try? await loadPlaylistSongsIfNeeded(playlistId: playlistId)
            }
            throw error
        }
        try checkSession(generation)
        playlistRevision += 1
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[index] = MusicPlaylist(
                id: playlistId, name: playlists[index].name, description: "\(songs.count) 首歌曲",
                songs: songs, songCount: songs.count
            )
            saveLibrarySnapshot()
        }
    }

    func deletePlaylist(playlistId: String) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        let generation = sessionGeneration
        try await client.deletePlaylist(playlistId: playlistId, session: session)
        try checkSession(generation)
        playlistRevision += 1
        playlists.removeAll { $0.id == playlistId }
        if playlists.isEmpty { playlists = generatedPlaylists }
        saveLibrarySnapshot()
    }

    func renamePlaylist(playlistId: String, name: String) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        let generation = sessionGeneration
        try await client.renamePlaylist(playlistId: playlistId, name: name, session: session)
        try checkSession(generation)
        playlistRevision += 1
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            let playlist = playlists[index]
            playlists[index] = MusicPlaylist(
                id: playlist.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: playlist.description, songs: playlist.songs, songCount: playlist.songCount
            )
            saveLibrarySnapshot()
        }
    }

    /// Deletes the song on the Emby server — its audio file is removed from disk — and then
    /// drops it from everything held locally. Irreversible.
    func deleteSong(_ song: EmbyAudioItem) async throws {
        guard let session else { throw EmbyError.invalidResponse }
        let generation = sessionGeneration
        try await client.deleteSong(itemId: song.id, session: session)
        try checkSession(generation)

        let id = song.id
        deletedSongIds.insert(id)
        playlistRevision += 1
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
            UserDefaults.standard.set(recentSongIds, forKey: accountKey(recentKey, session.account))
        }

        if songs.contains(where: { $0.id == id }) {
            // Rebuilds albums, artists, recommendations and recents without the song.
            guard await applySongs(songs.filter { $0.id != id }) else { return }
        } else {
            dailyRecommendedSongs.removeAll { $0.id == id }
            recentlyAddedSongs.removeAll { $0.id == id }
            refreshRecentSongs()
        }
        if sessionGeneration == generation { saveLibrarySnapshot() }
    }

    func refreshAudiobookProgress(for audiobook: Audiobook) async {
        guard let session else { return }
        let generation = sessionGeneration
        let episodeIds = audiobook.episodes.map(\.id)
        guard !episodeIds.isEmpty else { return }

        do {
            let refreshedEpisodes = try await client.fetchItems(itemIds: episodeIds, session: session)
            try checkSession(generation)
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

    private func fetchAndApplyFullLibrary(session: EmbySession, generation: UUID) async throws {
        // Right after the home content was fetched (sign-in, or a launch without cache), its
        // playlists, audiobooks, most-played list and favorites are current. Reuse them rather
        // than downloading all of it a second time.
        let reusesHomeContent = homeContentFetchedAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        homeContentFetchedAt = nil

        let api = client
        let revision = playlistRevision
        async let songsRequest = api.fetchSongs(session: session)
        let cachedPlaylists = playlists.filter(\.isServerEditable)
        let cachedEpisodes = audiobookEpisodes
        let cachedMostPlayed = mostPlayedSongs
        async let playlistsRequest: [MusicPlaylist]? = reusesHomeContent ? cachedPlaylists
            : (try? await api.fetchPlaylistSummaries(session: session))
        async let audiobookRequest: [EmbyAudioItem]? = reusesHomeContent ? cachedEpisodes
            : (try? await api.fetchAudiobookEpisodes(session: session))
        async let mostPlayedRequest: [EmbyAudioItem]? = reusesHomeContent ? cachedMostPlayed
            : (try? await api.fetchMostPlayedSongs(session: session, limit: 50))

        let loadedSongs = try await songsRequest
        let (summaries, episodes, mostPlayed) = await (playlistsRequest, audiobookRequest, mostPlayedRequest)
        try checkSession(generation)
        let filteredSongs = deletedSongIds.isEmpty ? loadedSongs : loadedSongs.filter { !deletedSongIds.contains($0.id) }
        guard await applySongs(filteredSongs) else { return }
        try checkSession(generation)
        if let episodes, !(await applyAudiobookEpisodes(episodes)) { return }
        try checkSession(generation)
        if let summaries, playlistRevision == revision {
            let merged = await playlistsKeepingLoadedSongs(summaries, session: session)
            try checkSession(generation)
            if playlistRevision == revision {
                playlists = merged.isEmpty ? generatedPlaylists : merged
            }
        }
        if let mostPlayed { mostPlayedSongs = mostPlayed.filter { !deletedSongIds.contains($0.id) } }
        hasLoadedInitialContent = true
        if summaries != nil, episodes != nil {
            libraryCacheSavedAt = Date()
        } else {
            errorMessage = "部分资料库同步失败，已保留已有的歌单和有声书。"
        }
        saveLibrarySnapshot()
        updateLibraryStatus()
        await refreshFavoritesFromServer(session: session, generation: generation)
    }

    /// Playlist summaries come without songs. Reuse songs already loaded for playlists whose
    /// track count is unchanged, and fetch a few cover songs for the rest, instead of
    /// downloading every playlist's full track list on each refresh.
    private func playlistsKeepingLoadedSongs(
        _ summaries: [MusicPlaylist],
        session: EmbySession
    ) async -> [MusicPlaylist] {
        let existingById = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = summaries.map { summary -> MusicPlaylist in
            // These tracks are provisional. Opening the playlist fetches the latest entries.
            guard let existing = existingById[summary.id],
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
        guard let session, !isRestoringCachedContent else { return }
        if let running = libraryRefreshTask {
            await running.value
            return
        }
        let generation = sessionGeneration
        isRefreshingLibrary = true
        errorMessage = nil
        let refresh = Task {
            await client.invalidateCachedLibraryViews()
            do {
                try checkSession(generation)
                try await fetchAndApplyFullLibrary(session: session, generation: generation)
            } catch is CancellationError {
            } catch {
                if sessionGeneration == generation {
                    errorMessage = error.localizedDescription
                    if !hasLoadedInitialContent { libraryStatus = error.localizedDescription }
                }
            }
            if sessionGeneration == generation {
                libraryRefreshTask = nil
                isRefreshingLibrary = false
            }
        }
        libraryRefreshTask = refresh
        await refresh.value
    }

    private func refreshFavoritesFromServer(session: EmbySession, generation: UUID) async {
        let revision = favoriteRevision
        do {
            let favoriteSongs = try await client.fetchFavoriteSongs(session: session)
            try checkSession(generation)
            guard favoriteRevision == revision else { return }
            applyServerFavoriteSongs(favoriteSongs)
        } catch is CancellationError {
        } catch {
            print("[AppStore] Failed to refresh favorite songs: \(error.localizedDescription)")
        }
    }

    private func applyServerFavoriteSongs(_ songs: [EmbyAudioItem]) {
        var seen = Set<String>()
        let musicFavorites = songs.filter { song in
            song.isAudio && !song.isAudiobookAudio && !deletedSongIds.contains(song.id)
                && !pendingFavoriteSongIds.contains(song.id) && seen.insert(song.id).inserted
        }
        serverFavoriteSongs = musicFavorites + serverFavoriteSongs.filter { pendingFavoriteSongIds.contains($0.id) }
        favoriteSongIds = Set(musicFavorites.map(\.id)).union(favoriteSongIds.intersection(pendingFavoriteSongIds))
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
        guard let account = session?.account else { return }
        recentSongIds.removeAll { $0 == song.id }
        recentSongIds.insert(song.id, at: 0)
        recentSongIds = Array(recentSongIds.prefix(50))
        UserDefaults.standard.set(recentSongIds, forKey: accountKey(recentKey, account))
        refreshRecentSongs()
    }

    func isFavorite(_ song: EmbyAudioItem) -> Bool {
        favoriteSongIds.contains(song.id)
    }

    func toggleFavorite(_ song: EmbyAudioItem) {
        guard let session else { return }
        guard !pendingFavoriteSongIds.contains(song.id) else { return }

        let generation = sessionGeneration
        favoriteRevision += 1
        favoriteErrorMessage = nil
        let shouldFavorite = !favoriteSongIds.contains(song.id)
        let previousServerSong = serverFavoriteSongs.first { $0.id == song.id }
        pendingFavoriteSongIds.insert(song.id)
        applyFavorite(song: song, isFavorite: shouldFavorite)

        Task {
            do {
                try checkSession(generation)
                try await client.setFavorite(itemId: song.id, isFavorite: shouldFavorite, session: session)
                guard sessionGeneration == generation else { return }
                pendingFavoriteSongIds.remove(song.id)
            } catch is CancellationError {
                guard sessionGeneration == generation else { return }
                rollbackFavorite(song: song, previousServerSong: previousServerSong, wasFavorite: !shouldFavorite)
            } catch {
                guard sessionGeneration == generation else { return }
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
        guard let account = session?.account else { return }
        let store = AudiobookProgressStore(directory: account.directory)
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
        let account = session?.account
        signInAttempt = nil
        isConnecting = false
        activateSession(nil, forgetPreviousAccount: true)
        UserDefaults.standard.removeObject(forKey: sessionKey)
        do {
            try sessionTokenStore.deleteAllTokens()
        } catch {
            print("[AppStore] Failed to clear Emby session token: \(error.localizedDescription)")
        }
        if let account {
            if ownsLegacyData(account) { UserDefaults.standard.set("", forKey: legacyAccountKey) }
            clearPersistedSnapshots(for: account)
            UserDefaults.standard.removeObject(forKey: accountKey(favoritesKey, account))
            UserDefaults.standard.removeObject(forKey: accountKey(recentKey, account))
            ArtworkLoader.shared.clear(scope: account.id)
        }
        URLCache.shared.removeAllCachedResponses()
        cacheUsageBytes = nil
    }

    private func activateSession(_ newSession: EmbySession?, forgetPreviousAccount: Bool = false) {
        let previousAccount = session?.account
        let accountChanged = newSession?.account != previousAccount
        // The stop callback checkpoints progress against the old session.
        player?.setSession(
            newSession,
            migratesLegacy: newSession.map { ownsLegacyData($0.account) } ?? false,
            forgetPreviousAccount: forgetPreviousAccount
        )
        if accountChanged { flushAudiobookProgress() }
        session = newSession
        sessionGeneration = UUID()
        libraryRefreshTask?.cancel()
        libraryRefreshTask = nil
        isRefreshingLibrary = false
        isRestoringCachedContent = false
        activeSearchToken = nil
        isSearching = false
        searchResults = []
        pendingFavoriteSongIds = []
        derivedDataGeneration += 1
        audiobookDataGeneration += 1
        homeContentFetchedAt = nil
        guard accountChanged else { return }

        clearSongs()
        liveAudiobookProgress = nil
        lastAudiobookProgressPublish = .distantPast
        generatedPlaylists = []
        playlists = []
        clearAudiobooks()
        audiobookProgress = [:]
        favoriteSongIds = []
        recentSongIds = []
        deletedSongIds = []
        serverFavoriteSongs = []
        dailyRecommendedSongs = []
        recentlyAddedSongs = []
        mostPlayedSongs = []
        dailyRecommendationDay = nil
        hasLoadedInitialContent = false
        libraryCacheSavedAt = nil
        errorMessage = nil
        favoriteErrorMessage = nil
        libraryStatus = "Not connected"
    }

    private func checkSession(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
    }

    func clearCaches() {
        guard !isClearingCache else { return }
        isClearingCache = true
        // Only cached song audio. The library snapshot and artwork stay so the app doesn't
        // have to resync from Emby afterwards.

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
    private func clearPersistedSnapshots(for account: EmbyAccountStorage) {
        let directory = account.directory
        let librarySnapshots = LibrarySnapshotStore(directory: directory)
        let homeSnapshots = InitialHomeContentSnapshotStore(directory: directory)
        let progressStore = AudiobookProgressStore(directory: directory)
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
        let previousSongs = songs
        let requiresDailyRecommendation = dailyRecommendationDay != day
        let derived = await Task.detached(priority: .userInitiated) {
            let trace = PerformanceTrace.library
            let span = trace.beginInterval("Index music library", id: trace.makeSignpostID())
            defer { trace.endInterval("Index music library", span) }
            guard previousSongs != newSongs else { return nil as DerivedLibraryData? }
            return DerivedLibraryData(songs: newSongs, day: day)
        }.value
        guard generation == derivedDataGeneration, !Task.isCancelled else { return false }
        guard let derived else {
            if requiresDailyRecommendation {
                let recommendation = await Task.detached(priority: .utility) {
                    DerivedLibraryData.dailyRecommendation(from: newSongs, day: day, limit: 50)
                }.value
                guard generation == derivedDataGeneration, !Task.isCancelled else { return false }
                dailyRecommendationDay = day
                dailyRecommendedSongs = recommendation
            }
            return true
        }

        songs = newSongs
        songsById = derived.songsById
        albums = derived.albums
        artists = derived.artists
        albumSections = derived.albumSections
        artistSections = derived.artistSections
        dailyRecommendationDay = day
        dailyRecommendedSongs = derived.dailyRecommendedSongs
        recentlyAddedSongs = derived.recentlyAddedSongs
        generatedPlaylists = derived.generatedPlaylists
        if !playlists.contains(where: \.isServerEditable) {
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
        generatedPlaylists = []
        recentSongs = []
        dailyRecommendedSongs = []
        recentlyAddedSongs = []
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
        let previousEpisodes = audiobookEpisodes
        let derived = await Task.detached(priority: .userInitiated) {
            previousEpisodes == episodes ? nil : DerivedAudiobookData(episodes: episodes)
        }.value
        guard generation == audiobookDataGeneration, !Task.isCancelled else { return false }
        guard let derived else { return true }

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
            if UserDefaults.standard.string(forKey: legacyAccountKey) == nil {
                UserDefaults.standard.set("", forKey: legacyAccountKey)
            }
            return
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: legacyAccountKey) == nil {
            defaults.set(restored.account.id, forKey: legacyAccountKey)
            for key in [favoritesKey, recentKey] {
                let scopedKey = accountKey(key, restored.account)
                if defaults.object(forKey: scopedKey) == nil, let values = defaults.stringArray(forKey: key) {
                    defaults.set(values, forKey: scopedKey)
                }
                defaults.removeObject(forKey: key)
            }
        }
        activateSession(restored)
        let generation = sessionGeneration
        isRestoringCachedContent = true
        Task {
            await restoreAccountContent(for: restored, generation: generation)
            guard sessionGeneration == generation else { return }
            if !hasLoadedInitialContent {
                isRestoringCachedContent = true
                await loadInitialHomeContent(session: restored, generation: generation)
                guard sessionGeneration == generation else { return }
                isRestoringCachedContent = false
            }
            if libraryCacheSavedAt.map({ Calendar.current.isDateInToday($0) }) == true {
                async let favorites: Void = refreshFavoritesFromServer(session: restored, generation: generation)
                async let mostPlayed: Void = refreshMostPlayedSongsFromServer(session: restored, generation: generation)
                _ = await (favorites, mostPlayed)
            } else {
                await refreshLibrary()
            }
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

    private func restoreAccountContent(for session: EmbySession, generation: UUID) async {
        guard sessionGeneration == generation, !Task.isCancelled else { return }
        isRestoringCachedContent = true
        defer {
            if sessionGeneration == generation { isRestoringCachedContent = false }
        }
        let account = session.account
        let defaults = UserDefaults.standard
        favoriteSongIds = Set(defaults.stringArray(forKey: accountKey(favoritesKey, account)) ?? [])
        recentSongIds = defaults.stringArray(forKey: accountKey(recentKey, account)) ?? []
        let directory = account.directory
        let libraryStore = LibrarySnapshotStore(directory: directory)
        let homeStore = InitialHomeContentSnapshotStore(directory: directory)
        let progressStore = AudiobookProgressStore(directory: directory)
        let migratesLegacy = ownsLegacyData(account)
        let cached: (LibrarySnapshot?, InitialHomeContentSnapshot?, [String: AudiobookPlaybackProgress]) =
            await withCheckedContinuation { continuation in
                persistenceQueue.async {
                    let trace = PerformanceTrace.library
                    let span = trace.beginInterval("Read library snapshots", id: trace.makeSignpostID())
                    defer { trace.endInterval("Read library snapshots", span) }
                    if migratesLegacy {
                        account.migrateLegacyFiles([
                            LibrarySnapshotStore.fileName,
                            InitialHomeContentSnapshotStore.fileName,
                            AudiobookProgressStore.fileName
                        ])
                    }
                    continuation.resume(returning: (libraryStore.load(), homeStore.load(), progressStore.load()))
                }
            }
        guard sessionGeneration == generation, !Task.isCancelled else { return }
        audiobookProgress.merge(cached.2) { live, saved in
            live.updatedAt >= saved.updatedAt ? live : saved
        }
        if let snapshot = cached.0 {
            guard await applySongs(snapshot.songs),
                  sessionGeneration == generation,
                  await applyAudiobookEpisodes(snapshot.audiobookEpisodes),
                  sessionGeneration == generation else { return }
            playlists = snapshot.playlists.isEmpty ? generatedPlaylists : snapshot.playlists
            mostPlayedSongs = cached.1?.content.mostPlayedSongs ?? []
            hasLoadedInitialContent = true
            libraryCacheSavedAt = snapshot.savedAt
            updateLibraryStatusFromCache()
        } else if let snapshot = cached.1 {
            guard await applyInitialHomeContent(
                snapshot.content, session: session, generation: generation, savesSnapshot: false
            ) else { return }
            libraryStatus = "Loaded home content from cache."
        }
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

    private func saveLibrarySnapshot() {
        guard let account = session?.account, hasLoadedInitialContent else { return }
        let store = LibrarySnapshotStore(directory: account.directory)
        let savedSongs = songs
        let savedPlaylists = playlists
        let savedAudiobookEpisodes = audiobookEpisodes
        let savedAt = libraryCacheSavedAt ?? Date(timeIntervalSince1970: 0)
        persistenceQueue.async {
            store.save(songs: savedSongs, playlists: savedPlaylists, audiobookEpisodes: savedAudiobookEpisodes, savedAt: savedAt)
        }
    }

    private func persistFavoriteSongIds() {
        guard let account = session?.account else { return }
        UserDefaults.standard.set(Array(favoriteSongIds).sorted(), forKey: accountKey(favoritesKey, account))
    }

    private func accountKey(_ key: String, _ account: EmbyAccountStorage) -> String {
        "\(key).\(account.id)"
    }

    private func ownsLegacyData(_ account: EmbyAccountStorage) -> Bool {
        UserDefaults.standard.string(forKey: legacyAccountKey) == account.id
    }

    private func restoreLocalState() {
        if let rawValue = UserDefaults.standard.string(forKey: cellularOnlineQualityKey),
           let quality = OnlinePlaybackQuality(rawValue: rawValue) {
            cellularOnlineQuality = quality
        }
        if let rawValue = UserDefaults.standard.string(forKey: wifiOnlineQualityKey),
           let quality = OnlinePlaybackQuality(rawValue: rawValue) {
            wifiOnlineQuality = quality
        }
        startsOnBrowse = UserDefaults.standard.bool(forKey: startsOnBrowseKey)
        keepsScreenAwakeOnPlayerPage = UserDefaults.standard.bool(forKey: keepsScreenAwakeKey)
        // The 120Hz toggle was removed: the Info.plist key already enables ProMotion everywhere.
        UserDefaults.standard.removeObject(forKey: highRefreshRateKey)
        // Song caching was removed (it downloaded each song twice), and with it this setting.
        UserDefaults.standard.removeObject(forKey: audioCacheLimitKey)
    }

    private func refreshMostPlayedSongsFromServer(session: EmbySession, generation: UUID) async {
        do {
            let fresh = try await client.fetchMostPlayedSongs(session: session, limit: 50)
            try checkSession(generation)
            mostPlayedSongs = fresh.filter { !deletedSongIds.contains($0.id) }
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

struct LibrarySnapshot: Codable, Sendable {
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

struct LibrarySnapshotStore: Sendable {
    static let fileName = "library-snapshot.json"
    let directory: URL
    private let version = 2

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

    func save(songs: [EmbyAudioItem], playlists: [MusicPlaylist], audiobookEpisodes: [EmbyAudioItem], savedAt: Date) {
        let trace = PerformanceTrace.library
        let span = trace.beginInterval("Write library snapshot", id: trace.makeSignpostID())
        defer { trace.endInterval("Write library snapshot", span) }
        let snapshot = LibrarySnapshot(
            version: version,
            savedAt: savedAt,
            songs: songs,
            playlists: playlists,
            audiobookEpisodes: audiobookEpisodes
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
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
        directory.appendingPathComponent(Self.fileName)
    }
}

private struct InitialHomeContentSnapshot: Codable, Sendable {
    let version: Int
    let savedAt: Date
    let content: InitialHomeContent
}

private struct InitialHomeContentSnapshotStore: Sendable {
    static let fileName = "initial-home-snapshot.json"
    let directory: URL
    private let version = 2

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
        directory.appendingPathComponent(Self.fileName)
    }
}

struct AudiobookPlaybackProgress: Codable, Hashable, Sendable {
    let position: TimeInterval
    let duration: TimeInterval
    let updatedAt: Date
    let isFinished: Bool
}

private struct AudiobookProgressStore: Sendable {
    static let fileName = "audiobook-progress.json"
    let directory: URL
    private let version = 1

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
        directory.appendingPathComponent(Self.fileName)
    }

    private struct Snapshot: Codable {
        let version: Int
        let progress: [String: AudiobookPlaybackProgress]
    }
}
