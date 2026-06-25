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

    private let commandCenter = MPRemoteCommandCenter.shared()

    private init() {
        configureCommands()
    }

    func update(canGoNext: Bool, canGoPrevious: Bool, canSeek: Bool) {
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = canGoNext
        commandCenter.previousTrackCommand.isEnabled = canGoPrevious
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

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.ratingCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false
    }
}
