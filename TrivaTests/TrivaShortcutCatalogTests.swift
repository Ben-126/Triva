//
//  TrivaShortcutCatalogTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M1) : catalogue des raccourcis clavier de l'app.
//

import Foundation
import Testing
@testable import Triva

struct TrivaShortcutCatalogTests {
    private func shortcut(
        _ id: String, key: String, _ modifiers: ShortcutModifiers,
        platforms: ShortcutPlatforms = [.mac, .iPad], context: ShortcutContext = .global
    ) -> TrivaShortcut {
        TrivaShortcut(id: id, title: id, key: key, modifiers: modifiers, platforms: platforms, context: context, source: .menu)
    }

    // MARK: - Le catalogue réel

    @Test("Aucun doublon dans le catalogue réel")
    func realCatalogHasNoConflict() {
        #expect(TrivaShortcutCatalog.conflicts().isEmpty)
        let ids = TrivaShortcutCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Aucun raccourci du catalogue ne masque un raccourci système, sur chaque plateforme")
    func realCatalogAvoidsSystemShortcuts() {
        #expect(TrivaShortcutCatalog.systemShadowing().isEmpty)
    }

    @Test("Chaque entrée a un titre, une touche, au moins une plateforme")
    func entriesAreWellFormed() {
        for entry in TrivaShortcutCatalog.all {
            #expect(!entry.title.isEmpty, "\(entry.id)")
            #expect(!entry.key.isEmpty, "\(entry.id)")
            #expect(!entry.platforms.isEmpty, "\(entry.id)")
        }
    }

    @Test("Les raccourcis décidés par le chef : ⌘N nouvelle recherche (fenêtre), ⇧⌘O nouvelle conversation")
    func decidedShortcuts() throws {
        let newSearch = try #require(TrivaShortcutCatalog.all.first { $0.id == "file.newSearch" })
        #expect(newSearch.displayString == "⌘N")
        let newConversation = try #require(TrivaShortcutCatalog.all.first { $0.id == "file.newConversation" })
        #expect(newConversation.displayString == "⇧⌘O")
        let attach = try #require(TrivaShortcutCatalog.all.first { $0.id == "file.attach" })
        #expect(attach.displayString == "⇧⌘A")
    }

    @Test("Les raccourcis existants restés dans les vues sont catalogués (⌘R Découvrir, Échap, flèches des images)")
    func viewShortcutsAreListed() {
        let ids = Set(TrivaShortcutCatalog.all.map(\.id))
        #expect(ids.isSuperset(of: ["discover.refresh", "composer.stopGeneration", "images.previous", "images.next"]))
    }

    @Test("⌘, : absent sur Mac (la scène Réglages le possède), présent sur iPad seulement")
    func settingsShortcutIsIPadOnly() throws {
        let settings = try #require(TrivaShortcutCatalog.all.first { $0.id == "app.settings" })
        #expect(settings.platforms == [.iPad])
        #expect(TrivaShortcutCatalog.shortcuts(for: .mac).allSatisfy { $0.id != "app.settings" })
        #expect(TrivaShortcutCatalog.shortcuts(for: .iPad).contains { $0.id == "app.settings" })
    }

    @Test("Aller : ⌘1 à ⌘4 dans l'ordre des destinations")
    func goShortcuts() {
        let go = ["go.search": "⌘1", "go.discover": "⌘2", "go.library": "⌘3", "go.favorites": "⌘4"]
        for (id, display) in go {
            #expect(TrivaShortcutCatalog.all.first { $0.id == id }?.displayString == display, "\(id)")
        }
    }

    // MARK: - Détection (le test ne doit pas être vide de sens)

    @Test("Détection : deux raccourcis globaux identiques sur une même plateforme sont en conflit")
    func detectsGlobalDuplicate() {
        let a = shortcut("a", key: "n", .command)
        let b = shortcut("b", key: "n", .command)
        #expect(TrivaShortcutCatalog.conflicts(in: [a, b]).count == 1)
    }

    @Test("Détection : même touche sur deux plateformes disjointes, ou avec modificateurs différents : pas de conflit")
    func noFalseConflict() {
        let mac = shortcut("a", key: "n", .command, platforms: [.mac])
        let ipad = shortcut("b", key: "n", .command, platforms: [.iPad])
        let shifted = shortcut("c", key: "n", [.command, .shift])
        #expect(TrivaShortcutCatalog.conflicts(in: [mac, ipad, shifted]).isEmpty)
    }

    @Test("Détection : un raccourci de contexte contre un global est un conflit, deux contextes différents non")
    func contextRules() {
        let global = shortcut("g", key: "r", .command)
        let discover = shortcut("d", key: "r", .command, context: .discover)
        let library = shortcut("l", key: "r", .command, context: .library)
        #expect(TrivaShortcutCatalog.conflicts(in: [global, discover]).count == 1)
        #expect(TrivaShortcutCatalog.conflicts(in: [discover, library]).isEmpty)
        #expect(TrivaShortcutCatalog.conflicts(in: [discover, shortcut("d2", key: "r", .command, context: .discover)]).count == 1)
    }

    @Test("Détection : un raccourci qui reprend ⌘Q, ⌘H, ⌘M, ⌘W, ⌘C, ⌘V, ⌘X, ⌘Z, ⌘A est signalé")
    func detectsSystemShadowing() {
        let reserved = ["q", "h", "m", "w", "c", "v", "x", "z", "a"]
        for key in reserved {
            let entry = shortcut("s.\(key)", key: key, .command)
            #expect(TrivaShortcutCatalog.systemShadowing(in: [entry]).count == 1, "⌘\(key)")
        }
    }

    @Test("⌘, est réservé sur Mac seulement")
    func commaReservedOnMacOnly() {
        let onMac = shortcut("m", key: ",", .command, platforms: [.mac])
        let onIPad = shortcut("i", key: ",", .command, platforms: [.iPad])
        #expect(TrivaShortcutCatalog.systemShadowing(in: [onMac]).count == 1)
        #expect(TrivaShortcutCatalog.systemShadowing(in: [onIPad]).isEmpty)
    }

    @Test("Un raccourci à plusieurs plateformes est signalé s'il masque le système sur l'une d'elles")
    func shadowingOnOnePlatformOnly() {
        let both = shortcut("b", key: ",", .command, platforms: [.mac, .iPad])
        #expect(TrivaShortcutCatalog.systemShadowing(in: [both]).count == 1)
    }

    // MARK: - Affichage

    @Test("displayString : ordre ⌃⌥⇧⌘ puis touche en majuscule ; touches nommées en symbole")
    func displayStrings() {
        #expect(shortcut("x", key: "o", [.command, .shift]).displayString == "⇧⌘O")
        #expect(shortcut("x", key: "a", [.command, .option, .shift, .control]).displayString == "⌃⌥⇧⌘A")
        #expect(shortcut("x", key: ".", .command).displayString == "⌘.")
        #expect(shortcut("x", key: "escape", []).displayString == "⎋")
        #expect(shortcut("x", key: "leftArrow", []).displayString == "←")
        #expect(shortcut("x", key: "rightArrow", []).displayString == "→")
    }
}
