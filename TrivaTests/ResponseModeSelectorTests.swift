//
//  ResponseModeSelectorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/10/2026.
//

import Foundation
import SwiftUI
import Testing
@testable import Triva

/// `UserDefaults` isolé par test, même principe que
/// `ResponseModeSettingsStoreTests.uniqueDefaults()`.
private func uniqueSelectorDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "test.responseModeSelector.\(UUID().uuidString)"))
}

/// `@MainActor` : `ResponseModeSelectorPresentation`, `ResponseModeSelector` et
/// `ResponseModeSettingsStore` sont isolés au main actor (isolation par défaut
/// de l'app, et `ResponseMode` n'est pas `nonisolated`).
@MainActor
@Suite("Sélecteur de mode de réponse")
struct ResponseModeSelectorTests {

    // MARK: Présentation

    @Test("Le titre ne disparaît qu'en largeur compacte ; nil (macOS) vaut une largeur confortable")
    func showsTitleOutsideCompactWidth() {
        #expect(ResponseModeSelectorPresentation.showsTitle(for: nil))
        #expect(ResponseModeSelectorPresentation.showsTitle(for: .regular))
        #expect(!ResponseModeSelectorPresentation.showsTitle(for: .compact))
    }

    @Test("L'infobulle reprend le titre et l'explication de chaque mode, sans les réécrire")
    func helpTextReusesModeTexts() {
        for mode in ResponseMode.allCases {
            let help = ResponseModeSelectorPresentation.helpText(for: mode)
            #expect(help.hasPrefix(ResponseModeSelectorPresentation.controlTitle))
            #expect(help.contains(mode.title))
            #expect(help.contains(mode.explanation))
        }
    }

    // MARK: Branchement sur le store

    @Test("init(store:) affiche le mode du store")
    func storeInitializerReadsStoreValue() throws {
        let store = ResponseModeSettingsStore(userDefaults: try uniqueSelectorDefaults())
        store.selectedMode = .reliable

        #expect(ResponseModeSelector(store: store).selection == .reliable)
    }

    @Test("Un choix dans le menu est écrit dans le store, et mémorisé entre deux lancements")
    func choiceIsWrittenThroughAndPersisted() throws {
        let defaults = try uniqueSelectorDefaults()
        let store = ResponseModeSettingsStore(userDefaults: defaults)
        let selector = ResponseModeSelector(store: store)

        selector.selection = .reliable

        #expect(store.selectedMode == .reliable)
        let relaunched = ResponseModeSelector(store: ResponseModeSettingsStore(userDefaults: defaults))
        #expect(relaunched.selection == .reliable)
    }

    // MARK: Décision de Ben : Rapide par défaut

    /// Rouge tant que `ResponseModeSettingsStore.defaultMode` vaut `.deep`
    /// (`Triva/Core/Search/ResponseMode.swift`) : la décision de Ben est
    /// Rapide par défaut. Corriger le store, pas ce test.
    @Test("Sans choix mémorisé, le menu affiche Rapide")
    func defaultsToQuickWithoutStoredValue() throws {
        let store = ResponseModeSettingsStore(userDefaults: try uniqueSelectorDefaults())

        #expect(ResponseModeSelector(store: store).selection == .quick)
    }

    /// Même remarque que ci-dessus. Contrôle positif d'abord, avec une valeur
    /// différente du défaut : prouve que la clé est bien celle que lit le
    /// store, sinon le repli serait testé à vide.
    @Test("Valeur mémorisée inconnue (ancien « debate » du web) : retour à Rapide")
    func unknownStoredValueFallsBackToQuick() throws {
        let defaults = try uniqueSelectorDefaults()
        let storageKey = "chat.responseMode.selected"
        defaults.set("reliable", forKey: storageKey)
        #expect(ResponseModeSelector(store: ResponseModeSettingsStore(userDefaults: defaults)).selection == .reliable)

        defaults.set("debate", forKey: storageKey)

        #expect(ResponseModeSelector(store: ResponseModeSettingsStore(userDefaults: defaults)).selection == .quick)
    }
}
