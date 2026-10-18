import AVFoundation
import Combine
import Foundation
import Network
import Synchronization
import UIKit

struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let time: TimeInterval?
    let text: String
}

private let seekBackwardTolerance: TimeInterval = 0.35

private struct RemoteCommandAvailability: Equatable {
    let canGoNext: Bool
    let canGoPrevious: Bool
    let canSeek: Bool
    let isSpokenAudio: Bool
}
/// Serializes queue snapshot writes and deletes off the main thread while keeping them in order.
private let queuePersistenceQueue = DispatchQueue(label: "PrivSong.queue-persistence", qos: .utility)

@MainActor
final class PlaybackTimeline: ObservableObject {
    @Published private(set) var seekTarget: TimeInterval?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    func updateSeekTarget(_ value: TimeInterval?) {
        guard seekTarget != value else { return }
        seekTarget = value
    }

    func updateElapsed(_ value: TimeInterval) {
        guard abs(elapsed - value) > 0.01 else { return }
        elapsed = value
    }

    func updateDuration(_ value: TimeInterval) {
        guard abs(duration - value) > 0.05 else { return }
        duration = value
    }
}

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentSong: EmbyAudioItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeeking = false
    private(set) var seekTarget: TimeInterval? {
        didSet { timeline.updateSeekTarget(seekTarget) }
    }
    private(set) var elapsed: TimeInterval = 0 {
        didSet { timeline.updateElapsed(elapsed) }
    }
    private(set) var duration: TimeInterval = 0 {
        didSet { timeline.updateDuration(duration) }
    }
    @Published private(set) var upcomingQueueSnapshot: [EmbyAudioItem] = []
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var lyricsSongId: String?
    @Published private(set) var isLoadingLyrics = false
    @Published private(set) var playbackStatusText: String?
    @Published private(set) var isBuffering = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published var isShuffleEnabled = false
    @Published var repeatMode: RepeatMode = .none

    /// (item, position, duration, isFinished, isCheckpoint). `isCheckpoint` is true for start,
    /// pause, seek and stop reports, and false for the periodic progress ticks.
    var onPlaybackPositionChanged: ((EmbyAudioItem, TimeInterval, TimeInterval, Bool, Bool) -> Void)?
    let timeline = PlaybackTimeline()

    private let engine = AVPlayer()
    private let audioSession = AudioSessionCoordinator.shared
    private let nowPlaying = NowPlayingCoordinator.shared
    private let remoteCommands = RemoteCommandCoordinator.shared
    private let client = EmbyClient()
    private let audioCache = CurrentSongAudioCache()
    private let queueSnapshotStore = PlaybackQueueSnapshotStore()
    private let pathMonitor = NWPathMonitor()
    private var networkKind: PlaybackNetworkKind = .wifi
    private var qualityPreferences = PlaybackQualityPreferences()
    /// Bitrate the current track is being transcoded to, or nil when playing the original.
    private var currentTranscodeBitrate: Int?
    private var lastRemoteCommandAvailability: RemoteCommandAvailability?
    /// Set by the store, which knows which tracks belong to audiobooks (they can be plain
    /// `Audio` items inside an audiobook library). Turns on the skip buttons on the lock screen.
    var isAudiobookEpisode: ((EmbyAudioItem) -> Bool)?

    private var session: EmbySession?
    private var queue: [EmbyAudioItem] = []
    private var queueBeforeShuffle: [EmbyAudioItem]?
    private var restoredQueueCurrentSongID: String?
    private var restoredQueuePosition: TimeInterval = 0
    /// Set when every playback source failed; cleared when a track starts. Drives retry on
    /// network recovery and on the next play tap.
    @Published private(set) var hasPlaybackFailed = false
    private var isNetworkAvailable = true
    /// Whether this track already fell back to its cached file once; prevents a fail loop.
    private var hasTriedCachedFallback = false
    private var stallWatchdogTask: Task<Void, Never>?
    /// Reconnect attempts for a stalled song; keyed by song so a reconnect (which restarts the
    /// track) doesn't reset the count.
    private var stallRecovery: (songId: String, attempts: Int)?
    private var networkRecoveryTask: Task<Void, Never>?
    private var streamCandidates: [AuthenticatedURL] = []
    private var streamCandidateIndex = 0
    private var currentStreamURL: AuthenticatedURL?
    private var currentDurationOverride: TimeInterval?
    private var currentPlaySessionId: String?
    private var currentPlaybackReportMethod: EmbyPlaybackReportMethod = .directStream
    private var lastPlaybackProgressReport = Date.distantPast
    private var activeAudioCacheKey: PlaybackAudioCache.Key?
    private var currentArtwork: UIImage?
    /// Duration last sent to Now Playing; periodic ticks only resend when it changes.
    private var lastNowPlayingDuration: TimeInterval = -1
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
    private var playbackStalledObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var audioCacheTask: Task<Void, Never>?
    private var playbackReportTask: Task<Void, Never>?
    private var queuePersistTask: Task<Void, Never>?
    private var pendingQueueWrite: (@Sendable () -> Void)?
    private var pendingStateWrite: (@Sendable () -> Void)?
    /// Signature of the queue contents last scheduled for writing.
    private var scheduledQueueSignature: Int?

    init() {
        engine.automaticallyWaitsToMinimizeStalling = true

        audioSession.configureForPlayback()
        configureRemoteCommands()
        configurePlayerObservers()
        configureAudioSessionObservers()
        configureNetworkMonitor()
        restorePlaybackQueueSnapshot()
    }

    private func configureNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind: PlaybackNetworkKind = path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi)
                && !path.usesInterfaceType(.wiredEthernet)
                ? .cellular
                : .wifi
            let isAvailable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let previousKind = self.networkKind
                self.networkKind = kind
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = isAvailable
                // Back online, or moved to another interface: the current stream's connection is
                // gone, so reconnect it (or retry a song that failed while offline).
                if isAvailable, !wasAvailable || previousKind != kind {
                    self.scheduleNetworkRecovery()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "PrivSong.network-path", qos: .utility))
    }

    /// Target transcode bitrate for `song` on the current network, or nil to play the original.
    private func transcodeBitrate(for song: EmbyAudioItem) -> Int? {
        guard let maxBitrate = qualityPreferences.quality(for: networkKind).bitrate,
              client.shouldTranscode(song, maxBitrate: maxBitrate) else {
            return nil
        }
        return maxBitrate
    }

    func setSession(_ session: EmbySession?) {
        self.session = session
    }

    /// Forgets a song that was deleted from the server: skips it if it's playing (stopping when
    /// nothing follows), drops it from the queue, and removes its cached audio file.
    func removeDeletedSong(_ song: EmbyAudioItem) {
        if currentSong?.id == song.id {
            playRelative(offset: 1, wrap: repeatMode == .all)
            if currentSong?.id == song.id {
                stopPlaybackForConfigurationChange()
            }
        }

        if let session {
            PlaybackAudioCache.removeCachedFile(for: PlaybackAudioCache.Key(session: session, item: song))
        }
        queueBeforeShuffle?.removeAll { $0.id == song.id }
        if restoredQueueCurrentSongID == song.id {
            restoredQueueCurrentSongID = nil
        }
        applyActiveQueue(queue.filter { $0.id != song.id })
    }

    func clearPersistedQueue() {
        queue = []
        queueBeforeShuffle = nil
        restoredQueueCurrentSongID = nil
        restoredQueuePosition = 0
        clearQueueSnapshot()
        syncQueueSnapshots(persists: false)
        syncRemoteCommandAvailability()
    }

    func play(
        song: EmbyAudioItem,
        in songs: [EmbyAudioItem],
        session: EmbySession,
        startPosition: TimeInterval = 0,
        durationOverride: TimeInterval? = nil,
        shuffle: Bool? = nil
    ) {
        guard !isSwitchingTracks else { return }

        self.session = session
        var playbackQueue = songs.isEmpty ? [song] : songs
        if !playbackQueue.contains(song) {
            playbackQueue.insert(song, at: 0)
        }

        let shouldShuffle = shuffle ?? isShuffleEnabled
        isShuffleEnabled = shouldShuffle
        restoredQueueCurrentSongID = nil
        if shouldShuffle {
            queueBeforeShuffle = playbackQueue
            queue = shuffledPlaybackQueue(from: playbackQueue, keeping: song)
        } else {
            queueBeforeShuffle = nil
            queue = playbackQueue
        }

        syncQueueSnapshots()
        start(
            song: song,
            session: session,
            autoplay: true,
            startPosition: startPosition,
            durationOverride: durationOverride
        )
    }

    func togglePlayPause() {
        // Waiting for data still counts as "playing" here, so a tap while buffering pauses.
        if isPlaying || engine.timeControlStatus != .paused {
            pause()
        } else {
            resume()
        }
    }

    func setPlaybackQualityPreferences(_ preferences: PlaybackQualityPreferences) {
        guard preferences != qualityPreferences else { return }
        let previousQuality = qualityPreferences.quality(for: networkKind)
        qualityPreferences = preferences

        // Restart a streaming track at its current position when the quality for the current
        // network changed and that alters how the track is served. Tracks playing from the
        // local cache use no network, so they're left alone.
        guard preferences.quality(for: networkKind) != previousQuality,
              let currentSong,
              let session,
              currentStreamURL?.isFileURL == false,
              transcodeBitrate(for: currentSong) != currentTranscodeBitrate else { return }

        start(
            song: currentSong,
            session: session,
            autoplay: isPlaying || engine.timeControlStatus == .playing,
            startPosition: elapsed,
            durationOverride: currentDurationOverride
        )
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
        let removeIndex: Int
        if let currentIndex = currentQueueReferenceIndex(in: songs) {
            removeIndex = songs.index(after: currentIndex) + index
        } else {
            removeIndex = index
        }
        guard songs.indices.contains(removeIndex) else { return }

        var updated = songs
        updated.remove(at: removeIndex)
        applyActiveQueue(updated)
    }

    func clearUpcomingQueue() {
        let songs = activeQueue
        guard let currentIndex = currentQueueReferenceIndex(in: songs) else {
            applyActiveQueue([])
            return
        }
        applyActiveQueue(Array(songs[...currentIndex]))
    }

    func moveUpcomingQueueItem(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex else { return }

        let songs = activeQueue
        guard let currentIndex = currentQueueReferenceIndex(in: songs) else {
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
        persistQueueSnapshot()
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

    /// The player's actual position, read straight from AVPlayer. The published `elapsed` only
    /// updates every 0.5 s, which is too coarse for line-accurate lyrics.
    var precisePlaybackTime: TimeInterval {
        let seconds = engine.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return elapsed }
        return duration > 0 ? min(seconds, duration) : seconds
    }

    /// Reads the song's embedded lyrics on demand (when the lyrics panel shows it), instead of
    /// opening another connection to the audio file for every track that plays.
    func loadLyricsIfNeeded(for song: EmbyAudioItem) {
        guard lyricsSongId != song.id, let session else { return }

        // The cached copy of the playing track has the same tags and needs no network.
        let cachedResource = currentSong?.id == song.id
            ? activeAudioCacheKey.flatMap(PlaybackAudioCache.cachedFileURL(for:)).map { AuthenticatedURL(url: $0) }
            : nil
        loadEmbeddedLyrics(
            from: cachedResource ?? client.originalAudioStreamURL(for: song, session: session),
            songId: song.id
        )
    }

    private var activeQueue: [EmbyAudioItem] {
        queue
    }

    private func playbackReportMethod(isUsingLocalFile: Bool) -> EmbyPlaybackReportMethod {
        if isUsingLocalFile {
            return .directPlay
        }
        // Only the first candidate is the transcode; later ones are original-file fallbacks.
        return streamCandidateIndex == 0 && currentTranscodeBitrate != nil ? .transcode : .directStream
    }

    func cancelAudioCaching() {
        audioCacheTask?.cancel()
        audioCacheTask = nil
    }

    private func cacheCurrentSong(from sourceURL: AuthenticatedURL?, cacheKey: PlaybackAudioCache.Key) {
        audioCacheTask?.cancel()
        guard let sourceURL, !sourceURL.isFileURL, PlaybackAudioCache.isEnabled else { return }

        let currentAudioCache = audioCache
        audioCacheTask = Task {
            do {
                // Give the stream the bandwidth while it starts, and skip caching tracks that get skipped quickly.
                try await Task.sleep(for: PlaybackAudioCache.downloadDelay)
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
        startPosition: TimeInterval = 0,
        durationOverride: TimeInterval? = nil
    ) {
        reportPlaybackStoppedIfNeeded(position: elapsed)
        audioCacheTask?.cancel()
        let normalizedStartPosition = max(0, startPosition)
        let knownDuration = max(song.duration, durationOverride ?? 0)
        let initialPosition = knownDuration > normalizedStartPosition
            ? min(normalizedStartPosition, max(knownDuration - 1, 0))
            : normalizedStartPosition
        isSwitchingTracks = true
        currentSong = song
        restoredQueueCurrentSongID = nil
        restoredQueuePosition = 0
        hasPlaybackFailed = false
        hasTriedCachedFallback = false
        elapsed = initialPosition
        duration = max(knownDuration, initialPosition)
        isPlaying = autoplay
        currentArtwork = nil
        // Restarting the same song (reconnect, retry) keeps its lyrics: the lyrics panel only
        // asks again when the song changes, so clearing them here left it stuck on "loading".
        if lyricsSongId != song.id {
            lyricsTask?.cancel()
            lyrics = []
            lyricsSongId = nil
            isLoadingLyrics = false
        }
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        playbackStatusText = "正在连接"
        isBuffering = true
        lastNowPlayingDuration = -1
        currentStreamURL = nil
        currentDurationOverride = durationOverride
        seekTarget = nil
        pendingSeekTarget = nil
        suppressTimeUpdatesUntil = .distantPast
        seekGeneration += 1
        lastPlaybackProgressReport = .distantPast

        let cacheKey = PlaybackAudioCache.Key(session: session, item: song)
        let playSessionId = UUID().uuidString
        activeAudioCacheKey = cacheKey
        PlaybackAudioCache.setProtectedKey(cacheKey)
        currentPlaySessionId = playSessionId
        currentTranscodeBitrate = transcodeBitrate(for: song)
        streamCandidates = client.playbackURLCandidates(
            for: song,
            session: session,
            playSessionId: playSessionId,
            transcodeBitrate: currentTranscodeBitrate
        )
        streamCandidateIndex = 0
        syncQueueSnapshots()

        audioSession.activate()
        // A cached original plays without any network use, so it wins even over a transcode.
        let cachedResource = PlaybackAudioCache.cachedFileURL(for: cacheKey).map { AuthenticatedURL(url: $0) }
        let initialURL = cachedResource ?? streamCandidates.first
        currentPlaybackReportMethod = playbackReportMethod(isUsingLocalFile: cachedResource != nil)
        replaceCurrentItem(with: initialURL, autoplay: autoplay, startAt: initialPosition, candidateIndex: 0)
        // Caching downloads the full original file, which would defeat a lower-bitrate transcode.
        if cachedResource == nil, currentTranscodeBitrate == nil {
            cacheCurrentSong(from: streamCandidates.first, cacheKey: cacheKey)
        }
        loadArtwork(for: song, session: session)
        // Lyrics are loaded when the lyrics panel asks for them (loadLyricsIfNeeded).
        reportPlaybackStarted(position: initialPosition)
        syncNowPlaying(force: true)
        syncRemoteCommandAvailability()
    }

    private func replaceCurrentItem(
        with resource: AuthenticatedURL?,
        autoplay: Bool,
        startAt startTime: TimeInterval? = nil,
        candidateIndex: Int? = nil
    ) {
        guard let resource else {
            print("[Player] No playable Emby URL for current item.")
            handleAllSourcesFailed()
            return
        }

        if let candidateIndex {
            streamCandidateIndex = candidateIndex
        }
        currentStreamURL = resource

        let url = resource.url
        let asset = AVURLAsset(url: url, options: resource.playbackAssetOptions)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 45
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = !url.isFileURL
        observeStatus(of: item)
        observeBuffering(of: item)

        engine.replaceCurrentItem(with: item)

        if let startTime, startTime > 0 {
            let clampedStartTime = max(0, startTime)
            isSeeking = true
            updateStallWatchdog()
            item.seek(
                to: CMTime(seconds: clampedStartTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor in
                    // The user may have moved on to another track before this seek finished.
                    guard let self, self.engine.currentItem === item else { return }
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
        // Nothing has played since launch: continue the queue saved from the last run. This is
        // also what the lock screen, headphones and CarPlay play commands land on.
        guard let currentSong else {
            resumeRestoredQueue()
            return
        }
        // The track failed (e.g. the network dropped): restart it where it stopped.
        if hasPlaybackFailed {
            retryFailedPlayback()
            return
        }
        // The queue played to the end and the session was reported stopped: play the track
        // again from the start under a new Emby play session instead of resuming at the end.
        if currentPlaySessionId == nil, let session {
            // Honour a scrub made after the end; otherwise start over.
            let isAtEnd = elapsed >= max(duration - 1, 0)
            start(song: currentSong, session: session, autoplay: true, startPosition: isAtEnd ? 0 : elapsed)
            return
        }
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
        // Remember where we paused so the next launch can resume from here.
        persistQueueSnapshot()
    }

    /// Arms an 8 s timer whenever a network stream is waiting for data or a seek hasn't landed.
    /// A connection that died with the network (e.g. Wi-Fi to cellular) otherwise leaves the
    /// player waiting forever: no sound, frozen clock, until the next track.
    private func updateStallWatchdog() {
        let mayBeStuck = currentStreamURL?.isFileURL == false
            && (engine.timeControlStatus == .waitingToPlayAtSpecifiedRate || isSeeking)
        guard mayBeStuck else {
            stallWatchdogTask?.cancel()
            stallWatchdogTask = nil
            return
        }
        guard stallWatchdogTask == nil else { return }

        let watchedItem = engine.currentItem
        stallWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            self.stallWatchdogTask = nil
            guard self.engine.currentItem === watchedItem else { return }
            self.recoverFromStall()
        }
    }

    private func recoverFromStall() {
        guard let currentSong,
              engine.timeControlStatus == .waitingToPlayAtSpecifiedRate || isSeeking else { return }

        // Two reconnects per song; after that, show the failure (tap play or a network change
        // retries) instead of looping.
        let attempts = (stallRecovery?.songId == currentSong.id ? stallRecovery?.attempts ?? 0 : 0) + 1
        stallRecovery = (currentSong.id, attempts)
        guard attempts <= 2 else {
            handleAllSourcesFailed()
            return
        }
        print("[Player] Playback stalled; reconnecting (attempt \(attempts))")
        reconnectCurrentTrack()
    }

    /// Rebuilds the current track's stream at the current position, picking the source and
    /// quality for the network we're on now.
    private func reconnectCurrentTrack() {
        guard let currentSong, let session else { return }
        let position = isSeeking ? (pendingSeekTarget ?? seekTarget ?? elapsed) : precisePlaybackTime
        let wantsPlayback = isPlaying || engine.timeControlStatus != .paused
        start(
            song: currentSong,
            session: session,
            autoplay: wantsPlayback,
            startPosition: position,
            durationOverride: currentDurationOverride
        )
    }

    /// Called when the network comes back or switches interface (e.g. Wi-Fi to cellular). The
    /// stream's connection belonged to the old network and is dead, and the quality setting for
    /// the new network should apply now rather than from the next track.
    private func scheduleNetworkRecovery() {
        networkRecoveryTask?.cancel()
        networkRecoveryTask = Task { [weak self] in
            // Path updates arrive in bursts while the interfaces switch over.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            if self.hasPlaybackFailed {
                self.retryFailedPlayback()
                return
            }
            guard self.currentSong != nil, self.currentStreamURL?.isFileURL == false else { return }
            // Don't let the background full-file cache download carry on over cellular data.
            self.cancelAudioCaching()
            self.reconnectCurrentTrack()
        }
    }

    private func retryFailedPlayback() {
        guard hasPlaybackFailed, let currentSong, let session else { return }
        start(
            song: currentSong,
            session: session,
            autoplay: true,
            startPosition: elapsed,
            durationOverride: currentDurationOverride
        )
    }

    /// Every stream candidate failed. Keep playing from a fully cached copy if there is one;
    /// otherwise surface the failure so the UI can show it and the next play tap (or the network
    /// coming back) retries from the same position.
    private func handleAllSourcesFailed() {
        if !hasTriedCachedFallback,
           currentStreamURL?.isFileURL != true,
           let activeAudioCacheKey,
           let cachedURL = PlaybackAudioCache.cachedFileURL(for: activeAudioCacheKey) {
            hasTriedCachedFallback = true
            playbackStatusText = "正在切换播放源"
            isBuffering = true
            currentPlaybackReportMethod = .directPlay
            replaceCurrentItem(with: AuthenticatedURL(url: cachedURL), autoplay: true, startAt: elapsed)
            return
        }

        // Stop the engine too, so a stream that later recovers on its own can't start playing
        // behind a "failed" UI.
        engine.pause()
        isPlaying = false
        isBuffering = false
        playbackStatusText = "播放失败"
        hasPlaybackFailed = true
        isSwitchingTracks = false
        syncNowPlaying(force: true)
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
        currentDurationOverride = nil
        activeAudioCacheKey = nil
        PlaybackAudioCache.setProtectedKey(nil)
        seekTarget = nil
        pendingSeekTarget = nil
        suppressTimeUpdatesUntil = .distantPast
        seekGeneration += 1
        elapsed = 0
        duration = 0
        lyrics = []
        lyricsSongId = nil
        isLoadingLyrics = false
        lastNowPlayingDuration = -1
        syncQueueSnapshots()
        syncNowPlaying(force: true)
        syncRemoteCommandAvailability()
    }

    private func seek(toSeconds seconds: TimeInterval, shouldPlayAfterSeek: Bool) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        guard currentStreamURL != nil else { return }

        seekGeneration += 1
        let generation = seekGeneration

        let currentItem = engine.currentItem
        let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
        isSeeking = true
        updateStallWatchdog()
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
                    let actualElapsed = self.playbackElapsed(for: self.engine.currentTime().seconds)
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
              let currentIndex = songs.firstIndex(where: { $0.id == currentSong.id }) else {
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

        if currentStreamURL?.isFileURL == true {
            // After the cached-copy fallback, the streams have already been tried and failed.
            guard !hasTriedCachedFallback,
                  streamCandidates.indices.contains(streamCandidateIndex) else {
                handleAllSourcesFailed()
                return
            }

            playbackStatusText = "正在切换播放源"
            isBuffering = true
            currentPlaybackReportMethod = playbackReportMethod(isUsingLocalFile: false)
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
            handleAllSourcesFailed()
            return
        }

        streamCandidateIndex = nextIndex
        playbackStatusText = "正在切换播放源"
        isBuffering = true
        currentPlaybackReportMethod = playbackReportMethod(isUsingLocalFile: false)
        print("[Player] Retrying with fallback stream URL \(nextIndex + 1)/\(streamCandidates.count)")
        replaceCurrentItem(
            with: streamCandidates[nextIndex],
            autoplay: true,
            startAt: elapsed,
            candidateIndex: nextIndex
        )
        // If the transcode failed, don't also download the full original in the background.
        if let activeAudioCacheKey, currentTranscodeBitrate == nil {
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
        guard song.id != restoredQueueCurrentSongID else { return }
        var songs = activeQueue
        guard currentQueueReferenceIndex(in: songs) != nil else {
            songs.append(song)
            applyActiveQueue(songs)
            return
        }

        songs.removeAll { $0.id == song.id }
        guard let baseIndex = currentQueueReferenceIndex(in: songs) else {
            songs.append(song)
            applyActiveQueue(songs)
            return
        }
        let insertionIndex: Int
        if let offsetFromCurrent {
            insertionIndex = min(songs.index(baseIndex, offsetBy: offsetFromCurrent), songs.endIndex)
        } else {
            insertionIndex = songs.endIndex
        }
        songs.insert(song, at: insertionIndex)
        applyActiveQueue(songs)
    }

    private func currentQueueReferenceIndex(in songs: [EmbyAudioItem]) -> Int? {
        // Match by id: full equality compares every field and is slow on large queues.
        if let currentSong,
           let index = songs.firstIndex(where: { $0.id == currentSong.id }) {
            return index
        }
        guard let restoredQueueCurrentSongID else { return nil }
        return songs.firstIndex { $0.id == restoredQueueCurrentSongID }
    }

    private func syncQueueSnapshots(persists: Bool = true) {
        let songs = activeQueue

        guard let currentIndex = currentQueueReferenceIndex(in: songs) else {
            upcomingQueueSnapshot = songs
            if persists {
                persistQueueSnapshot()
            }
            return
        }

        let nextIndex = songs.index(after: currentIndex)
        upcomingQueueSnapshot = nextIndex < songs.endIndex ? Array(songs[nextIndex...]) : []
        if persists {
            persistQueueSnapshot()
        }
    }

    private func restorePlaybackQueueSnapshot() {
        let store = queueSnapshotStore
        Task { [weak self] in
            // The saved queue can hold the whole library; decode it off the main thread.
            let snapshot = await Task.detached(priority: .userInitiated) { store.load() }.value
            guard let self, let snapshot else { return }
            self.applyRestoredQueueSnapshot(snapshot)
        }
    }

    private func applyRestoredQueueSnapshot(_ snapshot: PlaybackQueueSnapshot) {
        // Playback started before the snapshot finished loading; that queue wins.
        guard !snapshot.queue.isEmpty, queue.isEmpty, currentSong == nil else { return }

        queue = snapshot.queue
        queueBeforeShuffle = snapshot.isShuffleEnabled ? snapshot.queueBeforeShuffle : nil
        isShuffleEnabled = snapshot.isShuffleEnabled
        repeatMode = snapshot.repeatMode
        if let currentSongID = snapshot.currentSongID,
           snapshot.queue.contains(where: { $0.id == currentSongID }) {
            restoredQueueCurrentSongID = currentSongID
            restoredQueuePosition = max(snapshot.currentPosition ?? 0, 0)
        } else {
            restoredQueueCurrentSongID = nil
            restoredQueuePosition = 0
        }
        // Already on disk; the next save only needs the queue file if it changes. (Not for an
        // old single-file snapshot, which must be rewritten in the new format once.)
        if snapshot.version >= 2 {
            scheduledQueueSignature = queueSignature()
        }

        syncQueueSnapshots(persists: false)
        syncRemoteCommandAvailability()
    }

    /// The song the restored queue was on when the app last ran, before anything has played.
    var restoredSong: EmbyAudioItem? {
        guard currentSong == nil, let restoredQueueCurrentSongID else { return nil }
        return queue.first { $0.id == restoredQueueCurrentSongID }
    }

    /// Continues the queue saved from the last run, at the saved song and position. Returns
    /// false when there's nothing to resume, so callers can fall back to starting something new.
    @discardableResult
    func resumeRestoredQueue() -> Bool {
        guard let song = restoredSong, let session else { return false }
        start(song: song, session: session, autoplay: true, startPosition: restoredQueuePosition)
        return true
    }

    /// Saves the queue and current position right away, e.g. on pause or when backgrounding.
    func savePlaybackStateNow() {
        guard !queue.isEmpty else { return }
        persistQueueSnapshot()
        flushQueueSnapshot()
    }

    private func persistQueueSnapshot() {
        guard !queue.isEmpty else {
            clearQueueSnapshot()
            return
        }

        let currentSongID = (currentSong?.id ?? restoredQueueCurrentSongID).flatMap { id in
            queue.contains { $0.id == id } ? id : nil
        }

        let store = queueSnapshotStore

        // The song list is only rewritten when its contents change. A track change, pause or
        // mode change touches just the small state file; before, every one of those re-encoded
        // the whole queue, which can be the entire library.
        let signature = queueSignature()
        if signature != scheduledQueueSignature {
            scheduledQueueSignature = signature
            let savedQueue = queue
            let savedQueueBeforeShuffle = queueBeforeShuffle
            pendingQueueWrite = {
                store.saveQueue(queue: savedQueue, queueBeforeShuffle: savedQueueBeforeShuffle)
            }
        }

        let savedPosition = currentSong != nil ? elapsed : restoredQueuePosition
        let savedShuffleEnabled = isShuffleEnabled
        let savedRepeatMode = repeatMode
        pendingStateWrite = {
            store.saveState(
                currentSongID: currentSongID,
                currentPosition: savedPosition,
                isShuffleEnabled: savedShuffleEnabled,
                repeatMode: savedRepeatMode
            )
        }

        // Coalesce bursts (play() and start() both sync the queue) into a single write.
        queuePersistTask?.cancel()
        queuePersistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushQueueSnapshot()
        }
    }

    /// Writes any pending queue snapshot now, e.g. when the app moves to the background.
    func flushQueueSnapshot() {
        queuePersistTask?.cancel()
        queuePersistTask = nil
        let writes = [pendingQueueWrite, pendingStateWrite].compactMap { $0 }
        pendingQueueWrite = nil
        pendingStateWrite = nil
        guard !writes.isEmpty else { return }
        queuePersistenceQueue.async {
            for write in writes {
                write()
            }
        }
    }

    /// Identifies the queue's contents (ids and order, plus the pre-shuffle order) so unchanged
    /// queues aren't rewritten. Hashing ids is far cheaper than encoding the songs.
    private func queueSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(queue.count)
        for song in queue {
            hasher.combine(song.id)
        }
        if let queueBeforeShuffle {
            hasher.combine(queueBeforeShuffle.count)
            for song in queueBeforeShuffle {
                hasher.combine(song.id)
            }
        }
        return hasher.finalize()
    }

    private func clearQueueSnapshot() {
        queuePersistTask?.cancel()
        queuePersistTask = nil
        pendingQueueWrite = nil
        pendingStateWrite = nil
        scheduledQueueSignature = nil
        let store = queueSnapshotStore
        queuePersistenceQueue.async {
            store.clear()
        }
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
        remoteCommands.onSkip = { [weak self] offset in
            Task { @MainActor in
                guard let self else { return }
                self.seek(toSeconds: self.precisePlaybackTime + offset, shouldPlayAfterSeek: self.isPlaying)
            }
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
                    self.duration = self.playbackDuration(for: observedItem.duration.seconds)
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
                      self.engine.timeControlStatus != .playing else { return }
                self.isBuffering = true
                self.playbackStatusText = "正在缓冲"
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

        let newElapsed = playbackElapsed(for: time.seconds)
        if let pendingSeekTarget {
            if Date() < suppressTimeUpdatesUntil {
                let isOutsideSeekWindow = abs(newElapsed - pendingSeekTarget) > 0.45
                let isBeforeSeekTarget = newElapsed + seekBackwardTolerance < pendingSeekTarget
                if isOutsideSeekWindow || isBeforeSeekTarget {
                    return
                }
            }
            self.pendingSeekTarget = nil
            seekTarget = nil
        } else if seekTarget != nil {
            seekTarget = nil
        }

        let previousElapsed = elapsed
        elapsed = newElapsed
        if engine.timeControlStatus == .playing || newElapsed > previousElapsed + 0.05 {
            clearTransientPlaybackStatus()
        }
        reportPlaybackProgress()
        if let itemDuration = engine.currentItem?.duration.seconds,
           itemDuration.isFinite,
           itemDuration > 0 {
            duration = playbackDuration(for: itemDuration)
        }

        syncPlaybackStateFromEngine(forceNowPlaying: false)
    }

    private func syncPlaybackStateFromEngine(forceNowPlaying: Bool) {
        // While AVPlayer waits for data its `rate` stays 1, so the old `rate`-based checks showed
        // a stalled stream as playing (no sound, no spinner). Use the control status instead:
        // waiting = buffering, and anything but paused means the user wants playback.
        let playing = engine.timeControlStatus != .paused
        let buffering = engine.timeControlStatus == .waitingToPlayAtSpecifiedRate
        updateStallWatchdog()
        // Runs on every 0.5s tick: only touch @Published state when it actually changes,
        // otherwise every observing view (mini player, now playing) re-renders each tick.
        if buffering {
            setBuffering(true)
            setPlaybackStatusText("正在缓冲")
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
        setBuffering(false)
        if playbackStatusText == "正在跳转" ||
            playbackStatusText == "正在缓冲" ||
            playbackStatusText == "正在连接" ||
            playbackStatusText == "正在恢复播放" ||
            playbackStatusText == "正在切换播放源" {
            playbackStatusText = nil
        }
    }

    private func setBuffering(_ value: Bool) {
        guard isBuffering != value else { return }
        isBuffering = value
    }

    private func setPlaybackStatusText(_ value: String?) {
        guard playbackStatusText != value else { return }
        playbackStatusText = value
    }

    private func handlePlaybackStalled(for itemId: ObjectIdentifier) {
        guard let currentItem = engine.currentItem,
              ObjectIdentifier(currentItem) == itemId else { return }

        isBuffering = true
        playbackStatusText = "正在缓冲"
    }

    private func playbackElapsed(for itemTime: TimeInterval) -> TimeInterval {
        let elapsed = itemTime.validDuration(fallback: 0)
        guard duration > 0 else { return max(0, elapsed) }
        return max(0, min(elapsed, duration))
    }

    private func playbackDuration(for itemDuration: TimeInterval) -> TimeInterval {
        let playbackDuration = itemDuration.validDuration(fallback: 0)
        let knownDuration = max(currentSong?.duration ?? 0, currentDurationOverride ?? 0)
        if knownDuration > 0 {
            return max(knownDuration, playbackDuration)
        }

        return max(playbackDuration, duration)
    }

    private func syncNowPlaying(force: Bool) {
        guard let currentSong else {
            nowPlaying.clear()
            return
        }

        // State changes (track, play/pause, seek, artwork) always pass `force`. Periodic ticks
        // only update when the duration became known or changed: the system extrapolates the
        // elapsed time from the playback rate, so rebuilding the info every second was wasted.
        guard force || abs(duration - lastNowPlayingDuration) > 0.5 else { return }
        lastNowPlayingDuration = duration

        let queueIndex = queue.firstIndex { $0.id == currentSong.id }
        nowPlaying.update(
            song: currentSong,
            elapsed: elapsed,
            duration: duration,
            // While buffering, report rate 0 so the lock screen doesn't run its clock ahead.
            isPlaying: isPlaying && !isBuffering,
            artwork: currentArtwork,
            queueIndex: queueIndex,
            queueCount: queueIndex == nil ? nil : queue.count
        )
    }

    /// Runs on every periodic tick, so it compares by id and only touches
    /// MPRemoteCommandCenter when availability actually changes.
    private func syncRemoteCommandAvailability() {
        let availability: RemoteCommandAvailability
        if let currentSong {
            let songs = activeQueue
            let currentIndex = songs.firstIndex { $0.id == currentSong.id }
            availability = RemoteCommandAvailability(
                canGoNext: repeatMode == .all || currentIndex.map { $0 < songs.index(before: songs.endIndex) } == true,
                canGoPrevious: elapsed > 3 || repeatMode == .all || currentIndex.map { $0 > songs.startIndex } == true,
                canSeek: duration > 0,
                isSpokenAudio: currentSong.isAudiobookAudio || isAudiobookEpisode?(currentSong) == true
            )
        } else {
            availability = RemoteCommandAvailability(canGoNext: false, canGoPrevious: false, canSeek: false, isSpokenAudio: false)
        }

        guard availability != lastRemoteCommandAvailability else { return }
        lastRemoteCommandAvailability = availability
        remoteCommands.update(
            canGoNext: availability.canGoNext,
            canGoPrevious: availability.canGoPrevious,
            canSeek: availability.canSeek,
            isSpokenAudio: availability.isSpokenAudio
        )
    }

    private func reportPlaybackStarted(position: TimeInterval) {
        guard let currentSong, let session, let currentPlaySessionId else { return }

        let item = currentSong
        let activeSession = session
        let playSessionId = currentPlaySessionId
        let playMethod = currentPlaybackReportMethod
        let clampedPosition = max(0, position)
        lastPlaybackProgressReport = Date()
        notifyPlaybackPosition(position: clampedPosition, isFinished: false, isCheckpoint: true)

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
        notifyPlaybackPosition(position: clampedPosition, isFinished: false, isCheckpoint: force)

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
        notifyPlaybackPosition(position: clampedPosition, isFinished: isFinished, isCheckpoint: true)
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

    private func notifyPlaybackPosition(position: TimeInterval, isFinished: Bool, isCheckpoint: Bool) {
        guard let currentSong else { return }
        onPlaybackPositionChanged?(currentSong, position, max(duration, currentSong.duration), isFinished, isCheckpoint)
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

        guard let resource = client.imageURL(for: song, session: session, size: 600) else {
            syncNowPlaying(force: true)
            return
        }

        // The player page shows the same 600px artwork, so it's usually cached already.
        let url = resource.url
        if let cached = ArtworkImageCache.shared.image(for: url) {
            currentArtwork = cached
            syncNowPlaying(force: true)
            return
        }

        artworkTask = Task { [weak self, songId = song.id] in
            var artworkData = await ArtworkDiskCache.data(for: url)
            if artworkData == nil,
               let (downloaded, response) = try? await URLSession.shared.data(for: resource.request),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                artworkData = downloaded
                await ArtworkDiskCache.insert(downloaded, for: url)
            }

            guard let artworkData,
                  let image = UIImage(data: artworkData),
                  !Task.isCancelled,
                  let self,
                  self.currentSong?.id == songId else {
                return
            }
            self.currentArtwork = image
            self.syncNowPlaying(force: true)
        }
    }

    private func loadEmbeddedLyrics(from resource: AuthenticatedURL?, songId: String) {
        lyricsTask?.cancel()
        lyrics = []
        lyricsSongId = songId
        isLoadingLyrics = false
        guard let resource else { return }

        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            let lines = await Self.readEmbeddedLyrics(from: resource)
            await MainActor.run {
                guard !Task.isCancelled, self?.lyricsSongId == songId else { return }
                self?.lyrics = lines
                self?.isLoadingLyrics = false
            }
        }
    }

    private nonisolated static func readEmbeddedLyrics(from resource: AuthenticatedURL) async -> [LyricLine] {
        let asset = AVURLAsset(url: resource.url, options: resource.avAssetOptions)
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

    /// The LRC `[offset:…]` value in seconds, or 0 when absent.
    private nonisolated static func lyricOffset(in rawLyrics: String) -> TimeInterval {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#,
            options: [.caseInsensitive]
        ) else {
            return 0
        }
        let range = NSRange(rawLyrics.startIndex..., in: rawLyrics)
        guard let match = regex.firstMatch(in: rawLyrics, range: range),
              let valueRange = Range(match.range(at: 1), in: rawLyrics),
              let milliseconds = Double(rawLyrics[valueRange]) else {
            return 0
        }
        return milliseconds / 1000
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
        // LRC `[offset:±ms]` shifts every timestamp; positive values make lyrics appear earlier.
        let offset = lyricOffset(in: rawLyrics)

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
                timedLines.append((max(time - offset, 0), text))
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
    static let downloadDelay: Duration = .seconds(10)

    private struct State {
        var limitBytes = AudioCacheLimit.defaultValue.bytes
        var generation = 0
        var protectedFileName: String?
    }

    private static let state = Mutex(State())

    struct Key: Hashable {
        let serverHash: String
        let userId: String
        let itemId: String
        let fileExtension: String

        init(session: EmbySession, item: EmbyAudioItem) {
            serverHash = PlaybackAudioCache.stableHash(session.serverURL.absoluteString)
            userId = session.userId
            itemId = item.id
            fileExtension = item.audioCacheFileExtension
        }

        var fileName: String {
            let stem = [
                PlaybackAudioCache.version,
                serverHash,
                userId,
                itemId,
                "lossless",
                "aac"
            ]
            .map(PlaybackAudioCache.sanitizedPathComponent)
            .joined(separator: "-")

            return "\(stem).\(PlaybackAudioCache.sanitizedFileExtension(fileExtension))"
        }
    }

    static var limitBytes: Int64 {
        state.withLock { $0.limitBytes }
    }

    static var isEnabled: Bool {
        limitBytes > 0
    }

    static func setLimit(_ limit: AudioCacheLimit) {
        state.withLock { $0.limitBytes = limit.bytes }
    }

    /// The file the player is reading right now; trimming never removes it.
    static func setProtectedKey(_ key: Key?) {
        state.withLock { $0.protectedFileName = key?.fileName }
    }

    static func cachedFileURL(for key: Key) -> URL? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            return nil
        }
        DiskCacheMaintenance.markUsed(url)
        return url
    }

    static func removeCachedFile(for key: Key) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    static func clearAll() {
        // Downloads that started before this point must not write their file back.
        state.withLock { $0.generation += 1 }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func totalSize() -> Int64 {
        DiskCacheMaintenance.size(of: directoryURL)
    }

    /// Evicts least recently played songs until the cache fits the configured limit.
    static func trimToLimit() {
        let (limit, protectedFileName) = state.withLock { ($0.limitBytes, $0.protectedFileName) }
        DiskCacheMaintenance.trim(directoryURL, toBytes: limit, protecting: protectedFileName)
    }

    fileprivate static var generation: Int {
        state.withLock { $0.generation }
    }

    fileprivate static func fileURL(for key: Key) -> URL {
        directoryURL.appendingPathComponent(key.fileName, isDirectory: false)
    }

    fileprivate static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static var directoryURL: URL {
        DiskCacheMaintenance.cachesBaseURL
            .appendingPathComponent("PrivSong", isDirectory: true)
            .appendingPathComponent("CurrentPlaybackAudio", isDirectory: true)
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
    func cacheCurrentSong(from sourceURL: AuthenticatedURL, key: PlaybackAudioCache.Key) async throws -> URL? {
        if let cachedURL = PlaybackAudioCache.cachedFileURL(for: key) {
            return cachedURL
        }
        guard PlaybackAudioCache.isEnabled else { return nil }

        let generation = PlaybackAudioCache.generation
        let (temporaryURL, response) = try await URLSession.shared.download(for: sourceURL.request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        let fileSize = try validate(response: response, temporaryURL: temporaryURL)

        // The cache was cleared or shrunk while downloading, or this single file would not fit at all.
        guard PlaybackAudioCache.generation == generation,
              fileSize <= PlaybackAudioCache.limitBytes else {
            return nil
        }

        try PlaybackAudioCache.prepareDirectory()
        let destinationURL = PlaybackAudioCache.fileURL(for: key)
        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        }
        PlaybackAudioCache.trimToLimit()
        return destinationURL
    }

    private func validate(response: URLResponse, temporaryURL: URL) throws -> Int64 {
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0 else {
            throw URLError(.zeroByteResource)
        }
        return Int64(fileSize)
    }
}

enum DiskCacheMaintenance {
    private struct CachedFile {
        let url: URL
        let size: Int64
        let lastUsed: Date
    }

    static var cachesBaseURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static func size(of directory: URL) -> Int64 {
        files(in: directory).reduce(0) { $0 + $1.size }
    }

    /// Removes the least recently used files until the directory fits within `maxBytes`.
    static func trim(_ directory: URL, toBytes maxBytes: Int64, protecting protectedFileName: String? = nil) {
        let files = files(in: directory)
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }

        for file in files.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > maxBytes {
            guard file.url.lastPathComponent != protectedFileName else { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }

    static func markUsed(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Deletes storage left behind by older builds (pre-rename folders, artwork kept in
    /// Application Support) and by audio downloads interrupted when the app was killed.
    static func removeOrphanedFiles() {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let legacyDirectories = [
            cachesBaseURL.appendingPathComponent("MusicEmby", isDirectory: true),
            applicationSupportURL?.appendingPathComponent("MusicEmby", isDirectory: true),
            applicationSupportURL?.appendingPathComponent("PrivSong/ArtworkCache", isDirectory: true)
        ]
        for directory in legacyDirectories.compactMap({ $0 }) {
            try? fileManager.removeItem(at: directory)
        }

        let temporaryFiles = (try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in temporaryFiles where url.lastPathComponent.hasPrefix("CFNetworkDownload_") {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func files(in directory: URL) -> [CachedFile] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else {
            return []
        }

        var files: [CachedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            files.append(CachedFile(
                url: url,
                size: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                lastUsed: values.contentModificationDate ?? .distantPast
            ))
        }
        return files
    }
}

private extension AuthenticatedURL {
    var avAssetOptions: [String: Any]? {
        guard !httpHeaders.isEmpty else { return nil }
        return ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders]
    }

    /// Options for the asset that is actually played. Precise timing makes seeks in
    /// variable-bitrate files (FLAC, VBR MP3) land where the reported time says. Without it
    /// AVFoundation estimates the byte offset from the average bitrate, so after a seek the
    /// audio drifted away from the clock that drives the progress bar and lyrics.
    var playbackAssetOptions: [String: Any] {
        var options = avAssetOptions ?? [:]
        options[AVURLAssetPreferPreciseDurationAndTimingKey] = true
        return options
    }
}

enum RepeatMode: String, Codable {
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

private struct PlaybackQueueSnapshot: Codable {
    let version: Int
    let savedAt: Date
    let queue: [EmbyAudioItem]
    let queueBeforeShuffle: [EmbyAudioItem]?
    let currentSongID: String?
    /// Where the current song was when last saved. Optional so older snapshots still decode.
    let currentPosition: TimeInterval?
    let isShuffleEnabled: Bool
    let repeatMode: RepeatMode
}

/// Persists the play queue as two files so a track change doesn't rewrite the whole queue:
/// - `playback-queue.json`: the songs (large; written only when the queue's contents change)
/// - `playback-state.json`: current song, position, shuffle and repeat (tiny; written often)
/// Reads the old single-file `playback-queue-snapshot.json` once for migration.
private struct PlaybackQueueSnapshotStore {
    private let version = 2
    private let legacyVersion = 1
    private let queueFileName = "playback-queue.json"
    private let stateFileName = "playback-state.json"
    private let legacyFileName = "playback-queue-snapshot.json"

    private struct QueueFile: Codable {
        let version: Int
        let queue: [EmbyAudioItem]
        let queueBeforeShuffle: [EmbyAudioItem]?
    }

    private struct StateFile: Codable {
        let version: Int
        let savedAt: Date
        let currentSongID: String?
        let currentPosition: TimeInterval?
        let isShuffleEnabled: Bool
        let repeatMode: RepeatMode
    }

    func load() -> PlaybackQueueSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let queueData = try? Data(contentsOf: url(queueFileName)),
           let queueFile = try? decoder.decode(QueueFile.self, from: queueData),
           queueFile.version == version {
            let state = (try? Data(contentsOf: url(stateFileName)))
                .flatMap { try? decoder.decode(StateFile.self, from: $0) }
            return PlaybackQueueSnapshot(
                version: version,
                savedAt: state?.savedAt ?? Date(),
                queue: queueFile.queue,
                queueBeforeShuffle: queueFile.queueBeforeShuffle,
                currentSongID: state?.currentSongID,
                currentPosition: state?.currentPosition,
                isShuffleEnabled: state?.isShuffleEnabled ?? false,
                repeatMode: state?.repeatMode ?? RepeatMode.none
            )
        }

        guard let legacyData = try? Data(contentsOf: url(legacyFileName)),
              let legacy = try? decoder.decode(PlaybackQueueSnapshot.self, from: legacyData),
              legacy.version == legacyVersion else {
            return nil
        }
        return legacy
    }

    func saveQueue(queue: [EmbyAudioItem], queueBeforeShuffle: [EmbyAudioItem]?) {
        write(QueueFile(version: version, queue: queue, queueBeforeShuffle: queueBeforeShuffle), to: queueFileName)
        // The split files now hold everything the old single file did.
        try? FileManager.default.removeItem(at: url(legacyFileName))
    }

    func saveState(
        currentSongID: String?,
        currentPosition: TimeInterval?,
        isShuffleEnabled: Bool,
        repeatMode: RepeatMode
    ) {
        write(
            StateFile(
                version: version,
                savedAt: Date(),
                currentSongID: currentSongID,
                currentPosition: currentPosition,
                isShuffleEnabled: isShuffleEnabled,
                repeatMode: repeatMode
            ),
            to: stateFileName
        )
    }

    func clear() {
        for name in [queueFileName, stateFileName, legacyFileName] {
            try? FileManager.default.removeItem(at: url(name))
        }
    }

    private func write<Value: Encodable>(_ value: Value, to fileName: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url(fileName), options: [.atomic])
        } catch {
            print("[PlaybackQueueSnapshotStore] Failed to save \(fileName): \(error.localizedDescription)")
        }
    }

    private func url(_ fileName: String) -> URL {
        applicationSupportDirectory.appendingPathComponent(fileName)
    }

    private var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PrivSong", isDirectory: true)
    }
}

private extension TimeInterval {
    func validDuration(fallback: TimeInterval) -> TimeInterval {
        guard isFinite, self > 0 else { return fallback }
        return self
    }
}
