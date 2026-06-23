import AVFoundation
import Combine
import Foundation
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

    private var session: EmbySession?
    private var queue: [EmbyAudioItem] = []
    private var shuffledQueue: [EmbyAudioItem] = []
    private var streamCandidates: [URL] = []
    private var streamCandidateIndex = 0
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
    private var playbackFadesEnabled = false

    init() {
        engine.volume = Float(volume)
        engine.automaticallyWaitsToMinimizeStalling = true

        audioSession.configureForPlayback()
        configureRemoteCommands()
        configurePlayerObservers()
        configureAudioSessionObservers()
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

    private func start(song: EmbyAudioItem, session: EmbySession, autoplay: Bool) {
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

        streamCandidates = client.playbackURLCandidates(for: song, session: session)
        streamCandidateIndex = 0
        syncQueueSnapshots()

        audioSession.activate()
        replaceCurrentItem(with: streamCandidates.first, autoplay: autoplay)
        loadArtwork(for: song, session: session)
        loadEmbeddedLyrics(from: streamCandidates.first)
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

    private func replaceCurrentItem(with url: URL?, autoplay: Bool) {
        guard let url else {
            print("[Player] No playable Emby URL for current item.")
            isPlaying = false
            isBuffering = false
            playbackStatusText = "播放失败"
            isSwitchingTracks = false
            syncNowPlaying(force: true)
            return
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 8
        observeStatus(of: item)
        observeBuffering(of: item)

        engine.replaceCurrentItem(with: item)
        if autoplay {
            if playbackFadesEnabled {
                engine.volume = 0
            } else {
                engine.volume = Float(volume)
            }
            engine.play()
            if playbackFadesEnabled {
                fadeEngineVolume(to: volume, duration: 1.1)
            }
        }

        isSwitchingTracks = false
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
        let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
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
        replaceCurrentItem(with: streamCandidates[nextIndex], autoplay: true)
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
                    self?.duration = observedItem.duration.seconds.validDuration(fallback: self?.currentSong?.duration ?? 0)
                    self?.isBuffering = false
                    self?.playbackStatusText = nil
                    self?.syncNowPlaying(force: true)
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

        let newElapsed = time.seconds.validDuration(fallback: 0)
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
            duration = itemDuration
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

    private func loadEmbeddedLyrics(from url: URL?) {
        lyricsTask?.cancel()
        lyrics = []
        guard let url else { return }

        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            let lines = await Self.readEmbeddedLyrics(from: url)
            await MainActor.run {
                guard !Task.isCancelled else { return }
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
