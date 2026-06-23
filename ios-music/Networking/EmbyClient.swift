import Foundation

struct InitialHomeContent: Codable {
    let playlists: [MusicPlaylist]
    let dailySeedSongs: [EmbyAudioItem]
    let recentlyAddedSongs: [EmbyAudioItem]
    let mostPlayedSongs: [EmbyAudioItem]
}

struct EmbyClient {
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    private let deviceIdKey = "EmbyDeviceId"
    private let itemFields = "Album,AlbumId,AlbumArtist,AlbumPrimaryImageTag,Artists,Bitrate,Container,DateCreated,ImageTags,MediaSources,MediaType,PrimaryImageItemId,PrimaryImageAspectRatio,ProductionYear,RunTimeTicks,UserData"

    init(session: URLSession = .shared) {
        self.session = session
        self.jsonDecoder = JSONDecoder()
    }

    func authenticate(server: String, username: String, password: String) async throws -> EmbySession {
        let baseURL = try normalizedServerURL(server)
        var request = URLRequest(url: baseURL.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(accessToken: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "Username": username,
            "Pw": password
        ])

        let response: EmbyAuthResponse = try await send(request)
        return EmbySession(
            serverURL: baseURL,
            userId: response.user.id,
            username: response.user.name,
            accessToken: response.accessToken
        )
    }

    func fetchSongs(session embySession: EmbySession, searchTerm: String? = nil) async throws -> [EmbyAudioItem] {
        let musicViews = try await fetchMusicViews(session: embySession)
        let scopedSongs = try await fetchSongsFromViews(
            musicViews,
            session: embySession,
            searchTerm: searchTerm
        )
        if !scopedSongs.isEmpty {
            return scopedSongs
        }

        let walkedSongs = try await fetchSongsByWalkingDirectories(
            musicViews,
            session: embySession,
            searchTerm: searchTerm
        )
        if !walkedSongs.isEmpty {
            return walkedSongs
        }

        let primary = try await fetchSongs(
            session: embySession,
            searchTerm: searchTerm,
            parentId: nil,
            filterName: "IncludeItemTypes",
            filterValue: "Audio"
        )
        if !primary.isEmpty {
            return primary
        }

        let mediaTypeMatches = try await fetchSongs(
            session: embySession,
            searchTerm: searchTerm,
            parentId: nil,
            filterName: "MediaTypes",
            filterValue: "Audio"
        )
        if !mediaTypeMatches.isEmpty {
            return mediaTypeMatches
        }

        let visibleItems = try await fetchSongs(
            session: embySession,
            searchTerm: searchTerm,
            parentId: nil,
            filterName: nil,
            filterValue: nil
        )
        return visibleItems.filter(\.isAudio)
    }

    func fetchInitialHomeContent(session embySession: EmbySession) async throws -> InitialHomeContent {
        let musicViews = try await fetchMusicViews(session: embySession)

        async let playlists = fetchPlaylistSummaries(session: embySession)
        async let dailySeedSongs = fetchSongSample(
            from: musicViews,
            session: embySession,
            sortBy: "Random",
            sortOrder: "Ascending",
            limit: 50
        )
        async let recentlyAddedSongs = fetchSongSample(
            from: musicViews,
            session: embySession,
            sortBy: "DateCreated",
            sortOrder: "Descending",
            limit: 50
        )
        async let mostPlayedSongs = fetchSongSample(
            from: musicViews,
            session: embySession,
            sortBy: "PlayCount",
            sortOrder: "Descending",
            limit: 50
        )

        return InitialHomeContent(
            playlists: (try? await playlists) ?? [],
            dailySeedSongs: (try? await dailySeedSongs) ?? [],
            recentlyAddedSongs: (try? await recentlyAddedSongs) ?? [],
            mostPlayedSongs: (try? await mostPlayedSongs) ?? []
        )
    }

    func fetchPlaylists(session embySession: EmbySession) async throws -> [MusicPlaylist] {
        let playlistItems = try await fetchPlaylistItems(session: embySession)
        guard !playlistItems.isEmpty else { return [] }

        var playlists: [MusicPlaylist] = []
        for item in playlistItems {
            let songs = (try? await fetchPlaylistSongs(playlistId: item.id, session: embySession)) ?? []
            playlists.append(
                MusicPlaylist(
                    id: item.id,
                    name: item.name,
                    description: "\(songs.count) 首歌曲",
                    songs: songs,
                    songCount: item.childCount ?? songs.count
                )
            )
        }

        return playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchPlaylistSummaries(session embySession: EmbySession) async throws -> [MusicPlaylist] {
        try await fetchPlaylistItems(session: embySession)
            .map { item in
                let count = item.childCount ?? 0
                return MusicPlaylist(
                    id: item.id,
                    name: item.name,
                    description: "\(count) 首歌曲",
                    songs: [],
                    songCount: item.childCount
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchPlaylistSongs(playlistId: String, session embySession: EmbySession) async throws -> [EmbyAudioItem] {
        do {
            return try await fetchPlaylistSongsFromPlaylistEndpoint(playlistId: playlistId, session: embySession)
        } catch {
            return try await fetchSongs(
                session: embySession,
                searchTerm: nil,
                parentId: playlistId,
                filterName: "IncludeItemTypes",
                filterValue: "Audio"
            )
        }
    }

    private func fetchMusicViews(session embySession: EmbySession) async throws -> [EmbyLibraryView] {
        let views = try await fetchViews(session: embySession)
        let musicViews = views.filter(\.isMusicLibrary)
        guard !musicViews.isEmpty else {
            throw EmbyError.noMusicLibrary(views.map { "\($0.name)(\($0.collectionType ?? "unknown"))" })
        }
        return musicViews
    }

    private func fetchViews(session embySession: EmbySession) async throws -> [EmbyLibraryView] {
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Users/\(embySession.userId)/Views"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "IncludeExternalContent", value: "false")
        ]
        guard let url = components?.url else { throw EmbyError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

        let response: EmbyViewsResponse = try await send(request)
        return response.items
    }

    private func fetchSongsFromViews(
        _ views: [EmbyLibraryView],
        session embySession: EmbySession,
        searchTerm: String?
    ) async throws -> [EmbyAudioItem] {
        var songs: [EmbyAudioItem] = []
        for view in views {
            let primary = try await fetchSongs(
                session: embySession,
                searchTerm: searchTerm,
                parentId: view.id,
                filterName: "IncludeItemTypes",
                filterValue: "Audio"
            )
            if !primary.isEmpty {
                songs.append(contentsOf: primary)
                continue
            }

            let mediaTypeMatches = try await fetchSongs(
                session: embySession,
                searchTerm: searchTerm,
                parentId: view.id,
                filterName: "MediaTypes",
                filterValue: "Audio"
            )
            if !mediaTypeMatches.isEmpty {
                songs.append(contentsOf: mediaTypeMatches)
                continue
            }

            let visibleItems = try await fetchSongs(
                session: embySession,
                searchTerm: searchTerm,
                parentId: view.id,
                filterName: nil,
                filterValue: nil
            )
            songs.append(contentsOf: visibleItems.filter(\.isAudio))
        }

        return uniqueSongs(songs)
    }

    private func fetchSongsByWalkingDirectories(
        _ views: [EmbyLibraryView],
        session embySession: EmbySession,
        searchTerm: String?
    ) async throws -> [EmbyAudioItem] {
        var songs: [EmbyAudioItem] = []
        var visited = Set<String>()

        for view in views {
            let items = try await walkDirectory(
                parentId: view.id,
                session: embySession,
                visited: &visited,
                depth: 0
            )
            songs.append(contentsOf: items)
        }

        let filteredSongs = songs.filter(\.isAudio).filter { song in
            guard let searchTerm, !searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return true
            }
            return matchesSearch(song: song, searchTerm: searchTerm)
        }
        return uniqueSongs(filteredSongs)
    }

    private func walkDirectory(
        parentId: String,
        session embySession: EmbySession,
        visited: inout Set<String>,
        depth: Int
    ) async throws -> [EmbyAudioItem] {
        guard depth < 12, visited.insert(parentId).inserted else { return [] }

        let children = try await fetchDirectoryItems(
            parentId: parentId,
            session: embySession
        )
        var results = children.filter(\.isAudio)

        for child in children where child.canContainAudio {
            let nested = try await walkDirectory(
                parentId: child.id,
                session: embySession,
                visited: &visited,
                depth: depth + 1
            )
            results.append(contentsOf: nested)
        }

        return results
    }

    private func fetchDirectoryItems(
        parentId: String,
        session embySession: EmbySession
    ) async throws -> [EmbyAudioItem] {
        let pageLimit = 200
        var startIndex = 0
        var items: [EmbyAudioItem] = []
        var totalRecordCount: Int?

        repeat {
            var components = URLComponents(
                url: embySession.serverURL.appending(path: "Users/\(embySession.userId)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "ParentId", value: parentId),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
                URLQueryItem(name: "ImageTypeLimit", value: "1"),
                URLQueryItem(name: "SortBy", value: "IsFolder,Filename"),
                URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
                URLQueryItem(name: "Limit", value: "\(pageLimit)"),
                URLQueryItem(name: "Fields", value: itemFields)
            ]
            guard let url = components?.url else { throw EmbyError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

            let response: EmbyItemsResponse = try await send(request)
            items.append(contentsOf: response.items)
            totalRecordCount = response.totalRecordCount

            if response.items.count < pageLimit {
                break
            }
            startIndex += response.items.count
        } while totalRecordCount.map { items.count < $0 } ?? true

        return items
    }

    private func fetchSongs(
        session embySession: EmbySession,
        searchTerm: String?,
        parentId: String?,
        filterName: String?,
        filterValue: String?
    ) async throws -> [EmbyAudioItem] {
        let pageLimit = 200
        var startIndex = 0
        var songs: [EmbyAudioItem] = []
        var totalRecordCount: Int?

        repeat {
            let response = try await fetchSongPage(
                session: embySession,
                searchTerm: searchTerm,
                parentId: parentId,
                filterName: filterName,
                filterValue: filterValue,
                startIndex: startIndex,
                limit: pageLimit,
                sortBy: "SortName",
                sortOrder: "Ascending"
            )
            songs.append(contentsOf: response.items)
            totalRecordCount = response.totalRecordCount

            if response.items.count < pageLimit {
                break
            }
            startIndex += response.items.count
        } while totalRecordCount.map { songs.count < $0 } ?? true

        return songs
    }

    private func fetchSongSample(
        from views: [EmbyLibraryView],
        session embySession: EmbySession,
        sortBy: String,
        sortOrder: String,
        limit: Int
    ) async throws -> [EmbyAudioItem] {
        var songs: [EmbyAudioItem] = []
        var lastError: Error?
        let perViewLimit = max(limit, 1)

        for view in views {
            do {
                let response = try await fetchSongPage(
                    session: embySession,
                    searchTerm: nil,
                    parentId: view.id,
                    filterName: "IncludeItemTypes",
                    filterValue: "Audio",
                    startIndex: 0,
                    limit: perViewLimit,
                    sortBy: sortBy,
                    sortOrder: sortOrder
                )
                songs.append(contentsOf: response.items.filter(\.isAudio))
            } catch {
                lastError = error
            }
        }

        if songs.isEmpty, let lastError {
            throw lastError
        }

        let unique = uniqueSongs(songs)
        return Array(sortSampleSongs(unique, sortBy: sortBy, sortOrder: sortOrder).prefix(limit))
    }

    private func sortSampleSongs(
        _ songs: [EmbyAudioItem],
        sortBy: String,
        sortOrder: String
    ) -> [EmbyAudioItem] {
        let descending = sortOrder.localizedCaseInsensitiveCompare("Descending") == .orderedSame

        switch sortBy.lowercased() {
        case "datecreated":
            return songs.sorted {
                let left = $0.dateCreated ?? .distantPast
                let right = $1.dateCreated ?? .distantPast
                return descending ? left > right : left < right
            }
        case "playcount":
            return songs.sorted {
                let left = $0.userData?.playCount ?? 0
                let right = $1.userData?.playCount ?? 0
                if left != right {
                    return descending ? left > right : left < right
                }
                let leftDate = $0.userData?.lastPlayedDate ?? .distantPast
                let rightDate = $1.userData?.lastPlayedDate ?? .distantPast
                return descending ? leftDate > rightDate : leftDate < rightDate
            }
        default:
            return songs
        }
    }

    private func fetchSongPage(
        session embySession: EmbySession,
        searchTerm: String?,
        parentId: String?,
        filterName: String?,
        filterValue: String?,
        startIndex: Int,
        limit: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> EmbyItemsResponse {
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Users/\(embySession.userId)/Items"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: itemFields),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)")
        ]
        if let filterName, let filterValue {
            queryItems.insert(URLQueryItem(name: filterName, value: filterValue), at: 0)
        }
        if let parentId {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        components?.queryItems = queryItems

        if let searchTerm, !searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "SearchTerm", value: searchTerm))
        }

        guard let url = components?.url else { throw EmbyError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

        return try await send(request)
    }

    private func fetchPlaylistItems(session embySession: EmbySession) async throws -> [EmbyPlaylistItem] {
        let pageLimit = 100
        var startIndex = 0
        var playlists: [EmbyPlaylistItem] = []
        var totalRecordCount: Int?

        repeat {
            var components = URLComponents(
                url: embySession.serverURL.appending(path: "Users/\(embySession.userId)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
                URLQueryItem(name: "Fields", value: "ChildCount,DateCreated,ImageTags"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
                URLQueryItem(name: "Limit", value: "\(pageLimit)")
            ]
            guard let url = components?.url else { throw EmbyError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

            let response: EmbyPlaylistItemsResponse = try await send(request)
            playlists.append(contentsOf: response.items)
            totalRecordCount = response.totalRecordCount

            if response.items.count < pageLimit {
                break
            }
            startIndex += response.items.count
        } while totalRecordCount.map { playlists.count < $0 } ?? true

        return playlists
    }

    private func fetchPlaylistSongsFromPlaylistEndpoint(
        playlistId: String,
        session embySession: EmbySession
    ) async throws -> [EmbyAudioItem] {
        let pageLimit = 200
        var startIndex = 0
        var songs: [EmbyAudioItem] = []
        var totalRecordCount: Int?

        repeat {
            var components = URLComponents(
                url: embySession.serverURL.appending(path: "Playlists/\(playlistId)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "UserId", value: embySession.userId),
                URLQueryItem(name: "Fields", value: itemFields),
                URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
                URLQueryItem(name: "Limit", value: "\(pageLimit)")
            ]
            guard let url = components?.url else { throw EmbyError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

            let response: EmbyItemsResponse = try await send(request)
            songs.append(contentsOf: response.items.filter(\.isAudio))
            totalRecordCount = response.totalRecordCount

            if response.items.count < pageLimit {
                break
            }
            startIndex += response.items.count
        } while totalRecordCount.map { songs.count < $0 } ?? true

        return uniqueSongs(songs)
    }

    private func uniqueSongs(_ songs: [EmbyAudioItem]) -> [EmbyAudioItem] {
        var seen = Set<String>()
        return songs.filter { song in
            seen.insert(song.id).inserted
        }
    }

    private func matchesSearch(song: EmbyAudioItem, searchTerm: String) -> Bool {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }

        return song.name.localizedCaseInsensitiveContains(term) ||
            song.album?.localizedCaseInsensitiveContains(term) == true ||
            song.artistLine.localizedCaseInsensitiveContains(term)
    }

    func playbackURLCandidates(
        for item: EmbyAudioItem,
        session embySession: EmbySession,
        options: PlaybackStreamOptions = PlaybackStreamOptions(
            quality: .lossless,
            transcodeFormat: .aac,
            networkKind: .wifi
        ),
        playSessionId requestedPlaySessionId: String? = nil,
        startTime: TimeInterval = 0
    ) -> [URL] {
        let playSessionId = requestedPlaySessionId ?? UUID().uuidString
        let startTimeTicks = startTime.embyStartTimeTicks
        let candidates: [URL?]
        if let bitrate = options.quality.bitrate {
            candidates = [
                transcodedAudioStreamURL(
                    for: item,
                    session: embySession,
                    playSessionId: playSessionId,
                    startTimeTicks: startTimeTicks,
                    format: options.transcodeFormat,
                    maxStreamingBitrate: bitrate
                )
            ]
        } else {
            candidates = [
                directAudioStreamURL(
                    for: item,
                    session: embySession,
                    playSessionId: playSessionId,
                    startTimeTicks: startTimeTicks
                ),
                startTimeTicks == nil ? downloadURL(for: item, session: embySession) : nil
            ]
        }

        var seen = Set<String>()
        return candidates.compactMap { $0 }.filter { seen.insert($0.absoluteString).inserted }
    }

    func originalAudioStreamURL(for item: EmbyAudioItem, session embySession: EmbySession) -> URL? {
        directAudioStreamURL(
            for: item,
            session: embySession,
            playSessionId: UUID().uuidString,
            startTimeTicks: nil
        )
    }

    func reportPlaybackStarted(
        item: EmbyAudioItem,
        session embySession: EmbySession,
        playSessionId: String,
        playMethod: EmbyPlaybackReportMethod,
        position: TimeInterval
    ) async throws {
        try await sendPlaybackReport(
            path: "Sessions/Playing",
            item: item,
            session: embySession,
            playSessionId: playSessionId,
            playMethod: playMethod,
            position: position,
            isPaused: false,
            includeStartFields: true
        )
    }

    func reportPlaybackProgress(
        item: EmbyAudioItem,
        session embySession: EmbySession,
        playSessionId: String,
        playMethod: EmbyPlaybackReportMethod,
        position: TimeInterval,
        isPaused: Bool
    ) async throws {
        try await sendPlaybackReport(
            path: "Sessions/Playing/Progress",
            item: item,
            session: embySession,
            playSessionId: playSessionId,
            playMethod: playMethod,
            position: position,
            isPaused: isPaused,
            includeStartFields: false
        )
    }

    func reportPlaybackStopped(
        item: EmbyAudioItem,
        session embySession: EmbySession,
        playSessionId: String,
        playMethod: EmbyPlaybackReportMethod,
        position: TimeInterval
    ) async throws {
        try await sendPlaybackReport(
            path: "Sessions/Playing/Stopped",
            item: item,
            session: embySession,
            playSessionId: playSessionId,
            playMethod: playMethod,
            position: position,
            isPaused: true,
            includeStartFields: false
        )
    }

    private func directAudioStreamURL(
        for item: EmbyAudioItem,
        session embySession: EmbySession,
        playSessionId: String,
        startTimeTicks: Int64?
    ) -> URL? {
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Audio/\(item.id)/stream"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "api_key", value: embySession.accessToken),
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "PlaySessionId", value: playSessionId)
        ]
        if let startTimeTicks {
            queryItems.append(URLQueryItem(name: "StartTimeTicks", value: "\(startTimeTicks)"))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    private func transcodedAudioStreamURL(
        for item: EmbyAudioItem,
        session embySession: EmbySession,
        playSessionId: String,
        startTimeTicks: Int64?,
        format: AudioTranscodeFormat,
        maxStreamingBitrate: Int
    ) -> URL? {
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Audio/\(item.id)/stream.\(format.transcodingContainer)"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "api_key", value: embySession.accessToken),
            URLQueryItem(name: "UserId", value: embySession.userId),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "PlaySessionId", value: playSessionId),
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "Container", value: format.containerQueryValue),
            URLQueryItem(name: "AudioCodec", value: format.codec),
            URLQueryItem(name: "AudioBitRate", value: "\(maxStreamingBitrate)"),
            URLQueryItem(name: "MaxAudioBitrate", value: "\(maxStreamingBitrate)"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "\(maxStreamingBitrate)"),
            URLQueryItem(name: "EnableAutoStreamCopy", value: "false")
        ]
        if let startTimeTicks {
            queryItems.append(URLQueryItem(name: "StartTimeTicks", value: "\(startTimeTicks)"))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    private func downloadURL(for item: EmbyAudioItem, session embySession: EmbySession) -> URL? {
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Items/\(item.id)/Download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: embySession.accessToken)
        ]
        return components?.url
    }

    private func sendPlaybackReport(
        path: String,
        item: EmbyAudioItem,
        session embySession: EmbySession,
        playSessionId: String,
        playMethod: EmbyPlaybackReportMethod,
        position: TimeInterval,
        isPaused: Bool,
        includeStartFields: Bool
    ) async throws {
        var request = URLRequest(url: embySession.serverURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

        var body: [String: Any] = [
            "ItemId": item.id,
            "PlaySessionId": playSessionId,
            "PlayMethod": playMethod.rawValue,
            "PositionTicks": position.embyPositionTicks,
            "IsPaused": isPaused,
            "IsMuted": false,
            "VolumeLevel": 100
        ]
        if let mediaSourceId = item.mediaSources?.first?.id, !mediaSourceId.isEmpty {
            body["MediaSourceId"] = mediaSourceId
        }
        if includeStartFields {
            body["CanSeek"] = true
            body["QueueableMediaTypes"] = ["Audio"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await sendEmpty(request)
    }

    private var deviceId: String {
        let key = "EmbyDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    func imageURL(for item: EmbyAudioItem, session embySession: EmbySession, size: Int = 600) -> URL? {
        let imageItemId: String?
        if item.imageTags?["Primary"] != nil {
            imageItemId = item.id
        } else if let primaryImageItemId = item.primaryImageItemId, !primaryImageItemId.isEmpty {
            imageItemId = primaryImageItemId
        } else if let albumId = item.albumId,
                  !albumId.isEmpty,
                  item.albumPrimaryImageTag?.isEmpty == false {
            imageItemId = albumId
        } else {
            imageItemId = nil
        }

        guard let imageItemId else { return nil }
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Items/\(imageItemId)/Images/Primary"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "maxHeight", value: "\(size)"),
            URLQueryItem(name: "maxWidth", value: "\(size)"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: embySession.accessToken)
        ]
        return components?.url
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw EmbyError.server(statusCode: httpResponse.statusCode)
        }
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw EmbyError.decoding(error.localizedDescription)
        }
    }

    private func sendEmpty(_ request: URLRequest) async throws {
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw EmbyError.server(statusCode: httpResponse.statusCode)
        }
    }

    private func normalizedServerURL(_ rawServer: String) throws -> URL {
        var value = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.localizedCaseInsensitiveContains("://") {
            value = "http://\(value)"
        }
        guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty else {
            throw EmbyError.invalidURL
        }
        if components.path == "" {
            components.path = "/"
        }
        guard let url = components.url else { throw EmbyError.invalidURL }
        return url
    }

    private func authorizationHeader(accessToken: String?) -> String {
        let deviceId = UserDefaults.standard.string(forKey: deviceIdKey) ?? {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: deviceIdKey)
            return id
        }()

        var parts = [
            #"MediaBrowser Client="MusicEmby""#,
            #"Device="iPhone""#,
            #"DeviceId="\#(deviceId)""#,
            #"Version="1.0.0""#
        ]
        if let accessToken {
            parts.append(#"Token="\#(accessToken)""#)
        }
        return parts.joined(separator: ", ")
    }
}

enum EmbyError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(statusCode: Int)
    case decoding(String)
    case noMusicLibrary([String])

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址无效。"
        case .invalidResponse:
            return "服务器响应无效。"
        case .server(let statusCode):
            return "Emby 请求失败，状态码 \(statusCode)。"
        case .decoding(let message):
            return "Emby 返回的数据无法解析：\(message)"
        case .noMusicLibrary(let libraries):
            if libraries.isEmpty {
                return "当前 Emby 用户没有可见媒体库。"
            }
            return "当前 Emby 用户没有可见音乐库。可见媒体库：\(libraries.joined(separator: ", "))。"
        }
    }
}

enum EmbyPlaybackReportMethod: String, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

private extension TimeInterval {
    var embyStartTimeTicks: Int64? {
        guard isFinite, self > 0 else { return nil }
        return embyPositionTicks
    }

    var embyPositionTicks: Int64 {
        guard isFinite, self > 0 else { return 0 }
        return Int64((self * 10_000_000).rounded())
    }
}
