import Foundation
import MediaPlayer
import UIKit

final class NowPlayingCoordinator: @unchecked Sendable {
    static let shared = NowPlayingCoordinator()

    private let infoCenter = MPNowPlayingInfoCenter.default()

    private init() {}

    func update(
        song: EmbyAudioItem,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        artwork: UIImage?
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artistLine.isEmpty ? "Unknown Artist" : song.artistLine,
            MPMediaItemPropertyPlaybackDuration: max(duration, 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(elapsed, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]

        if let album = song.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                artwork
            }
        }

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    func updatePlaybackState(elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        guard var info = infoCenter.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(elapsed, 0)
        info[MPMediaItemPropertyPlaybackDuration] = max(duration, 0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }
}
