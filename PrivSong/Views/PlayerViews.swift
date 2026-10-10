import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct MiniPlayerView: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var player: PlayerController

    let expand: () -> Void

    var body: some View {
        let song = player.currentSong ?? store.lastPlayedSong
        let isInline = accessoryPlacement == .inline
        let artworkURL = song.flatMap { store.imageURL(for: $0, size: 160) }
        let artworkSize: CGFloat = 36
        let artworkCornerRadius: CGFloat = 8
        let cornerRadius: CGFloat = isInline ? 26 : 16
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        HStack(spacing: 10) {
            // A real button (not a tap gesture) so VoiceOver and keyboard users can open the player.
            Button(action: openPlayer) {
                HStack(spacing: 10) {
                    if song != nil {
                        ArtworkView(url: artworkURL, cornerRadius: artworkCornerRadius)
                            .frame(width: artworkSize, height: artworkSize)
                            .transaction { transaction in
                                transaction.disablesAnimations = true
                            }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                                .fill(.primary.opacity(0.08))
                            Image(systemName: "music.note")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: artworkSize, height: artworkSize)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song?.name ?? "暂无歌曲")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(miniSubtitle(for: song))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityHint("打开播放页")

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
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

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
            .accessibilityLabel("下一首")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .frame(maxWidth: 430, alignment: .leading)
        // The accessory bar has a fixed height; cap text growth so it never clips.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        // No custom fill: the bottom accessory already sits in the system Liquid Glass capsule,
        // the same material as the tab bar. Painting over it made the two look different.
        .contentShape(shape)
        .transaction { transaction in
            transaction.animation = nil
        }
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
    @Environment(AppStore.self) private var store
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
        let volumeHeight = PlayerVolumeMetrics.height
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
                .frame(width: contentWidth, height: transportHeight, alignment: .center)

            Color.clear.frame(height: middleGap)

            volumeControl
                .frame(width: contentWidth, height: volumeHeight, alignment: .center)

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
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("前往专辑")

                Button {
                    onOpenArtist(song)
                } label: {
                    Text(song.artistLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("前往艺术家")
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
            .accessibilityLabel(store.isFavorite(song) ? "取消喜欢" : "喜欢")
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
            .buttonStyle(.plain)
            .accessibilityLabel("上一首")

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
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 48, height: 52)
            }
            .disabled(player.currentSong == nil)
            .opacity(player.currentSong == nil ? 0.42 : 1)
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")

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
        .accessibilityLabel("随机播放")
        .accessibilityValue(player.isShuffleEnabled ? "开" : "关")
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
        .accessibilityLabel("重复播放")
        .accessibilityValue(player.repeatMode.accessibilityValue)
    }

    private var volumeControl: some View {
        let iconOffsetY: CGFloat = -0.4
        let height = PlayerVolumeMetrics.height

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: height, alignment: .center)
                .offset(y: iconOffsetY)
                .accessibilityHidden(true)
            SystemVolumeSlider()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: height, alignment: .center)
                .offset(y: iconOffsetY)
                .accessibilityHidden(true)
        }
        .frame(height: height, alignment: .center)
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
        .accessibilityLabel("睡眠定时")
        .accessibilityValue(sleepTimerRemainingText.map { "剩余 \($0)" } ?? "关")
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
        .accessibilityLabel(target.accessibilityLabel)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
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
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(playbackTimeText(elapsed)) / \(playbackTimeText(duration))")

            HStack {
                Text(playbackTimeText(elapsed))
                    .monospacedDigit()
                Spacer()
                Text("-\(playbackTimeText(duration - elapsed))")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            // The slider already announces the position.
            .accessibilityHidden(true)
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

private enum PlayerVolumeMetrics {
    static let height: CGFloat = 32
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> VolumeSliderContainer {
        VolumeSliderContainer()
    }

    func updateUIView(_ view: VolumeSliderContainer, context: Context) {
        view.refreshIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: VolumeSliderContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: PlayerVolumeMetrics.height)
    }
}

final class VolumeSliderContainer: UIView {
    private let visibleSlider = UISlider(frame: .zero)
    private let hiddenVolumeView = MPVolumeView(frame: .zero)
    private var systemSlider: UISlider?
    private var volumeObservation: NSKeyValueObservation?
    private var isPushingVolumeToSystem = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        volumeObservation?.invalidate()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: PlayerVolumeMetrics.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        visibleSlider.frame = bounds
        hiddenVolumeView.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
        refreshSystemSlider()
    }

    func refreshIfNeeded() {
        refreshSystemSlider()
    }

    private func configure() {
        clipsToBounds = false

        hiddenVolumeView.showsVolumeSlider = true
        hiddenVolumeView.alpha = 0.01
        hiddenVolumeView.isUserInteractionEnabled = false
        hiddenVolumeView.clipsToBounds = false
        hiddenVolumeView.setContentHuggingPriority(.required, for: .vertical)
        hiddenVolumeView.setContentCompressionResistancePriority(.required, for: .vertical)

        visibleSlider.minimumValue = 0
        visibleSlider.maximumValue = 1
        visibleSlider.value = AVAudioSession.sharedInstance().outputVolume
        visibleSlider.minimumTrackTintColor = .musicRed
        visibleSlider.accessibilityLabel = "音量"
        visibleSlider.clipsToBounds = false
        visibleSlider.layer.masksToBounds = false
        visibleSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        visibleSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        visibleSlider.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)

        addSubview(hiddenVolumeView)
        addSubview(visibleSlider)

        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.initial, .new]
        ) { [weak self] session, _ in
            DispatchQueue.main.async {
                self?.syncVisibleVolume(session.outputVolume)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.refreshSystemSlider()
            self?.syncVisibleVolume(AVAudioSession.sharedInstance().outputVolume)
        }
    }

    private func refreshSystemSlider() {
        guard let slider = hiddenVolumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            return
        }
        systemSlider = slider
        slider.isHidden = true
        slider.isUserInteractionEnabled = false
    }

    private func syncVisibleVolume(_ value: Float) {
        guard !visibleSlider.isTracking, !isPushingVolumeToSystem else { return }
        visibleSlider.value = value
    }

    @objc
    private func volumeChanged(_ sender: UISlider) {
        refreshSystemSlider()
        guard let slider = systemSlider else { return }
        isPushingVolumeToSystem = true
        slider.setValue(sender.value, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        isPushingVolumeToSystem = false
    }
}

private struct PlayerPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    let imageURL: AuthenticatedURL?

    @State private var palette: BackdropPalette?
    @State private var loadedImageURL: AuthenticatedURL?

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
                // No blur: blurring an already smooth gradient changed nothing visible but cost a
                // full-screen offscreen pass on every frame of the player page.
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
    private func updatePalette(for imageURL: AuthenticatedURL?) async {
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
    static func palette(for imageURL: AuthenticatedURL) async -> BackdropPalette? {
        let request = imageURL.request

        if let cachedResponse = URLCache.shared.cachedResponse(for: request),
           let palette = await palette(from: cachedResponse.data) {
            return palette
        }

        if let diskData = ArtworkDiskCache.dataSync(for: imageURL.url),
           let palette = await palette(from: diskData) {
            return palette
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            await ArtworkDiskCache.insert(data, for: imageURL.url)
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
    @State private var timedLyricIndexCache = TimedLyricIndexCache()

    /// Small head start so a line is highlighted as it begins, allowing for the scroll animation.
    private let lyricActivationLeadTime: TimeInterval = 0.15

    /// Position used to pick the active line. Reads AVPlayer directly: the shared timeline only
    /// updates every 0.5 s, which made lines switch up to half a second off.
    private var lyricElapsed: TimeInterval {
        guard isPlaybackActive else { return 0 }
        if isScrubbing {
            return scrubElapsed
        }
        if let seekTarget = timeline.seekTarget {
            return seekTarget
        }
        return player.precisePlaybackTime
    }

    private var isLyricClockRunning: Bool {
        isPlaybackActive && player.isPlaying && !isScrubbing
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
            // Requested on appear; about to start loading.
            return [LyricLine(id: -1, time: nil, text: "正在读取歌曲内置歌词")]
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
        // Lyrics are only read while this panel is on screen, and again when the track changes.
        .task(id: song.id) {
            player.loadLyricsIfNeeded(for: song)
        }
    }

    private var lyricsScrollView: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                // Re-evaluated about 10 times a second while playing (paused otherwise) so the
                // highlighted line follows the audio closely.
                TimelineView(.animation(minimumInterval: 0.1, paused: !isLyricClockRunning)) { _ in
                    let lines = self.lines
                    let activeIndex = activeLyricIndex(at: lyricElapsed, in: lines)
                    let activeID = activeLyricId(for: activeIndex, in: lines)

                    ScrollView {
                        // Not lazy: `scrollTo(_:anchor: .center)` needs real row heights. A lazy stack
                        // estimates heights for rows it hasn't built, which left the active line
                        // off-centre.
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                let isActive = activeIndex == index
                                Button {
                                    player.seek(toLyric: line)
                                } label: {
                                    // One text style for every line (scales with Dynamic Type); the
                                    // active line is emphasised with a scale effect, which animates
                                    // without re-laying out the text like switching fonts did.
                                    Text(line.text)
                                        .font(.title2.bold())
                                        .lineSpacing(2)
                                        .multilineTextAlignment(.leading)
                                        .foregroundStyle(isActive ? .primary : .secondary)
                                        .scaleEffect(isActive ? 1 : 0.84, anchor: .leading)
                                        .animation(.easeOut(duration: 0.2), value: isActive)
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
                        // Scroll on every line change. The old 0.35 s throttle dropped scrolls for
                        // quick lines and never caught up, leaving the view behind the audio.
                        scrollToActiveLyric(id, using: proxy, animated: true)
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
            .font(.title3.bold())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
    }

    private var isPlaceholderLyrics: Bool {
        lines.count == 1 && lines[0].id < 0 && lines[0].time == nil
    }

    private func activeLyricIndex(at elapsed: TimeInterval, in lines: [LyricLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let anchors = currentTimedLyricAnchors
        if !anchors.isEmpty {
            // Before the first timed line, stay on it rather than falling through to the
            // progress-based estimate meant for untimed lyrics.
            return activeTimedLyricIndex(at: elapsed, anchors: anchors) ?? anchors[0].lineIndex
        }

        // Untimed lyrics: approximate by playback progress.
        let duration = max(playbackDuration, 1)
        let progress = min(max(elapsed / duration, 0), 0.999)
        return min(Int(progress * Double(lines.count)), lines.count - 1)
    }

    private func activeTimedLyricIndex(at elapsed: TimeInterval, anchors: [TimedLyricAnchor]) -> Int? {
        let adjustedElapsed = elapsed + lyricActivationLeadTime
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

    private func activeLyricId(for activeIndex: Int, in lines: [LyricLine]) -> Int? {
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
    @Environment(AppStore.self) private var store
    @EnvironmentObject private var player: PlayerController
    @State private var editMode: EditMode = .inactive

    var body: some View {
        let upcoming = player.upcomingQueueSnapshot

        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("接下来播放")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.isShuffleEnabled ? Color.musicRed : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("随机播放")
                .accessibilityValue(player.isShuffleEnabled ? "开" : "关")

                Button {
                    player.cycleRepeatMode()
                } label: {
                    Image(systemName: player.repeatMode.iconName)
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.repeatMode == .none ? .secondary : Color.musicRed)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重复播放")
                .accessibilityValue(player.repeatMode.accessibilityValue)

                Button {
                    player.clearUpcomingQueue()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(upcoming.isEmpty ? Color.secondary.opacity(0.35) : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(upcoming.isEmpty)
                .accessibilityLabel("清空待播放")

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                } label: {
                    Image(systemName: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .disabled(upcoming.isEmpty)
                .accessibilityLabel(editMode.isEditing ? "完成" : "调整顺序")
            }

            if upcoming.isEmpty {
                ContentUnavailableView("没有待播放歌曲", systemImage: "music.note.list")
                    .foregroundStyle(.secondary)
            } else {
                // System list: drag handles in edit mode, swipe to delete otherwise.
                List {
                    ForEach(upcoming) { song in
                        queueRow(song: song)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        // `onMove` reports the destination before removal; the player expects
                        // the final index.
                        player.moveUpcomingQueueItem(from: from, to: destination > from ? destination - 1 : destination)
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) {
                            player.removeUpcomingQueueItem(at: index)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .environment(\.editMode, $editMode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: upcoming.isEmpty) { _, isEmpty in
            if isEmpty {
                editMode = .inactive
            }
        }
    }

    private func queueRow(song: EmbyAudioItem) -> some View {
        Button {
            player.playQueued(song: song)
        } label: {
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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(editMode.isEditing)
        .accessibilityElement(children: .combine)
    }
}

private enum PlayerMode {
    case nowPlaying
    case lyrics
    case queue

    var accessibilityLabel: String {
        switch self {
        case .nowPlaying:
            return "正在播放"
        case .lyrics:
            return "歌词"
        case .queue:
            return "播放队列"
        }
    }
}

private extension RepeatMode {
    var accessibilityValue: String {
        switch self {
        case .none:
            return "关"
        case .all:
            return "全部重复"
        case .one:
            return "单曲重复"
        }
    }
}

extension Notification.Name {
    static let lyricsTapped = Notification.Name("LyricsPlayerViewTapped")
}
