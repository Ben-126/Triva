//
//  TrivaShortcutCatalog.swift
//  Triva
//
//  Chantier 2.2 (M1) : catalogue de TOUS les raccourcis clavier de l'app (barre de menus,
//  Mac et iPad, et ceux restés dans les vues). Logique pure : décrit l'état cible du
//  chantier 2.2 ; les missions M2 à M5 y branchent les menus. Un test vérifie qu'aucun
//  raccourci n'est en double et qu'aucun ne masque un raccourci du système.
//

import Foundation

nonisolated struct ShortcutModifiers: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)
}

nonisolated struct ShortcutPlatforms: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let mac = ShortcutPlatforms(rawValue: 1 << 0)
    static let iPad = ShortcutPlatforms(rawValue: 1 << 1)
    static let iPhone = ShortcutPlatforms(rawValue: 1 << 2)
    static let allSingles: [ShortcutPlatforms] = [.mac, .iPad, .iPhone]
}

/// Où le raccourci est actif. `.global` : toute la fenêtre. Deux raccourcis de contextes
/// différents (hors global) peuvent partager la même touche.
nonisolated enum ShortcutContext: Sendable, Hashable {
    case global, discover, library, composer, imageViewer, sheet
}

/// Où il est déclaré : dans la barre de menus (`.commands`) ou dans une vue.
nonisolated enum ShortcutSource: Sendable, Hashable {
    case menu, view
}

nonisolated struct TrivaShortcut: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    /// Une seule lettre, un chiffre ou un signe en minuscule (« o », « 1 », « . »),
    /// ou une touche nommée : « escape », « leftArrow », « rightArrow ».
    let key: String
    let modifiers: ShortcutModifiers
    let platforms: ShortcutPlatforms
    let context: ShortcutContext
    let source: ShortcutSource

    /// Forme affichée, ordre d'Apple : ⌃ ⌥ ⇧ ⌘ puis la touche.
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keySymbol(for: key)
    }

    private static func keySymbol(for key: String) -> String {
        switch key {
        case "escape": return "⎋"
        case "leftArrow": return "←"
        case "rightArrow": return "→"
        case "upArrow": return "↑"
        case "downArrow": return "↓"
        case "return": return "↩"
        case "space": return "␣"
        case "tab": return "⇥"
        default: return key.uppercased()
        }
    }
}

nonisolated enum TrivaShortcutCatalog {
    private static func entry(
        _ id: String, _ title: String, _ key: String, _ modifiers: ShortcutModifiers,
        platforms: ShortcutPlatforms = [.mac, .iPad],
        context: ShortcutContext = .global, source: ShortcutSource = .menu
    ) -> TrivaShortcut {
        TrivaShortcut(id: id, title: title, key: key, modifiers: modifiers, platforms: platforms, context: context, source: source)
    }

    /// Titres : textes visibles (menus), à valider par Ben.
    static let all: [TrivaShortcut] = [
        entry("file.newSearch", "Nouvelle recherche", "n", .command),
        entry("file.newConversation", "Nouvelle conversation", "o", [.command, .shift]),
        entry("file.attach", "Joindre des fichiers…", "a", [.command, .shift]),
        entry("edit.searchHistory", "Rechercher dans l'historique", "f", .command),
        entry("edit.copyAnswer", "Copier la réponse", "c", [.command, .shift]),
        entry("go.search", "Recherche", "1", .command),
        entry("go.discover", "Découvrir", "2", .command),
        entry("go.library", "Bibliothèque", "3", .command),
        entry("go.favorites", "Favoris", "4", .command),
        entry("conversation.stop", "Arrêter la réponse", ".", .command),
        // iPad seulement : sur Mac, la scène Réglages possède déjà ⌘,.
        entry("app.settings", "Réglages…", ",", .command, platforms: [.iPad]),
        // Restés dans les vues.
        entry("discover.refresh", "Actualiser Découvrir", "r", .command,
              platforms: [.mac, .iPad, .iPhone], context: .discover, source: .view),
        entry("composer.stopGeneration", "Arrêter la génération", "escape", [],
              platforms: [.mac, .iPad, .iPhone], context: .composer, source: .view),
        entry("images.previous", "Image précédente", "leftArrow", [],
              platforms: [.mac, .iPad, .iPhone], context: .imageViewer, source: .view),
        entry("images.next", "Image suivante", "rightArrow", [],
              platforms: [.mac, .iPad, .iPhone], context: .imageViewer, source: .view)
    ]

    static func shortcuts(for platform: ShortcutPlatforms) -> [TrivaShortcut] {
        all.filter { !$0.platforms.isDisjoint(with: platform) }
    }

    // MARK: Doublons

    /// Paires qui se disputent la même touche : même touche, mêmes modificateurs, au moins
    /// une plateforme commune, et des contextes qui se recouvrent (identiques, ou l'un global).
    static func conflicts(in shortcuts: [TrivaShortcut] = all) -> [(TrivaShortcut, TrivaShortcut)] {
        var pairs: [(TrivaShortcut, TrivaShortcut)] = []
        for (index, first) in shortcuts.enumerated() {
            for second in shortcuts[(index + 1)...] where sameKey(first, second)
                && !first.platforms.isDisjoint(with: second.platforms)
                && contextsOverlap(first.context, second.context) {
                pairs.append((first, second))
            }
        }
        return pairs
    }

    private static func sameKey(_ a: TrivaShortcut, _ b: TrivaShortcut) -> Bool {
        a.key.lowercased() == b.key.lowercased() && a.modifiers == b.modifiers
    }

    private static func contextsOverlap(_ a: ShortcutContext, _ b: ShortcutContext) -> Bool {
        a == b || a == .global || b == .global
    }

    // MARK: Raccourcis du système

    private struct Reserved: Hashable {
        let key: String
        let modifiers: ShortcutModifiers
    }

    private static let commonReserved: Set<Reserved> = [
        Reserved(key: "q", modifiers: .command), Reserved(key: "h", modifiers: .command),
        Reserved(key: "m", modifiers: .command), Reserved(key: "w", modifiers: .command),
        Reserved(key: "c", modifiers: .command), Reserved(key: "v", modifiers: .command),
        Reserved(key: "x", modifiers: .command), Reserved(key: "z", modifiers: .command),
        Reserved(key: "z", modifiers: [.command, .shift]), Reserved(key: "a", modifiers: .command),
        Reserved(key: "space", modifiers: .command), Reserved(key: "tab", modifiers: .command)
    ]

    /// ⌘, appartient à la scène Réglages sur Mac ; l'iPad le laisse à l'app.
    private static let macOnlyReserved: Set<Reserved> = [
        Reserved(key: ",", modifiers: .command), Reserved(key: "h", modifiers: [.command, .option]),
        Reserved(key: "`", modifiers: .command), Reserved(key: "f", modifiers: [.command, .control]),
        Reserved(key: "escape", modifiers: [.command, .option])
    ]

    private static func reserved(for platform: ShortcutPlatforms) -> Set<Reserved> {
        platform == .mac ? commonReserved.union(macOnlyReserved) : commonReserved
    }

    /// Raccourcis qui reprennent une combinaison réservée au système sur l'une de leurs plateformes.
    static func systemShadowing(in shortcuts: [TrivaShortcut] = all) -> [TrivaShortcut] {
        shortcuts.filter { shortcut in
            let combination = Reserved(key: shortcut.key.lowercased(), modifiers: shortcut.modifiers)
            return ShortcutPlatforms.allSingles.contains { platform in
                shortcut.platforms.contains(platform) && reserved(for: platform).contains(combination)
            }
        }
    }
}
