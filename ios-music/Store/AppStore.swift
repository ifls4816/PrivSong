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
    @Published private(set) var hasLibraryCache = false
    @Published var errorMessage: String?
    @Published var libraryStatus = "Not connected"
    @Published var favoriteSongIds: Set<String> = []
    @Published var recentSongIds: [String] = []
    @Published var isPlaybackFadeEnabled = false {
        didSet {
            UserDefaults.standard.set(isPlaybackFadeEnabled, forKey: playbackFadeKey)
            player?.setPlaybackFadesEnabled(isPlaybackFadeEnabled)
        }
    }
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
    @Published var audioTranscodeFormat: AudioTranscodeFormat = .mp3 {
        didSet {
            UserDefaults.standard.set(audioTranscodeFormat.rawValue, forKey: audioTranscodeFormatKey)
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

    // Cached derived data — recomputed only when songs change
    @Published private(set) var albums: [MusicAlbum] = []
    @Published private(set) var artists: [MusicArtist] = []
    @Published private(set) var albumSections: [IndexedSection<MusicAlbum>] = []
    @Published private(set) var artistSections: [IndexedSection<MusicArtist>] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var recentSongs: [EmbyAudioItem] = []
    @Published private(set) var dailyRecommendedSongs: [EmbyAudioItem] = []
    @Published private(set) var recentlyAddedSongs: [EmbyAudioItem] = []
    @Published private(set) var mostPlayedSongs: [EmbyAudioItem] = []

    private let client = EmbyClient()
    private let snapshotStore = LibrarySnapshotStore()
    private let libraryCacheRefreshInterval: TimeInterval = 6 * 60 * 60
    private let sessionKey = "EmbySession"
    private let favoritesKey = "FavoriteSongIds"
    private let recentKey = "RecentSongIds"
    private let playbackFadeKey = "PlaybackFadeEnabled"
    private let cellularOnlineQualityKey = "CellularOnlinePlaybackQuality"
    private let wifiOnlineQualityKey = "WiFiOnlinePlaybackQuality"
    private let audioTranscodeFormatKey = "AudioTranscodeFormat"
    private let startsOnBrowseKey = "StartsOnBrowse"
    private let keepsScreenAwakeKey = "KeepsScreenAwakeOnPlayerPage"
    private let highRefreshRateKey = "PrefersHighRefreshRate"
    private var activeSearchToken: UUID?
    private var libraryCacheSavedAt: Date?
    private var dailyRecommendationDay: Int?

    weak var player: PlayerController? {
        didSet {
            player?.setPlaybackFadesEnabled(isPlaybackFadeEnabled)
            player?.setPlaybackQualityPreferences(playbackQualityPreferences)
        }
    }

    var lastPlayedSong: EmbyAudioItem? {
        recentSongs.first
    }

    var favoriteSongs: [EmbyAudioItem] {
        songs.filter { favoriteSongIds.contains($0.id) }
    }

    var playbackQualityPreferences: PlaybackQualityPreferences {
        PlaybackQualityPreferences(
            cellularQuality: cellularOnlineQuality,
            wifiQuality: wifiOnlineQuality,
            transcodeFormat: audioTranscodeFormat
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
        if let count = loadedSongCount(from: libraryStatus, suffix: " songs.") {
            return "已加载 \(count) 首歌曲"
        }
        if let count = loadedSongCount(from: libraryStatus, suffix: " songs from cache.") {
            return "已从缓存加载 \(count) 首歌曲"
        }
        return libraryStatus
    }

    func play(song: EmbyAudioItem, in songs: [EmbyAudioItem]) {
        guard let session else { return }
        registerPlayback(song: song)
        player?.play(song: song, in: songs, session: session)
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
            let songs = try await client.fetchSongs(session: session)
            let playlists = (try? await client.fetchPlaylists(session: session)) ?? []
            self.songs = songs
            self.playlists = playlists.isEmpty ? songs.generatedPlaylists : playlists
            self.hasLibraryCache = !songs.isEmpty
            self.libraryCacheSavedAt = Date()
            self.saveLibrarySnapshot()
            self.updateLibraryStatus()
        }
    }

    func refreshLibrary() async {
        guard let session else { return }
        await perform {
            let songs = try await client.fetchSongs(session: session)
            let playlists = (try? await client.fetchPlaylists(session: session)) ?? []
            self.songs = songs
            self.playlists = playlists.isEmpty ? songs.generatedPlaylists : playlists
            self.hasLibraryCache = !songs.isEmpty
            self.libraryCacheSavedAt = Date()
            self.saveLibrarySnapshot()
            self.updateLibraryStatus()
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

    func registerPlayback(song: EmbyAudioItem) {
        recentSongIds.removeAll { $0 == song.id }
        recentSongIds.insert(song.id, at: 0)
        recentSongIds = Array(recentSongIds.prefix(50))
        UserDefaults.standard.set(recentSongIds, forKey: recentKey)
        recomputeDerivedData()
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

    func signOut() {
        session = nil
        songs = []
        playlists = []
        searchResults = []
        dailyRecommendedSongs = []
        recentlyAddedSongs = []
        mostPlayedSongs = []
        hasLibraryCache = false
        libraryCacheSavedAt = nil
        errorMessage = nil
        libraryStatus = "Not connected"
        UserDefaults.standard.removeObject(forKey: sessionKey)
        snapshotStore.clear()
        ArtworkImageCache.shared.clear()
        ArtworkDiskCache.clear()
        PlaybackAudioCache.clearAll()
        URLCache.shared.removeAllCachedResponses()
    }

    func clearCaches() {
        snapshotStore.clear()
        ArtworkImageCache.shared.clear()
        ArtworkDiskCache.clear()
        PlaybackAudioCache.clearAll()
        URLCache.shared.removeAllCachedResponses()
        hasLibraryCache = false
        libraryCacheSavedAt = nil
        libraryStatus = songs.isEmpty ? "Cache cleared." : "Cache cleared. Current library remains in memory."
    }

    func refreshDailyRecommendationsIfNeeded() {
        let day = currentRecommendationDay()
        guard dailyRecommendationDay != day else { return }
        refreshDailyRecommendations(for: day)
    }

    private func updateLibraryStatus() {
        if songs.isEmpty {
            libraryStatus = "Connected, but Emby returned 0 audio items."
        } else {
            libraryStatus = "Loaded \(songs.count) songs."
        }
    }

    private func loadedSongCount(from status: String, suffix: String) -> Int? {
        guard status.hasPrefix("Loaded "), status.hasSuffix(suffix) else { return nil }
        let start = status.index(status.startIndex, offsetBy: "Loaded ".count)
        let end = status.index(status.endIndex, offsetBy: -suffix.count)
        return Int(status[start..<end])
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
            if songs.isEmpty {
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
            albums = []; artists = []; albumSections = []; artistSections = []; playlists = []; recentSongs = []
            dailyRecommendedSongs = []; recentlyAddedSongs = []; mostPlayedSongs = []
            return
        }
        albums = songs.musicAlbums
        artists = songs.musicArtists
        albumSections = PinyinIndexer.sections(for: albums, title: \.title)
        artistSections = PinyinIndexer.sections(for: artists, title: \.name)
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let ordered = recentSongIds.compactMap { byId[$0] }
        recentSongs = ordered.isEmpty ? Array(songs.prefix(20)) : ordered
        refreshDailyRecommendations(for: currentRecommendationDay())
        recentlyAddedSongs = recentlyAdded(from: songs, limit: 50)
        mostPlayedSongs = mostPlayed(from: songs, fallback: recentSongs, limit: 50)
        if playlists.isEmpty {
            playlists = songs.generatedPlaylists
        }
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let restored = try? JSONDecoder().decode(EmbySession.self, from: data) else {
            return
        }
        session = restored

        if restoreLibrarySnapshot() {
            if shouldRefreshCachedLibrary() {
                Task {
                    await refreshLibrary()
                }
            }
            return
        }

        Task {
            await refreshLibrary()
        }
    }

    private func restoreLibrarySnapshot() -> Bool {
        guard let snapshot = snapshotStore.load(),
              !snapshot.songs.isEmpty else {
            hasLibraryCache = false
            return false
        }

        songs = snapshot.songs
        playlists = snapshot.playlists.isEmpty ? snapshot.songs.generatedPlaylists : snapshot.playlists
        hasLibraryCache = true
        libraryCacheSavedAt = snapshot.savedAt
        libraryStatus = "Loaded \(snapshot.songs.count) songs from cache."
        return true
    }

    private func shouldRefreshCachedLibrary() -> Bool {
        guard let libraryCacheSavedAt else { return true }
        return Date().timeIntervalSince(libraryCacheSavedAt) >= libraryCacheRefreshInterval
    }

    private func saveLibrarySnapshot() {
        guard !songs.isEmpty else { return }
        snapshotStore.save(songs: songs, playlists: playlists)
    }

    private func restoreLocalState() {
        favoriteSongIds = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        recentSongIds = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        isPlaybackFadeEnabled = UserDefaults.standard.bool(forKey: playbackFadeKey)
        if let rawValue = UserDefaults.standard.string(forKey: cellularOnlineQualityKey),
           let quality = OnlinePlaybackQuality(rawValue: rawValue) {
            cellularOnlineQuality = quality
        }
        if let rawValue = UserDefaults.standard.string(forKey: wifiOnlineQualityKey),
           let quality = OnlinePlaybackQuality(rawValue: rawValue) {
            wifiOnlineQuality = quality
        }
        if let rawValue = UserDefaults.standard.string(forKey: audioTranscodeFormatKey),
           let format = AudioTranscodeFormat(rawValue: rawValue) {
            audioTranscodeFormat = format
        }
        startsOnBrowse = UserDefaults.standard.bool(forKey: startsOnBrowseKey)
        keepsScreenAwakeOnPlayerPage = UserDefaults.standard.bool(forKey: keepsScreenAwakeKey)
        prefersHighRefreshRate = UserDefaults.standard.bool(forKey: highRefreshRateKey)
    }

    private func refreshDailyRecommendations(for day: Int) {
        dailyRecommendationDay = day
        dailyRecommendedSongs = dailyRecommendation(from: songs, day: day, limit: 50)
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

    private func mostPlayed(from songs: [EmbyAudioItem], fallback: [EmbyAudioItem], limit: Int) -> [EmbyAudioItem] {
        let played = songs.filter { ($0.userData?.playCount ?? 0) > 0 }
        if !played.isEmpty {
            return Array(played.sorted {
                let leftCount = $0.userData?.playCount ?? 0
                let rightCount = $1.userData?.playCount ?? 0
                if leftCount != rightCount {
                    return leftCount > rightCount
                }
                return ($0.userData?.lastPlayedDate ?? .distantPast) > ($1.userData?.lastPlayedDate ?? .distantPast)
            }.prefix(limit))
        }
        return Array((fallback.isEmpty ? songs : fallback).prefix(limit))
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
}

private struct LibrarySnapshotStore {
    private let version = 1
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

    func save(songs: [EmbyAudioItem], playlists: [MusicPlaylist]) {
        let snapshot = LibrarySnapshot(
            version: version,
            savedAt: Date(),
            songs: songs,
            playlists: playlists
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
