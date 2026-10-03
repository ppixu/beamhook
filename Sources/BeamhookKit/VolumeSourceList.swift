import Foundation

/// A sounding source listed during a volume or mute picker session.
public enum VolumeSource: Hashable, Sendable {
    /// Whatever is hooked — for a browser, its selected tab. Routed through
    /// `TargetManager` exactly like a volume key outside a session.
    case hookedTarget
    /// Another sounding app, including apps that support only mute.
    case app(bundleID: String)
    /// A browser tab, by `BrowserMediaCandidate.id`.
    case browserTab(id: String)

    /// Stable across list refreshes; used to keep the selection and as the
    /// mute-memory key.
    public var id: String {
        switch self {
        case .hookedTarget: return "target"
        case .app(let bundleID): return "app:\(bundleID)"
        case .browserTab(let id): return "tab:\(id)"
        }
    }
}

public struct VolumeSourceEntry: Equatable, Sendable {
    public let source: VolumeSource
    public let name: String
    public let parentSource: VolumeSource?

    public init(source: VolumeSource, name: String, parentSource: VolumeSource? = nil) {
        self.parentSource = parentSource
        self.source = source
        self.name = name
    }
}

/// The rows of the volume-source picker: the hooked target first, then other
/// playing apps, with browser tabs grouped below their parent. Selection
/// wraps at both ends and survives refreshes by source identity, because tabs
/// arrive a moment after the list first appears.
public struct VolumeSourceList: Equatable, Sendable {
    public private(set) var entries: [VolumeSourceEntry] = []
    public private(set) var selectedIndex = 0

    public var selected: VolumeSourceEntry? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
    }

    public init(target: VolumeSourceEntry?, apps: [VolumeSourceEntry], tabs: [VolumeSourceEntry]) {
        entries = Self.ordered(target: target, apps: apps, tabs: tabs)
        selectedIndex = entries.firstIndex { $0.source == target?.source } ?? 0
    }

    public mutating func selectNext() {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % entries.count
    }

    public mutating func selectPrevious() {
        guard !entries.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + entries.count) % entries.count
    }

    /// Swap in fresh rows, keeping the selected source if it is still listed and
    /// otherwise landing on the row that took its place.
    public mutating func replace(target: VolumeSourceEntry?, apps: [VolumeSourceEntry],
                                 tabs: [VolumeSourceEntry]) {
        let previous = selected?.source
        entries = Self.ordered(target: target, apps: apps, tabs: tabs)
        if let previous, let index = entries.firstIndex(where: { $0.source == previous }) {
            selectedIndex = index
        } else {
            selectedIndex = entries.isEmpty ? 0 : min(selectedIndex, entries.count - 1)
        }
    }

    private static func ordered(target: VolumeSourceEntry?, apps: [VolumeSourceEntry],
                                tabs: [VolumeSourceEntry]) -> [VolumeSourceEntry] {
        var seen = Set<VolumeSource>()
        let all = (target.map { [$0] } ?? []) + apps + tabs
        let unique = all.filter { seen.insert($0.source).inserted }
        let sources = Set(unique.map(\.source))
        var result: [VolumeSourceEntry] = []
        for entry in unique where entry.parentSource.map({ sources.contains($0) }) != true {
            result.append(entry)
            result.append(contentsOf: unique.filter { $0.parentSource == entry.source }.sorted {
                switch $0.name.localizedStandardCompare($1.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return $0.source.id < $1.source.id
                }
            })
        }
        return result
    }
}
