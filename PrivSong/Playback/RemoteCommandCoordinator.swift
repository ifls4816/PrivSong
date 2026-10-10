import Foundation
import MediaPlayer
import UIKit

final class RemoteCommandCoordinator: @unchecked Sendable {
    static let shared = RemoteCommandCoordinator()

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    /// Relative jump in seconds (negative = back), used by the audiobook skip buttons.
    var onSkip: ((TimeInterval) -> Void)?

    static let skipBackwardInterval: TimeInterval = 15
    static let skipForwardInterval: TimeInterval = 30

    private let commandCenter = MPRemoteCommandCenter.shared()

    private init() {
        configureCommands()
    }

    /// `isSpokenAudio` (audiobooks) swaps the previous/next track buttons for skip back 15 s /
    /// forward 30 s on the lock screen, Control Center and CarPlay.
    func update(canGoNext: Bool, canGoPrevious: Bool, canSeek: Bool, isSpokenAudio: Bool) {
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = canGoNext && !isSpokenAudio
        commandCenter.previousTrackCommand.isEnabled = canGoPrevious && !isSpokenAudio
        commandCenter.skipForwardCommand.isEnabled = canSeek && isSpokenAudio
        commandCenter.skipBackwardCommand.isEnabled = canSeek && isSpokenAudio
        commandCenter.changePlaybackPositionCommand.isEnabled = canSeek
    }

    private func configureCommands() {
        Task { @MainActor in
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.onPlay?()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard self?.onNext != nil else { return .noSuchContent }
            self?.onNext?()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard self?.onPrevious != nil else { return .noSuchContent }
            self?.onPrevious?()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.onSeek?(event.positionTime)
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForwardInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let onSkip = self?.onSkip else { return .noSuchContent }
            onSkip(Self.skipForwardInterval)
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackwardInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let onSkip = self?.onSkip else { return .noSuchContent }
            onSkip(-Self.skipBackwardInterval)
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.ratingCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false
    }
}
