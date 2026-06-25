import AVFoundation
import Foundation

final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()

    private init() {}

    func configureForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            print("[AudioSession] Failed to configure playback category: \(error.localizedDescription)")
        }
    }

    func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioSession] Failed to activate: \(error.localizedDescription)")
        }
    }

    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("[AudioSession] Failed to deactivate: \(error.localizedDescription)")
        }
    }
}
