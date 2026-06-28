import AppKit

final class TapWatchdog {
    private let tap: MediaKeyTap
    private var timer: Timer?

    init(tap: MediaKeyTap) {
        self.tap = tap
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.tap.ensureEnabled()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    @objc private func systemDidWake() {
        tap.recreate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    deinit { stop() }
}
