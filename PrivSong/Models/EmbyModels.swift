import Foundation

struct EmbySession: Codable, Equatable {
    let serverURL: URL
    let userId: String
    let username: String
    let accessToken: String
}

enum OnlinePlaybackQuality: String, CaseIterable, Codable, Identifiable, Hashable {
    case lossless
    case veryHigh
    case high
    case standard
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lossless:
            return "无损"
        case .veryHigh:
            return "极高"
        case .high:
            return "较高"
        case .standard:
            return "标准"
        case .low:
            return "较低"
        }
    }

    var bitrate: Int? {
        switch self {
        case .lossless:
            return nil
        case .veryHigh:
            return 320_000
        case .high:
            return 256_000
        case .standard:
            return 192_000
        case .low:
            return 128_000
        }
    }

    var displayTitle: String {
        guard let bitrate else { return "无损（不转码）" }
        return "\(title) (\(bitrate / 1_000) kbps)"
    }

    var usesTranscoding: Bool {
        bitrate != nil
    }
}

enum AudioTranscodeFormat: String, Hashable {
    case aac

    var codec: String {
        "aac"
    }

    var transcodingContainer: String {
        "aac"
    }

    var containerQueryValue: String {
        "aac"
    }

    var fileExtension: String {
        transcodingContainer
    }
}

enum PlaybackNetworkKind: String, Hashable {
    case wifi
    case cellular
}

struct PlaybackQualityPreferences: Equatable {
    var cellularQuality: OnlinePlaybackQuality = .standard
    var wifiQuality: OnlinePlaybackQuality = .lossless
    var transcodeFormat: AudioTranscodeFormat = .aac

    func quality(for networkKind: PlaybackNetworkKind) -> OnlinePlaybackQuality {
        switch networkKind {
        case .wifi:
            return wifiQuality
        case .cellular:
            return cellularQuality
        }
    }
}

struct PlaybackStreamOptions: Hashable {
    let quality: OnlinePlaybackQuality
    let transcodeFormat: AudioTranscodeFormat
    let networkKind: PlaybackNetworkKind

    func cacheFileExtension(for item: EmbyAudioItem) -> String {
        if quality.usesTranscoding {
            return transcodeFormat.fileExtension
        }
        return item.audioCacheFileExtension
    }
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

    var isAudiobookLibrary: Bool {
        let normalizedType = collectionType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedType == "books" ||
            normalizedType == "audiobooks" ||
            name.localizedCaseInsensitiveContains("audiobook") ||
            name.localizedCaseInsensitiveContains("audio book") ||
            name.localizedCaseInsensitiveContains("有声书") ||
            name.localizedCaseInsensitiveContains("听书")
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
    let parentId: String?
    let primaryImageItemId: String?
    let type: String?
    let mediaType: String?
    let container: String?
    let bitrate: Int?
    let mediaSources: [EmbyMediaSource]?
    let isFolder: Bool?
    let runTimeTicks: Int64?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let sortName: String?
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
        case parentId = "ParentId"
        case primaryImageItemId = "PrimaryImageItemId"
        case type = "Type"
        case mediaType = "MediaType"
        case container = "Container"
        case bitrate = "Bitrate"
        case mediaSources = "MediaSources"
        case isFolder = "IsFolder"
        case runTimeTicks = "RunTimeTicks"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case sortName = "SortName"
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
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        primaryImageItemId = try container.decodeIfPresent(String.self, forKey: .primaryImageItemId)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        bitrate = container.decodeIntIfPresent(forKey: .bitrate)
        mediaSources = try container.decodeIfPresent([EmbyMediaSource].self, forKey: .mediaSources)
        isFolder = try container.decodeIfPresent(Bool.self, forKey: .isFolder)
        runTimeTicks = container.decodeInt64IfPresent(forKey: .runTimeTicks)
        indexNumber = container.decodeIntIfPresent(forKey: .indexNumber)
        parentIndexNumber = container.decodeIntIfPresent(forKey: .parentIndexNumber)
        sortName = try container.decodeIfPresent(String.self, forKey: .sortName)
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
            type?.localizedCaseInsensitiveCompare("AudioBook") == .orderedSame ||
            mediaType?.localizedCaseInsensitiveCompare("Audio") == .orderedSame
    }

    var isAudiobookAudio: Bool {
        type?.localizedCaseInsensitiveCompare("AudioBook") == .orderedSame
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

    var audioCacheFileExtension: String {
        let rawValue = firstNonEmpty(
            container,
            mediaSources?.first?.container,
            mediaSources?.first?.audioStream?.codec
        )
        return rawValue.flatMap(Self.audioFileExtension) ?? "audio"
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

    private static func audioFileExtension(_ value: String) -> String? {
        let normalized = normalizedAudioFormat(value)
        switch normalized {
        case "mpeg", "mpga":
            return "mp3"
        case "alac":
            return "m4a"
        case "wave":
            return "wav"
        case "x-flac":
            return "flac"
        default:
            let allowed = CharacterSet.alphanumerics
            let sanitized = normalized.unicodeScalars.filter { allowed.contains($0) }
            guard !sanitized.isEmpty else { return nil }
            return String(String.UnicodeScalarView(sanitized))
        }
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
    let id: String?
    let container: String?
    let bitrate: Int?
    let mediaStreams: [EmbyMediaStream]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case bitrate = "Bitrate"
        case mediaStreams = "MediaStreams"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
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
    let playbackPositionTicks: Int64?
    let playedPercentage: Double?
    let played: Bool?

    enum CodingKeys: String, CodingKey {
        case playCount = "PlayCount"
        case lastPlayedDate = "LastPlayedDate"
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playedPercentage = "PlayedPercentage"
        case played = "Played"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playCount = container.decodeIntIfPresent(forKey: .playCount)
        lastPlayedDate = container.decodeEmbyDateIfPresent(forKey: .lastPlayedDate)
        playbackPositionTicks = container.decodeInt64IfPresent(forKey: .playbackPositionTicks)
        playedPercentage = container.decodeDoubleIfPresent(forKey: .playedPercentage)
        played = try container.decodeIfPresent(Bool.self, forKey: .played)
    }

    var playbackPosition: TimeInterval {
        guard let playbackPositionTicks else { return 0 }
        return TimeInterval(playbackPositionTicks) / 10_000_000
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

struct Audiobook: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let author: String
    let episodes: [EmbyAudioItem]

    var representativeEpisode: EmbyAudioItem? { episodes.first }
    var episodeCount: Int { episodes.count }
}

struct IndexedSection<Item: Identifiable>: Identifiable {
    let title: String
    let items: [Item]

    var id: String { title }
}

enum PinyinIndexer {
    static func sections<Item>(for items: [Item], title: KeyPath<Item, String>) -> [IndexedSection<Item>] where Item: Identifiable {
        let grouped = Dictionary(grouping: items) { item in
            indexTitle(for: item[keyPath: title])
        }

        return grouped.keys
            .sorted(by: sectionSort)
            .compactMap { key in
                guard let values = grouped[key] else { return nil }
                let sorted = values.sorted {
                    $0[keyPath: title].localizedCaseInsensitiveCompare($1[keyPath: title]) == .orderedAscending
                }
                return IndexedSection(title: key, items: sorted)
            }
    }

    private static func indexTitle(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#" }

        let mutable = NSMutableString(string: trimmed) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)

        let latin = String(mutable).uppercased()
        guard let scalar = latin.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(scalar) else {
            return "#"
        }

        return String(Character(scalar))
    }

    private static func sectionSort(_ left: String, _ right: String) -> Bool {
        if left == "#" { return false }
        if right == "#" { return true }
        return left < right
    }
}

struct MusicPlaylist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let description: String
    let songs: [EmbyAudioItem]
    let songCount: Int?

    init(
        id: String,
        name: String,
        description: String,
        songs: [EmbyAudioItem],
        songCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.songs = songs
        self.songCount = songCount
    }

    var displaySongCount: Int {
        songCount ?? songs.count
    }

    var hasCompleteSongList: Bool {
        songCount.map { $0 <= songs.count } ?? true
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

    var audiobooks: [Audiobook] {
        let grouped = Dictionary(grouping: self) { episode in
            episode.audiobookGroupId
        }

        return grouped.map { groupId, episodes in
            let sortedEpisodes = episodes.sorted(by: Self.audiobookEpisodeSort)
            let first = sortedEpisodes.first
            return Audiobook(
                id: groupId,
                title: first?.audiobookTitle ?? "未知有声书",
                author: first?.audiobookAuthor ?? "未知作者",
                episodes: sortedEpisodes
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func audiobookEpisodeSort(_ left: EmbyAudioItem, _ right: EmbyAudioItem) -> Bool {
        let leftParentIndex = left.parentIndexNumber ?? Int.max
        let rightParentIndex = right.parentIndexNumber ?? Int.max
        if leftParentIndex != rightParentIndex {
            return leftParentIndex < rightParentIndex
        }

        let leftIndex = left.indexNumber ?? Int.max
        let rightIndex = right.indexNumber ?? Int.max
        if leftIndex != rightIndex {
            return leftIndex < rightIndex
        }

        let leftSortName = left.sortName ?? left.name
        let rightSortName = right.sortName ?? right.name
        return leftSortName.localizedStandardCompare(rightSortName) == .orderedAscending
    }
}

private extension EmbyAudioItem {
    var audiobookGroupId: String {
        firstNonEmpty(albumId, album, parentId, primaryImageItemId) ?? id
    }

    var audiobookTitle: String {
        firstNonEmpty(album, name) ?? "未知有声书"
    }

    var audiobookAuthor: String {
        firstNonEmpty(albumArtist, artists?.joined(separator: ", ")) ?? "未知作者"
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

    func decodeDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
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

}

private extension Int {
    var kilobitText: String {
        "\(Swift.max(Int((Double(self) / 1_000).rounded()), 1))k"
    }
}
