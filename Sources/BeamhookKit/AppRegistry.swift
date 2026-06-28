import Foundation

public final class AppRegistry: MediaAppResolver {
    private let store: AppDefinitionStore
    private let executor: ScriptExecuting
    private let presence: AppPresenceChecking

    public init(store: AppDefinitionStore, executor: ScriptExecuting, presence: AppPresenceChecking) {
        self.store = store
        self.executor = executor
        self.presence = presence
    }

    public func allApps() -> [MediaApp] {
        store.allDefinitions().map {
            ScriptedMediaApp(definition: $0, executor: executor, presence: presence)
        }
    }

    public func app(withID id: String) -> MediaApp? {
        guard let def = store.allDefinitions().first(where: { $0.id == id }) else { return nil }
        return ScriptedMediaApp(definition: def, executor: executor, presence: presence)
    }
}
