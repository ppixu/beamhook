/// Keep one write in flight per slider source and only its newest pending value.
/// The final value drains even if the menu closes before the current send ends.
@MainActor
final class VolumeWriteCoalescer {
    private var pending: [String: () async -> Void] = [:]
    private var active: Set<String> = []

    func submit(source: String, write: @escaping () async -> Void) {
        pending[source] = write
        guard active.insert(source).inserted else { return }
        Task {
            while let write = pending.removeValue(forKey: source) {
                await write()
            }
            active.remove(source)
        }
    }
}
