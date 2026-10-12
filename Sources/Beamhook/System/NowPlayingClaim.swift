import MediaPlayer
import BeamhookKit
import os

/// Makes Beamhook the system's Now Playing app so headphone buttons reach it.
///
/// AirPods and Bluetooth headsets send play/pause/next/previous over AVRCP.
/// macOS turns those into MediaRemote commands for the Now Playing app — they
/// never become the system-defined events `MediaKeyTap` sees. Registering
/// `MPRemoteCommandCenter` handlers and publishing a playback state makes
/// Beamhook eligible; macOS gives the role to whichever app most recently
/// published, so `claim(force:)` re-publishes even an unchanged state.
@MainActor
final class NowPlayingClaim {
    private static let log = Logger(subsystem: "com.github.ppixu.beamhook", category: "NowPlaying")

    private let onCommand: @MainActor (HeadphoneCommand) -> Void
    private var isClaimed = false
    private var published: (title: String, playing: Bool?)?

    init(onCommand: @escaping @MainActor (HeadphoneCommand) -> Void) {
        self.onCommand = onCommand
    }

    /// `playing` mirrors the hooked app (nil when unknown — shown as paused).
    /// Without `force`, an unchanged state isn't re-published.
    func claim(title: String, playing: Bool?, force: Bool = false) {
        if !isClaimed {
            registerCommands()
            isClaimed = true
            Self.log.info("claimed Now Playing for \(title, privacy: .public)")
        } else if !force, let published, published.title == title, published.playing == playing {
            return
        }
        published = (title, playing)

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Beamhook",
            MPNowPlayingInfoPropertyPlaybackRate: playing == true ? 1.0 : 0.0,
        ]
        center.playbackState = playing == true ? .playing : .paused
    }

    /// Hands the headphone buttons back to macOS's own Now Playing choice.
    func release() {
        guard isClaimed else { return }
        isClaimed = false
        published = nil
        let commands = MPRemoteCommandCenter.shared()
        for command in Self.routedCommands(commands).map(\.1) {
            command.removeTarget(nil)
            command.isEnabled = false
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        Self.log.info("released Now Playing")
    }

    private func registerCommands() {
        for (kind, command) in Self.routedCommands(MPRemoteCommandCenter.shared()) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                // MediaPlayer calls handlers on the main thread.
                MainActor.assumeIsolated { self?.onCommand(kind) }
                return .success
            }
        }
    }

    private static func routedCommands(_ center: MPRemoteCommandCenter) -> [(HeadphoneCommand, MPRemoteCommand)] {
        [
            (.togglePlayPause, center.togglePlayPauseCommand),
            (.play, center.playCommand),
            (.pause, center.pauseCommand),
            (.next, center.nextTrackCommand),
            (.previous, center.previousTrackCommand),
        ]
    }
}
