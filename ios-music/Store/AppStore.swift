import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published var session: EmbySession?
    @Published var songs: [EmbyAudioItem] = [] {
        didSet { recomputeDerivedData() }
    }
    @Published var searchResults: [EmbyAudioItem] = []
    @Published var isLoading = false
    @Published var isSearching = false
    @Published private(set) var hasLoadedInitialContent = false
    @Published var errorMessage: String?
    @Published var libraryStatus = "Not connected"
    @Published var favoriteSongIds: Set<String> = []
    @Published var recentSongIds: [String] = []
    @Published var cellularOnlineQuality: OnlinePlaybackQuality = .standard {
        didSet {
            UserDefaults.standard.set(cellularOnlineQuality.rawValue, forKey: cellularOnlineQualityKey)
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
        }
    }
    @Published var wifiOnlineQuality: OnlinePlaybackQuality = .lossless {
        didSet {
            UserDefaults.standard.set(wifiOnlineQuality.rawValue, forKey: wifiOnlineQualityKey)
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
        }
    }
    @Published var startsOnBrowse = false {
        didSet { UserDefaults.standard.set(startsOnBrowse, forKey: startsOnBrowseKey) }
    }
    @Published var keepsScreenAwakeOnPlayerPage = false {
        didSet { UserDefaults.standard.set(keepsScreenAwakeOnPlayerPage, forKey: keepsScreenAwakeKey) }
    }
    @Published var prefersHighRefreshRate = false {
        didSet { UserDefaults.standard.set(prefersHighRefreshRate, forKey: highRefreshRateKey) }
    }

    // Cached derived data — recomputed only when source media changes
    @Published private(set) var albums: [MusicAlbum] = []
    @Published private(set) var artists: [MusicArtist] = []
    @Published private(set) var albumSections: [IndexedSection<MusicAlbum>] = []
    @Published private(set) var artistSections: [IndexedSection<MusicArtist>] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var audiobookEpisodes: [EmbyAudioItem] = [] {
        didSet { recomputeAudiobooks() }
    }
    @Published private(set) var audiobooks: [Audiobook] = []
    @Published private(set) var audiobookSections: [IndexedSection<Audiobook>] = []
    @Published private(set) var audiobookProgress: [String: AudiobookPlaybackProgress] = [:]
    @Published private(set) var recentSongs: [EmbyAudioItem] = []
    @Published private(set) var dailyRecommendedSongs: [EmbyAudioItem] = []
    @Published private(set) var recentlyAddedSongs: [EmbyAudioItem] = []
    @Published private(set) var mostPlayedSongs: [EmbyAudioItem] = []

    private let client = EmbyClient()
    private let snapshotStore = LibrarySnapshotStore()
    private let initialHomeSnapshotStore = InitialHomeContentSnapshotStore()
    private let audiobookProgressStore = AudiobookProgressStore()
    private let sessionKey = "EmbySession"
    private let favoritesKey = "FavoriteSongIds"
    private let recentKey = "RecentSongIds"
    private let cellularOnlineQualityKey = "CellularOnlinePlaybackQuality"
    private let wifiOnlineQualityKey = "WiFiOnlinePlaybackQuality"
    private let startsOnBrowseKey = "StartsOnBrowse"
    private let keepsScreenAwakeKey = "KeepsScreenAwakeOnPlayerPage"
    private let highRefreshRateKey = "PrefersHighRefreshRate"
    private var activeSearchToken: UUID?
    private var libraryCacheSavedAt: Date?
    private var dailyRecommendationDay: Int?
    private var audiobookEpisodeBookIds: [String: String] = [:]
    private var lastAudiobookProgressSave = Date.distantPast

    weak var player: PlayerController? {
        didSet {
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
            player?.onPlaybackPositionChanged = { [weak self] item, position, duration, isFinished in
                self?.recordAudiobookPlayback(
                    item: item,
                    position: position,
                    duration: duration,
                    isFinished: isFinished
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

    var favoriteSongs: [EmbyAudioItem] {
        songs.filter { favoriteSongIds.contains($0.id) }
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
        if libraryStatus == "Cache cleared." {
            return "缓存已清除"
        }
        if libraryStatus == "Cache cleared. Current library remains in memory." {
            return "缓存已清除，当前资料库仍保留在内存中"
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
        durationOverride: TimeInterval? = nil
    ) {
        guard let session else { return }
        registerPlayback(song: song)
        player?.play(
            song: song,
            in: songs,
            session: session,
            startPosition: startPosition,
            durationOverride: durationOverride
        )
    }

    func playAudiobook(_ audiobook: Audiobook) {
        guard let target = audiobookResumeTarget(for: audiobook) else { return }
        play(
            song: target.episode,
            in: audiobook.episodes,
            startPosition: target.position,
            durationOverride: target.duration
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
    }

    func signIn(server: String, username: String, password: String) async {
        await perform {
            let session = try await client.authenticate(server: server, username: username, password: password)
            self.session = session
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
        applyInitialHomeContent(content)
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
    ) {
        playlists = content.playlists
        audiobookEpisodes = content.audiobookEpisodes
        recentlyAddedSongs = content.recentlyAddedSongs
        mostPlayedSongs = content.mostPlayedSongs

        let day = currentRecommendationDay()
        let dailySeed = firstNonEmptySongList(
            content.dailySeedSongs,
            content.recentlyAddedSongs,
            content.mostPlayedSongs
        )
        dailyRecommendationDay = day
        dailyRecommendedSongs = dailyRecommendation(from: dailySeed, day: day, limit: 50)
        hasLoadedInitialContent = true
        libraryStatus = "Loaded home content."

        if savesSnapshot {
            initialHomeSnapshotStore.save(content)
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
    ) {
        self.songs = songs
        self.playlists = playlists.isEmpty ? songs.generatedPlaylists : playlists
        self.audiobookEpisodes = audiobookEpisodes
        if let mostPlayedSongs {
            self.mostPlayedSongs = mostPlayedSongs
        }
        self.hasLoadedInitialContent = true
        self.libraryCacheSavedAt = Date()
        self.saveLibrarySnapshot()
        self.updateLibraryStatus()
    }

    private func fetchAndApplyFullLibrary(session: EmbySession) async throws {
        async let songs = client.fetchSongs(session: session)
        async let playlists = client.fetchPlaylists(session: session)
        async let audiobookEpisodes = client.fetchAudiobookEpisodes(session: session)
        async let mostPlayedSongs = client.fetchMostPlayedSongs(session: session, limit: 50)

        let loadedSongs = try await songs
        let loadedPlaylists = (try? await playlists) ?? []
        let loadedAudiobookEpisodes = (try? await audiobookEpisodes) ?? []
        let loadedMostPlayedSongs = (try? await mostPlayedSongs) ?? self.mostPlayedSongs

        applyFullLibrary(
            songs: loadedSongs,
            playlists: loadedPlaylists,
            audiobookEpisodes: loadedAudiobookEpisodes,
            mostPlayedSongs: loadedMostPlayedSongs
        )
    }

    func refreshLibrary() async {
        guard let session else { return }
        await perform {
            try await self.fetchAndApplyFullLibrary(session: session)
        }
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
            let results = try await client.fetchSongs(session: session, searchTerm: normalized)
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

    func imageURL(for song: EmbyAudioItem, size: Int = 600) -> URL? {
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

    func isCurrentAudiobookEpisode(_ episode: EmbyAudioItem) -> Bool {
        player?.currentSong?.id == episode.id
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
        if favoriteSongIds.contains(song.id) {
            favoriteSongIds.remove(song.id)
        } else {
            favoriteSongIds.insert(song.id)
        }
        UserDefaults.standard.set(Array(favoriteSongIds), forKey: favoritesKey)
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
        isFinished: Bool
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

        var updatedProgress = audiobookProgress
        updatedProgress[item.id] = progress
        audiobookProgress = updatedProgress
        saveAudiobookProgressIfNeeded(force: finished)
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
            hasChanges = true
        }

        guard hasChanges else { return }
        audiobookProgress = updatedProgress
        audiobookProgressStore.save(updatedProgress)
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

    private func saveAudiobookProgressIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastAudiobookProgressSave) >= 4 else { return }
        lastAudiobookProgressSave = now
        audiobookProgressStore.save(audiobookProgress)
    }

    func signOut() {
        session = nil
        songs = []
        playlists = []
        audiobookEpisodes = []
        audiobooks = []
        audiobookSections = []
        audiobookProgress = [:]
        audiobookEpisodeBookIds = [:]
        searchResults = []
        dailyRecommendedSongs = []
        recentlyAddedSongs = []
        mostPlayedSongs = []
        dailyRecommendationDay = nil
        hasLoadedInitialContent = false
        libraryCacheSavedAt = nil
        errorMessage = nil
        libraryStatus = "Not connected"
        UserDefaults.standard.removeObject(forKey: sessionKey)
        snapshotStore.clear()
        initialHomeSnapshotStore.clear()
        audiobookProgressStore.clear()
        ArtworkImageCache.shared.clear()
        ArtworkDiskCache.clear()
        PlaybackAudioCache.clearAll()
        URLCache.shared.removeAllCachedResponses()
    }

    func clearCaches() {
        snapshotStore.clear()
        initialHomeSnapshotStore.clear()
        ArtworkImageCache.shared.clear()
        ArtworkDiskCache.clear()
        PlaybackAudioCache.clearAll()
        URLCache.shared.removeAllCachedResponses()
        hasLoadedInitialContent = hasHomeContent || hasBrowseContent
        libraryCacheSavedAt = nil
        libraryStatus = songs.isEmpty && audiobookEpisodes.isEmpty
            ? "Cache cleared."
            : "Cache cleared. Current library remains in memory."
    }

    func refreshDailyRecommendationsIfNeeded() {
        let day = currentRecommendationDay()
        if dailyRecommendationDay != day {
            refreshDailyRecommendations(for: day)
        }
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
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    private func recomputeDerivedData() {
        guard !songs.isEmpty else {
            albums = []; artists = []; albumSections = []; artistSections = []; recentSongs = []
            dailyRecommendedSongs = []; recentlyAddedSongs = []; mostPlayedSongs = []
            dailyRecommendationDay = nil
            return
        }
        albums = songs.musicAlbums
        artists = songs.musicArtists
        albumSections = PinyinIndexer.sections(for: albums, title: \.title)
        artistSections = PinyinIndexer.sections(for: artists, title: \.name)
        refreshRecentSongs()
        let day = currentRecommendationDay()
        refreshDailyRecommendations(for: day)
        recentlyAddedSongs = recentlyAdded(from: songs, limit: 50)
        if playlists.isEmpty {
            playlists = songs.generatedPlaylists
        }
    }

    private func refreshRecentSongs() {
        guard !songs.isEmpty else {
            recentSongs = []
            return
        }

        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let ordered = recentSongIds.compactMap { byId[$0] }
        recentSongs = ordered.isEmpty ? Array(songs.prefix(20)) : ordered
    }

    private func recomputeAudiobooks() {
        audiobooks = audiobookEpisodes.audiobooks
        audiobookSections = PinyinIndexer.sections(for: audiobooks, title: \.title)
        var episodeBookIds: [String: String] = [:]
        for audiobook in audiobooks {
            for episode in audiobook.episodes {
                episodeBookIds[episode.id] = audiobook.id
            }
        }
        audiobookEpisodeBookIds = episodeBookIds
        mergeServerAudiobookProgress(from: audiobookEpisodes)
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let restored = try? JSONDecoder().decode(EmbySession.self, from: data) else {
            return
        }
        session = restored

        if restoreLibrarySnapshot() {
            return
        }

        if restoreInitialHomeSnapshot() {
            Task {
                await refreshLibraryIfNeededForToday()
            }
            return
        }

        Task {
            await loadInitialHomeContent(session: restored)
            await refreshLibraryIfNeededForToday()
        }
    }

    private func restoreLibrarySnapshot() -> Bool {
        guard let snapshot = snapshotStore.load(),
              (!snapshot.songs.isEmpty || !snapshot.audiobookEpisodes.isEmpty),
              Calendar.current.isDateInToday(snapshot.savedAt) else {
            return false
        }

        songs = snapshot.songs
        playlists = snapshot.playlists.isEmpty ? snapshot.songs.generatedPlaylists : snapshot.playlists
        audiobookEpisodes = snapshot.audiobookEpisodes
        hasLoadedInitialContent = true
        libraryCacheSavedAt = snapshot.savedAt
        updateLibraryStatusFromCache()
        Task {
            await refreshMostPlayedSongsFromServer()
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

    private func restoreInitialHomeSnapshot() -> Bool {
        guard let snapshot = initialHomeSnapshotStore.load(),
              Calendar.current.isDateInToday(snapshot.savedAt) else {
            return false
        }

        applyInitialHomeContent(snapshot.content, savedAt: snapshot.savedAt, savesSnapshot: false)
        libraryStatus = "Loaded home content from cache."
        return true
    }

    private func saveLibrarySnapshot() {
        guard !songs.isEmpty || !audiobookEpisodes.isEmpty else { return }
        snapshotStore.save(songs: songs, playlists: playlists, audiobookEpisodes: audiobookEpisodes)
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
        prefersHighRefreshRate = UserDefaults.standard.bool(forKey: highRefreshRateKey)
    }

    private func refreshDailyRecommendations(for day: Int) {
        dailyRecommendationDay = day
        dailyRecommendedSongs = dailyRecommendation(from: songs, day: day, limit: 50)
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

    private func dailyRecommendation(from songs: [EmbyAudioItem], day: Int, limit: Int) -> [EmbyAudioItem] {
        return songs
            .sorted { deterministicScore(for: $0.id, day: day) < deterministicScore(for: $1.id, day: day) }
            .prefix(limit)
            .map { $0 }
    }

    private func recentlyAdded(from songs: [EmbyAudioItem], limit: Int) -> [EmbyAudioItem] {
        let sorted = songs.sorted {
            ($0.dateCreated ?? .distantPast) > ($1.dateCreated ?? .distantPast)
        }
        if sorted.first?.dateCreated != nil {
            return Array(sorted.prefix(limit))
        }
        return Array(songs.prefix(limit))
    }

    private func deterministicScore(for id: String, day: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for scalar in id.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }
        hash ^= UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15
        return avalanche(hash)
    }

    private func avalanche(_ value: UInt64) -> UInt64 {
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
        return base.appendingPathComponent("MusicEmby", isDirectory: true)
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
        return base.appendingPathComponent("MusicEmby", isDirectory: true)
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
        return base.appendingPathComponent("MusicEmby", isDirectory: true)
    }

    private struct Snapshot: Codable {
        let version: Int
        let progress: [String: AudiobookPlaybackProgress]
    }
}
