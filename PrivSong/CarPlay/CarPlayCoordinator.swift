import CarPlay
import Foundation
import Observation
import UIKit

@MainActor
final class CarPlayCoordinator: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private let store: AppStore
    private let player: PlayerController
    private var isObservingStore = false
    private var tabBarTemplate: CPTabBarTemplate?
    private var homeListTemplate: CPListTemplate?
    private var discoveryListTemplate: CPListTemplate?
    private var refreshTask: Task<Void, Never>?
    private var cardArtworkTasks: [Task<Void, Never>] = []
    private var observedStoreContentSignature = ""

    init(interfaceController: CPInterfaceController, store: AppStore, player: PlayerController) {
        self.interfaceController = interfaceController
        self.store = store
        self.player = player
        super.init()
    }

    func connect() {
        setRootTemplate(animated: false)
        observeStoreChanges()
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        cardArtworkTasks.forEach { $0.cancel() }
        cardArtworkTasks.removeAll()
        isObservingStore = false
        interfaceController = nil
        tabBarTemplate = nil
        homeListTemplate = nil
        discoveryListTemplate = nil
    }

    private func observeStoreChanges() {
        isObservingStore = true
        observedStoreContentSignature = trackedStoreContentSignature()
    }

    /// Computes the signature while registering for changes to exactly the store properties it
    /// reads; `onChange` fires once, so each change re-registers.
    private func trackedStoreContentSignature() -> String {
        withObservationTracking {
            storeContentSignature()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObservingStore else { return }
                let signature = self.trackedStoreContentSignature()
                guard self.observedStoreContentSignature != signature else { return }
                self.observedStoreContentSignature = signature
                self.scheduleRootRefresh()
            }
        }
    }

    private func scheduleRootRefresh() {
        guard let interfaceController,
              let tabBarTemplate else {
            return
        }

        let topTemplate = interfaceController.topTemplate
        guard topTemplate === tabBarTemplate ||
              topTemplate === homeListTemplate ||
              topTemplate === discoveryListTemplate else {
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshRootTabs()
        }
    }

    private func storeContentSignature() -> String {
        let playlistSignature = store.playlists
            .map { playlist in
                [
                    playlist.id,
                    playlist.name,
                    "\(playlist.displaySongCount)",
                    playlist.songs.first?.id ?? ""
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        let audiobookSignature = store.audiobooks
            .map { audiobook in
                [
                    audiobook.id,
                    audiobook.title,
                    "\(audiobook.episodeCount)",
                    audiobook.representativeEpisode?.id ?? ""
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        let discoverySignature = [
            store.dailyRecommendedSongs.map(\.id).joined(separator: ","),
            store.recentlyAddedSongs.map(\.id).joined(separator: ","),
            store.mostPlayedSongs.map(\.id).joined(separator: ",")
        ].joined(separator: "|")

        return [
            store.session?.userId ?? "signed-out",
            store.hasLoadedInitialContent ? "loaded" : "not-loaded",
            store.isLoadingContent ? "loading" : "idle",
            store.localizedLibraryStatus,
            playlistSignature,
            audiobookSignature,
            discoverySignature
        ].joined(separator: "#")
    }

    private func setRootTemplate(animated: Bool) {
        let template = makeTabBarTemplate()
        tabBarTemplate = template
        interfaceController?.setRootTemplate(template, animated: animated, completion: nil)
    }

    private func refreshRootTabs() {
        cardArtworkTasks.forEach { $0.cancel() }
        cardArtworkTasks.removeAll()
        homeListTemplate?.updateSections(homeTabSections())
        discoveryListTemplate?.updateSections(discoveryTabSections())
    }

    private func makeTabBarTemplate() -> CPTabBarTemplate {
        let templates = makeTabTemplates()
        return CPTabBarTemplate(templates: templates)
    }

    private func makeTabTemplates() -> [CPTemplate] {
        cardArtworkTasks.forEach { $0.cancel() }
        cardArtworkTasks.removeAll()

        let home = configuredTab(
            makeHomeTemplate(),
            title: "主页",
            imageName: "house.fill"
        )
        let discovery = configuredTab(
            makeDiscoveryTemplate(),
            title: "发现",
            imageName: "sparkles"
        )
        homeListTemplate = home
        discoveryListTemplate = discovery
        return [home, discovery]
    }

    private func configuredTab<T: CPTemplate>(_ template: T, title: String, imageName: String) -> T {
        template.tabTitle = title
        template.tabImage = UIImage(systemName: imageName)
        return template
    }

    private func makeHomeTemplate() -> CPListTemplate {
        let template = listTemplate(title: nil, sections: homeTabSections())
        homeListTemplate = template
        return template
    }

    private func makeDiscoveryTemplate() -> CPListTemplate {
        let template = listTemplate(title: nil, sections: discoveryTabSections())
        discoveryListTemplate = template
        return template
    }

    private func rootStatusSections() -> [CPListSection]? {
        if store.session == nil {
            return [statusSection(title: "未连接 Emby", detail: "请先在 iPhone 上连接资料库", imageName: "antenna.radiowaves.left.and.right.slash")]
        }
        if !store.hasLoadedInitialContent && store.isLoadingContent {
            return [statusSection(title: "正在加载资料库", detail: "请稍候", imageName: "arrow.clockwise")]
        }
        return nil
    }

    private func homeTabSections() -> [CPListSection] {
        if let statusSections = rootStatusSections() {
            return statusSections
        }

        var sections: [CPListSection] = []

        let playlistCards = previewCards(store.playlists.map { playlist in
            CarPlayCardDescriptor(
                title: playlist.name,
                subtitle: nil,
                imageURL: playlist.songs.first.flatMap { store.imageURL(for: $0, size: 360) },
                placeholderSystemImageName: "music.note.list",
                tintColor: .secondarySystemBackground
            )
        })
        if !playlistCards.isEmpty {
            sections.append(
                CPListSection(
                    items: [
                        makeCardRow(
                            title: "我的歌单",
                            cards: playlistCards,
                            rowSelection: { [weak self] in
                                self?.pushPlaylists()
                            }
                        ) { [weak self] index in
                            guard let playlist = self?.store.playlists[safe: index] else { return }
                            self?.loadAndPushPlaylist(playlist)
                        }
                    ],
                    header: nil,
                    sectionIndexTitle: nil
                )
            )
        }

        let audiobookCards = previewCards(store.audiobooks.map { audiobook in
            CarPlayCardDescriptor(
                title: audiobook.title,
                subtitle: nil,
                imageURL: audiobook.representativeEpisode.flatMap { store.imageURL(for: $0, size: 360) },
                placeholderSystemImageName: "book.closed.fill",
                tintColor: .secondarySystemBackground
            )
        })
        if !audiobookCards.isEmpty {
            sections.append(
                CPListSection(
                    items: [
                        makeCardRow(
                            title: "有声书",
                            cards: audiobookCards,
                            rowSelection: { [weak self] in
                                self?.pushAudiobooks()
                            }
                        ) { [weak self] index in
                            guard let audiobook = self?.store.audiobooks[safe: index] else { return }
                            self?.pushAudiobook(audiobook)
                        }
                    ],
                    header: nil,
                    sectionIndexTitle: nil
                )
            )
        }

        if sections.isEmpty {
            return [statusSection(title: "暂无主页内容", detail: store.localizedLibraryStatus, imageName: "music.note.list")]
        }

        return [homeTopSpacerSection()] + sections
    }

    private func discoveryTabSections() -> [CPListSection] {
        if let statusSections = rootStatusSections() {
            return statusSections
        }

        let discoveryCards = [
            CarPlayCardDescriptor(
                title: "每日推荐",
                subtitle: nil,
                imageURL: store.dailyRecommendedSongs.first.flatMap { store.imageURL(for: $0, size: 360) },
                placeholderSystemImageName: "sparkles",
                tintColor: .secondarySystemBackground
            ),
            CarPlayCardDescriptor(
                title: "最近添加",
                subtitle: nil,
                imageURL: store.recentlyAddedSongs.first.flatMap { store.imageURL(for: $0, size: 360) },
                placeholderSystemImageName: "clock",
                tintColor: .secondarySystemBackground
            ),
            CarPlayCardDescriptor(
                title: "最常播放",
                subtitle: nil,
                imageURL: store.mostPlayedSongs.first.flatMap { store.imageURL(for: $0, size: 360) },
                placeholderSystemImageName: "chart.bar.fill",
                tintColor: .secondarySystemBackground
            )
        ]
        return [
            homeTopSpacerSection(),
            CPListSection(
                items: [
                    makeCardRow(
                        title: "发现",
                        cards: discoveryCards,
                        rowSelection: { [weak self] in
                            self?.pushDiscovery()
                        }
                    ) { [weak self] index in
                        switch index {
                        case 0:
                            self?.pushSongCollection(title: "每日推荐", songs: self?.store.dailyRecommendedSongs ?? [])
                        case 1:
                            self?.pushSongCollection(title: "最近添加", songs: self?.store.recentlyAddedSongs ?? [])
                        case 2:
                            self?.pushSongCollection(title: "最常播放", songs: self?.store.mostPlayedSongs ?? [])
                        default:
                            break
                        }
                    }
                ],
                header: nil,
                sectionIndexTitle: nil
            )
        ]
    }

    private func makeCardRow(
        title: String? = nil,
        cards: [CarPlayCardDescriptor],
        rowSelection: (() -> Void)? = nil,
        selection: @escaping (Int) -> Void
    ) -> CPListImageRowItem {
        let row = CPListImageRowItem(
            text: title,
            cardElements: cards.map { cardElement(for: $0, image: initialCardImage(for: $0)) },
            allowsMultipleLines: false
        )

        if let rowSelection {
            row.handler = { _, completion in
                Task { @MainActor in
                    completion()
                    rowSelection()
                }
            }
        }

        row.listImageRowHandler = { _, index, completion in
            Task { @MainActor in
                completion()
                selection(index)
            }
        }

        loadArtwork(for: row, cards: cards)
        return row
    }

    private func previewCards(_ cards: [CarPlayCardDescriptor]) -> [CarPlayCardDescriptor] {
        let limit = Int(CPMaximumNumberOfGridImages)
        guard limit > 0, cards.count > limit else { return cards }
        return Array(cards.prefix(limit))
    }

    private func loadArtwork(for row: CPListImageRowItem, cards: [CarPlayCardDescriptor]) {
        let task = Task { @MainActor [weak self, weak row] in
            guard let self else { return }
            var updatedElements: [CPListImageRowItemCardElement] = []
            updatedElements.reserveCapacity(cards.count)

            for card in cards {
                guard !Task.isCancelled else { return }
                let image = await self.cardImage(for: card)
                updatedElements.append(self.cardElement(for: card, image: image))
            }

            guard !Task.isCancelled else { return }
            row?.elements = updatedElements
        }
        cardArtworkTasks.append(task)
    }

    private func cardElement(for card: CarPlayCardDescriptor, image: UIImage) -> CPListImageRowItemCardElement {
        CPListImageRowItemCardElement(
            image: image,
            showsImageFullHeight: true,
            title: card.title,
            subtitle: card.subtitle,
            tintColor: card.tintColor
        )
    }

    private func cardImage(for card: CarPlayCardDescriptor) async -> UIImage {
        guard let imageURL = card.imageURL else {
            return placeholderImage(systemName: card.placeholderSystemImageName)
        }

        if let cached = ArtworkImageCache.shared.image(for: imageURL.url) ?? ArtworkImageCache.shared.fallbackImage(for: imageURL.url) {
            return preparedCardImage(cached)
        }

        // ArtworkDecoder downsamples and decodes off the main thread, so neither CarPlay nor
        // the phone UI (which shares ArtworkImageCache) has to decode these on the main actor.
        if let diskData = await ArtworkDiskCache.data(for: imageURL.url),
           let diskImage = await ArtworkDecoder.image(from: diskData, url: imageURL.url) {
            ArtworkImageCache.shared.insert(diskImage, for: imageURL.url)
            return preparedCardImage(diskImage)
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: imageURL.request)
            guard !Task.isCancelled, let image = await ArtworkDecoder.image(from: data, url: imageURL.url) else {
                return placeholderImage(systemName: card.placeholderSystemImageName)
            }
            ArtworkImageCache.shared.insert(image, for: imageURL.url)
            await ArtworkDiskCache.insert(data, for: imageURL.url)
            return preparedCardImage(image)
        } catch {
            return placeholderImage(systemName: card.placeholderSystemImageName)
        }
    }

    private func initialCardImage(for card: CarPlayCardDescriptor) -> UIImage {
        guard let imageURL = card.imageURL,
              let cached = ArtworkImageCache.shared.image(for: imageURL.url) ?? ArtworkImageCache.shared.fallbackImage(for: imageURL.url) else {
            return placeholderImage(systemName: card.placeholderSystemImageName)
        }
        return preparedCardImage(cached)
    }

    private func preparedCardImage(_ image: UIImage) -> UIImage {
        let maximumSize = CPListImageRowItemCardElement.maximumFullHeightImageSize
        let fallbackSize = CGSize(width: 240, height: 240)
        let targetSize = maximumSize.width > 1 && maximumSize.height > 1 ? maximumSize : fallbackSize
        return image.aspectFillResized(to: targetSize)
    }

    private func placeholderImage(systemName: String) -> UIImage {
        let maximumSize = CPListImageRowItemCardElement.maximumFullHeightImageSize
        let size = maximumSize.width > 1 && maximumSize.height > 1 ? maximumSize : CGSize(width: 240, height: 240)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.secondarySystemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let symbolSize = min(size.width, size.height) * 0.34
            let configuration = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
            let symbol = UIImage(systemName: systemName, withConfiguration: configuration)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            let origin = CGPoint(
                x: (size.width - symbolSize) / 2,
                y: (size.height - symbolSize) / 2
            )
            symbol?.draw(in: CGRect(origin: origin, size: CGSize(width: symbolSize, height: symbolSize)))
        }
    }

    private func loadAndPushPlaylist(_ playlist: MusicPlaylist) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let songs = try await store.loadPlaylistSongsIfNeeded(playlistId: playlist.id)
                pushSongCollection(title: playlist.name, songs: songs)
            } catch {
                pushStatusTemplate(title: playlist.name, message: error.localizedDescription, imageName: "exclamationmark.triangle")
            }
        }
    }

    private func pushPlaylists() {
        guard !store.playlists.isEmpty else {
            pushStatusTemplate(title: "我的歌单", message: "暂无歌单", imageName: "music.note.list")
            return
        }

        let items = store.playlists.map { playlist in
            navigationItem(
                title: playlist.name,
                detail: nil,
                imageName: "music.note.list"
            ) { [weak self] in
                self?.loadAndPushPlaylist(playlist)
            }
        }
        pushList(title: "我的歌单", sections: [CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    private func pushAudiobooks() {
        guard !store.audiobooks.isEmpty else {
            pushStatusTemplate(title: "有声书", message: "暂无有声书", imageName: "book.closed")
            return
        }

        let items = store.audiobooks.map { audiobook in
            navigationItem(
                title: audiobook.title,
                detail: audiobook.author.isEmpty ? nil : audiobook.author,
                imageName: "book.closed.fill"
            ) { [weak self] in
                self?.pushAudiobook(audiobook)
            }
        }
        pushList(title: "有声书", sections: [CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    private func pushDiscovery() {
        let items = [
            navigationItem(
                title: "每日推荐",
                detail: nil,
                imageName: "music.note.list"
            ) { [weak self] in
                self?.pushSongCollection(title: "每日推荐", songs: self?.store.dailyRecommendedSongs ?? [])
            },
            navigationItem(
                title: "最近添加",
                detail: nil,
                imageName: "music.note.list"
            ) { [weak self] in
                self?.pushSongCollection(title: "最近添加", songs: self?.store.recentlyAddedSongs ?? [])
            },
            navigationItem(
                title: "最常播放",
                detail: nil,
                imageName: "music.note.list"
            ) { [weak self] in
                self?.pushSongCollection(title: "最常播放", songs: self?.store.mostPlayedSongs ?? [])
            }
        ]
        pushList(title: "发现", sections: [CPListSection(items: items, header: nil, sectionIndexTitle: nil)])
    }

    private func pushAudiobook(_ audiobook: Audiobook) {
        guard !audiobook.episodes.isEmpty else {
            pushStatusTemplate(title: audiobook.title, message: "暂无分集", imageName: "book.closed")
            return
        }

        let continueItem = playableItem(
            title: "继续播放",
            detail: store.audiobookListSubtitle(for: audiobook),
            imageName: "play.fill"
        ) { [weak self] in
            self?.store.playAudiobook(audiobook)
            self?.showNowPlayingAfterPlaybackStarts()
        }

        let episodeItems = audiobook.episodes.enumerated().map { index, episode in
            playableItem(
                title: episodeTitle(for: episode, index: index),
                detail: episodeDetailText(for: episode),
                imageName: "book.pages"
            ) { [weak self] in
                self?.store.playAudiobookEpisode(episode, in: audiobook)
                self?.showNowPlayingAfterPlaybackStarts()
            }
        }

        let sections = [
            CPListSection(items: [continueItem], header: "\(audiobook.author) - \(audiobook.episodeCount) 集", sectionIndexTitle: nil),
            CPListSection(items: episodeItems, header: "分集", sectionIndexTitle: nil)
        ]
        pushList(title: audiobook.title, sections: sections)
    }

    private func pushSongCollection(title: String, songs: [EmbyAudioItem]) {
        guard !songs.isEmpty else {
            pushStatusTemplate(title: title, message: "暂无歌曲", imageName: "music.note")
            return
        }

        let items = songs.map { song in
            playableItem(
                title: song.name,
                detail: song.artistLine.isEmpty ? "未知艺术家" : song.artistLine,
                imageName: "music.note"
            ) { [weak self] in
                self?.store.play(song: song, in: songs)
                self?.showNowPlayingAfterPlaybackStarts()
            }
        }
        let sections = [CPListSection(items: items, header: nil, sectionIndexTitle: nil)]
        let template = listTemplate(
            title: title,
            sections: sections,
            headerGridButtons: songPlaybackButtons(songs: songs)
        )
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func songPlaybackButtons(songs: [EmbyAudioItem]) -> [CPGridButton] {
        [
            CPGridButton(
                titleVariants: ["顺序播放"],
                image: UIImage(systemName: "play.fill") ?? UIImage()
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let first = songs.first else { return }
                    self?.store.play(song: first, in: songs)
                    self?.showNowPlayingAfterPlaybackStarts()
                }
            },
            CPGridButton(
                titleVariants: ["随机播放"],
                image: UIImage(systemName: "shuffle") ?? UIImage()
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let randomSong = songs.randomElement() else { return }
                    self?.store.play(song: randomSong, in: songs, shuffle: true)
                    self?.showNowPlayingAfterPlaybackStarts()
                }
            }
        ]
    }

    private func pushNowPlayingTemplate() {
        guard player.currentSong != nil else { return }
        guard interfaceController?.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func pushList(title: String, sections: [CPListSection]) {
        let template = listTemplate(title: title, sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func listTemplate(
        title: String?,
        sections: [CPListSection],
        headerGridButtons: [CPGridButton]? = nil
    ) -> CPListTemplate {
        let template = CPListTemplate(
            title: title,
            sections: sections,
            assistantCellConfiguration: nil,
            headerGridButtons: headerGridButtons
        )
        return template
    }

    private func pushStatusTemplate(title: String, message: String, imageName: String) {
        pushList(title: title, sections: [statusSection(title: message, detail: nil, imageName: imageName)])
    }

    private func navigationItem(
        title: String,
        detail: String?,
        imageName: String,
        action: @escaping () -> Void
    ) -> CPListItem {
        let item = CPListItem(
            text: title,
            detailText: detail,
            image: UIImage(systemName: imageName),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = { _, completion in
            Task { @MainActor in
                completion()
                action()
            }
        }
        return item
    }

    private func playableItem(
        title: String,
        detail: String?,
        imageName: String,
        action: @escaping () -> Void
    ) -> CPListItem {
        let item = CPListItem(
            text: title,
            detailText: detail,
            image: UIImage(systemName: imageName),
            accessoryImage: nil,
            accessoryType: .none
        )
        item.handler = { _, completion in
            Task { @MainActor in
                completion()
                action()
            }
        }
        return item
    }

    private func showNowPlayingAfterPlaybackStarts() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.pushNowPlayingTemplate()
        }
    }

    private func statusSection(title: String, detail: String?, imageName: String) -> CPListSection {
        CPListSection(items: [statusItem(title: title, detail: detail, imageName: imageName)])
    }

    private func homeTopSpacerSection() -> CPListSection {
        CPListSection(items: [], header: " ", sectionIndexTitle: nil)
    }

    private func statusItem(title: String, detail: String?, imageName: String) -> CPListItem {
        let item = CPListItem(
            text: title,
            detailText: detail,
            image: UIImage(systemName: imageName),
            accessoryImage: nil,
            accessoryType: .none
        )
        item.isEnabled = false
        return item
    }

    private func episodeTitle(for episode: EmbyAudioItem, index: Int) -> String {
        if let number = episode.indexNumber, number > 0 {
            return "第 \(number) 集 \(episode.name)"
        }
        return "第 \(index + 1) 集 \(episode.name)"
    }

    private func episodeDetailText(for episode: EmbyAudioItem) -> String {
        var parts: [String] = []
        if episode.duration > 0 {
            parts.append(episode.duration.musicDurationText)
        }
        if let progress = store.audiobookProgressText(for: episode) {
            parts.append(progress)
        }
        return parts.isEmpty ? " " : parts.joined(separator: " - ")
    }
}

private struct CarPlayCardDescriptor {
    let title: String
    let subtitle: String?
    let imageURL: AuthenticatedURL?
    let placeholderSystemImageName: String
    let tintColor: UIColor?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension UIImage {
    func aspectFillResized(to targetSize: CGSize) -> UIImage {
        guard targetSize.width > 0, targetSize.height > 0, size.width > 0, size.height > 0 else {
            return self
        }

        let widthScale = targetSize.width / size.width
        let heightScale = targetSize.height / size.height
        let scale = max(widthScale, heightScale)
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )

        return UIGraphicsImageRenderer(size: targetSize).image { _ in
            draw(in: drawRect)
        }
    }
}
