//
//  TrivaCommands.swift
//  Triva
//
//  Chantier 2.2 (M4) : barre de menus du Mac et menu clavier de l'iPad (touche ⌘ maintenue).
//
//  Chaque item agit sur la fenêtre au premier plan : la coquille publie son coordinateur par
//  `.focusedSceneValue`, lu ici par `@FocusedValue`. Sans fenêtre (Mac, toutes fermées), les items qui
//  ont besoin d'une fenêtre sont grisés (HIG : un item reste visible, grisé quand il ne s'applique pas).
//
//  Libellés et raccourcis viennent de `TrivaShortcutCatalog`, la table unique testée contre les doublons et
//  les raccourcis du système : un raccourci ne se déclare pas deux fois.
//

import SwiftUI

/// Identifiants du catalogue utilisés par les menus (un test vérifie qu'ils existent tous).
nonisolated enum TrivaCommandID {
    static let newSearch = "file.newSearch"
    static let newConversation = "file.newConversation"
    static let attach = "file.attach"
    static let searchHistory = "edit.searchHistory"
    static let copyAnswer = "edit.copyAnswer"
    static let goSearch = "go.search"
    static let goDiscover = "go.discover"
    static let goLibrary = "go.library"
    static let goFavorites = "go.favorites"
    static let stop = "conversation.stop"
    static let settings = "app.settings"

    /// Tous ceux que `TrivaCommands` déclare.
    static let all = [
        newSearch, newConversation, attach, searchHistory, copyAnswer,
        goSearch, goDiscover, goLibrary, goFavorites, stop, settings
    ]
}

extension TrivaShortcut {
    /// Raccourci SwiftUI équivalent ; `nil` pour une touche que les menus ne gèrent pas (aucune aujourd'hui).
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "escape": return .escape
        case "leftArrow": return .leftArrow
        case "rightArrow": return .rightArrow
        case "upArrow": return .upArrow
        case "downArrow": return .downArrow
        case "return": return .return
        case "space": return .space
        case "tab": return .tab
        default:
            guard key.count == 1, let character = key.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    private var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

extension TrivaShortcutCatalog {
    static func shortcut(id: String) -> TrivaShortcut? {
        all.first { $0.id == id }
    }
}

struct TrivaCommands: Commands {
    @FocusedValue(TrivaRootCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some Commands {
        // Remplace « Nouvelle fenêtre » (⌘N) : une recherche = une fenêtre (M2). L'iPhone n'a qu'une
        // fenêtre : « Nouvelle recherche » y repart d'une conversation vierge.
        CommandGroup(replacing: .newItem) {
            item(TrivaCommandID.newSearch, enabled: supportsMultipleWindows || coordinator != nil) { newSearch() }
            item(TrivaCommandID.newConversation, enabled: coordinator?.canStartNewConversation ?? false) {
                coordinator?.startNewConversationFromMenu()
            }
            Divider()
            item(TrivaCommandID.attach, enabled: coordinator != nil) { coordinator?.requestAttachFiles() }
        }
        CommandGroup(after: .textEditing) {
            item(TrivaCommandID.searchHistory, enabled: coordinator != nil) { coordinator?.requestHistorySearch() }
        }
        CommandGroup(after: .pasteboard) {
            item(TrivaCommandID.copyAnswer, enabled: coordinator?.copyableAnswerText != nil) {
                coordinator?.copyLastAnswer()
            }
        }
        CommandMenu("Aller") {
            go(TrivaCommandID.goSearch, .search)
            go(TrivaCommandID.goDiscover, .discover)
            go(TrivaCommandID.goLibrary, .library)
            go(TrivaCommandID.goFavorites, .favorites)
        }
        CommandMenu("Conversation") {
            item(TrivaCommandID.stop, enabled: coordinator?.canStopGeneration ?? false) { coordinator?.stopGeneration() }
        }
        #if os(iOS)
        // iPad : pas de scène Réglages. Sur Mac, la scène `Settings` possède déjà ⌘, : ne pas la remplacer.
        CommandGroup(replacing: .appSettings) {
            item(TrivaCommandID.settings, enabled: coordinator != nil) { coordinator?.showSettings() }
        }
        #endif
    }

    private func go(_ id: String, _ destination: TrivaRootDestination) -> some View {
        item(id, enabled: coordinator != nil) { coordinator?.go(to: destination) }
    }

    private func item(_ id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        let shortcut = TrivaShortcutCatalog.shortcut(id: id)
        assert(shortcut != nil, "Raccourci absent du catalogue : \(id)")
        return Button(shortcut?.title ?? id, action: action)
            .keyboardShortcut(shortcut?.keyboardShortcut)
            .disabled(!enabled)
    }

    /// ⌘N : une fenêtre neuve, avec un identifiant NEUF (sans lui, SwiftUI ramènerait la fenêtre vide déjà ouverte).
    private func newSearch() {
        if supportsMultipleWindows {
            openWindow(id: TrivaWindowTarget.sceneID, value: TrivaWindowTarget.freshSearch())
        } else {
            coordinator?.startNewConversationFromMenu()
        }
    }
}
