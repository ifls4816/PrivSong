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

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentSong: EmbyAudioItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeeking = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var queueSnapshot: [EmbyAudioItem] = []
    @Published private(set) var upcomingQueueSnapshot: [EmbyAudioItem] = []
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var isLoadingLyrics = false
    @Published private(set) var playbackStatusText: String?
    @Published private(set) var isBuffering = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published var isShuffleEnabled = false
    @Published var repeatMode: RepeatMode = .none
    @Published private(set) var volume = 1.0

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
    private var shuffledQueue: [EmbyAudioItem] = []
    private var streamCandidates: [URL] = []
    private var streamCandidateIndex = 0
    private var currentStreamURL: URL?
    private var streamStartOffset: TimeInterval = 0
    private var currentNetworkKind: PlaybackNetworkKind = .wifi
    private var playbackQualityPreferences = PlaybackQualityPreferences()
    private var activeAudioCacheKey: PlaybackAudioCache.Key?
    private var currentArtwork: UIImage?
    private var lastNowPlayingSync = Date.distantPast
    private var shouldResumeAfterInterruption = false
    private var isSwitchingTracks = false
    private var isFadingToPause = false
    private var pendingSeekTarget: TimeInterval?
    private var suppressTimeUpdatesUntil = Date.distantPast

    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemPlaybackBufferEmptyObserver: NSKeyValueObservation?
    private var itemPlaybackLikelyToKeepUpObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var audioCacheTask: Task<Void, Never>?
    private var playbackFadesEnabled = false

    init() {
        engine.volume = Float(volume)
        engine.automaticallyWaitsToMinimizeStalling = true

        audioSession.configureForPlayback()
        configureRemoteCommands()
        configurePlayerObservers()
        configureAudioSessionObservers()
        configureNetworkPathMonitor()
    }

    func play(song: EmbyAudioItem, in songs: [EmbyAudioItem], session: EmbySession) {
        guard !isSwitchingTracks else { return }

        self.session = session
        queue = songs.isEmpty ? [song] : songs
        if !queue.contains(song) {
            queue.insert(song, at: 0)
        }

        if isShuffleEnabled {
            rebuildShuffledQueue(keeping: song)
        }

        syncQueueSnapshots()
        transitionToSong(song, session: session, autoplay: true)
    }

    func togglePlayPause() {
        if isFadingToPause {
            resume()
        } else if isPlaying || engine.timeControlStatus == .playing {
            pause()
        } else {
            resume()
        }
    }

    func setPlaybackFadesEnabled(_ enabled: Bool) {
        playbackFadesEnabled = enabled
        if !enabled {
            fadeTask?.cancel()
            engine.volume = Float(volume)
            isSwitchingTracks = false
            isFadingToPause = false
        }
    }

    func setPlaybackQualityPreferences(_ preferences: PlaybackQualityPreferences) {
        playbackQualityPreferences = preferences
    }

    func seek(to progress: Double) {
        let target = max(0, min(1, progress)) * max(duration, 1)
        seek(toSeconds: target, shouldPlayAfterSeek: isPlaying)
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
        isShuffleEnabled.toggle()
        if isShuffleEnabled {
            rebuildShuffledQueue(keeping: currentSong)
        }
        syncQueueSnapshots()
        syncRemoteCommandAvailability()
    }

    func playQueued(song: EmbyAudioItem) {
        guard activeQueue.contains(song), let session else { return }
        transitionToSong(song, session: session, autoplay: true)
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

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        if !isFadingToPause {
            engine.volume = Float(clamped)
        }
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

    private var activeQueue: [EmbyAudioItem] {
        isShuffleEnabled ? shuffledQueue : queue
    }

    private func currentPlaybackStreamOptions() -> PlaybackStreamOptions {
        PlaybackStreamOptions(
            quality: playbackQualityPreferences.quality(for: currentNetworkKind),
            transcodeFormat: playbackQualityPreferences.transcodeFormat,
            networkKind: currentNetworkKind
        )
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

    private func start(song: EmbyAudioItem, session: EmbySession, autoplay: Bool) {
        audioCacheTask?.cancel()
        isFadingToPause = false
        isSwitchingTracks = true
        currentSong = song
        elapsed = 0
        duration = song.duration
        isPlaying = autoplay
        currentArtwork = nil
        lyrics = []
        isLoadingLyrics = false
        playbackStatusText = "正在连接"
        isBuffering = true
        lastNowPlayingSync = .distantPast
        currentStreamURL = nil
        streamStartOffset = 0

        let streamOptions = currentPlaybackStreamOptions()
        let cacheKey = PlaybackAudioCache.Key(session: session, item: song, options: streamOptions)
        activeAudioCacheKey = cacheKey
        streamCandidates = client.playbackURLCandidates(for: song, session: session, options: streamOptions)
        streamCandidateIndex = 0
        syncQueueSnapshots()

        audioSession.activate()
        let cachedURL = PlaybackAudioCache.cachedFileURL(for: cacheKey)
        let initialURL = cachedURL ?? streamCandidates.first
        replaceCurrentItem(with: initialURL, autoplay: autoplay, candidateIndex: 0)
        cacheCurrentSong(from: streamStartOffset == 0 ? streamCandidates.first : nil, cacheKey: cacheKey)
        loadArtwork(for: song, session: session)
        loadEmbeddedLyrics(from: client.originalAudioStreamURL(for: song, session: session), songId: song.id)
        syncNowPlaying(force: true)
        syncRemoteCommandAvailability()
    }

    private func transitionToSong(_ song: EmbyAudioItem, session: EmbySession, autoplay: Bool) {
        guard playbackFadesEnabled,
              engine.currentItem != nil,
              engine.timeControlStatus == .playing || isPlaying else {
            start(song: song, session: session, autoplay: autoplay)
            return
        }

        isFadingToPause = false
        isSwitchingTracks = true
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 10
            let startVolume = Double(self.engine.volume)
            let duration: TimeInterval = 0.35
            let stepDuration = duration / Double(steps)

            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let progress = Double(step) / Double(steps)
                let value = startVolume + (0 - startVolume) * progress
                self.engine.volume = Float(min(max(value, 0), 1))
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            self.engine.volume = 0
            self.start(song: song, session: session, autoplay: autoplay)
        }
    }

    private func replaceCurrentItem(
        with url: URL?,
        autoplay: Bool,
        startAt startTime: TimeInterval? = nil,
        candidateIndex: Int? = nil,
        usesFadeIn: Bool = true
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
                    self.beginPlaybackIfNeeded(autoplay: autoplay, usesFadeIn: usesFadeIn)
                    self.isSwitchingTracks = false
                    self.syncNowPlaying(force: true)
                }
            }
        } else {
            beginPlaybackIfNeeded(autoplay: autoplay, usesFadeIn: usesFadeIn)
            isSwitchingTracks = false
        }
    }

    private func beginPlaybackIfNeeded(autoplay: Bool, usesFadeIn: Bool) {
        guard autoplay else { return }
        if playbackFadesEnabled, usesFadeIn {
            engine.volume = 0
        } else {
            engine.volume = Float(volume)
        }
        engine.play()
        isPlaying = true
        if playbackFadesEnabled, usesFadeIn {
            fadeEngineVolume(to: volume, duration: 1.1)
        }
    }

    private func resume() {
        guard currentSong != nil else { return }
        audioSession.activate()
        let wasFadingToPause = isFadingToPause
        isFadingToPause = false
        fadeTask?.cancel()

        if playbackFadesEnabled, !wasFadingToPause {
            engine.volume = 0
        }
        engine.play()
        isPlaying = true
        if playbackFadesEnabled {
            fadeEngineVolume(to: volume, duration: wasFadingToPause ? 0.35 : 0.8)
        }
        syncNowPlaying(force: true)
    }

    private func pause() {
        if playbackFadesEnabled, isPlaying {
            isFadingToPause = true
            isPlaying = false
            syncNowPlaying(force: true)
            fadeEngineVolume(to: 0, duration: 0.45, pauseWhenFinished: true)
            return
        }
        fadeTask?.cancel()
        isFadingToPause = false
        engine.pause()
        isPlaying = false
        syncNowPlaying(force: true)
    }

    private func seek(toSeconds seconds: TimeInterval, shouldPlayAfterSeek: Bool) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        guard currentStreamURL?.isFileURL == true else {
            seekRemoteStream(to: clamped, shouldPlayAfterSeek: shouldPlayAfterSeek)
            return
        }

        let targetTime = CMTime(seconds: itemTime(forAbsoluteTime: clamped), preferredTimescale: 600)
        isSeeking = true
        pendingSeekTarget = clamped
        suppressTimeUpdatesUntil = Date().addingTimeInterval(1.0)
        elapsed = clamped
        syncNowPlaying(force: true)
        engine.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if shouldPlayAfterSeek {
                    self.engine.play()
                    self.isPlaying = true
                }
                self.elapsed = clamped
                self.pendingSeekTarget = clamped
                self.suppressTimeUpdatesUntil = Date().addingTimeInterval(0.8)
                self.isSeeking = false
                self.syncNowPlaying(force: true)
            }
        }
    }

    private func seekRemoteStream(to seconds: TimeInterval, shouldPlayAfterSeek: Bool) {
        guard let currentSong, let session else {
            return
        }

        audioCacheTask?.cancel()
        let clamped = max(0, min(seconds, max(duration, currentSong.duration)))
        let streamOptions = currentPlaybackStreamOptions()
        let candidates = client.playbackURLCandidates(
            for: currentSong,
            session: session,
            options: streamOptions,
            startTime: clamped
        )

        guard let firstCandidate = candidates.first else {
            isSeeking = false
            isBuffering = false
            playbackStatusText = "播放失败"
            syncNowPlaying(force: true)
            return
        }

        streamCandidates = candidates
        streamCandidateIndex = 0
        streamStartOffset = clamped
        isSeeking = true
        pendingSeekTarget = clamped
        suppressTimeUpdatesUntil = Date().addingTimeInterval(1.0)
        elapsed = clamped
        isBuffering = true
        playbackStatusText = "正在跳转"
        syncNowPlaying(force: true)
        replaceCurrentItem(
            with: firstCandidate,
            autoplay: shouldPlayAfterSeek,
            candidateIndex: 0,
            usesFadeIn: false
        )
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
            transitionToSong(songs[targetIndex], session: session, autoplay: true)
            return
        }

        guard wrap, !songs.isEmpty else { return }
        let wrappedIndex = offset > 0 ? songs.startIndex : songs.index(before: songs.endIndex)
        transitionToSong(songs[wrappedIndex], session: session, autoplay: true)
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
        }
    }

    private func fadeEngineVolume(to target: Double, duration: TimeInterval, pauseWhenFinished: Bool = false) {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 16
            let startVolume = Double(self.engine.volume)
            let stepDuration = duration / Double(steps)

            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let progress = Double(step) / Double(steps)
                let value = startVolume + (target - startVolume) * progress
                self.engine.volume = Float(min(max(value, 0), 1))
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            self.engine.volume = Float(min(max(target, 0), 1))
            if pauseWhenFinished {
                self.engine.pause()
                self.engine.volume = Float(self.volume)
                self.isPlaying = false
                self.isFadingToPause = false
                self.syncNowPlaying(force: true)
            }
        }
    }

    private func handleItemFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        print("[Player] AVPlayerItem failed: \(message)")

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
            replaceCurrentItem(
                with: streamCandidates[streamCandidateIndex],
                autoplay: true,
                startAt: elapsed,
                candidateIndex: streamCandidateIndex,
                usesFadeIn: false
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
            candidateIndex: nextIndex,
            usesFadeIn: false
        )
        if streamStartOffset == 0, let activeAudioCacheKey {
            cacheCurrentSong(from: streamCandidates[nextIndex], cacheKey: activeAudioCacheKey)
        }
    }

    private func rebuildShuffledQueue(keeping current: EmbyAudioItem?) {
        shuffledQueue = queue.shuffled()
        guard let current else { return }
        shuffledQueue.removeAll { $0 == current }
        shuffledQueue.insert(current, at: 0)
    }

    private func applyActiveQueue(_ songs: [EmbyAudioItem]) {
        if isShuffleEnabled {
            shuffledQueue = songs
        } else {
            queue = songs
        }
        syncQueueSnapshots()
        syncRemoteCommandAvailability()
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
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackEnded() }
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
                switch observedItem.status {
                case .readyToPlay:
                    guard let self else { return }
                    self.duration = self.absoluteDuration(for: observedItem.duration.seconds)
                    if self.isSeeking, let pendingSeekTarget = self.pendingSeekTarget {
                        self.elapsed = pendingSeekTarget
                        self.isSeeking = false
                    }
                    self.isBuffering = false
                    if self.playbackStatusText == "正在跳转" ||
                        self.playbackStatusText == "正在缓冲" ||
                        self.playbackStatusText == "正在连接" {
                        self.playbackStatusText = nil
                    }
                    self.syncNowPlaying(force: true)
                case .failed:
                    self?.handleItemFailure(observedItem.error)
                default:
                    break
                }
            }
        }
    }

    private func observeBuffering(of item: AVPlayerItem) {
        itemPlaybackBufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard observedItem.isPlaybackBufferEmpty else { return }
                self?.isBuffering = true
                self?.playbackStatusText = "正在缓冲"
            }
        }

        itemPlaybackLikelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard observedItem.isPlaybackLikelyToKeepUp else { return }
                self?.isBuffering = false
                self?.playbackStatusText = nil
            }
        }
    }

    private func handlePeriodicTime(_ time: CMTime) {
        guard !isSeeking else { return }

        let newElapsed = absoluteElapsed(forItemTime: time.seconds)
        if let pendingSeekTarget {
            if Date() < suppressTimeUpdatesUntil,
               abs(newElapsed - pendingSeekTarget) > 0.45 {
                return
            }
            self.pendingSeekTarget = nil
        }

        elapsed = newElapsed
        if let itemDuration = engine.currentItem?.duration.seconds,
           itemDuration.isFinite,
           itemDuration > 0 {
            duration = absoluteDuration(for: itemDuration)
        }

        syncPlaybackStateFromEngine(forceNowPlaying: false)
    }

    private func syncPlaybackStateFromEngine(forceNowPlaying: Bool) {
        let playing = engine.timeControlStatus == .playing
        let buffering = engine.timeControlStatus == .waitingToPlayAtSpecifiedRate
        isBuffering = buffering
        if buffering {
            playbackStatusText = "正在缓冲"
        } else if playbackStatusText == "正在缓冲" || playbackStatusText == "正在连接" {
            playbackStatusText = nil
        }
        if !isFadingToPause, isPlaying != playing {
            isPlaying = playing
        }
        syncNowPlaying(force: forceNowPlaying)
        syncRemoteCommandAvailability()
    }

    private func itemTime(forAbsoluteTime absoluteTime: TimeInterval) -> TimeInterval {
        max(0, absoluteTime - streamStartOffset)
    }

    private func absoluteElapsed(forItemTime itemTime: TimeInterval) -> TimeInterval {
        let absoluteTime = streamStartOffset + itemTime.validDuration(fallback: 0)
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
        guard let url else { return }

        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            let lines = await Self.readEmbeddedLyrics(from: url)
            await MainActor.run {
                guard !Task.isCancelled, self?.currentSong?.id == songId else { return }
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
    private static let version = "v2"

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
