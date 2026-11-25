import Foundation
import os
import XCTest
@testable import PrivSong

final class RegressionTests: XCTestCase {
    @MainActor
    func testPlaybackModeCyclesThroughRepeatAndShuffle() throws {
        let player = PlayerController()
        player.addToQueueEnd(try song("first"))
        player.addToQueueEnd(try song("second"))

        player.cyclePlaybackMode()
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertFalse(player.isShuffleEnabled)
        player.cyclePlaybackMode()
        XCTAssertEqual(player.repeatMode, .one)
        XCTAssertFalse(player.isShuffleEnabled)
        player.cyclePlaybackMode()
        XCTAssertEqual(player.repeatMode, .none)
        XCTAssertTrue(player.isShuffleEnabled)
        player.cyclePlaybackMode()
        XCTAssertEqual(player.repeatMode, .none)
        XCTAssertFalse(player.isShuffleEnabled)
    }

    @MainActor
    func testUpcomingTracksKeepTheirEntryIDsWhenMovedInEitherDirection() throws {
        let player = PlayerController()
        let repeated = try song("repeated")
        player.addToQueueEnd(repeated)
        player.addToQueueEnd(try song("middle"))
        player.addToQueueEnd(repeated)
        player.addToQueueEnd(try song("last"))
        let initial = player.upcomingQueueSnapshot.map(\.id)
        XCTAssertEqual(Set(initial).count, 4)

        player.moveUpcomingQueueItem(from: 0, to: 3)
        XCTAssertEqual(player.upcomingQueueSnapshot.map(\.id), [initial[1], initial[2], initial[3], initial[0]])
        XCTAssertEqual(player.upcomingQueueSnapshot.map(\.song.id), ["middle", "repeated", "last", "repeated"])

        player.moveUpcomingQueueItem(from: 3, to: 0)
        XCTAssertEqual(player.upcomingQueueSnapshot.map(\.id), initial)
    }

    func testServerAddressDefaultsToHTTPSAndPreservesExplicitHTTP() throws {
        XCTAssertEqual(try EmbyClient.normalizedServerURL(" music.example.test/emby ").scheme, "https")
        XCTAssertEqual(try EmbyClient.normalizedServerURL("http://192.168.1.5:8096/emby").scheme, "http")
        XCTAssertThrowsError(try EmbyClient.normalizedServerURL("ftp://music.example.test"))
    }

    func testPlaylistRestoredAfterSecondDeleteBatchFails() async throws {
        let original = (0..<95).map { "song-\($0)" }
        let playlist = PlaylistFixture(songs: original)
        MockEmbyProtocol.handler.withLock { $0 = { playlist.reply(to: $0) } }
        defer { MockEmbyProtocol.handler.withLock { $0 = nil } }

        let client = mockClient()
        let replacement = [try song("new")]
        do {
            try await client.replacePlaylistSongs(playlistId: "playlist", songs: replacement, session: session())
            XCTFail("The second delete request should fail")
        } catch EmbyError.playlistReplacementFailed(_, let restored) {
            XCTAssertTrue(restored)
        }
        XCTAssertEqual(playlist.songIDs, original)
    }

    func testQueueMigrationKeepsLegacyAfterFailedWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("playback-queue-snapshot.json")
        let current = directory.appendingPathComponent("playback-queue.json")
        let item = try song("saved")
        let checkpoint = PlaybackQueueSnapshotStore.State(
            queueRevision: UUID(), currentSongID: item.id, currentQueueIndex: 0,
            currentPosition: 30, isShuffleEnabled: false, repeatMode: .all
        )
        let previous = PlaybackQueueSnapshot(
            version: 1, savedAt: .now, queue: [item], queueBeforeShuffle: nil,
            currentSongID: item.id, currentQueueIndex: nil, queueRevision: nil,
            currentPosition: 30, isShuffleEnabled: false, repeatMode: .all
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(previous).write(to: legacy)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)

        let store = PlaybackQueueSnapshotStore(directory: directory)
        XCTAssertFalse(store.saveQueue(queue: [item], queueBeforeShuffle: nil, checkpoint: checkpoint))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(store.load()?.version, 1)
        try FileManager.default.removeItem(at: current)
        XCTAssertTrue(store.saveQueue(queue: [item], queueBeforeShuffle: nil, checkpoint: checkpoint))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(store.load()?.currentPosition, 30)

        let stale = PlaybackQueueSnapshotStore.State(
            queueRevision: UUID(), currentSongID: item.id, currentQueueIndex: 0,
            currentPosition: 800, isShuffleEnabled: true, repeatMode: .one
        )
        store.saveState(stale)
        XCTAssertEqual(store.load()?.currentPosition, 30)
        XCTAssertEqual(store.load()?.repeatMode, .all)
    }

    @MainActor
    func testOldAccountSnapshotIsAvailableWhenEmbyIsOffline() async throws {
        let previous = session()
        let item = try song("saved")
        let snapshot = LibrarySnapshotStore(directory: previous.account.directory)
        snapshot.save(songs: [item], playlists: [], audiobookEpisodes: [], savedAt: Date(timeIntervalSince1970: 100))
        MockEmbyProtocol.handler.withLock { $0 = { request in
            if request.url?.path.hasSuffix("/AuthenticateByName") == true { return loginReply(previous.userId) }
            return .failure(URLError(.notConnectedToInternet))
        } }
        let store = AppStore(client: mockClient(), restoresSession: false)
        defer {
            store.signOut()
            MockEmbyProtocol.handler.withLock { $0 = nil }
        }

        await store.signIn(server: previous.serverURL.absoluteString, username: previous.username, password: "test")
        XCTAssertEqual(store.songs.map(\.id), ["saved"])
        await store.refreshLibrary()
        XCTAssertEqual(store.songs.map(\.id), ["saved"])
    }

    @MainActor
    func testLateSearchDoesNotPublishAfterAccountChange() async throws {
        let previous = session()
        let next = session()
        let desktopSearchStarted = OSAllocatedUnfairLock(initialState: false)
        MockEmbyProtocol.handler.withLock { $0 = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/AuthenticateByName") {
                return loginReply(request.url?.host == previous.serverURL.host ? previous.userId : next.userId)
            }
            if path.hasSuffix("/Views") {
                return .json(200, ["Items": [["Id": "music", "Name": "Music", "CollectionType": "music"]]])
            }
            if request.url?.query?.contains("SearchTerm=late") == true {
                desktopSearchStarted.withLock { $0 = true }
                return .json(200, ["Items": [["Id": "old-only", "Name": "Late", "Type": "Audio"]]], delay: 0.4)
            }
            return .json(200, ["Items": [], "TotalRecordCount": 0])
        } }
        let store = AppStore(client: mockClient(), restoresSession: false)
        defer {
            store.signOut()
            MockEmbyProtocol.handler.withLock { $0 = nil }
        }
        await store.signIn(server: previous.serverURL.absoluteString, username: "old", password: "test")
        let oldRequest = Task { await store.search("late") }
        for _ in 0..<100 {
            if desktopSearchStarted.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(desktopSearchStarted.withLock { $0 })

        await store.signIn(server: next.serverURL.absoluteString, username: "new", password: "test")
        await oldRequest.value
        XCTAssertEqual(store.session?.account, next.account)
        XCTAssertTrue(store.searchResults.isEmpty)
        XCTAssertFalse(store.isSearching)
    }

    private func song(_ id: String) throws -> EmbyAudioItem {
        let json = try JSONSerialization.data(withJSONObject: ["Id": id, "Name": id, "Type": "Audio"])
        return try JSONDecoder().decode(EmbyAudioItem.self, from: json)
    }

    private func session() -> EmbySession {
        let id = UUID().uuidString.lowercased()
        return EmbySession(
            serverURL: URL(string: "https://\(id).example.test/")!,
            userId: id, username: id, accessToken: "test-token"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func mockClient() -> EmbyClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockEmbyProtocol.self]
    return EmbyClient(session: URLSession(configuration: configuration))
}

private func loginReply(_ userID: String) -> MockReply {
    .json(200, ["User": ["Id": userID, "Name": userID], "AccessToken": "test-token"])
}

private enum MockReply: Sendable {
    case response(Int, Data, TimeInterval)
    case failure(URLError)

    static func json(_ status: Int, _ object: [String: Any], delay: TimeInterval = 0) -> Self {
        do {
            return .response(status, try JSONSerialization.data(withJSONObject: object), delay)
        } catch {
            return .failure(URLError(.cannotParseResponse))
        }
    }
}

private final class MockEmbyProtocol: URLProtocol, @unchecked Sendable {
    static let handler = OSAllocatedUnfairLock<(@Sendable (URLRequest) -> MockReply)?>(initialState: nil)
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.handler.withLock { $0 }
        switch handler?(request) ?? .failure(URLError(.unsupportedURL)) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let data, let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                guard !stopped.withLock({ $0 }), let url = request.url,
                      let response = HTTPURLResponse(
                        url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                      ) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

private final class PlaylistFixture: Sendable {
    private struct State: Sendable {
        var songs: [String]
        var deleteRequests = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(songs: [String]) {
        state = OSAllocatedUnfairLock(initialState: State(songs: songs))
    }

    var songIDs: [String] { state.withLock { $0.songs } }

    func reply(to request: URLRequest) -> MockReply {
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        return state.withLock { value in
            switch request.httpMethod {
            case "GET":
                let items = value.songs.map { ["Id": $0, "PlaylistItemId": "entry-\($0)"] }
                return .json(200, ["Items": items, "TotalRecordCount": items.count])
            case "DELETE":
                value.deleteRequests += 1
                if value.deleteRequests == 2 { return .json(503, [:]) }
                let removed = Set(query?.first { $0.name == "EntryIds" }?.value?.components(separatedBy: ",") ?? [])
                value.songs.removeAll { removed.contains("entry-\($0)") }
                return .json(200, [:])
            case "POST":
                value.songs += query?.first { $0.name == "Ids" }?.value?.components(separatedBy: ",") ?? []
                return .json(200, [:])
            default:
                return .json(405, [:])
            }
        }
    }
}
