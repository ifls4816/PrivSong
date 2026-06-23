import CarPlay
import Combine
import Foundation
import UIKit

@MainActor
final class CarPlayCoordinator: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private let store: AppStore
    private let player: PlayerController
    private var cancellables: Set<AnyCancellable> = []
    private var tabBarTemplate: CPTabBarTemplate?
    private var refreshTask: Task<Void, Never>?

    init(interfaceController: CPInterfaceController, store: AppStore, player: PlayerController) {
        self.interfaceController = interfaceController
        self.store = store
        self.player = player
        super.init()
    }

    func connect() {
        setRootTemplate(animated: false)
        observeStoreChanges()
        observePlayerChanges()
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        cancellables.removeAll()
        interfaceController = nil
        tabBarTemplate = nil
    }

    private func observeStoreChanges() {
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleRootRefresh()
            }
            .store(in: &cancellables)
    }

    private func observePlayerChanges() {
        player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.scheduleRootRefresh()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleRootRefresh() {
        guard let interfaceController,
              let tabBarTemplate,
              interfaceController.topTemplate === tabBarTemplate else {
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshRootTabs()
        }
    }

    private func setRootTemplate(animated: Bool) {
        let template = makeTabBarTemplate()
        tabBarTemplate = template
        interfaceController?.setRootTemplate(template, animated: animated, completion: nil)
    }

    private func refreshRootTabs() {
        tabBarTemplate?.updateTemplates(makeTabTemplates())
    }

    private func makeTabBarTemplate() -> CPTabBarTemplate {
        CPTabBarTemplate(templates: makeTabTemplates())
    }

    private func makeTabTemplates() -> [CPTemplate] {
        [
            configuredTab(
                makeRecommendationsTemplate(),
                title: "推荐",
                imageName: "music.note.house"
            ),
            configuredTab(
                makeLibraryTemplate(),
                title: "资料库",
                imageName: "square.stack"
            ),
            configuredTab(
                makeNowPlayingLauncherTemplate(),
                title: "播放",
                imageName: "play.circle.fill"
            )
        ]
    }

    private func configuredTab<T: CPTemplate>(_ template: T, title: String, imageName: String) -> T {
        template.tabTitle = title
        template.tabImage = UIImage(systemName: imageName)
        return template
    }

    private func makeRecommendationsTemplate() -> CPListTemplate {
        let sections: [CPListSection]
        if store.session == nil {
            sections = [statusSection(title: "未连接 Emby", detail: "请先在 iPhone 上连接资料库", imageName: "antenna.radiowaves.left.and.right.slash")]
        } else if !store.hasLoadedInitialContent && store.isLoading {
            sections = [statusSection(title: "正在加载资料库", detail: "请稍候", imageName: "arrow.clockwise")]
        } else {
            sections = recommendationSections()
        }

        return CPListTemplate(title: "推荐", sections: sections)
    }

    private func makeNowPlayingLauncherTemplate() -> CPListTemplate {
        let sections: [CPListSection]
        if let currentSong = player.currentSong {
            let item = navigationItem(
                title: currentSong.name,
                detail: currentSong.artistLine.isEmpty ? "正在播放" : currentSong.artistLine,
                imageName: "play.circle.fill"
            ) { [weak self] in
                self?.pushNowPlayingTemplate()
            }
            sections = [CPListSection(items: [item], header: "正在播放", sectionIndexTitle: nil)]
        } else {
            sections = [statusSection(title: "暂无播放内容", detail: "播放歌曲后可在这里继续控制", imageName: "play.circle")]
        }

        return CPListTemplate(title: "播放", sections: sections)
    }

    private func recommendationSections() -> [CPListSection] {
        var sections: [CPListSection] = []

        if let currentSong = player.currentSong {
            sections.append(
                CPListSection(
                    items: [
                        navigationItem(
                            title: currentSong.name,
                            detail: currentSong.artistLine.isEmpty ? "正在播放" : currentSong.artistLine,
                            imageName: "play.circle.fill"
                        ) { [weak self] in
                            self?.pushNowPlayingTemplate()
                        }
                    ],
                    header: "继续播放",
                    sectionIndexTitle: nil
                )
            )
        }

        if !store.dailyRecommendedSongs.isEmpty {
            sections.append(
                CPListSection(
                    items: [
                        navigationItem(
                            title: "每日推荐",
                            detail: "\(store.dailyRecommendedSongs.count) 首歌曲",
                            imageName: "sparkles"
                        ) { [weak self] in
                            self?.pushSongList(title: "每日推荐", songs: self?.store.dailyRecommendedSongs ?? [])
                        }
                    ],
                    header: "为你推荐",
                    sectionIndexTitle: nil
                )
            )
        }

        var discoveryItems: [CPListItem] = []
        if !store.recentlyAddedSongs.isEmpty {
            discoveryItems.append(
                navigationItem(
                    title: "最近添加",
                    detail: "\(store.recentlyAddedSongs.count) 首歌曲",
                    imageName: "clock"
                ) { [weak self] in
                    self?.pushSongList(title: "最近添加", songs: self?.store.recentlyAddedSongs ?? [])
                }
            )
        }
        if !store.mostPlayedSongs.isEmpty {
            discoveryItems.append(
                navigationItem(
                    title: "最长播放",
                    detail: "\(store.mostPlayedSongs.count) 首歌曲",
                    imageName: "chart.bar.fill"
                ) { [weak self] in
                    self?.pushSongList(title: "最长播放", songs: self?.store.mostPlayedSongs ?? [])
                }
            )
        }
        if !discoveryItems.isEmpty {
            sections.append(CPListSection(items: discoveryItems, header: "更多推荐", sectionIndexTitle: nil))
        }

        if sections.isEmpty {
            sections.append(statusSection(title: "暂无推荐内容", detail: store.localizedLibraryStatus, imageName: "music.note.list"))
        }

        return sections
    }

    private func makeLibraryTemplate() -> CPListTemplate {
        let sections: [CPListSection]
        if store.session == nil {
            sections = [statusSection(title: "未连接 Emby", detail: "请先在 iPhone 上连接资料库", imageName: "antenna.radiowaves.left.and.right.slash")]
        } else if !store.hasLoadedInitialContent && store.isLoading {
            sections = [statusSection(title: "正在加载资料库", detail: "请稍候", imageName: "arrow.clockwise")]
        } else {
            sections = librarySections()
        }

        return CPListTemplate(title: "资料库", sections: sections)
    }

    private func librarySections() -> [CPListSection] {
        var items: [CPListItem] = []
        items.append(
            navigationItem(
                title: "我的歌单",
                detail: "\(store.playlists.count) 个歌单",
                imageName: "music.note.list"
            ) { [weak self] in
                self?.pushPlaylists()
            }
        )
        items.append(
            navigationItem(
                title: "有声书",
                detail: "\(store.audiobooks.count) 本",
                imageName: "book.closed.fill"
            ) { [weak self] in
                self?.pushAudiobooks()
            }
        )

        if store.playlists.isEmpty, store.audiobooks.isEmpty {
            return [statusSection(title: "暂无资料库内容", detail: store.localizedLibraryStatus, imageName: "music.note.list")]
        }

        return [CPListSection(items: items, header: "资料库", sectionIndexTitle: nil)]
    }

    private func pushPlaylists() {
        guard !store.playlists.isEmpty else {
            pushStatusTemplate(title: "我的歌单", message: "暂无歌单", imageName: "music.note.list")
            return
        }

        let items = store.playlists.map { playlist in
            navigationItem(
                title: playlist.name,
                detail: "\(playlist.displaySongCount) 首歌曲",
                imageName: "music.note.list"
            ) { [weak self] in
                self?.loadAndPushPlaylist(playlist)
            }
        }
        pushList(title: "我的歌单", sections: [CPListSection(items: items, header: "\(store.playlists.count) 个歌单", sectionIndexTitle: nil)])
    }

    private func loadAndPushPlaylist(_ playlist: MusicPlaylist) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let songs = try await store.loadPlaylistSongsIfNeeded(playlistId: playlist.id)
                pushSongList(title: playlist.name, songs: songs)
            } catch {
                pushStatusTemplate(title: playlist.name, message: error.localizedDescription, imageName: "exclamationmark.triangle")
            }
        }
    }

    private func pushAudiobooks() {
        guard !store.audiobooks.isEmpty else {
            pushStatusTemplate(title: "有声书", message: "暂无有声书", imageName: "book.closed")
            return
        }

        let items = store.audiobooks.map { audiobook in
            navigationItem(
                title: audiobook.title,
                detail: audiobookDetailText(for: audiobook),
                imageName: "book.closed.fill"
            ) { [weak self] in
                self?.pushAudiobook(audiobook)
            }
        }
        pushList(title: "有声书", sections: [CPListSection(items: items, header: "\(store.audiobooks.count) 本有声书", sectionIndexTitle: nil)])
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

    private func pushSongList(title: String, songs: [EmbyAudioItem]) {
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
        pushList(title: title, sections: [CPListSection(items: items, header: "\(songs.count) 首歌曲", sectionIndexTitle: nil)])
    }

    private func pushNowPlayingTemplate() {
        guard player.currentSong != nil else { return }
        guard interfaceController?.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func pushList(title: String, sections: [CPListSection]) {
        let template = CPListTemplate(title: title, sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
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

    private func audiobookDetailText(for audiobook: Audiobook) -> String {
        let progress = store.audiobookListSubtitle(for: audiobook)
        return "\(audiobook.author) - \(progress)"
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
