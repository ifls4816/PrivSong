import AVFoundation
import Combine
import Foundation
import Network
import UIKit

struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let time: TimeInterval?
    let text: String
}

private enum StreamTimebase {
    case relativeToStartOffset
    case absolute
}

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentSong: EmbyAudioItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeeking = false
    @Published private(set) var seekTarget: TimeInterval?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var queueSnapshot: [EmbyAudioItem] = []
    @Published private(set) var upcomingQueueSnapshot: [EmbyAudioItem] = []
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var lyricsSongId: String?
    @Published private(set) var isLoadingLyrics = false
    @Published private(set) var playbackStatusText: String?
    @Published private(set) var isBuffering = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published var isShuffleEnabled = false
    @Published var repeatMode: RepeatMode = .none

    var onPlaybackPositionChanged: ((EmbyAudioItem, TimeInterval, TimeInterval, Bool) -> Void)?

    private let engine = AVPlayer()
    private let audioSession = AudioSessionCoordinator.shared
    private let nowPlaying = NowPlayingCoordinator.shared
    private let remoteCommands = RemoteCommandCoordinator.shared
    private let client = EmbyClient()
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "MusicEmby.NetworkPathMonitor")
    private let audioCache = CurrentSongAudioCache()

    private var session: EmbySession?
    private var queue: [EmbyAudioItem] = []
    private var queueBeforeShuffle: [EmbyAudioItem]?
    private var streamCandidates: [URL] = []
    private var streamCandidateIndex = 0
    private var currentStreamURL: URL?
    private var streamStartOffset: TimeInterval = 0
    private var currentStreamTimebase: StreamTimebase?
    private var currentStreamOptions: PlaybackStreamOptions?
    private var currentPlaySessionId: String?
    private var currentPlaybackReportMethod: EmbyPlaybackReportMethod = .directStream
    private var lastPlaybackProgressReport = Date.distantPast
    private var lastTranscodedStreamRefresh = Date.distantPast
    private var currentNetworkKind: PlaybackNetworkKind = .wifi
    private var playbackQualityPreferences = PlaybackQualityPreferences()
    private var activeAudioCacheKey: PlaybackAudioCache.Key?
    private var currentArtwork: UIImage?
    private var lastNowPlayingSync = Date.distantPast
    private var shouldResumeAfterInterruption = false
    private var isSwitchingTracks = false
    private var pendingSeekTarget: TimeInterval?
    private var suppressTimeUpdatesUntil = Date.distantPast
    private var seekGeneration = 0

    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemPlaybackBufferEmptyObserver: NSKeyValueObservation?
    private var itemPlaybackLikelyToKeepUpObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var accessLogObserver: NSObjectProtocol?
    private var playbackStalledObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var audioCacheTask: Task<Void, Never>?
    private var playbackReportTask: Task<Void, Never>?
    private var currentAccessLogEventCount = 0

    init() {
        engine.automaticallyWaitsToMinimizeStalling = true

        audioSession.configureForPlayback()
        configureRemoteCommands()
        configurePlayerObservers()
        configureAudioSessionObservers()
        configureNetworkPathMonitor()
    }

    func play(song: EmbyAudioItem, in songs: [EmbyAudioItem], session: EmbySession, startPosition: TimeInterval = 0) {
        guard !isSwitchingTracks else { return }

        self.session = session
        var playbackQueue = songs.isEmpty ? [song] : songs
        if !playbackQueue.contains(song) {
            playbackQueue.insert(song, at: 0)
        }

        if isShuffleEnabled {
            queueBeforeShuffle = playbackQueue
            queue = shuffledPlaybackQueue(from: playbackQueue, keeping: song)
        } else {
            queueBeforeShuffle = nil
            queue = playbackQueue
        }

        syncQueueSnapshots()
        start(song: song, session: session, autoplay: true, startPosition: startPosition)
    }

    func togglePlayPause() {
        if isPlaying || engine.timeControlStatus == .playing {
            pause()
        } else {
            resume()
        }
    }

    func setPlaybackQualityPreferences(_ preferences: PlaybackQualityPreferences) {
        let previousOptions = currentPlaybackStreamOptions()
        playbackQualityPreferences = preferences
        let updatedOptions = currentPlaybackStreamOptions()
        if previousOptions.transcodeFormat != updatedOptions.transcodeFormat,
           currentSong != nil,
           currentStreamURL != nil {
            stopPlaybackForConfigurationChange()
            return
        }

        guard previousOptions != updatedOptions,
              let currentSong,
              let session,
              currentStreamURL != nil else { return }

        let resumePosition = elapsed
        let shouldResume = isPlaying || engine.timeControlStatus == .playing
        start(song: currentSong, session: session, autoplay: shouldResume, startPosition: resumePosition)
    }

    func seek(to progress: Double) {
        let target = max(0, min(1, progress)) * max(duration, 1)
        seek(toSeconds: target, shouldPlayAfterSeek: isPlaying)
    }

    func seek(toElapsed seconds: TimeInterval) {
        seek(toSeconds: seconds, shouldPlayAfterSeek: isPlaying)
    }

    func next() {
        playRelative(offset: 1, wrap: repeatMode == .all)
    }

    func previous() {
        if elapsed > 3 {
            seek(toSeconds: 0, shouldPlayAfterSeek: isPlaying)
            return
        }
        playRelative(offset: -1, wrap: repeatMode == .all)
    }

    func toggleShuffle() {
        if isShuffleEnabled {
            if let originalQueue = queueBeforeShuffle {
                queue = originalQueue
            }
            queueBeforeShuffle = nil
            isShuffleEnabled = false
        } else {
            guard !queue.isEmpty else { return }
            queueBeforeShuffle = queue
            queue = shuffledPlaybackQueue(from: queue, keeping: currentSong)
            isShuffleEnabled = true
        }
        syncQueueSnapshots()
        syncRemoteCommandAvailability()
    }

    func playQueued(song: EmbyAudioItem) {
        guard activeQueue.contains(song), let session else { return }
        start(song: song, session: session, autoplay: true)
    }

    func playNext(_ song: EmbyAudioItem) {
        insertIntoUpcoming(song, offsetFromCurrent: 1)
    }

    func addToQueueEnd(_ song: EmbyAudioItem) {
        insertIntoUpcoming(song, offsetFromCurrent: nil)
    }

    func removeUpcomingQueueItem(at index: Int) {
        let songs = activeQueue
        guard let currentSong,
              let currentIndex = songs.firstIndex(of: currentSong) else { return }
        let removeIndex = songs.index(after: currentIndex) + index
        guard songs.indices.contains(removeIndex) else { return }

        var updated = songs
        updated.remove(at: removeIndex)
        applyActiveQueue(updated)
    }

    func clearUpcomingQueue() {
        let songs = activeQueue
        guard let currentSong,
              let currentIndex = songs.firstIndex(of: currentSong) else { return }
        applyActiveQueue(Array(songs[...currentIndex]))
    }

    func moveUpcomingQueueItem(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex else { return }

        let songs = activeQueue
        guard let currentSong,
              let currentIndex = songs.firstIndex(of: currentSong) else {
            applyActiveQueue(reordered(songs, moving: sourceIndex, to: destinationIndex))
            return
        }

        let upcomingStart = songs.index(after: currentIndex)
        var upcoming = Array(songs[upcomingStart...])
        guard upcoming.indices.contains(sourceIndex),
              upcoming.indices.contains(destinationIndex) else {
            return
        }

        upcoming = reordered(upcoming, moving: sourceIndex, to: destinationIndex)
        applyActiveQueue(Array(songs[...currentIndex]) + upcoming)
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .none:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .none
        }
        syncRemoteCommandAvailability()
    }

    func setSleepTimer(after duration: TimeInterval) {
        sleepTimerTask?.cancel()
        sleepTimerEndDate = Date().addingTimeInterval(duration)
        sleepTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.sleepTimerTask = nil
            self.sleepTimerEndDate = nil
            self.pause()
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    func seek(toLyric line: LyricLine) {
        guard let time = line.time else { return }
        seek(toSeconds: time, shouldPlayAfterSeek: isPlaying)
    }

    func preloadLyrics(for song: EmbyAudioItem, session: EmbySession) {
        guard currentSong?.id != song.id,
              lyricsSongId != song.id else { return }

        loadEmbeddedLyrics(from: client.originalAudioStreamURL(for: song, session: session), songId: song.id)
    }

    private var activeQueue: [EmbyAudioItem] {
        queue
    }

    private func currentPlaybackStreamOptions() -> PlaybackStreamOptions {
        PlaybackStreamOptions(
            quality: playbackQualityPreferences.quality(for: currentNetworkKind),
            transcodeFormat: playbackQualityPreferences.transcodeFormat,
            networkKind: currentNetworkKind
        )
    }

    private func playbackReportMethod(for options: PlaybackStreamOptions, isUsingLocalFile: Bool) -> EmbyPlaybackReportMethod {
        if isUsingLocalFile {
            return .directPlay
        }
        return options.quality.usesTranscoding ? .transcode : .directStream
    }

    private func configureNetworkPathMonitor() {
        currentNetworkKind = pathMonitor.currentPath.playbackNetworkKind
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.currentNetworkKind = path.playbackNetworkKind
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func cacheCurrentSong(from sourceURL: URL?, cacheKey: PlaybackAudioCache.Key) {
        audioCacheTask?.cancel()
        guard let sourceURL, !sourceURL.isFileURL else { return }

        let currentAudioCache = audioCache
        audioCacheTask = Task {
            do {
                _ = try await currentAudioCache.cacheCurrentSong(from: sourceURL, key: cacheKey)
            } catch is CancellationError {
            } catch {
                print("[Player] Failed to cache current song: \(error.localizedDescription)")
            }
        }
    }

    private func start(
        song: EmbyAudioItem,
        session: EmbySession,
        autoplay: Bool,
        startPosition: TimeInterval = 0
    ) {
        reportPlaybackStoppedIfNeeded(position: elapsed)
        audioCacheTask?.cancel()
        let initialPosition = max(0, min(startPosition, song.duration > 0 ? max(song.duration - 1, 0) : startPosition))
        isSwitchingTracks = true
        currentSong = song
        elapsed = initialPosition
        duration = song.duration
        isPlaying = autoplay
        currentArtwork = nil
        lyrics = []
        lyricsSongId = nil
        isLoadingLyrics = false
        playbackStatusText = "正在连接"
        isBuffering = true
        lastNowPlayingSync = .distantPast
        currentStreamURL = nil
        streamStartOffset = 0
        currentStreamTimebase = nil
        currentStreamOptions = nil
        seekTarget = nil
        pendingSeekTarget = nil
        suppressTimeUpdatesUntil = .distantPast
        seekGeneration += 1
        lastPlaybackProgressReport = .distantPast
        currentAccessLogEventCount = 0

        let streamOptions = currentPlaybackStreamOptions()
        currentStreamOptions = streamOptions
        streamStartOffset = streamOptions.quality.usesTranscoding ? initialPosition : 0
        let cacheKey = PlaybackAudioCache.Key(session: session, item: song, options: streamOptions)
        let playSessionId = UUID().uuidString
        activeAudioCacheKey = cacheKey
        currentPlaySessionId = playSessionId
        streamCandidates = client.playbackURLCandidates(
            for: song,
            session: session,
            options: streamOptions,
            playSessionId: playSessionId,
            startTime: streamStartOffset
        )
        streamCandidateIndex = 0
        syncQueueSnapshots()

        audioSession.activate()
        let allowsLocalCachePlayback = !streamOptions.quality.usesTranscoding
        let cachedURL = allowsLocalCachePlayback ? PlaybackAudioCache.cachedFileURL(for: cacheKey) : nil
        let initialURL = cachedURL ?? streamCandidates.first
        currentPlaybackReportMethod = playbackReportMethod(for: streamOptions, isUsingLocalFile: cachedURL != nil)
        replaceCurrentItem(with: initialURL, autoplay: autoplay, startAt: initialPosition, candidateIndex: 0)
        if allowsLocalCachePlayback {
            cacheCurrentSong(from: streamStartOffset == 0 ? streamCandidates.first : nil, cacheKey: cacheKey)
        }
        loadArtwork(for: song, session: session)
        loadEmbeddedLyrics(from: client.originalAudioStreamURL(for: song, session: session), songId: song.id)
        reportPlaybackStarted(position: initialPosition)
        syncNowPlaying(force: true)
        syncRemoteCommandAvailability()
    }

    private func replaceCurrentItem(
        with url: URL?,
        autoplay: Bool,
        startAt startTime: TimeInterval? = nil,
        candidateIndex: Int? = nil
    ) {
        guard let url else {
            print("[Player] No playable Emby URL for current item.")
            isPlaying = false
            isBuffering = false
            playbackStatusText = "播放失败"
            isSwitchingTracks = false
            syncNowPlaying(force: true)
            return
        }

        if let candidateIndex {
            streamCandidateIndex = candidateIndex
        }
        currentStreamURL = url
        currentStreamTimebase = nil
        currentAccessLogEventCount = 0

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 45
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = !url.isFileURL
        observeStatus(of: item)
        observeBuffering(of: item)

        engine.replaceCurrentItem(with: item)

        if let startTime, startTime > 0 {
            let clampedStartTime = max(0, startTime)
            isSeeking = true
            item.seek(
                to: CMTime(seconds: itemTime(forAbsoluteTime: clampedStartTime), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsed = clampedStartTime
                    self.pendingSeekTarget = clampedStartTime
                    self.suppressTimeUpdatesUntil = Date().addingTimeInterval(0.8)
                    self.isSeeking = false
                    self.beginPlaybackIfNeeded(autoplay: autoplay)
                    self.isSwitchingTracks = false
                    self.syncNowPlaying(force: true)
                }
            }
        } else {
            beginPlaybackIfNeeded(autoplay: autoplay)
            isSwitchingTracks = false
        }
    }

    private func beginPlaybackIfNeeded(autoplay: Bool) {
        guard autoplay else { return }
        engine.play()
        isPlaying = true
    }

    private func resume() {
        guard currentSong != nil else { return }
        audioSession.activate()
        engine.play()
        isPlaying = true
        syncNowPlaying(force: true)
        reportPlaybackProgress(force: true)
    }

    private func pause() {
        engine.pause()
        isPlaying = false
        syncNowPlaying(force: true)
        reportPlaybackProgress(force: true, isPaused: true)
    }

    private func stopPlaybackForConfigurationChange() {
        reportPlaybackStoppedIfNeeded(position: elapsed)
        audioCacheTask?.cancel()
        artworkTask?.cancel()
        lyricsTask?.cancel()

        engine.pause()
        engine.replaceCurrentItem(with: nil)
        isPlaying = false
        isSeeking = false
        isSwitchingTracks = false
        isBuffering = false
        playbackStatusText = nil
        currentSong = nil
        currentArtwork = nil
        currentStreamURL = nil
        streamCandidates = []
        streamCandidateIndex = 0
        streamStartOffset = 0
        currentStreamTimebase = nil
        currentStreamOptions = nil
        activeAudioCacheKey = nil
        seekTarget = nil
        pendingSeekTarget = nil
        suppressTimeUpdatesUntil = .distantPast
        seekGeneration += 1
        elapsed = 0
        duration = 0
        lyrics = []
        lyricsSongId = nil
        isLoadingLyrics = false
        lastNowPlayingSync = .distantPast
        syncQueueSnapshots()
        syncNowPlaying(force: true)
        syncRemoteCommandAvailability()
    }

    private func seek(toSeconds seconds: TimeInterval, shouldPlayAfterSeek: Bool) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        guard currentStreamURL != nil else { return }

        seekGeneration += 1
        let generation = seekGeneration

        if currentStreamOptions?.quality.usesTranscoding == true {
            seekTarget = clamped
            pendingSeekTarget = clamped
            elapsed = clamped
            syncNowPlaying(force: true)
            reportPlaybackProgress(force: true, position: clamped)
            refreshTranscodedStream(at: clamped, autoplay: shouldPlayAfterSeek, statusText: "正在跳转")
            return
        }

        let currentItem = engine.currentItem
        let targetTime = CMTime(seconds: itemTime(forAbsoluteTime: clamped), preferredTimescale: 600)
        isSeeking = true
        seekTarget = clamped
        pendingSeekTarget = clamped
        suppressTimeUpdatesUntil = Date().addingTimeInterval(1.0)
        elapsed = clamped
        syncNowPlaying(force: true)
        reportPlaybackProgress(force: true, position: clamped)
        engine.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self,
                      self.seekGeneration == generation,
                      self.engine.currentItem === currentItem else { return }
                guard finished else {
                    let actualElapsed = self.resolvedElapsed(
                        forItemTime: self.engine.currentTime().seconds,
                        reference: clamped
                    )
                    self.elapsed = actualElapsed
                    self.seekTarget = nil
                    self.pendingSeekTarget = nil
                    self.isSeeking = false
                    self.syncNowPlaying(force: true)
                    self.reportPlaybackProgress(force: true, position: actualElapsed)
                    return
                }
                if shouldPlayAfterSeek {
                    self.engine.play()
                    self.isPlaying = true
                }
                self.elapsed = clamped
                self.pendingSeekTarget = clamped
                self.suppressTimeUpdatesUntil = Date().addingTimeInterval(0.8)
                self.isSeeking = false
                self.syncNowPlaying(force: true)
                self.reportPlaybackProgress(force: true, position: clamped)
            }
        }
    }

    private func playRelative(offset: Int, wrap: Bool) {
        let songs = activeQueue
        guard let currentSong,
              let session,
              let currentIndex = songs.firstIndex(of: currentSong) else {
            return
        }

        let targetIndex = currentIndex + offset
        if songs.indices.contains(targetIndex) {
            start(song: songs[targetIndex], session: session, autoplay: true)
            return
        }

        guard wrap, !songs.isEmpty else { return }
        let wrappedIndex = offset > 0 ? songs.startIndex : songs.index(before: songs.endIndex)
        start(song: songs[wrappedIndex], session: session, autoplay: true)
    }

    private func handleTrackEnded() {
        guard !isSwitchingTracks else { return }

        if repeatMode == .one {
            seek(toSeconds: 0, shouldPlayAfterSeek: true)
            return
        }

        let before = currentSong
        playRelative(offset: 1, wrap: repeatMode == .all)
        if currentSong == before {
            isPlaying = false
            syncNowPlaying(force: true)
            reportPlaybackStoppedIfNeeded(position: duration)
        }
    }

    private func handleItemFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        print("[Player] AVPlayerItem failed: \(message)")

        if currentStreamOptions?.quality.usesTranscoding == true,
           refreshTranscodedStreamAfterInterruption(reason: "item failure") {
            return
        }

        if currentStreamURL?.isFileURL == true {
            guard streamCandidates.indices.contains(streamCandidateIndex) else {
                isPlaying = false
                isBuffering = false
                playbackStatusText = "播放失败"
                isSwitchingTracks = false
                syncNowPlaying(force: true)
                return
            }

            playbackStatusText = "正在切换播放源"
            isBuffering = true
            currentPlaybackReportMethod = playbackReportMethod(for: currentPlaybackStreamOptions(), isUsingLocalFile: false)
            reportPlaybackProgress(force: true)
            replaceCurrentItem(
                with: streamCandidates[streamCandidateIndex],
                autoplay: true,
                startAt: elapsed,
                candidateIndex: streamCandidateIndex
            )
            return
        }

        let nextIndex = streamCandidateIndex + 1
        guard nextIndex < streamCandidates.count else {
            isPlaying = false
            isBuffering = false
            playbackStatusText = "播放失败"
            isSwitchingTracks = false
            syncNowPlaying(force: true)
            return
        }

        streamCandidateIndex = nextIndex
        playbackStatusText = "正在切换播放源"
        isBuffering = true
        print("[Player] Retrying with fallback stream URL \(nextIndex + 1)/\(streamCandidates.count)")
        replaceCurrentItem(
            with: streamCandidates[nextIndex],
            autoplay: true,
            startAt: elapsed,
            candidateIndex: nextIndex
        )
        if streamStartOffset == 0, let activeAudioCacheKey {
            cacheCurrentSong(from: streamCandidates[nextIndex], cacheKey: activeAudioCacheKey)
        }
    }

    private func shuffledPlaybackQueue(from songs: [EmbyAudioItem], keeping current: EmbyAudioItem?) -> [EmbyAudioItem] {
        var shuffled = songs.shuffled()
        guard let current else { return shuffled }
        shuffled.removeAll { $0 == current }
        shuffled.insert(current, at: 0)
        return shuffled
    }

    private func applyActiveQueue(_ songs: [EmbyAudioItem]) {
        if isShuffleEnabled {
            reconcileOriginalQueue(with: songs)
        }
        queue = songs
        syncQueueSnapshots()
        syncRemoteCommandAvailability()
    }

    private func reconcileOriginalQueue(with activeSongs: [EmbyAudioItem]) {
        guard var originalQueue = queueBeforeShuffle else { return }

        let activeIds = Set(activeSongs.map(\.id))
        originalQueue.removeAll { !activeIds.contains($0.id) }

        var originalIds = Set(originalQueue.map(\.id))
        for song in activeSongs where !originalIds.contains(song.id) {
            originalQueue.append(song)
            originalIds.insert(song.id)
        }

        queueBeforeShuffle = originalQueue
    }

    private func insertIntoUpcoming(_ song: EmbyAudioItem, offsetFromCurrent: Int?) {
        guard song.id != currentSong?.id else { return }
        var songs = activeQueue
        guard let currentSong,
              let currentIndex = songs.firstIndex(of: currentSong) else {
            songs.append(song)
            applyActiveQueue(songs)
            return
        }

        songs.removeAll { $0.id == song.id }
        let baseIndex = songs.firstIndex(of: currentSong) ?? currentIndex
        let insertionIndex: Int
        if let offsetFromCurrent {
            insertionIndex = min(songs.index(baseIndex, offsetBy: offsetFromCurrent), songs.endIndex)
        } else {
            insertionIndex = songs.endIndex
        }
        songs.insert(song, at: insertionIndex)
        applyActiveQueue(songs)
    }

    private func syncQueueSnapshots() {
        let songs = activeQueue
        queueSnapshot = songs

        guard let currentSong,
              let currentIndex = songs.firstIndex(of: currentSong) else {
            upcomingQueueSnapshot = songs
            return
        }

        let nextIndex = songs.index(after: currentIndex)
        upcomingQueueSnapshot = nextIndex < songs.endIndex ? Array(songs[nextIndex...]) : []
    }

    private func reordered(_ songs: [EmbyAudioItem], moving sourceIndex: Int, to destinationIndex: Int) -> [EmbyAudioItem] {
        guard songs.indices.contains(sourceIndex),
              songs.indices.contains(destinationIndex) else {
            return songs
        }

        var result = songs
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: destinationIndex)
        return result
    }

    private func configureRemoteCommands() {
        remoteCommands.onPlay = { [weak self] in
            Task { @MainActor in self?.resume() }
        }
        remoteCommands.onPause = { [weak self] in
            Task { @MainActor in self?.pause() }
        }
        remoteCommands.onTogglePlayPause = { [weak self] in
            Task { @MainActor in self?.togglePlayPause() }
        }
        remoteCommands.onNext = { [weak self] in
            Task { @MainActor in self?.next() }
        }
        remoteCommands.onPrevious = { [weak self] in
            Task { @MainActor in self?.previous() }
        }
        remoteCommands.onSeek = { [weak self] seconds in
            Task { @MainActor in self?.seek(toSeconds: seconds, shouldPlayAfterSeek: self?.isPlaying == true) }
        }
    }

    private func configurePlayerObservers() {
        timeControlStatusObserver = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlaybackStateFromEngine(forceNowPlaying: true) }
        }

        timeObserver = engine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.handlePeriodicTime(time) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let finishedItemId = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init) else {
                return
            }

            MainActor.assumeIsolated {
                guard let self,
                      let currentItem = self.engine.currentItem,
                      ObjectIdentifier(currentItem) == finishedItemId else { return }
                self.handleTrackEnded()
            }
        }

        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let itemId = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init) else {
                return
            }

            Task { @MainActor in
                self?.handleAccessLogEntry(for: itemId)
            }
        }

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let itemId = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init) else {
                return
            }

            Task { @MainActor in
                self?.handlePlaybackStalled(for: itemId)
            }
        }
    }

    private func configureAudioSessionObservers() {
        let notificationCenter = NotificationCenter.default

        interruptionObserver = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        }

        routeChangeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(rawReason: rawReason)
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self,
                      observedItem === self.engine.currentItem else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.duration = self.absoluteDuration(for: observedItem.duration.seconds)
                    if self.isSeeking, let pendingSeekTarget = self.pendingSeekTarget {
                        self.elapsed = pendingSeekTarget
                        self.isSeeking = false
                    }
                    self.isBuffering = false
                    if self.playbackStatusText == "正在跳转" ||
                        self.playbackStatusText == "正在缓冲" ||
                        self.playbackStatusText == "正在连接" ||
                        self.playbackStatusText == "正在恢复播放" {
                        self.playbackStatusText = nil
                    }
                    self.syncNowPlaying(force: true)
                case .failed:
                    self.handleItemFailure(observedItem.error)
                default:
                    break
                }
            }
        }
    }

    private func observeBuffering(of item: AVPlayerItem) {
        itemPlaybackBufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self,
                      observedItem === self.engine.currentItem,
                      observedItem.isPlaybackBufferEmpty,
                      self.engine.rate == 0 else { return }
                self.isBuffering = true
                self.playbackStatusText = "正在缓冲"
                if self.currentStreamOptions?.quality.usesTranscoding == true {
                    self.refreshTranscodedStreamAfterInterruption(reason: "buffer empty")
                }
            }
        }

        itemPlaybackLikelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self,
                      observedItem === self.engine.currentItem,
                      observedItem.isPlaybackLikelyToKeepUp else { return }
                self.clearTransientPlaybackStatus()
            }
        }
    }

    private func handlePeriodicTime(_ time: CMTime) {
        guard !isSeeking else { return }

        let newElapsed = resolvedElapsed(
            forItemTime: time.seconds,
            reference: pendingSeekTarget ?? seekTarget ?? elapsed
        )
        if let pendingSeekTarget {
            if Date() < suppressTimeUpdatesUntil,
               abs(newElapsed - pendingSeekTarget) > 0.45 {
                return
            }
            self.pendingSeekTarget = nil
            seekTarget = nil
        } else if seekTarget != nil {
            seekTarget = nil
        }

        let previousElapsed = elapsed
        elapsed = newElapsed
        if refreshLongRunningCellularTranscodeIfNeeded() {
            return
        }
        if engine.rate > 0 || newElapsed > previousElapsed + 0.05 {
            clearTransientPlaybackStatus()
        }
        reportPlaybackProgress()
        if let itemDuration = engine.currentItem?.duration.seconds,
           itemDuration.isFinite,
           itemDuration > 0 {
            duration = absoluteDuration(for: itemDuration)
        }

        syncPlaybackStateFromEngine(forceNowPlaying: false)
    }

    private func syncPlaybackStateFromEngine(forceNowPlaying: Bool) {
        let playing = engine.timeControlStatus == .playing || engine.rate > 0
        let buffering = engine.timeControlStatus == .waitingToPlayAtSpecifiedRate && engine.rate == 0
        isBuffering = buffering
        if buffering {
            playbackStatusText = "正在缓冲"
        } else {
            clearTransientPlaybackStatus()
        }
        if isPlaying != playing {
            isPlaying = playing
        }
        syncNowPlaying(force: forceNowPlaying)
        syncRemoteCommandAvailability()
    }

    private func clearTransientPlaybackStatus() {
        isBuffering = false
        if playbackStatusText == "正在跳转" ||
            playbackStatusText == "正在缓冲" ||
            playbackStatusText == "正在连接" ||
            playbackStatusText == "正在恢复播放" ||
            playbackStatusText == "正在切换播放源" {
            playbackStatusText = nil
        }
    }

    private func itemTime(forAbsoluteTime absoluteTime: TimeInterval) -> TimeInterval {
        max(0, absoluteTime - streamStartOffset)
    }

    private func resolvedElapsed(forItemTime itemTime: TimeInterval, reference: TimeInterval?) -> TimeInterval {
        let normalizedItemTime = itemTime.validDuration(fallback: 0)
        updateStreamTimebaseIfNeeded(forItemTime: normalizedItemTime, reference: reference)
        return absoluteElapsed(forNormalizedItemTime: normalizedItemTime)
    }

    private func updateStreamTimebaseIfNeeded(forItemTime itemTime: TimeInterval, reference: TimeInterval?) {
        guard currentStreamTimebase == nil,
              streamStartOffset > 1,
              let reference else { return }

        let relativeElapsed = streamStartOffset + itemTime
        let absoluteElapsed = itemTime
        let relativeDelta = abs(relativeElapsed - reference)
        let absoluteDelta = abs(absoluteElapsed - reference)

        if absoluteDelta + 0.25 < relativeDelta {
            currentStreamTimebase = .absolute
        } else if relativeDelta + 0.25 < absoluteDelta {
            currentStreamTimebase = .relativeToStartOffset
        }
    }

    private var currentStreamUsesHLS: Bool {
        guard let currentStreamURL else { return false }
        let absoluteString = currentStreamURL.absoluteString.lowercased()
        return currentStreamURL.pathExtension.localizedCaseInsensitiveCompare("m3u8") == .orderedSame ||
            absoluteString.contains("transcodingprotocol=hls")
    }

    private func handleAccessLogEntry(for itemId: ObjectIdentifier) {
        guard currentStreamOptions?.quality.usesTranscoding == true,
              !currentStreamUsesHLS,
              let currentItem = engine.currentItem,
              ObjectIdentifier(currentItem) == itemId else { return }

        let eventCount = currentItem.accessLog()?.events.count ?? 0
        let previousEventCount = currentAccessLogEventCount
        currentAccessLogEventCount = eventCount

        guard previousEventCount > 0,
              eventCount > previousEventCount,
              elapsed > 10 else { return }

        _ = refreshTranscodedStreamAfterInterruption(reason: "stream reconnect")
    }

    private func handlePlaybackStalled(for itemId: ObjectIdentifier) {
        guard currentStreamOptions?.quality.usesTranscoding == true,
              let currentItem = engine.currentItem,
              ObjectIdentifier(currentItem) == itemId else { return }

        isBuffering = true
        playbackStatusText = "正在缓冲"
        _ = refreshTranscodedStreamAfterInterruption(reason: "playback stalled")
    }

    @discardableResult
    private func refreshLongRunningCellularTranscodeIfNeeded() -> Bool {
        let isCellularTranscode = currentNetworkKind == .cellular ||
            currentStreamOptions?.networkKind == .cellular
        let isPlayingNow = isPlaying ||
            engine.timeControlStatus == .playing ||
            engine.timeControlStatus == .waitingToPlayAtSpecifiedRate ||
            engine.rate > 0

        guard isCellularTranscode,
              currentStreamOptions?.quality.usesTranscoding == true,
              !currentStreamUsesHLS,
              isPlayingNow,
              !isSwitchingTracks,
              !isSeeking,
              elapsed - streamStartOffset >= 115 else { return false }

        return refreshTranscodedStreamAfterInterruption(reason: "long cellular transcode stream")
    }

    @discardableResult
    private func refreshTranscodedStreamAfterInterruption(reason: String) -> Bool {
        let shouldKeepPlaying = isPlaying ||
            engine.timeControlStatus == .playing ||
            engine.timeControlStatus == .waitingToPlayAtSpecifiedRate ||
            engine.rate > 0
        guard currentStreamOptions?.quality.usesTranscoding == true,
              shouldKeepPlaying,
              !isSwitchingTracks,
              !isSeeking,
              elapsed > 1 else { return false }

        let now = Date()
        guard now.timeIntervalSince(lastTranscodedStreamRefresh) > 8 else { return false }
        lastTranscodedStreamRefresh = now

        print("[Player] Refreshing transcoded stream after \(reason) at \(elapsed.musicDurationText)")
        refreshTranscodedStream(
            at: elapsed,
            autoplay: shouldKeepPlaying,
            statusText: "正在恢复播放"
        )
        return true
    }

    private func refreshTranscodedStream(at position: TimeInterval, autoplay: Bool, statusText: String) {
        guard let currentSong,
              let session,
              let streamOptions = currentStreamOptions,
              streamOptions.quality.usesTranscoding else { return }

        let clamped = max(0, min(position, max(duration, currentSong.duration)))
        let playSessionId = currentPlaySessionId ?? UUID().uuidString
        currentPlaySessionId = playSessionId
        lastTranscodedStreamRefresh = Date()
        streamStartOffset = clamped
        streamCandidateIndex = 0
        streamCandidates = client.playbackURLCandidates(
            for: currentSong,
            session: session,
            options: streamOptions,
            playSessionId: playSessionId,
            startTime: clamped
        )
        currentPlaybackReportMethod = playbackReportMethod(for: streamOptions, isUsingLocalFile: false)
        isSwitchingTracks = true
        isSeeking = true
        isBuffering = true
        playbackStatusText = statusText

        replaceCurrentItem(
            with: streamCandidates.first,
            autoplay: autoplay,
            startAt: clamped,
            candidateIndex: 0
        )
    }

    private func absoluteElapsed(forItemTime itemTime: TimeInterval) -> TimeInterval {
        absoluteElapsed(forNormalizedItemTime: itemTime.validDuration(fallback: 0))
    }

    private func absoluteElapsed(forNormalizedItemTime itemTime: TimeInterval) -> TimeInterval {
        let absoluteTime: TimeInterval
        if currentStreamTimebase == .absolute {
            absoluteTime = itemTime
        } else {
            absoluteTime = streamStartOffset + itemTime
        }
        guard duration > 0 else { return max(0, absoluteTime) }
        return max(0, min(absoluteTime, duration))
    }

    private func absoluteDuration(for itemDuration: TimeInterval) -> TimeInterval {
        if let songDuration = currentSong?.duration, songDuration > 0 {
            return songDuration
        }

        let absoluteDuration = streamStartOffset + itemDuration.validDuration(fallback: 0)
        return absoluteDuration > 0 ? absoluteDuration : duration
    }

    private func syncNowPlaying(force: Bool) {
        guard let currentSong else {
            nowPlaying.clear()
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastNowPlayingSync) >= 1 else { return }
        lastNowPlayingSync = now

        nowPlaying.update(
            song: currentSong,
            elapsed: elapsed,
            duration: duration,
            isPlaying: isPlaying,
            artwork: currentArtwork
        )
    }

    private func syncRemoteCommandAvailability() {
        guard currentSong != nil else {
            remoteCommands.update(canGoNext: false, canGoPrevious: false, canSeek: false)
            return
        }

        let songs = activeQueue
        let currentIndex = currentSong.flatMap { songs.firstIndex(of: $0) }
        let canGoNext = repeatMode == .all || currentIndex.map { $0 < songs.index(before: songs.endIndex) } == true
        let canGoPrevious = elapsed > 3 || repeatMode == .all || currentIndex.map { $0 > songs.startIndex } == true
        remoteCommands.update(canGoNext: canGoNext, canGoPrevious: canGoPrevious, canSeek: duration > 0)
    }

    private func reportPlaybackStarted(position: TimeInterval) {
        guard let currentSong, let session, let currentPlaySessionId else { return }

        let item = currentSong
        let activeSession = session
        let playSessionId = currentPlaySessionId
        let playMethod = currentPlaybackReportMethod
        let clampedPosition = max(0, position)
        lastPlaybackProgressReport = Date()
        notifyPlaybackPosition(position: clampedPosition, isFinished: false)

        playbackReportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.reportPlaybackStarted(
                    item: item,
                    session: activeSession,
                    playSessionId: playSessionId,
                    playMethod: playMethod,
                    position: clampedPosition
                )
            } catch {
                print("[Player] Failed to report Emby playback start: \(error.localizedDescription)")
            }
        }
    }

    private func reportPlaybackProgress(
        force: Bool = false,
        position: TimeInterval? = nil,
        isPaused: Bool? = nil
    ) {
        guard let currentSong, let session, let currentPlaySessionId else { return }

        let now = Date()
        guard force || now.timeIntervalSince(lastPlaybackProgressReport) >= 5 else { return }
        lastPlaybackProgressReport = now

        let item = currentSong
        let activeSession = session
        let playSessionId = currentPlaySessionId
        let playMethod = currentPlaybackReportMethod
        let clampedPosition = max(0, min(position ?? elapsed, max(duration, currentSong.duration)))
        let paused = isPaused ?? !isPlaying
        notifyPlaybackPosition(position: clampedPosition, isFinished: false)

        playbackReportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.reportPlaybackProgress(
                    item: item,
                    session: activeSession,
                    playSessionId: playSessionId,
                    playMethod: playMethod,
                    position: clampedPosition,
                    isPaused: paused
                )
            } catch {
                print("[Player] Failed to report Emby playback progress: \(error.localizedDescription)")
            }
        }
    }

    private func reportPlaybackStoppedIfNeeded(position: TimeInterval? = nil) {
        guard let currentSong, let session, let currentPlaySessionId else { return }

        let item = currentSong
        let activeSession = session
        let playSessionId = currentPlaySessionId
        let playMethod = currentPlaybackReportMethod
        let clampedPosition = max(0, min(position ?? elapsed, max(duration, currentSong.duration)))
        let isFinished = duration > 0 && clampedPosition >= max(duration - 10, duration * 0.98)
        notifyPlaybackPosition(position: clampedPosition, isFinished: isFinished)
        self.currentPlaySessionId = nil
        lastPlaybackProgressReport = .distantPast

        playbackReportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.reportPlaybackStopped(
                    item: item,
                    session: activeSession,
                    playSessionId: playSessionId,
                    playMethod: playMethod,
                    position: clampedPosition
                )
            } catch {
                print("[Player] Failed to report Emby playback stop: \(error.localizedDescription)")
            }
        }
    }

    private func notifyPlaybackPosition(position: TimeInterval, isFinished: Bool) {
        guard let currentSong else { return }
        onPlaybackPositionChanged?(currentSong, position, max(duration, currentSong.duration), isFinished)
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt?) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isPlaying
            pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            if shouldResumeAfterInterruption, options.contains(.shouldResume) {
                resume()
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard let rawReason,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else {
            return
        }
        pause()
    }

    private func loadArtwork(for song: EmbyAudioItem, session: EmbySession) {
        artworkTask?.cancel()
        currentArtwork = nil

        guard let url = client.imageURL(for: song, session: session, size: 600) else {
            syncNowPlaying(force: true)
            return
        }

        artworkTask = Task { [weak self, songId = song.id] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard self?.currentSong?.id == songId else { return }
                self?.currentArtwork = image
                self?.syncNowPlaying(force: true)
            }
        }
    }

    private func loadEmbeddedLyrics(from url: URL?, songId: String) {
        lyricsTask?.cancel()
        lyrics = []
        lyricsSongId = songId
        isLoadingLyrics = false
        guard let url else { return }

        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            let lines = await Self.readEmbeddedLyrics(from: url)
            await MainActor.run {
                guard !Task.isCancelled, self?.lyricsSongId == songId else { return }
                self?.lyrics = lines
                self?.isLoadingLyrics = false
            }
        }
    }

    private nonisolated static func readEmbeddedLyrics(from url: URL) async -> [LyricLine] {
        let asset = AVURLAsset(url: url)
        do {
            var metadata: [AVMetadataItem] = []
            metadata += try await asset.load(.commonMetadata)
            for format in try await asset.load(.availableMetadataFormats) {
                metadata += try await asset.loadMetadata(for: format)
            }

            for item in metadata {
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                let commonKey = item.commonKey?.rawValue.lowercased() ?? ""
                let key = item.key.map { String(describing: $0).lowercased() } ?? ""
                guard identifier.contains("lyric") ||
                    identifier.contains("uslt") ||
                    commonKey.contains("description") ||
                    key.contains("lyric") ||
                    key.contains("uslt") else {
                    continue
                }

                if let value = try? await item.load(.stringValue),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return parseLyrics(value)
                }
            }
        } catch {}

        return []
    }

    private nonisolated static func parseLyrics(_ rawLyrics: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return rawLyrics.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
        }

        var timedLines: [(time: TimeInterval, text: String)] = []
        var plainLines: [String] = []

        for line in rawLyrics.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let nsLine = trimmedLine as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: trimmedLine, range: fullRange)
            let text = regex.stringByReplacingMatches(
                in: trimmedLine,
                range: fullRange,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }

            if matches.isEmpty {
                plainLines.append(text)
                continue
            }

            for match in matches {
                guard let time = lyricTime(from: nsLine, match: match) else { continue }
                timedLines.append((time, text))
            }
        }

        if !timedLines.isEmpty {
            return timedLines
                .sorted { $0.time < $1.time }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
        }

        return plainLines
            .enumerated()
            .map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
    }

    private nonisolated static func lyricTime(from line: NSString, match: NSTextCheckingResult) -> TimeInterval? {
        guard match.numberOfRanges >= 3 else { return nil }

        let minutesRange = match.range(at: 1)
        let secondsRange = match.range(at: 2)
        guard minutesRange.location != NSNotFound,
              secondsRange.location != NSNotFound,
              let minutes = Double(line.substring(with: minutesRange)),
              let seconds = Double(line.substring(with: secondsRange)) else {
            return nil
        }

        var fraction = 0.0
        if match.numberOfRanges > 3 {
            let fractionRange = match.range(at: 3)
            if fractionRange.location != NSNotFound {
                let rawFraction = line.substring(with: fractionRange)
                let divisor = pow(10.0, Double(rawFraction.count))
                fraction = (Double(rawFraction) ?? 0) / divisor
            }
        }

        return minutes * 60 + seconds + fraction
    }
}

enum PlaybackAudioCache {
    private static let version = "v3"

    struct Key: Hashable {
        let serverHash: String
        let userId: String
        let itemId: String
        let quality: OnlinePlaybackQuality
        let format: AudioTranscodeFormat
        let fileExtension: String

        init(session: EmbySession, item: EmbyAudioItem, options: PlaybackStreamOptions) {
            serverHash = PlaybackAudioCache.stableHash(session.serverURL.absoluteString)
            userId = session.userId
            itemId = item.id
            quality = options.quality
            format = options.transcodeFormat
            fileExtension = options.cacheFileExtension(for: item)
        }

        var fileName: String {
            let stem = [
                PlaybackAudioCache.version,
                serverHash,
                userId,
                itemId,
                quality.rawValue,
                format.rawValue
            ]
            .map(PlaybackAudioCache.sanitizedPathComponent)
            .joined(separator: "-")

            return "\(stem).\(PlaybackAudioCache.sanitizedFileExtension(fileExtension))"
        }
    }

    static func cachedFileURL(for key: Key) -> URL? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            return nil
        }
        return url
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    fileprivate static func fileURL(for key: Key) -> URL {
        directoryURL.appendingPathComponent(key.fileName, isDirectory: false)
    }

    fileprivate static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static var directoryURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MusicEmby/CurrentPlaybackAudio", isDirectory: true)
    }

    private static func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "value" : sanitized
    }

    private static func sanitizedFileExtension(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = value.lowercased().unicodeScalars.filter { allowed.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars))
        return sanitized.isEmpty ? "audio" : sanitized
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for scalar in value.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

actor CurrentSongAudioCache {
    func cacheCurrentSong(from sourceURL: URL, key: PlaybackAudioCache.Key) async throws -> URL {
        if let cachedURL = PlaybackAudioCache.cachedFileURL(for: key) {
            return cachedURL
        }

        try PlaybackAudioCache.prepareDirectory()
        let destinationURL = PlaybackAudioCache.fileURL(for: key)
        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        try Task.checkCancellation()
        try validate(response: response, temporaryURL: temporaryURL)

        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        return destinationURL
    }

    private func validate(response: URLResponse, temporaryURL: URL) throws {
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0 else {
            throw URLError(.zeroByteResource)
        }
    }
}

private extension NWPath {
    var playbackNetworkKind: PlaybackNetworkKind {
        if usesInterfaceType(.wifi) || usesInterfaceType(.wiredEthernet) {
            return .wifi
        }
        if usesInterfaceType(.cellular) {
            return .cellular
        }
        return .wifi
    }
}

enum RepeatMode {
    case none
    case all
    case one

    var iconName: String {
        switch self {
        case .none, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }
}

private extension TimeInterval {
    func validDuration(fallback: TimeInterval) -> TimeInterval {
        guard isFinite, self > 0 else { return fallback }
        return self
    }
}
