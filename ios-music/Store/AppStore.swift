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
    @Published var errorMessage: String?
    @Published var libraryStatus = "Not connected"
    @Published var favoriteSongIds: Set<String> = []
    @Published var recentSongIds: [String] = []

    // Cached derived data — recomputed only when songs change
    @Published private(set) var albums: [MusicAlbum] = []
    @Published private(set) var artists: [MusicArtist] = []
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var recentSongs: [EmbyAudioItem] = []
    @Published private(set) var dailyRecommendedSongs: [EmbyAudioItem] = []
    @Published private(set) var recentlyAddedSongs: [EmbyAudioItem] = []
    @Published private(set) var mostPlayedSongs: [EmbyAudioItem] = []

    private let client = EmbyClient()
    private let sessionKey = "EmbySession"
    private let favoritesKey = "FavoriteSongIds"
    private let recentKey = "RecentSongIds"
    private var activeSearchToken: UUID?

    weak var player: PlayerController?

    var lastPlayedSong: EmbyAudioItem? {
        recentSongs.first
    }

    func play(song: EmbyAudioItem, in songs: [EmbyAudioItem]) {
        guard let session else { return }
        registerPlayback(song: song)
        player?.play(song: song, in: songs, session: session)
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
        errorMessage = nil
        libraryStatus = "Not connected"
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    private func updateLibraryStatus() {
        if songs.isEmpty {
            libraryStatus = "Connected, but Emby returned 0 audio items."
        } else {
            libraryStatus = "Loaded \(songs.count) songs."
        }
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
            libraryStatus = error.localizedDescription
        }
    }

    private func persist(_ session: EmbySession) {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    private func recomputeDerivedData() {
        guard !songs.isEmpty else {
            albums = []; artists = []; playlists = []; recentSongs = []
            dailyRecommendedSongs = []; recentlyAddedSongs = []; mostPlayedSongs = []
            return
        }
        albums = songs.musicAlbums
        artists = songs.musicArtists
        let byId = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let ordered = recentSongIds.compactMap { byId[$0] }
        recentSongs = ordered.isEmpty ? Array(songs.prefix(20)) : ordered
        dailyRecommendedSongs = dailyRecommendation(from: songs, limit: 50)
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
        Task {
            await refreshLibrary()
        }
    }

    private func restoreLocalState() {
        favoriteSongIds = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        recentSongIds = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    private func dailyRecommendation(from songs: [EmbyAudioItem], limit: Int) -> [EmbyAudioItem] {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
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
        var hash = UInt64(day &* 1_103_515_245)
        for scalar in id.unicodeScalars {
            hash = hash &* 1_099_511_628_211 &+ UInt64(scalar.value)
        }
        return hash
    }
}
