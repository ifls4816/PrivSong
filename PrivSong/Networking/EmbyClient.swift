import Foundation

struct InitialHomeContent: Codable {
    let playlists: [MusicPlaylist]
    let audiobookEpisodes: [EmbyAudioItem]
    let dailySeedSongs: [EmbyAudioItem]
    let recentlyAddedSongs: [EmbyAudioItem]
    let mostPlayedSongs: [EmbyAudioItem]
}

struct EmbyClient {
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    private let deviceIdKey = "EmbyDeviceId"
    private let itemFields = "Album,AlbumId,AlbumArtist,AlbumPrimaryImageTag,Artists,Bitrate,Container,DateCreated,ImageTags,IndexNumber,MediaSources,MediaType,ParentId,ParentIndexNumber,PrimaryImageItemId,PrimaryImageAspectRatio,ProductionYear,RunTimeTicks,SortName,UserData"

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
        let views = try await fetchViews(session: embySession)
        let musicViews = views.filter(\.isMusicLibrary)
        guard !musicViews.isEmpty else { return [] }

        let scopedSongs = try await fetchSongsFromViews(
            musicViews,
            session: embySession,
            searchTerm: searchTerm
        )
        if !scopedSongs.isEmpty {
            return scopedSongs.filter { !$0.isAudiobookAudio }
        }

        let walkedSongs = try await fetchSongsByWalkingDirectories(
            musicViews,
            session: embySession,
            searchTerm: searchTerm
        )
        if !walkedSongs.isEmpty {
            return walkedSongs.filter { !$0.isAudiobookAudio }
        }

        let primary = try await fetchSongs(
            session: embySession,
            searchTerm: searchTerm,
            parentId: nil,
            filterName: "IncludeItemTypes",
            filterValue: "Audio"
        )
        if !primary.isEmpty {
            return primary.filter { !$0.isAudiobookAudio }
        }

        let mediaTypeMatches = try await fetchSongs(
            session: embySession,
            searchTerm: searchTerm,
            parentId: nil,
            filterName: "MediaTypes",
            filterValue: "Audio"
        )
        if !mediaTypeMatches.isEmpty {
            return mediaTypeMatches.filter { !$0.isAudiobookAudio }
        }

        let visibleItems = try await fetchSongs(
            session: embySession,
            searchTerm: searchTerm,
            parentId: nil,
            filterName: nil,
            filterValue: nil
        )
        return visibleItems.filter { $0.isAudio && !$0.isAudiobookAudio }
    }

    func fetchInitialHomeContent(session embySession: EmbySession) async throws -> InitialHomeContent {
        let views = try await fetchViews(session: embySession)
        let musicViews = views.filter(\.isMusicLibrary)
        let audiobookViews = views.filter(\.isAudiobookLibrary)
        guard !musicViews.isEmpty || !audiobookViews.isEmpty else {
            throw EmbyError.noPlayableLibrary(views.map { "\($0.name)(\($0.collectionType ?? "unknown"))" })
        }

        async let playlists = fetchPlaylistSummaries(session: embySession)
        async let audiobookEpisodes = fetchAudiobookEpisodes(from: audiobookViews, session: embySession)
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
            audiobookEpisodes: (try? await audiobookEpisodes) ?? [],
            dailySeedSongs: (try? await dailySeedSongs) ?? [],
            recentlyAddedSongs: (try? await recentlyAddedSongs) ?? [],
            mostPlayedSongs: (try? await mostPlayedSongs) ?? []
        )
    }

    func fetchMostPlayedSongs(session embySession: EmbySession, limit: Int = 50) async throws -> [EmbyAudioItem] {
        let views = try await fetchViews(session: embySession)
        let musicViews = views.filter(\.isMusicLibrary)
        guard !musicViews.isEmpty else { return [] }

        return try await fetchSongSample(
            from: musicViews,
            session: embySession,
            sortBy: "PlayCount",
            sortOrder: "Descending",
            limit: limit
        )
    }

    func fetchFavoriteSongs(session embySession: EmbySession) async throws -> [EmbyAudioItem] {
        let views = try await fetchViews(session: embySession)
        let musicViews = views.filter(\.isMusicLibrary)

        if musicViews.isEmpty {
            return uniqueSongs(try await fetchFavoriteSongs(parentId: nil, session: embySession))
                .filter { $0.isAudio && !$0.isAudiobookAudio }
        }

        var songs: [EmbyAudioItem] = []
        for view in musicViews {
            let viewSongs = try await fetchFavoriteSongs(parentId: view.id, session: embySession)
            songs.append(contentsOf: viewSongs)
        }
        return uniqueSongs(songs).filter { $0.isAudio && !$0.isAudiobookAudio }
    }

    func setFavorite(itemId: String, isFavorite: Bool, session embySession: EmbySession) async throws {
        var request = URLRequest(url: embySession.serverURL.appending(path: "Users/\(embySession.userId)/FavoriteItems/\(itemId)"))
        request.httpMethod = isFavorite ? "POST" : "DELETE"
        request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        try await sendEmpty(request)
    }

    func fetchAudiobookEpisodes(session embySession: EmbySession) async throws -> [EmbyAudioItem] {
        let views = try await fetchViews(session: embySession)
        return try await fetchAudiobookEpisodes(from: views.filter(\.isAudiobookLibrary), session: embySession)
    }

    func fetchItems(itemIds: [String], session embySession: EmbySession) async throws -> [EmbyAudioItem] {
        let ids = itemIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }

        let chunkSize = 80
        var items: [EmbyAudioItem] = []
        var startIndex = ids.startIndex

        while startIndex < ids.endIndex {
            let endIndex = ids.index(startIndex, offsetBy: chunkSize, limitedBy: ids.endIndex) ?? ids.endIndex
            let chunk = Array(ids[startIndex..<endIndex])
            var components = URLComponents(
                url: embySession.serverURL.appending(path: "Users/\(embySession.userId)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "Ids", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "Fields", value: itemFields),
                URLQueryItem(name: "Limit", value: "\(chunk.count)")
            ]

            guard let url = components?.url else { throw EmbyError.invalidURL }
            var request = URLRequest(url: url)
            request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

            let response: EmbyItemsResponse = try await send(request)
            items.append(contentsOf: response.items)
            startIndex = endIndex
        }

        return items
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

    func fetchMusicFolders(session embySession: EmbySession) async throws -> [MusicFolder] {
        let views = try await fetchViews(session: embySession)
        let musicViews = views.filter(\.isMusicLibrary)
        guard !musicViews.isEmpty else { return [] }

        var folders: [MusicFolder] = []
        var seen = Set<String>()
        for view in musicViews {
            let children = try await fetchDirectoryItems(parentId: view.id, session: embySession)
            for child in children where child.canContainAudio && seen.insert(child.id).inserted {
                folders.append(MusicFolder(id: child.id, name: child.name, songCount: nil))
            }
        }

        return folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchFolderSongs(folderId: String, session embySession: EmbySession) async throws -> [EmbyAudioItem] {
        let children = try await fetchDirectoryItems(parentId: folderId, session: embySession)
        return uniqueSongs(children.filter { $0.isAudio && !$0.isAudiobookAudio })
    }

    func createPlaylist(name: String, songs: [EmbyAudioItem], session embySession: EmbySession) async throws -> MusicPlaylist {
        let playlistName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !playlistName.isEmpty else { throw EmbyError.invalidPlaylistName }

        let songIds = songs.map(\.id)
        let initialItemIds = Array(songIds.prefix(80))
        let remainingItemIds = Array(songIds.dropFirst(initialItemIds.count))

        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Playlists"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "UserId", value: embySession.userId),
            URLQueryItem(name: "Name", value: playlistName),
            URLQueryItem(name: "MediaType", value: "Audio")
        ]
        if !initialItemIds.isEmpty {
            queryItems.append(URLQueryItem(name: "Ids", value: initialItemIds.joined(separator: ",")))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw EmbyError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

        let response: EmbyPlaylistCreationResponse = try await send(request)
        guard let playlistId = response.id, !playlistId.isEmpty else {
            throw EmbyError.invalidResponse
        }

        try await addPlaylistItems(playlistId: playlistId, itemIds: remainingItemIds, session: embySession)
        return MusicPlaylist(
            id: playlistId,
            name: playlistName,
            description: "\(songs.count) 首歌曲",
            songs: songs,
            songCount: songs.count
        )
    }

    func replacePlaylistSongs(playlistId: String, songs: [EmbyAudioItem], session embySession: EmbySession) async throws {
        let currentEntries = try await fetchPlaylistEntries(playlistId: playlistId, session: embySession)
        let currentEntryIds = currentEntries.compactMap(\.playlistItemId)
        let previousItemIds = currentEntries.map(\.itemId)

        guard currentEntries.isEmpty || currentEntryIds.count == currentEntries.count else {
            throw EmbyError.missingPlaylistItemIds
        }

        var removedExistingItems = false
        do {
            if !currentEntryIds.isEmpty {
                try await removePlaylistItems(playlistId: playlistId, entryIds: currentEntryIds, session: embySession)
            }
            removedExistingItems = true
            try await addPlaylistItems(playlistId: playlistId, itemIds: songs.map(\.id), session: embySession)
        } catch {
            if removedExistingItems {
                try? await removeAllPlaylistItems(playlistId: playlistId, session: embySession)
                if !previousItemIds.isEmpty {
                    try? await addPlaylistItems(playlistId: playlistId, itemIds: previousItemIds, session: embySession)
                }
            }
            throw error
        }
    }

    func deletePlaylist(playlistId: String, session embySession: EmbySession) async throws {
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Items/Delete"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "Ids", value: playlistId),
            URLQueryItem(name: "X-Emby-Token", value: embySession.accessToken)
        ]
        guard let url = components?.url else { throw EmbyError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        try await sendEmpty(request)

        let playlists = try await fetchPlaylistSummaries(session: embySession)
        guard !playlists.contains(where: { $0.id == playlistId }) else {
            throw EmbyError.playlistDeleteFailed
        }
    }

    func renamePlaylist(playlistId: String, name: String, session embySession: EmbySession) async throws {
        let playlistName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !playlistName.isEmpty else { throw EmbyError.invalidPlaylistName }

        var itemRequest = URLRequest(url: embySession.serverURL.appending(path: "Users/\(embySession.userId)/Items/\(playlistId)"))
        itemRequest.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        let itemData = try await sendData(itemRequest)

        guard var item = try JSONSerialization.jsonObject(with: itemData) as? [String: Any] else {
            throw EmbyError.invalidResponse
        }
        item["Name"] = playlistName
        item["SortName"] = playlistName

        var updateRequest = URLRequest(url: embySession.serverURL.appending(path: "Items/\(playlistId)"))
        updateRequest.httpMethod = "POST"
        updateRequest.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        updateRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        updateRequest.httpBody = try JSONSerialization.data(withJSONObject: item)
        try await sendEmpty(updateRequest)
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
        searchTerm: String?,
        includeItemTypes: String = "Audio"
    ) async throws -> [EmbyAudioItem] {
        var songs: [EmbyAudioItem] = []
        for view in views {
            let primary = try await fetchSongs(
                session: embySession,
                searchTerm: searchTerm,
                parentId: view.id,
                filterName: "IncludeItemTypes",
                filterValue: includeItemTypes
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

    private func fetchAudiobookEpisodes(
        from views: [EmbyLibraryView],
        session embySession: EmbySession
    ) async throws -> [EmbyAudioItem] {
        guard !views.isEmpty else { return [] }

        let scopedEpisodes = try await fetchSongsFromViews(
            views,
            session: embySession,
            searchTerm: nil,
            includeItemTypes: "Audio,AudioBook"
        )
        if !scopedEpisodes.isEmpty {
            return scopedEpisodes
        }

        let walkedEpisodes = try await fetchSongsByWalkingDirectories(
            views,
            session: embySession,
            searchTerm: nil
        )
        return walkedEpisodes
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
                songs.append(contentsOf: response.items.filter { $0.isAudio && !$0.isAudiobookAudio })
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

    private func fetchFavoriteSongs(parentId: String?, session embySession: EmbySession) async throws -> [EmbyAudioItem] {
        let pageLimit = 200
        var startIndex = 0
        var songs: [EmbyAudioItem] = []
        var totalRecordCount: Int?

        repeat {
            let response = try await fetchSongPage(
                session: embySession,
                searchTerm: nil,
                parentId: parentId,
                filterName: "IncludeItemTypes",
                filterValue: "Audio",
                startIndex: startIndex,
                limit: pageLimit,
                sortBy: "SortName",
                sortOrder: "Ascending",
                extraQueryItems: [
                    URLQueryItem(name: "Filters", value: "IsFavorite")
                ]
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
        sortOrder: String,
        extraQueryItems: [URLQueryItem] = []
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
        queryItems.append(contentsOf: extraQueryItems)
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

    private func fetchPlaylistEntries(playlistId: String, session embySession: EmbySession) async throws -> [EmbyPlaylistEntry] {
        let pageLimit = 200
        var startIndex = 0
        var entries: [EmbyPlaylistEntry] = []
        var totalRecordCount: Int?

        repeat {
            var components = URLComponents(
                url: embySession.serverURL.appending(path: "Playlists/\(playlistId)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "UserId", value: embySession.userId),
                URLQueryItem(name: "Fields", value: "\(itemFields),PlaylistItemId"),
                URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
                URLQueryItem(name: "Limit", value: "\(pageLimit)")
            ]
            guard let url = components?.url else { throw EmbyError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")

            let response: EmbyPlaylistEntriesResponse = try await send(request)
            entries.append(contentsOf: response.items)
            totalRecordCount = response.totalRecordCount

            if response.items.count < pageLimit {
                break
            }
            startIndex += response.items.count
        } while totalRecordCount.map { entries.count < $0 } ?? true

        return entries
    }

    private func addPlaylistItems(playlistId: String, itemIds: [String], session embySession: EmbySession) async throws {
        for chunk in chunks(from: itemIds, size: 80) {
            var components = URLComponents(
                url: embySession.serverURL.appending(path: "Playlists/\(playlistId)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "UserId", value: embySession.userId),
                URLQueryItem(name: "Ids", value: chunk.joined(separator: ","))
            ]
            guard let url = components?.url else { throw EmbyError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
            try await sendEmpty(request)
        }
    }

    private func removePlaylistItems(playlistId: String, entryIds: [String], session embySession: EmbySession) async throws {
        for chunk in chunks(from: entryIds, size: 80) {
            var components = URLComponents(
                url: embySession.serverURL.appending(path: "Playlists/\(playlistId)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "UserId", value: embySession.userId),
                URLQueryItem(name: "EntryIds", value: chunk.joined(separator: ","))
            ]
            guard let url = components?.url else { throw EmbyError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(authorizationHeader(accessToken: embySession.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
            try await sendEmpty(request)
        }
    }

    private func removeAllPlaylistItems(playlistId: String, session embySession: EmbySession) async throws {
        let entries = try await fetchPlaylistEntries(playlistId: playlistId, session: embySession)
        let entryIds = entries.compactMap(\.playlistItemId)
        guard entries.isEmpty || entryIds.count == entries.count else {
            throw EmbyError.missingPlaylistItemIds
        }
        try await removePlaylistItems(playlistId: playlistId, entryIds: entryIds, session: embySession)
    }

    private func chunks(from values: [String], size: Int) -> [[String]] {
        guard size > 0, !values.isEmpty else { return [] }

        var result: [[String]] = []
        var startIndex = values.startIndex
        while startIndex < values.endIndex {
            let endIndex = values.index(startIndex, offsetBy: size, limitedBy: values.endIndex) ?? values.endIndex
            result.append(Array(values[startIndex..<endIndex]))
            startIndex = endIndex
        }
        return result
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
        playSessionId requestedPlaySessionId: String? = nil
    ) -> [URL] {
        let playSessionId = requestedPlaySessionId ?? UUID().uuidString
        let candidates = [
            directAudioStreamURL(
                for: item,
                session: embySession,
                playSessionId: playSessionId
            ),
            downloadURL(for: item, session: embySession)
        ]

        var seen = Set<String>()
        return candidates.compactMap { $0 }.filter { seen.insert($0.absoluteString).inserted }
    }

    func originalAudioStreamURL(for item: EmbyAudioItem, session embySession: EmbySession) -> URL? {
        directAudioStreamURL(
            for: item,
            session: embySession,
            playSessionId: UUID().uuidString
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
        playSessionId: String
    ) -> URL? {
        var components = URLComponents(
            url: embySession.serverURL.appending(path: "Audio/\(item.id)/stream"),
            resolvingAgainstBaseURL: false
        )
        let queryItems = [
            URLQueryItem(name: "api_key", value: embySession.accessToken),
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "PlaySessionId", value: playSessionId)
        ]
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

    private func sendData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw EmbyError.server(statusCode: httpResponse.statusCode)
        }
        return data
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
            #"MediaBrowser Client="PrivSong""#,
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

private struct EmbyPlaylistEntriesResponse: Decodable {
    let items: [EmbyPlaylistEntry]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

private struct EmbyPlaylistEntry: Decodable {
    let itemId: String
    let playlistItemId: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "Id"
        case playlistItemId = "PlaylistItemId"
    }
}

enum EmbyError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(statusCode: Int)
    case decoding(String)
    case noPlayableLibrary([String])
    case invalidPlaylistName
    case missingPlaylistItemIds
    case playlistDeleteFailed

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
        case .noPlayableLibrary(let libraries):
            if libraries.isEmpty {
                return "当前 Emby 用户没有可见媒体库。"
            }
            return "当前 Emby 用户没有可见音乐或有声书库。可见媒体库：\(libraries.joined(separator: ", "))。"
        case .invalidPlaylistName:
            return "歌单名称不能为空。"
        case .missingPlaylistItemIds:
            return "Emby 未返回可编辑的歌单条目标识，无法编辑该歌单。"
        case .playlistDeleteFailed:
            return "Emby 已响应删除请求，但歌单仍然存在，请检查当前用户是否有删除该歌单的权限。"
        }
    }
}

enum EmbyPlaybackReportMethod: String, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
}

private extension TimeInterval {
    var embyPositionTicks: Int64 {
        guard isFinite, self > 0 else { return 0 }
        return Int64((self * 10_000_000).rounded())
    }
}
