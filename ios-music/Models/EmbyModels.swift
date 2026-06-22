import Foundation

struct EmbySession: Codable, Equatable {
    let serverURL: URL
    let userId: String
    let username: String
    let accessToken: String
}

struct EmbyAuthResponse: Decodable {
    let user: EmbyUser
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

struct EmbyUser: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct EmbyItemsResponse: Decodable {
    let items: [EmbyAudioItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct EmbyPlaylistItemsResponse: Decodable {
    let items: [EmbyPlaylistItem]
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct EmbyViewsResponse: Decodable {
    let items: [EmbyLibraryView]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct EmbyPlaylistItem: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let childCount: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case childCount = "ChildCount"
    }
}

struct EmbyLibraryView: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let collectionType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
    }

    var isMusicLibrary: Bool {
        collectionType?.localizedCaseInsensitiveCompare("music") == .orderedSame ||
            name.localizedCaseInsensitiveContains("music") ||
            name.localizedCaseInsensitiveContains("音乐")
    }
}

struct EmbyAudioItem: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let album: String?
    let albumId: String?
    let albumPrimaryImageTag: String?
    let artists: [String]?
    let albumArtist: String?
    let primaryImageItemId: String?
    let type: String?
    let mediaType: String?
    let isFolder: Bool?
    let runTimeTicks: Int64?
    let productionYear: Int?
    let imageTags: [String: String]?
    let dateCreated: Date?
    let userData: EmbyUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case album = "Album"
        case albumId = "AlbumId"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case artists = "Artists"
        case albumArtist = "AlbumArtist"
        case primaryImageItemId = "PrimaryImageItemId"
        case type = "Type"
        case mediaType = "MediaType"
        case isFolder = "IsFolder"
        case runTimeTicks = "RunTimeTicks"
        case productionYear = "ProductionYear"
        case imageTags = "ImageTags"
        case dateCreated = "DateCreated"
        case userData = "UserData"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        albumId = try container.decodeIfPresent(String.self, forKey: .albumId)
        albumPrimaryImageTag = try container.decodeIfPresent(String.self, forKey: .albumPrimaryImageTag)
        artists = container.decodeStringArrayIfPresent(forKey: .artists)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        primaryImageItemId = try container.decodeIfPresent(String.self, forKey: .primaryImageItemId)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        isFolder = try container.decodeIfPresent(Bool.self, forKey: .isFolder)
        runTimeTicks = container.decodeInt64IfPresent(forKey: .runTimeTicks)
        productionYear = try container.decodeIfPresent(Int.self, forKey: .productionYear)
        imageTags = try container.decodeIfPresent([String: String].self, forKey: .imageTags)
        dateCreated = container.decodeEmbyDateIfPresent(forKey: .dateCreated)
        userData = try container.decodeIfPresent(EmbyUserData.self, forKey: .userData)
    }

    var artistLine: String {
        if let artists, !artists.isEmpty {
            return artists.joined(separator: ", ")
        }
        return albumArtist ?? "Unknown Artist"
    }

    var subtitle: String {
        [artistLine, album].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " - ")
    }

    var duration: TimeInterval {
        guard let runTimeTicks else { return 0 }
        return TimeInterval(runTimeTicks) / 10_000_000
    }

    var isAudio: Bool {
        type?.localizedCaseInsensitiveCompare("Audio") == .orderedSame ||
            mediaType?.localizedCaseInsensitiveCompare("Audio") == .orderedSame
    }

    var canContainAudio: Bool {
        isFolder == true && !isAudio
    }
}

struct EmbyUserData: Decodable, Hashable {
    let playCount: Int?
    let lastPlayedDate: Date?

    enum CodingKeys: String, CodingKey {
        case playCount = "PlayCount"
        case lastPlayedDate = "LastPlayedDate"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playCount = container.decodeIntIfPresent(forKey: .playCount)
        lastPlayedDate = container.decodeEmbyDateIfPresent(forKey: .lastPlayedDate)
    }
}

struct MusicAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let songs: [EmbyAudioItem]

    var representativeSong: EmbyAudioItem? { songs.first }
    var yearText: String {
        songs.compactMap(\.productionYear).min().map(String.init) ?? ""
    }
}

struct MusicArtist: Identifiable, Hashable {
    let id: String
    let name: String
    let songs: [EmbyAudioItem]

    var albums: [MusicAlbum] { songs.musicAlbums }
    var representativeSong: EmbyAudioItem? { songs.first }
}

struct MusicPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let songs: [EmbyAudioItem]
}

extension Array where Element == EmbyAudioItem {
    var musicAlbums: [MusicAlbum] {
        let grouped = Dictionary(grouping: self) { song in
            let album = song.album?.trimmingCharacters(in: .whitespacesAndNewlines)
            return album?.isEmpty == false ? album! : "Unknown Album"
        }

        return grouped.map { title, songs in
            MusicAlbum(
                id: title,
                title: title,
                artist: songs.first?.albumArtist ?? songs.first?.artistLine ?? "Unknown Artist",
                songs: songs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var musicArtists: [MusicArtist] {
        let pairs = flatMap { song -> [(String, EmbyAudioItem)] in
            let artists = song.artists?.isEmpty == false ? song.artists! : [song.albumArtist ?? "Unknown Artist"]
            return artists.map { ($0, song) }
        }
        let grouped = Dictionary(grouping: pairs, by: \.0)

        return grouped.map { name, values in
            MusicArtist(id: name, name: name, songs: values.map(\.1))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var generatedPlaylists: [MusicPlaylist] {
        let recent = Array(prefix(30))
        let longSongs = filter { $0.duration >= 300 }
        let shortSongs = filter { $0.duration > 0 && $0.duration < 240 }

        return [
            MusicPlaylist(id: "recent", name: "最近播放", description: "按当前资料库生成", songs: recent),
            MusicPlaylist(id: "long", name: "沉浸聆听", description: "时长较长的曲目", songs: longSongs),
            MusicPlaylist(id: "short", name: "短歌精选", description: "适合快速播放", songs: shortSongs)
        ].filter { !$0.songs.isEmpty }
    }

}

private extension KeyedDecodingContainer {
    func decodeStringArrayIfPresent(forKey key: Key) -> [String]? {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values
        }
        if let value = try? decodeIfPresent(String.self, forKey: key), !value.isEmpty {
            return [value]
        }
        return nil
    }

    func decodeInt64IfPresent(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    func decodeIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeEmbyDateIfPresent(forKey key: Key) -> Date? {
        guard let rawValue = (try? decodeIfPresent(String.self, forKey: key)) ?? nil,
              !rawValue.isEmpty else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: rawValue) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: rawValue)
    }
}

extension TimeInterval {
    var musicDurationText: String {
        guard isFinite, self > 0 else { return "--:--" }
        let totalSeconds = Int(self.rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
