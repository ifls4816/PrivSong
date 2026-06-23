import MediaPlayer
import SwiftUI

struct MiniPlayerView: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController

    var visibility = 1.0
    let expand: () -> Void

    var body: some View {
        let song = player.currentSong ?? store.lastPlayedSong
        let isInline = accessoryPlacement == .inline
        let artworkURL = song.flatMap { store.imageURL(for: $0, size: 160) }
        let verticalPadding: CGFloat = isInline ? 6 : 8
        let horizontalPadding: CGFloat = isInline ? 10 : 12
        let artworkSize: CGFloat = isInline ? 32 : 38
        let cornerRadius: CGFloat = isInline ? 26 : 16
        let titleSize: CGFloat = isInline ? 14 : 15
        let subtitleSize: CGFloat = isInline ? 10.5 : 11
        let progressOpacity = isInline ? 0.0 : 1.0
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if song != nil {
                    ArtworkView(url: artworkURL, cornerRadius: isInline ? 7 : 8)
                        .frame(width: artworkSize, height: artworkSize)
                        .allowsHitTesting(false)
                        .transaction { transaction in
                            transaction.disablesAnimations = true
                        }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: isInline ? 7 : 8, style: .continuous)
                            .fill(.primary.opacity(0.08))
                        Image(systemName: "music.note")
                            .font(.system(size: isInline ? 13 : 15, weight: .semibold))
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
                .minimumScaleFactor(0.82)

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
                .opacity(isInline ? 0.9 : 1)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)

            ProgressView(value: player.currentSong != nil && player.duration > 0 ? player.elapsed / player.duration : 0)
                .tint(.secondary.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.bottom, 1)
                .opacity(progressOpacity)
                .frame(height: 3)
        }
        .background(Color.musicMiniPlayerBackground, in: shape)
        .overlay {
            shape.strokeBorder(Color.musicSeparatorStroke, lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(isInline ? 0.05 : 0.08), radius: isInline ? 8 : 14, y: isInline ? 3 : 6)
        .opacity(visibility)
        .contentShape(shape)
        .onTapGesture(perform: expand)
        .allowsHitTesting(visibility > 0.95)
        .animation(.easeOut(duration: 0.2), value: visibility)
    }

    private func miniSubtitle(for song: EmbyAudioItem?) -> String {
        return song.map { $0.artistLine.isEmpty ? "暂无艺术家" : $0.artistLine } ?? "播放后会显示当前歌曲"
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerController
    @Binding var collapseProgress: Double
    let onOpenAlbum: (EmbyAudioItem) -> Void
    let onOpenArtist: (EmbyAudioItem) -> Void
    let onDismiss: () -> Void

    @State private var mode: PlayerMode = .nowPlaying
    @State private var scrubProgress = 0.0
    @State private var isScrubbing = false

    // Smooth dismiss: single @State, no GestureState snap-back
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var screenHeight: CGFloat = 0
    @State private var isSleepTimerDialogPresented = false
    @State private var sleepTimerRemainingSnapshot: String?
    @State private var revealPlayerControls = false
    @State private var isPresented = false

    private var cornerRadius: CGFloat {
        dragOffset > 0 && !isDismissing ? 28 : (isPresented ? 0 : 28)
    }

    private var controlsRevealProgress: Double {
        revealPlayerControls ? 1 : 0
    }

    private var presentationOffset: CGFloat {
        isPresented ? 0 : max(screenHeight * 0.72, 420)
    }

    private func liveProgress(for song: EmbyAudioItem) -> Double {
        guard player.currentSong != nil, effectiveDuration(for: song) > 0 else { return 0 }
        return min(max(player.elapsed / effectiveDuration(for: song), 0), 1)
    }

    private func displayedProgress(for song: EmbyAudioItem) -> Double {
        (isScrubbing || player.isSeeking) ? scrubProgress : liveProgress(for: song)
    }

    private func displayedElapsed(for song: EmbyAudioItem) -> TimeInterval {
        guard player.currentSong != nil else { return 0 }
        let duration = effectiveDuration(for: song)
        guard duration > 0 else { return player.elapsed }
        return displayedProgress(for: song) * duration
    }

    private func effectiveDuration(for song: EmbyAudioItem) -> TimeInterval {
        player.currentSong == nil ? song.duration : player.duration
    }

    var body: some View {
        if let song = player.currentSong ?? store.lastPlayedSong {
            GeometryReader { proxy in
                let size = proxy.size
                let topInset = max(proxy.safeAreaInsets.top, 44)
                ZStack {
                    PlayerBackdrop(imageURL: store.imageURL(for: song), size: size)

                    VStack(spacing: 0) {
                        grabber(topInset: topInset)
                            .opacity(controlsRevealProgress)

                        nowPlayingPage(song: song, size: size)
                            .frame(width: size.width)
                    }
                    .frame(width: size.width, height: size.height, alignment: .top)
                }
                .frame(width: size.width, height: size.height)
                .onAppear { screenHeight = size.height }
            }
            .clipShape(
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: cornerRadius,
                        bottomLeading: 0,
                        bottomTrailing: 0,
                        topTrailing: cornerRadius
                    ),
                    style: .continuous
                )
            )
            .offset(y: dragOffset + presentationOffset)
            .ignoresSafeArea()
            .gesture(isDismissing ? nil : dragGesture)
            .onAppear {
                isPresented = false
                revealPlayerControls = false
                UIApplication.shared.isIdleTimerDisabled = store.keepsScreenAwakeOnPlayerPage
                withAnimation(.easeOut(duration: 0.28)) {
                    isPresented = true
                }
                withAnimation(.easeOut(duration: 0.22).delay(0.12)) {
                    revealPlayerControls = true
                }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                revealPlayerControls = false
                isPresented = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .lyricsTapped)) { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    mode = .nowPlaying
                }
            }
            .onChange(of: store.keepsScreenAwakeOnPlayerPage) { _, enabled in
                UIApplication.shared.isIdleTimerDisabled = enabled
            }
            .onChange(of: player.isSeeking) { _, isSeeking in
                if !isSeeking, isScrubbing {
                    isScrubbing = false
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = value.translation.height
                    collapseProgress = min(max(Double(value.translation.height / 320), 0), 1)
                }
            }
            .onEnded { value in
                let shouldDismiss = value.translation.height > 120 ||
                                    value.predictedEndTranslation.height > 240
                if shouldDismiss {
                    withAnimation(.interpolatingSpring(stiffness: 240, damping: 28)) {
                        isDismissing = true
                        revealPlayerControls = false
                        isPresented = true
                        dragOffset = screenHeight + 40
                        collapseProgress = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                        dragOffset = 0
                        isDismissing = false
                        onDismiss()
                    }
                } else {
                    withAnimation(.interpolatingSpring(stiffness: 400, damping: 32)) {
                        dragOffset = 0
                        collapseProgress = 0
                    }
                }
            }
    }

    private func grabber(topInset: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.34))
            .frame(width: 46, height: 5)
            .padding(.top, topInset + 18)
            .padding(.bottom, 6)
    }

    private func nowPlayingPage(song: EmbyAudioItem, size: CGSize) -> some View {
        let contentWidth = min(size.width - 48, 352)
        let compactHeight = size.height < 760
        let artworkSize = min(contentWidth * (compactHeight ? 0.82 : 0.90), compactHeight ? 276 : 332)
        let upperHeight = min(artworkSize + (compactHeight ? 26 : 34), compactHeight ? 304 : 366)
        let topOffset: CGFloat = compactHeight ? 34 : 42
        let titleGap: CGFloat = compactHeight ? 16 : 20
        let progressGap: CGFloat = compactHeight ? 10 : 12
        let controlsProgress = controlsRevealProgress

        return VStack(spacing: 0) {
            Color.clear.frame(height: topOffset)

            upperContent(song: song, width: contentWidth, height: upperHeight, artworkSize: artworkSize)

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
                    screenWidth: size.width,
                    height: lowerProxy.size.height,
                    compactHeight: compactHeight,
                    song: song
                )
            }
            .frame(maxHeight: .infinity)
            .opacity(controlsProgress)
            .offset(y: controlsProgress == 1 ? 0 : 18)
        }
        .frame(width: size.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
    }

    private func lowerControls(contentWidth: CGFloat, screenWidth: CGFloat, height: CGFloat, compactHeight: Bool, song: EmbyAudioItem) -> some View {
        let topGap = min(max(height * 0.045, compactHeight ? 8 : 12), compactHeight ? 18 : 24)
        let middleGap = min(max(height * 0.045, compactHeight ? 8 : 12), compactHeight ? 18 : 24)
        let lowerGap = min(max(height * 0.035, compactHeight ? 6 : 10), compactHeight ? 14 : 20)

        return VStack(spacing: 0) {
            Spacer(minLength: topGap)

            transportControls(width: contentWidth, song: song)

            Spacer(minLength: middleGap)

            playbackModeControls(width: contentWidth)

            Spacer(minLength: compactHeight ? 6 : 8)

            volumeControl
                .frame(width: contentWidth)

            Spacer(minLength: lowerGap)

            bottomBar(width: screenWidth)
                .frame(height: compactHeight ? 60 : 68, alignment: .top)
        }
        .frame(width: screenWidth, height: height, alignment: .bottom)
    }

    @ViewBuilder
    private func upperContent(song: EmbyAudioItem, width: CGFloat, height: CGFloat, artworkSize: CGFloat) -> some View {
        switch mode {
        case .nowPlaying:
            ArtworkView(url: store.imageURL(for: song), cornerRadius: 10)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipped()
                .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
                .frame(width: width, height: height, alignment: .top)
        case .lyrics:
            LyricsPanelView(song: song)
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
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    onOpenArtist(song)
                } label: {
                    Text(song.artistLine)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
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
                    .background(.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.78))
        }
    }

    private func progressControls(song: EmbyAudioItem) -> some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { displayedProgress(for: song) },
                set: { scrubProgress = $0 }
            ), in: 0...1) { editing in
                if editing {
                    if !isScrubbing {
                        scrubProgress = liveProgress(for: song)
                    }
                    isScrubbing = true
                } else {
                    player.seek(to: scrubProgress)
                }
            }
            .tint(.white)
            .disabled(player.currentSong == nil)

            HStack {
                let elapsed = displayedElapsed(for: song)
                let duration = effectiveDuration(for: song)
                Text(elapsed.musicDurationText)
                    .monospacedDigit()
                Spacer()
                Text("-\(max(duration - elapsed, 0).musicDurationText)")
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.48))
        }
    }

    private func transportControls(width: CGFloat, song: EmbyAudioItem) -> some View {
        HStack(spacing: 42) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 29, weight: .semibold))
                    .frame(width: 52, height: 52)
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
                            .controlSize(.regular)
                            .tint(.white)
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
                    .font(.system(size: 29, weight: .semibold))
                    .frame(width: 52, height: 52)
            }
            .disabled(player.currentSong == nil)
            .opacity(player.currentSong == nil ? 0.42 : 1)
        }
        .frame(width: width)
        .foregroundStyle(.white)
    }

    private func playbackModeControls(width: CGFloat) -> some View {
        HStack(spacing: 28) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 30)
                    .foregroundStyle(player.isShuffleEnabled ? .white : .white.opacity(0.42))
            }
            .buttonStyle(.plain)

            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode.iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 30)
                    .foregroundStyle(player.repeatMode == .none ? .white.opacity(0.42) : .white)
            }
            .buttonStyle(.plain)
        }
        .frame(width: width)
    }

    private var volumeControl: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .semibold))
            SystemVolumeSlider()
                .frame(height: 20)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.66))
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
        Button {
            sleepTimerRemainingSnapshot = player.sleepTimerEndDate.map { sleepTimerRemainingText(until: $0, from: Date()) }
            isSleepTimerDialogPresented = true
        } label: {
            Image(systemName: "moon.zzz")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 34, height: 28)
                .foregroundStyle(player.sleepTimerEndDate == nil ? .white.opacity(0.42) : .white.opacity(0.92))
        }
        .buttonStyle(.plain)
        .confirmationDialog("睡眠播放", isPresented: $isSleepTimerDialogPresented, titleVisibility: .visible) {
            Button("15分钟") {
                setSleepTimer(after: 15 * 60, snapshot: "15分钟")
            }

            Button("30分钟") {
                setSleepTimer(after: 30 * 60, snapshot: "30分钟")
            }

            Button("60分钟") {
                setSleepTimer(after: 60 * 60, snapshot: "60分钟")
            }

            Button("2小时") {
                setSleepTimer(after: 2 * 60 * 60, snapshot: "2小时")
            }

            Button("3小时") {
                setSleepTimer(after: 3 * 60 * 60, snapshot: "3小时")
            }

            Button("4小时") {
                setSleepTimer(after: 4 * 60 * 60, snapshot: "4小时")
            }

            if player.sleepTimerEndDate != nil {
                Button("关闭睡眠播放", role: .destructive) {
                    player.cancelSleepTimer()
                    sleepTimerRemainingSnapshot = nil
                }
            }

            Button("取消", role: .cancel) {}
        } message: {
            if let sleepTimerRemainingSnapshot {
                Text("剩余 \(sleepTimerRemainingSnapshot)")
            } else {
                Text("选择自动停止播放的时间")
            }
        }
    }

    private func setSleepTimer(after duration: TimeInterval, snapshot: String) {
        player.setSleepTimer(after: duration)
        sleepTimerRemainingSnapshot = snapshot
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
                .foregroundStyle(mode == target ? .white.opacity(0.92) : .white.opacity(0.42))
        }
        .buttonStyle(.plain)
    }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        style(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        style(uiView)
    }

    private func style(_ view: MPVolumeView) {
        view.tintColor = UIColor.white.withAlphaComponent(0.86)
        for subview in view.subviews {
            guard let slider = subview as? UISlider else {
                subview.isHidden = true
                subview.isUserInteractionEnabled = false
                continue
            }
            slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.86)
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.16)
            slider.thumbTintColor = .white
        }
    }
}

struct PlayerBackdrop: View {
    let imageURL: URL?
    let size: CGSize

    @State private var gradientTop = BackdropPalette.fallback.top
    @State private var gradientMid = BackdropPalette.fallback.mid
    @State private var gradientBottom = BackdropPalette.fallback.bottom

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: gradientTop, location: 0),
                    .init(color: gradientMid, location: 0.35),
                    .init(color: gradientBottom, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Subtle warm directional highlight
            RadialGradient(
                colors: [
                    gradientTop.opacity(0.18),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: size.height * 0.9
            )

            // Bottom fade to pure black
            LinearGradient(
                colors: [.clear, .black.opacity(0.22)],
                startPoint: .init(x: 0.5, y: 0.7),
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.6), value: gradientTop)
        .frame(width: size.width, height: size.height)
        .clipped()
        .ignoresSafeArea()
        .task(id: imageURL) {
            await loadColors(from: imageURL)
        }
    }

    @MainActor
    private func loadColors(from url: URL?) async {
        let palette = await ColorExtractor.backdropPalette(for: url)
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.45)) {
            gradientTop = palette.top
            gradientMid = palette.mid
            gradientBottom = palette.bottom
        }
    }
}

struct LyricsPanelView: View {
    @EnvironmentObject private var player: PlayerController
    let song: EmbyAudioItem

    private var lines: [LyricLine] {
        if !player.lyrics.isEmpty {
            return player.lyrics
        }
        if player.isLoadingLyrics {
            return [LyricLine(id: -1, time: nil, text: "正在读取歌曲内置歌词")]
        }
        return [
            LyricLine(id: -2, time: nil, text: "这首歌没有可读取的内置歌词"),
            LyricLine(id: -3, time: nil, text: "支持 ID3 / iTunes / QuickTime 元数据中的歌词字段")
        ]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        Button {
                            player.seek(toLyric: line)
                        } label: {
                            Text(line.text)
                                .font(.system(size: activeLyricIndex == index ? 24 : 19, weight: .bold))
                                .lineSpacing(2)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(activeLyricIndex == index ? .white : .white.opacity(0.38))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .id(line.id)
                        .buttonStyle(.plain)
                        .disabled(line.time == nil)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeLyricId) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(id, anchor: .center)
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

    private var activeLyricIndex: Int {
        guard !lines.isEmpty else { return 0 }
        if lines.contains(where: { $0.time != nil }) {
            return lines.lastIndex { line in
                guard let time = line.time else { return false }
                return time <= player.elapsed
            } ?? 0
        }

        let duration = max(player.duration, 1)
        let progress = min(max(player.elapsed / duration, 0), 0.999)
        return min(Int(progress * Double(lines.count)), lines.count - 1)
    }

    private var activeLyricId: Int? {
        guard lines.indices.contains(activeLyricIndex) else { return nil }
        return lines[activeLyricIndex].id
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
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.isShuffleEnabled ? Color.musicRed : .white.opacity(0.75))
                }
                .buttonStyle(.plain)

                Button {
                    player.cycleRepeatMode()
                } label: {
                    Image(systemName: player.repeatMode.iconName)
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.repeatMode == .none ? .white.opacity(0.55) : Color.musicRed)
                }
                .buttonStyle(.plain)

                Button {
                    player.clearUpcomingQueue()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 32, height: 30)
                        .foregroundStyle(player.upcomingQueueSnapshot.isEmpty ? .white.opacity(0.24) : .white.opacity(0.75))
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
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if player.upcomingQueueSnapshot.isEmpty {
                ContentUnavailableView("没有待播放歌曲", systemImage: "music.note.list")
                    .foregroundStyle(.white.opacity(0.72))
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
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(song.artistLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
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
                .foregroundStyle(.white.opacity(0.86))
            } else {
                Button {
                    player.removeUpcomingQueueItem(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white.opacity(0.62))
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

// MARK: - Color Extraction (album art → backdrop gradient)

private struct BackdropPalette: Sendable, Equatable {
    let hue: Double
    let saturation: Double
    let topBrightness: Double
    let midBrightness: Double
    let bottomBrightness: Double

    var top: Color {
        Color(hue: hue, saturation: min(saturation * 1.08, 0.9), brightness: topBrightness)
    }

    var mid: Color {
        Color(hue: hue, saturation: min(saturation * 0.94, 0.82), brightness: midBrightness)
    }

    var bottom: Color {
        Color(hue: hue, saturation: min(saturation * 0.72, 0.68), brightness: bottomBrightness)
    }

    static let fallback = BackdropPalette(
        hue: 0.58,
        saturation: 0.34,
        topBrightness: 0.32,
        midBrightness: 0.20,
        bottomBrightness: 0.10
    )
}

private enum ColorExtractor {
    static func backdropPalette(for url: URL?) async -> BackdropPalette {
        await Task.detached(priority: .utility) {
            guard let url else { return BackdropPalette.fallback }

            if let cachedResponse = URLCache.shared.cachedResponse(for: URLRequest(url: url)),
               let palette = backdropPalette(from: cachedResponse.data) {
                return palette
            }

            if let data = ArtworkDiskCache.dataSync(for: url),
               let palette = backdropPalette(from: data) {
                return palette
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                await ArtworkDiskCache.insert(data, for: url)
                return backdropPalette(from: data) ?? BackdropPalette.fallback
            } catch {
                return BackdropPalette.fallback
            }
        }.value
    }

    private static func backdropPalette(from data: Data) -> BackdropPalette? {
        guard let image = UIImage(data: data) else { return nil }
        return backdropPalette(from: image)
    }

    private static func backdropPalette(from image: UIImage) -> BackdropPalette {
        let pixels = samplePixels(from: image, targetWidth: 24)
        guard !pixels.isEmpty else { return .fallback }

        var weighted: [(h: Double, s: Double, v: Double, w: Double)] = []
        for p in pixels {
            guard p.v > 0.08 && p.v < 0.96 else { continue }
            let saturationWeight = pow(max(p.s, 0.02), 1.45)
            let brightnessWeight = 1 - min(abs(p.v - 0.56) / 0.56, 1)
            let w = saturationWeight * 0.78 + brightnessWeight * 0.22
            weighted.append((p.h, p.s, p.v, w))
        }
        if weighted.isEmpty {
            for p in pixels where p.v > 0.03 {
                weighted.append((p.h, p.s, p.v, 1))
            }
        }
        guard !weighted.isEmpty else { return .fallback }

        let selected = Array(weighted.sorted { $0.w > $1.w }.prefix(max(12, weighted.count / 4)))
        let total = selected.reduce(0) { $0 + $1.w }
        let h = circularMeanHue(selected)
        let s = selected.reduce(0) { $0 + $1.s * $1.w } / total
        let v = selected.reduce(0) { $0 + $1.v * $1.w } / total
        let liftedBrightness = min(max(v, 0.32), 0.68)

        return BackdropPalette(
            hue: h,
            saturation: min(max(s * 1.32 + 0.10, 0.30), 0.86),
            topBrightness: min(liftedBrightness * 0.72 + 0.22, 0.62),
            midBrightness: min(liftedBrightness * 0.48 + 0.15, 0.42),
            bottomBrightness: min(liftedBrightness * 0.30 + 0.08, 0.28)
        )
    }

    private static func circularMeanHue(_ weighted: [(h: Double, s: Double, v: Double, w: Double)]) -> Double {
        let x = weighted.reduce(0.0) { result, value in
            result + cos(value.h * 2 * Double.pi) * value.w
        }
        let y = weighted.reduce(0.0) { result, value in
            result + sin(value.h * 2 * Double.pi) * value.w
        }
        let hue = atan2(y, x) / (2 * Double.pi)
        return hue < 0 ? hue + 1 : hue
    }

    private static func samplePixels(from image: UIImage, targetWidth: Int) -> [(h: Double, s: Double, v: Double)] {
        guard let cg = image.cgImage else { return [] }
        let scale = CGFloat(targetWidth) / CGFloat(cg.width)
        let h = Int(CGFloat(cg.height) * scale)
        guard h > 0 else { return [] }
        let bytesPerPixel = 4
        var raw = [UInt8](repeating: 0, count: targetWidth * h * bytesPerPixel)
        guard let ctx = CGContext(
            data: &raw, width: targetWidth, height: h,
            bitsPerComponent: 8, bytesPerRow: targetWidth * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetWidth, height: h))
        var result: [(h: Double, s: Double, v: Double)] = []
        for y in 0..<h {
            for x in 0..<targetWidth {
                let o = (y * targetWidth + x) * bytesPerPixel
                let r = Double(raw[o]) / 255
                let g = Double(raw[o + 1]) / 255
                let b = Double(raw[o + 2]) / 255
                result.append(rgbToHSV(r: r, g: g, b: b))
            }
        }
        return result
    }

    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue

        let saturation = maxValue == 0 ? 0 : delta / maxValue
        guard delta > 0 else {
            return (0, saturation, maxValue)
        }

        let hue: Double
        if maxValue == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maxValue == g {
            hue = (((b - r) / delta) + 2) / 6
        } else {
            hue = (((r - g) / delta) + 4) / 6
        }

        return (hue < 0 ? hue + 1 : hue, saturation, maxValue)
    }
}
