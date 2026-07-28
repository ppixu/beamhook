import Foundation

public final class AppRegistry: MediaAppResolver {
    private let store: AppDefinitionStore
    private let executor: ScriptExecuting
    private let presser: MenuItemPressing
    private let presence: AppPresenceChecking

    public init(store: AppDefinitionStore, executor: ScriptExecuting,
                presser: MenuItemPressing, presence: AppPresenceChecking) {
        self.store = store
        self.executor = executor
        self.presser = presser
        self.presence = presence
    }

    public func allApps() -> [MediaApp] {
        store.allDefinitions().map(make)
    }

    public func app(withID id: String) -> MediaApp? {
        guard let def = store.allDefinitions().first(where: { $0.id == id }) else { return nil }
        return make(def)
    }

    /// A definition carrying a `menuControl` is driven through the menu bar; every
    /// other one is driven by AppleScript.
    private func make(_ definition: AppDefinition) -> MediaApp {
        if let menuApp = MenuDrivenMediaApp(definition: definition, presser: presser, presence: presence) {
            return menuApp
        }
        return ScriptedMediaApp(definition: definition, executor: executor, presence: presence)
    }
}
