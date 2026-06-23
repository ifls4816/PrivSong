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

struct EmbyAudioItem: Identifiable, Codable, Hashable {
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
    let container: String?
    let bitrate: Int?
    let mediaSources: [EmbyMediaSource]?
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
        case container = "Container"
        case bitrate = "Bitrate"
        case mediaSources = "MediaSources"
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
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        bitrate = container.decodeIntIfPresent(forKey: .bitrate)
        mediaSources = try container.decodeIfPresent([EmbyMediaSource].self, forKey: .mediaSources)
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

    var audioInfoTagText: String? {
        let format = preferredAudioFormat
        let bitrate = preferredBitrate

        switch (format, bitrate) {
        case let (format?, bitrate?):
            return "\(format) \(bitrate.kilobitText)"
        case let (format?, nil):
            return format
        case let (nil, bitrate?):
            return bitrate.kilobitText
        default:
            return nil
        }
    }

    private var preferredAudioFormat: String? {
        let rawValue = firstNonEmpty(
            container,
            mediaSources?.first?.container,
            mediaSources?.first?.audioStream?.codec
        )
        return rawValue.map(Self.normalizedAudioFormat)
    }

    private var preferredBitrate: Int? {
        firstPositive(
            bitrate,
            mediaSources?.first?.bitrate,
            mediaSources?.first?.audioStream?.bitRate
        )
    }

    private static func normalizedAudioFormat(_ value: String) -> String {
        let normalized = value
            .split(separator: ",")
            .first
            .map(String.init) ?? value
        return normalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private func firstPositive(_ values: Int?...) -> Int? {
        for value in values {
            if let value, value > 0 {
                return value
            }
        }
        return nil
    }
}

struct EmbyMediaSource: Codable, Hashable {
    let container: String?
    let bitrate: Int?
    let mediaStreams: [EmbyMediaStream]?

    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case bitrate = "Bitrate"
        case mediaStreams = "MediaStreams"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        bitrate = container.decodeIntIfPresent(forKey: .bitrate)
        mediaStreams = try container.decodeIfPresent([EmbyMediaStream].self, forKey: .mediaStreams)
    }

    var audioStream: EmbyMediaStream? {
        mediaStreams?.first { stream in
            stream.type?.localizedCaseInsensitiveCompare("Audio") == .orderedSame ||
                stream.codec != nil
        }
    }
}

struct EmbyMediaStream: Codable, Hashable {
    let type: String?
    let codec: String?
    let bitRate: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case bitRate = "BitRate"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        bitRate = container.decodeIntIfPresent(forKey: .bitRate)
    }
}

struct EmbyUserData: Codable, Hashable {
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

struct MusicPlaylist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let description: String
    let songs: [EmbyAudioItem]

    var totalDuration: TimeInterval {
        songs.reduce(0) { $0 + $1.duration }
    }
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
        if let date = try? decodeIfPresent(Date.self, forKey: key) {
            return date
        }

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

    var playlistDurationText: String {
        guard isFinite, self > 0 else { return "0分钟" }
        let totalMinutes = max(1, Int((self / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0, minutes > 0 {
            return "\(hours)小时\(minutes)分钟"
        }
        if hours > 0 {
            return "\(hours)小时"
        }
        return "\(minutes)分钟"
    }
}

private extension Int {
    var kilobitText: String {
        "\(Swift.max(Int((Double(self) / 1_000).rounded()), 1))k"
    }
}
