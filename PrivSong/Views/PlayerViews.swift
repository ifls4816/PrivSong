import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct MiniPlayerView: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController

    let expand: () -> Void

    var body: some View {
        let song = player.currentSong ?? store.lastPlayedSong
        let isInline = accessoryPlacement == .inline
        let artworkURL = song.flatMap { store.imageURL(for: $0, size: 160) }
        let verticalPadding: CGFloat = 6
        let horizontalPadding: CGFloat = 12
        let artworkSize: CGFloat = 36
        let artworkCornerRadius: CGFloat = 8
        let cornerRadius: CGFloat = isInline ? 26 : 16
        let titleSize: CGFloat = 12.5
        let subtitleSize: CGFloat = 11
        let contentHeight: CGFloat = 48
        let maxAccessoryWidth: CGFloat = 430
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glassTint = Color(red: 0.984, green: 0.984, blue: 1.0).opacity(0.86)
        let glassHighlight = Color.white.opacity(0.28)
        let glassOutline = Color.primary.opacity(0.08)

        HStack(spacing: 10) {
            if song != nil {
                ArtworkView(url: artworkURL, cornerRadius: artworkCornerRadius)
                    .frame(width: artworkSize, height: artworkSize)
                    .allowsHitTesting(false)
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                        .fill(.primary.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: artworkSize, height: artworkSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song?.name ?? "暂无歌曲")
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(miniSubtitle(for: song))
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(height: 34, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button {
                if player.currentSong != nil {
                    player.togglePlayPause()
                } else if let song {
                    store.play(song: song, in: store.songs)
                }
            } label: {
                ZStack {
                    if player.currentSong != nil && (player.isBuffering || player.isSeeking) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.primary)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.primary.opacity(song == nil ? 0.35 : 1))
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(song == nil)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.primary.opacity(player.currentSong == nil ? 0.35 : 1))
            }
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: contentHeight)
        .frame(maxWidth: maxAccessoryWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            shape
                .fill(glassTint)
        }
        .overlay {
            shape
                .strokeBorder(glassHighlight, lineWidth: 0.65)
        }
        .overlay {
            shape
                .strokeBorder(glassOutline, lineWidth: 0.5)
        }
        .clipShape(shape)
        .shadow(color: .white.opacity(0.1), radius: 0.75, y: -0.5)
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .contentShape(shape)
        .transaction { transaction in
            transaction.animation = nil
        }
        .onTapGesture(perform: openPlayer)
        .onLongPressGesture(minimumDuration: 0.45, perform: openPlayer)
    }

    private func miniSubtitle(for song: EmbyAudioItem?) -> String {
        return song.map { $0.artistLine.isEmpty ? "暂无艺术家" : $0.artistLine } ?? "播放后会显示当前歌曲"
    }

    private func openPlayer() {
        guard player.currentSong != nil || store.lastPlayedSong != nil else { return }
        expand()
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController
    let onOpenAlbum: (EmbyAudioItem) -> Void
    let onOpenArtist: (EmbyAudioItem) -> Void
    let onDismiss: () -> Void

    @State private var mode: PlayerMode = .nowPlaying
    @State private var scrubElapsed: TimeInterval = 0
    @State private var isScrubbing = false

    @State private var selectedSleepTimerTitle: String?
    @State private var revealPlayerControls = false

    private let sleepTimerOptions: [(title: String, duration: TimeInterval)] = [
        ("8小时", 8 * 60 * 60),
        ("6小时", 6 * 60 * 60),
        ("5小时", 5 * 60 * 60),
        ("4小时", 4 * 60 * 60),
        ("3小时", 3 * 60 * 60),
        ("2小时", 2 * 60 * 60),
        ("60分钟", 60 * 60),
        ("30分钟", 30 * 60),
        ("15分钟", 15 * 60)
    ]

    private var controlsRevealProgress: Double {
        revealPlayerControls ? 1 : 0
    }

    private func preloadDisplayedLyricsIfNeeded(for song: EmbyAudioItem) {
        guard let session = store.session else { return }
        player.preloadLyrics(for: song, session: session)
    }

    var body: some View {
        if let song = player.currentSong ?? store.lastPlayedSong {
            GeometryReader { proxy in
                let size = sanitizedPageSize(proxy.size)
                ZStack {
                    PlayerPageBackground(imageURL: store.imageURL(for: song))

                    VStack(spacing: 0) {
                        nowPlayingPage(song: song, size: size)
                            .frame(width: size.width)
                    }
                    .frame(width: size.width, height: size.height, alignment: .top)
                }
                .frame(width: size.width, height: size.height)
            }
            .onAppear {
                revealPlayerControls = false
                preloadDisplayedLyricsIfNeeded(for: song)
                UIApplication.shared.isIdleTimerDisabled = store.keepsScreenAwakeOnPlayerPage
                withAnimation(.easeOut(duration: 0.22).delay(0.12)) {
                    revealPlayerControls = true
                }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                revealPlayerControls = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .lyricsTapped)) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    mode = .nowPlaying
                }
            }
            .onChange(of: store.keepsScreenAwakeOnPlayerPage) { _, enabled in
                UIApplication.shared.isIdleTimerDisabled = enabled
            }
            .onChange(of: song.id) { _, _ in
                preloadDisplayedLyricsIfNeeded(for: song)
            }
        }
    }

    private func nowPlayingPage(song: EmbyAudioItem, size: CGSize) -> some View {
        let pageWidth = safeDimension(size.width)
        let pageHeight = safeDimension(size.height)
        let contentWidth = min(max(pageWidth - 48, 1), 352)
        let compactHeight = pageHeight < 760
        let artworkSlotSize = min(contentWidth * (compactHeight ? 0.92 : 1.0), compactHeight ? 312 : 352)
        let playingArtworkSize = artworkSlotSize * (compactHeight ? 0.84 : 0.86)
        let pausedArtworkScale = compactHeight ? CGFloat(0.82) : CGFloat(0.84)
        let upperHeight = min(artworkSlotSize + (compactHeight ? 58 : 92), compactHeight ? 370 : 444)
        let topOffset: CGFloat = compactHeight ? 22 : 28
        let titleGap: CGFloat = compactHeight ? 22 : 32
        let progressGap: CGFloat = compactHeight ? 9 : 10
        let controlsProgress = controlsRevealProgress

        return VStack(spacing: 0) {
            Color.clear.frame(height: topOffset)

            upperContent(
                song: song,
                width: contentWidth,
                height: upperHeight,
                artworkSize: playingArtworkSize,
                pausedArtworkScale: pausedArtworkScale
            )

            Color.clear.frame(height: titleGap)

            VStack(alignment: .leading, spacing: progressGap) {
                songHeader(song)
                progressControls(song: song)
                    .opacity(controlsProgress)
                    .offset(y: controlsProgress == 1 ? 0 : 8)
            }
            .frame(width: contentWidth)

            GeometryReader { lowerProxy in
                lowerControls(
                    contentWidth: contentWidth,
                    screenWidth: pageWidth,
                    height: lowerProxy.size.height,
                    compactHeight: compactHeight,
                    song: song
                )
            }
            .frame(maxHeight: .infinity)
            .opacity(controlsProgress)
            .offset(y: controlsProgress == 1 ? 0 : 18)
        }
        .frame(width: pageWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
    }

    private func lowerControls(contentWidth: CGFloat, screenWidth: CGFloat, height: CGFloat, compactHeight: Bool, song: EmbyAudioItem) -> some View {
        let contentWidth = safeDimension(contentWidth)
        let screenWidth = safeDimension(screenWidth)
        let height = safeDimension(height)
        let transportHeight: CGFloat = 62
        let volumeHeight: CGFloat = 32
        let bottomBarHeight: CGFloat = compactHeight ? 56 : 62
        let availableGap = max(0, height - transportHeight - volumeHeight - bottomBarHeight)
        let targetTopGap = compactHeight ? CGFloat(24) : CGFloat(30)
        let targetMiddleGap = compactHeight ? CGFloat(34) : CGFloat(42)
        let targetLowerGap = compactHeight ? CGFloat(36) : CGFloat(44)
        let targetGap = targetTopGap + targetMiddleGap + targetLowerGap
        let gapScale = targetGap > 0 ? min(1, availableGap / targetGap) : 1
        let topGap = targetTopGap * gapScale
        let middleGap = targetMiddleGap * gapScale
        let lowerGap = targetLowerGap * gapScale

        return VStack(spacing: 0) {
            Color.clear.frame(height: topGap)

            transportControls(width: contentWidth, song: song)

            Color.clear.frame(height: middleGap)

            volumeControl
                .frame(width: contentWidth)

            Color.clear.frame(height: lowerGap)

            bottomBar(width: screenWidth)
                .frame(height: bottomBarHeight, alignment: .top)
        }
        .frame(width: screenWidth, height: height, alignment: .top)
    }

    private func sanitizedPageSize(_ size: CGSize) -> CGSize {
        CGSize(width: safeDimension(size.width), height: safeDimension(size.height))
    }

    private func safeDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    @ViewBuilder
    private func upperContent(
        song: EmbyAudioItem,
        width: CGFloat,
        height: CGFloat,
        artworkSize: CGFloat,
        pausedArtworkScale: CGFloat
    ) -> some View {
        switch mode {
        case .nowPlaying:
            let isArtworkExpanded = player.isPlaying
            let artworkScale = isArtworkExpanded ? CGFloat(1) : pausedArtworkScale
            ArtworkView(url: store.imageURL(for: song), cornerRadius: 10)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipped()
                .scaleEffect(artworkScale)
                .shadow(color: .black.opacity(0.26), radius: 20, y: 10)
                .frame(width: width, height: height, alignment: .center)
                .animation(.smooth(duration: 0.32, extraBounce: 0), value: isArtworkExpanded)
        case .lyrics:
            LyricsPanelView(
                song: song,
                timeline: player.timeline,
                fallbackDuration: song.duration,
                isPlaybackActive: player.currentSong != nil,
                scrubElapsed: scrubElapsed,
                isScrubbing: isScrubbing
            )
                .frame(width: width, height: height)
        case .queue:
            QueuePlayerView()
                .frame(width: width, height: height)
        }
    }

    private func songHeader(_ song: EmbyAudioItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    onOpenAlbum(song)
                } label: {
                    Text(song.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    onOpenArtist(song)
                } label: {
                    Text(song.artistLine)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.toggleFavorite(song)
            } label: {
                Image(systemName: store.isFavorite(song) ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(store.isFavorite(song) ? Color.musicRed : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func progressControls(song: EmbyAudioItem) -> some View {
        PlaybackProgressControls(
            timeline: player.timeline,
            fallbackDuration: song.duration,
            isPlaybackActive: player.currentSong != nil,
            scrubElapsed: $scrubElapsed,
            isScrubbing: $isScrubbing
        ) { targetElapsed in
            player.seek(toElapsed: targetElapsed)
        }
    }

    private func transportControls(width: CGFloat, song: EmbyAudioItem) -> some View {
        let spacing = min(max((width - 236) / 4, 8), 22)

        return HStack(spacing: spacing) {
            shuffleModeButton

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 48, height: 52)
            }
            .disabled(player.currentSong == nil)
            .opacity(player.currentSong == nil ? 0.42 : 1)

            Button {
                if player.currentSong == nil {
                    store.play(song: song, in: store.songs)
                } else {
                    player.togglePlayPause()
                }
            } label: {
                ZStack {
                    if player.isBuffering || player.isSeeking {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.musicRed)
                            .scaleEffect(1.28)
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 45, weight: .semibold))
                    }
                }
                .frame(width: 68, height: 62)
            }

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 48, height: 52)
            }
            .disabled(player.currentSong == nil)
            .opacity(player.currentSong == nil ? 0.42 : 1)

            repeatModeButton
        }
        .frame(width: width)
        .foregroundStyle(.primary)
    }

    private var shuffleModeButton: some View {
        Button {
            player.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 44)
                .foregroundStyle(player.isShuffleEnabled ? Color.musicRed : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var repeatModeButton: some View {
        Button {
            player.cycleRepeatMode()
        } label: {
            Image(systemName: player.repeatMode.iconName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 44)
                .foregroundStyle(player.repeatMode == .none ? .secondary : Color.musicRed)
        }
        .buttonStyle(.plain)
    }

    private var volumeControl: some View {
        let iconOffsetY: CGFloat = -0.4

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 32, alignment: .center)
                .offset(y: iconOffsetY)
            SystemVolumeSlider()
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 32, alignment: .center)
                .offset(y: iconOffsetY)
        }
        .frame(height: 32, alignment: .center)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.secondary)
    }

    private func bottomBar(width: CGFloat) -> some View {
        HStack(spacing: 48) {
            playerModeButton(.lyrics, icon: "quote.bubble")
            sleepTimerButton
            playerModeButton(.queue, icon: "list.bullet")
        }
        .frame(width: width)
    }

    private var sleepTimerButton: some View {
        Menu {
            if let sleepTimerRemainingText {
                Section {
                    Text("剩余 \(sleepTimerRemainingText)")
                }
            }

            Section("睡眠播放") {
                Picker("睡眠播放", selection: sleepTimerSelection) {
                    ForEach(sleepTimerOptions, id: \.title) { option in
                        Text(option.title)
                            .tag(option.title)
                    }
                }
            }

            if player.sleepTimerEndDate != nil {
                Section {
                    Button("关闭睡眠播放", role: .destructive) {
                        player.cancelSleepTimer()
                        selectedSleepTimerTitle = nil
                    }
                }
            }
        } label: {
            Image(systemName: "moon.zzz")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 34, height: 28)
                .foregroundStyle(player.sleepTimerEndDate == nil ? .secondary : Color.musicRed)
        }
        .buttonStyle(.plain)
    }

    private var sleepTimerSelection: Binding<String> {
        Binding(
            get: { selectedSleepTimerTitle ?? "" },
            set: { title in
                guard let option = sleepTimerOptions.first(where: { $0.title == title }) else { return }
                setSleepTimer(after: option.duration, title: option.title)
            }
        )
    }

    private var sleepTimerRemainingText: String? {
        player.sleepTimerEndDate.map { sleepTimerRemainingText(until: $0, from: Date()) }
    }

    private func setSleepTimer(after duration: TimeInterval, title: String) {
        player.setSleepTimer(after: duration)
        selectedSleepTimerTitle = title
    }

    private func sleepTimerRemainingText(until endDate: Date, from referenceDate: Date) -> String {
        let remainingSeconds = max(0, endDate.timeIntervalSince(referenceDate))
        guard remainingSeconds >= 60 else { return "不到1分钟" }

        let totalMinutes = max(1, Int((remainingSeconds / 60).rounded()))
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

    private func playerModeButton(_ target: PlayerMode, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                if target == .nowPlaying {
                    mode = .nowPlaying
                } else {
                    mode = mode == target ? .nowPlaying : target
                }
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 34, height: 28)
                .foregroundStyle(mode == target ? Color.musicRed : .secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct PlaybackProgressControls: View {
    @ObservedObject var timeline: PlaybackTimeline
    let fallbackDuration: TimeInterval
    let isPlaybackActive: Bool
    @Binding var scrubElapsed: TimeInterval
    @Binding var isScrubbing: Bool
    let seek: (TimeInterval) -> Void

    private var duration: TimeInterval {
        effectivePlaybackDuration(
            timeline: timeline,
            fallbackDuration: fallbackDuration,
            isPlaybackActive: isPlaybackActive
        )
    }

    private var elapsed: TimeInterval {
        displayedPlaybackElapsed(
            timeline: timeline,
            fallbackDuration: fallbackDuration,
            isPlaybackActive: isPlaybackActive,
            isScrubbing: isScrubbing,
            scrubElapsed: scrubElapsed
        )
    }

    var body: some View {
        let sliderUpperBound = max(duration, 1)

        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { elapsed },
                set: { value in
                    isScrubbing = true
                    scrubElapsed = value
                }
            ), in: 0...sliderUpperBound) { editing in
                if editing {
                    if !isScrubbing {
                        scrubElapsed = elapsed
                    }
                    isScrubbing = true
                } else {
                    let targetElapsed = min(max(scrubElapsed, 0), duration)
                    isScrubbing = false
                    seek(targetElapsed)
                }
            }
            .tint(Color.musicRed)
            .allowsHitTesting(isPlaybackActive && duration > 0)

            HStack {
                Text(playbackTimeText(elapsed))
                    .monospacedDigit()
                Spacer()
                Text("-\(playbackTimeText(duration - elapsed))")
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private func effectivePlaybackDuration(
    timeline: PlaybackTimeline,
    fallbackDuration: TimeInterval,
    isPlaybackActive: Bool
) -> TimeInterval {
    isPlaybackActive ? timeline.duration : fallbackDuration
}

@MainActor
private func displayedPlaybackElapsed(
    timeline: PlaybackTimeline,
    fallbackDuration: TimeInterval,
    isPlaybackActive: Bool,
    isScrubbing: Bool,
    scrubElapsed: TimeInterval
) -> TimeInterval {
    guard isPlaybackActive else { return 0 }
    let duration = effectivePlaybackDuration(
        timeline: timeline,
        fallbackDuration: fallbackDuration,
        isPlaybackActive: isPlaybackActive
    )
    let upperBound = duration > 0 ? duration : max(timeline.elapsed, 0)
    if isScrubbing {
        return min(max(scrubElapsed, 0), upperBound)
    }
    if let seekTarget = timeline.seekTarget, duration > 0 {
        return min(max(seekTarget, 0), duration)
    }
    return min(max(timeline.elapsed, 0), upperBound)
}

private func playbackTimeText(_ value: TimeInterval) -> String {
    let totalSeconds = Int(max(value.isFinite ? value : 0, 0).rounded())
    return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = CenteredMPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.clipsToBounds = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        styleIfNeeded(view, context: context)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.showsVolumeSlider = true
        styleIfNeeded(view, context: context)
    }

    final class Coordinator {
        var didSyncInitialVolume = false
        var didStyleSlider = false
    }

    private final class CenteredMPVolumeView: MPVolumeView {
        override func layoutSubviews() {
            super.layoutSubviews()
            clipsToBounds = false
            for subview in subviews {
                guard let slider = subview as? UISlider else {
                    subview.isHidden = true
                    subview.isUserInteractionEnabled = false
                    continue
                }
                slider.frame = bounds
                slider.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                slider.clipsToBounds = false
                slider.layer.masksToBounds = false
            }
        }
    }

    private func styleIfNeeded(_ view: MPVolumeView, context: Context) {
        UIView.performWithoutAnimation {
            view.tintColor = .musicRed
            view.clipsToBounds = false
            var foundSlider = false
            for subview in view.subviews {
                guard let slider = subview as? UISlider else {
                    subview.isHidden = true
                    subview.isUserInteractionEnabled = false
                    continue
                }
                foundSlider = true
                slider.minimumTrackTintColor = .musicRed
                slider.maximumTrackTintColor = .musicSliderTrack
                slider.thumbTintColor = .musicSliderThumb
                slider.clipsToBounds = false
                slider.layer.masksToBounds = false
                slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
                slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                slider.frame = view.bounds
                slider.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                if !context.coordinator.didSyncInitialVolume {
                    slider.setValue(AVAudioSession.sharedInstance().outputVolume, animated: false)
                }
            }
            context.coordinator.didStyleSlider = foundSlider
            context.coordinator.didSyncInitialVolume = context.coordinator.didSyncInitialVolume || foundSlider
        }
    }
}

private struct PlayerPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let imageURL: URL?

    @State private var palette: BackdropPalette?
    @State private var loadedImageURL: URL?

    var body: some View {
        let isDark = colorScheme == .dark

        ZStack {
            Color.musicPageBackground

            if let palette {
                LinearGradient(
                    stops: [
                        .init(color: palette.top.swiftUIColor.opacity(isDark ? 0.46 : 0.38), location: 0.00),
                        .init(color: palette.middle.swiftUIColor.opacity(isDark ? 0.34 : 0.24), location: 0.36),
                        .init(color: palette.bottom.swiftUIColor.opacity(isDark ? 0.24 : 0.24), location: 0.72),
                        .init(color: Color.musicPageBackground.opacity(isDark ? 0.74 : 0.92), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blur(radius: 12)
                .saturation(0.92)
                .transition(.opacity)
            }

            Color.musicPageBackground.opacity(isDark ? 0.32 : 0.16)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: palette)
        .task(id: imageURL) {
            await updatePalette(for: imageURL)
        }
    }

    @MainActor
    private func updatePalette(for imageURL: URL?) async {
        guard loadedImageURL != imageURL else { return }
        loadedImageURL = imageURL

        guard let imageURL else {
            palette = nil
            return
        }

        let extractedPalette = await ColorExtractor.palette(for: imageURL)
        guard loadedImageURL == imageURL else { return }
        palette = extractedPalette ?? .fallback
    }
}

private struct BackdropPalette: Equatable, Sendable {
    let top: PaletteColor
    let middle: PaletteColor
    let bottom: PaletteColor

    static let fallback = BackdropPalette(
        top: PaletteColor(red: 0.50, green: 0.52, blue: 0.56),
        middle: PaletteColor(red: 0.72, green: 0.73, blue: 0.76),
        bottom: PaletteColor(red: 0.95, green: 0.95, blue: 0.97)
    )
}

private struct PaletteColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }
}

private enum ColorExtractor {
    static func palette(for imageURL: URL) async -> BackdropPalette? {
        let request = URLRequest(url: imageURL)

        if let cachedResponse = URLCache.shared.cachedResponse(for: request),
           let palette = await palette(from: cachedResponse.data) {
            return palette
        }

        if let diskData = ArtworkDiskCache.dataSync(for: imageURL),
           let palette = await palette(from: diskData) {
            return palette
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            await ArtworkDiskCache.insert(data, for: imageURL)
            return await palette(from: data)
        } catch {
            return nil
        }
    }

    private static func palette(from data: Data) async -> BackdropPalette? {
        await Task.detached(priority: .utility) {
            guard
                let image = UIImage(data: data),
                let cgImage = image.cgImage
            else {
                return nil
            }

            return makePalette(from: cgImage)
        }.value
    }

    private static func makePalette(from cgImage: CGImage) -> BackdropPalette? {
        let side = 22
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var samples: [PaletteSample] = []
        samples.reserveCapacity(side * side)

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.7 else { continue }

            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let brightness = max(red, green, blue)
            let saturation = saturation(red: red, green: green, blue: blue)
            guard brightness > 0.10, brightness < 0.96 else { continue }

            samples.append(PaletteSample(red: red, green: green, blue: blue, saturation: saturation, brightness: brightness))
        }

        guard !samples.isEmpty else { return nil }

        let vibrant = samples.max { lhs, rhs in
            lhs.saturation * 0.72 + lhs.brightness * 0.28 < rhs.saturation * 0.72 + rhs.brightness * 0.28
        } ?? samples[0]

        let calm = samples.min { lhs, rhs in
            abs(lhs.brightness - 0.58) + lhs.saturation * 0.2 < abs(rhs.brightness - 0.58) + rhs.saturation * 0.2
        } ?? vibrant

        return BackdropPalette(
            top: vibrant.mixed(withWhite: 0.18),
            middle: calm.mixed(withWhite: 0.38),
            bottom: vibrant.mixed(withWhite: 0.72)
        )
    }

    private static func saturation(red: Double, green: Double, blue: Double) -> Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        guard maximum > 0 else { return 0 }
        return (maximum - minimum) / maximum
    }
}

private struct PaletteSample {
    let red: Double
    let green: Double
    let blue: Double
    let saturation: Double
    let brightness: Double

    func mixed(withWhite amount: Double) -> PaletteColor {
        let clampedAmount = min(max(amount, 0), 1)
        return PaletteColor(
            red: red + (1 - red) * clampedAmount,
            green: green + (1 - green) * clampedAmount,
            blue: blue + (1 - blue) * clampedAmount
        )
    }
}

private struct TimedLyricAnchor: Equatable {
    let lineIndex: Int
    let time: TimeInterval
}

private struct TimedLyricIndexCache: Equatable {
    var version = ""
    var anchors: [TimedLyricAnchor] = []
}

struct LyricsPanelView: View {
    @EnvironmentObject private var player: PlayerController
    let song: EmbyAudioItem
    @ObservedObject var timeline: PlaybackTimeline
    let fallbackDuration: TimeInterval
    let isPlaybackActive: Bool
    let scrubElapsed: TimeInterval
    let isScrubbing: Bool
    @State private var lastAutoScrollAt = Date.distantPast
    @State private var timedLyricIndexCache = TimedLyricIndexCache()

    private let autoScrollInterval: TimeInterval = 0.35
    private let lyricActivationLeadTime: TimeInterval = 0.35

    private var playbackElapsed: TimeInterval {
        displayedPlaybackElapsed(
            timeline: timeline,
            fallbackDuration: fallbackDuration,
            isPlaybackActive: isPlaybackActive,
            isScrubbing: isScrubbing,
            scrubElapsed: scrubElapsed
        )
    }

    private var playbackDuration: TimeInterval {
        effectivePlaybackDuration(
            timeline: timeline,
            fallbackDuration: fallbackDuration,
            isPlaybackActive: isPlaybackActive
        )
    }

    private var lines: [LyricLine] {
        guard player.lyricsSongId == song.id else {
            return [LyricLine(id: -2, time: nil, text: "暂无歌词")]
        }
        if !player.lyrics.isEmpty {
            return player.lyrics
        }
        if player.isLoadingLyrics {
            return [LyricLine(id: -1, time: nil, text: "正在读取歌曲内置歌词")]
        }
        return [LyricLine(id: -2, time: nil, text: "暂无歌词")]
    }

    var body: some View {
        ZStack {
            Color.clear
            if isPlaceholderLyrics {
                placeholderView
            } else {
                lyricsScrollView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var lyricsScrollView: some View {
        let activeIndex = activeLyricIndex
        let activeID = activeLyricId(for: activeIndex)

        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            let isActive = activeIndex == index
                            Button {
                                player.seek(toLyric: line)
                            } label: {
                                Text(line.text)
                                    .font(.system(size: isActive ? 24 : 19, weight: .bold))
                                    .lineSpacing(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(isActive ? .primary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .id(line.id)
                            .buttonStyle(.plain)
                            .disabled(line.time == nil)
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: max(geometry.size.height, 1), alignment: .center)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    refreshTimedLyricIndexCache()
                    DispatchQueue.main.async {
                        scrollToActiveLyric(activeID, using: proxy, animated: false)
                    }
                }
                .onChange(of: song.id) { _, _ in
                    refreshTimedLyricIndexCache()
                    DispatchQueue.main.async {
                        scrollToActiveLyric(activeID, using: proxy, animated: false)
                    }
                }
                .onChange(of: lyricsScrollVersion) { _, _ in
                    refreshTimedLyricIndexCache()
                    DispatchQueue.main.async {
                        scrollToActiveLyric(activeID, using: proxy, animated: false)
                    }
                }
                .onChange(of: activeID) { _, id in
                    guard let id else { return }
                    let now = Date()
                    guard now.timeIntervalSince(lastAutoScrollAt) >= autoScrollInterval else { return }
                    lastAutoScrollAt = now
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var placeholderView: some View {
        Text(lines.first?.text ?? "暂无歌词")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
    }

    private var isPlaceholderLyrics: Bool {
        lines.count == 1 && lines[0].id < 0 && lines[0].time == nil
    }

    private var activeLyricIndex: Int {
        guard !lines.isEmpty else { return 0 }
        if let timedIndex = activeTimedLyricIndex {
            return timedIndex
        }

        let duration = max(playbackDuration, 1)
        let progress = min(max(playbackElapsed / duration, 0), 0.999)
        return min(Int(progress * Double(lines.count)), lines.count - 1)
    }

    private var activeTimedLyricIndex: Int? {
        let anchors = currentTimedLyricAnchors
        guard !anchors.isEmpty else { return nil }

        let adjustedElapsed = playbackElapsed + lyricActivationLeadTime
        var lowerBound = 0
        var upperBound = anchors.count
        var bestIndex: Int?

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            let anchor = anchors[middle]

            if anchor.time <= adjustedElapsed {
                bestIndex = anchor.lineIndex
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return bestIndex
    }

    private func activeLyricId(for activeIndex: Int) -> Int? {
        guard lines.indices.contains(activeIndex) else { return nil }
        return lines[activeIndex].id
    }

    private var lyricsScrollVersion: String {
        "\(song.id)-\(lines.count)-\(lines.first?.id ?? Int.min)-\(lines.last?.id ?? Int.min)"
    }

    private var currentTimedLyricAnchors: [TimedLyricAnchor] {
        timedLyricIndexCache.version == lyricsScrollVersion
            ? timedLyricIndexCache.anchors
            : Self.makeTimedLyricAnchors(from: lines)
    }

    private func refreshTimedLyricIndexCache() {
        timedLyricIndexCache = TimedLyricIndexCache(
            version: lyricsScrollVersion,
            anchors: Self.makeTimedLyricAnchors(from: lines)
        )
    }

    private static func makeTimedLyricAnchors(from lines: [LyricLine]) -> [TimedLyricAnchor] {
        lines.enumerated().compactMap { index, line in
            guard let time = line.time else { return nil }
            return TimedLyricAnchor(lineIndex: index, time: time)
        }
    }

    private func scrollToActiveLyric(_ activeLyricId: Int?, using proxy: ScrollViewProxy, animated: Bool) {
        guard let activeLyricId else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(activeLyricId, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeLyricId, anchor: .center)
        }
    }
}

struct QueuePlayerView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController
    @State private var isReordering = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("接下来播放")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.isShuffleEnabled ? Color.musicRed : .secondary)
                }
                .buttonStyle(.plain)

                Button {
                    player.cycleRepeatMode()
                } label: {
                    Image(systemName: player.repeatMode.iconName)
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.repeatMode == .none ? .secondary : Color.musicRed)
                }
                .buttonStyle(.plain)

                Button {
                    player.clearUpcomingQueue()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.upcomingQueueSnapshot.isEmpty ? Color.secondary.opacity(0.35) : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(player.upcomingQueueSnapshot.isEmpty)

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isReordering.toggle()
                    }
                } label: {
                    Image(systemName: isReordering ? "checkmark" : "arrow.up.arrow.down")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

            if player.upcomingQueueSnapshot.isEmpty {
                ContentUnavailableView("没有待播放歌曲", systemImage: "music.note.list")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(player.upcomingQueueSnapshot.enumerated()), id: \.element.id) { index, song in
                            queueRow(song: song, index: index)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func queueRow(song: EmbyAudioItem, index: Int) -> some View {
        HStack(spacing: 10) {
            ArtworkView(url: store.imageURL(for: song, size: 120), cornerRadius: 5)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(song.artistLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isReordering {
                HStack(spacing: 2) {
                    Button {
                        player.moveUpcomingQueueItem(from: index, to: index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 30, height: 30)
                    }
                    .disabled(index == 0)

                    Button {
                        player.moveUpcomingQueueItem(from: index, to: index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 30, height: 30)
                    }
                    .disabled(index >= player.upcomingQueueSnapshot.count - 1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    player.removeUpcomingQueueItem(at: index)
                } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 30, height: 30)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isReordering else { return }
            player.playQueued(song: song)
        }
    }
}

private enum PlayerMode {
    case nowPlaying
    case lyrics
    case queue
}

extension Notification.Name {
    static let lyricsTapped = Notification.Name("LyricsPlayerViewTapped")
}
