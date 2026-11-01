//
//  TrivaRootNavigationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 16/09/2026.
//

import Testing
import SwiftUI
@testable import Triva

/// Tests de la seule logique pure de la coquille de navigation racine : le
/// choix de présentation (onglets / sidebar) et la description des
/// destinations. Le reste de la coquille est de l'assemblage SwiftUI, qui
/// relève du test manuel — pas de XCUITest ici (voir CLAUDE.md).
@MainActor
@Suite("Coquille de navigation racine")
struct TrivaRootNavigationTests {
    @Test("Une classe de taille compacte donne des onglets")
    func compactUsesTabs() {
        #expect(TrivaRootNavigationStyle.preferred(for: .compact) == .tabs)
    }

    @Test("Une classe de taille regular donne la sidebar")
    func regularUsesSidebar() {
        #expect(TrivaRootNavigationStyle.preferred(for: .regular) == .sidebar)
    }

    /// macOS ne fournit pas toujours de classe de taille horizontale : l'absence
    /// de valeur ne doit jamais dégrader une fenêtre Mac en barre d'onglets
    /// iPhone.
    @Test("Aucune classe de taille (macOS) donne la sidebar")
    func missingSizeClassUsesSidebar() {
        #expect(TrivaRootNavigationStyle.preferred(for: nil) == .sidebar)
    }

    @Test("Les 5 destinations V1 sont dans l'ordre de la barre d'onglets")
    func destinationsAreOrderedForTheTabBar() {
        #expect(TrivaRootDestination.allCases == [.search, .discover, .library, .favorites, .settings])
    }

    /// iOS n'affiche que 5 onglets avant de replier le reste dans un menu
    /// "Plus" : dépasser 5 destinations de premier niveau changerait la
    /// présentation sans qu'on s'en rende compte.
    @Test("Il n'y a jamais plus de 5 destinations de premier niveau")
    func destinationCountFitsTheTabBar() {
        #expect(TrivaRootDestination.allCases.count <= 5)
    }

    @Test("Chaque destination a un libellé français court et un SF Symbol")
    func destinationsHaveLabelAndSymbol() {
        for destination in TrivaRootDestination.allCases {
            #expect(!destination.title.isEmpty)
            #expect(!destination.systemImage.isEmpty)
        }

        #expect(TrivaRootDestination.search.title == "Recherche")
        #expect(TrivaRootDestination.discover.title == "Découvrir")
        #expect(TrivaRootDestination.library.title == "Bibliothèque")
        #expect(TrivaRootDestination.favorites.title == "Favoris")
        #expect(TrivaRootDestination.settings.title == "Réglages")
    }

    /// Deux destinations qui partagent la même icône rendraient la barre
    /// d'onglets illisible — et c'est le genre de doublon qu'on introduit sans
    /// le voir en ajoutant une destination.
    @Test("Deux destinations ne partagent jamais le même SF Symbol")
    func destinationSymbolsAreUnique() {
        let symbols = TrivaRootDestination.allCases.map(\.systemImage)
        #expect(Set(symbols).count == symbols.count)
    }
}
