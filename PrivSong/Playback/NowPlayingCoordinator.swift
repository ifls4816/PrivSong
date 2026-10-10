import Foundation
import MediaPlayer
import UIKit

final class NowPlayingCoordinator: @unchecked Sendable {
    static let shared = NowPlayingCoordinator()

    private let infoCenter = MPNowPlayingInfoCenter.default()
    /// The artwork object handed to the system, reused while the image stays the same rather
    /// than rebuilt on every update.
    private var cachedArtworkImage: UIImage?
    private var cachedArtwork: MPMediaItemArtwork?

    private init() {}

    /// Call on state changes only (track, play/pause, seek, artwork). Between updates the system
    /// advances the elapsed time itself from the playback rate.
    func update(
        song: EmbyAudioItem,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        artwork: UIImage?,
        queueIndex: Int?,
        queueCount: Int?
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
        if let trackNumber = song.indexNumber, trackNumber > 0 {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
        }
        if let queueIndex, let queueCount, queueCount > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        }

        if let artwork {
            if cachedArtworkImage !== artwork {
                cachedArtworkImage = artwork
                cachedArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            }
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        cachedArtworkImage = nil
        cachedArtwork = nil
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }
}
