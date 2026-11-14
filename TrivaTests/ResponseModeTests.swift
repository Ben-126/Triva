//
//  ResponseModeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 16/09/2026.
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("ResponseMode")
struct ResponseModeTests {
    @Test("Exactement 3 cas — le mode debate de la version web d'origine est hors périmètre V1")
    func exactlyThreeCases() {
        #expect(ResponseMode.allCases.count == 3)
        #expect(ResponseMode.allCases == [.quick, .deep, .reliable])
    }

    @Test("Titres non vides et distincts")
    func titlesAreDistinctAndNonEmpty() {
        let titles = ResponseMode.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    @Test("Explications non vides et distinctes")
    func explanationsAreDistinctAndNonEmpty() {
        let explanations = ResponseMode.allCases.map(\.explanation)
        #expect(explanations.allSatisfy { !$0.isEmpty })
        #expect(Set(explanations).count == explanations.count)
    }

    @Test("Symboles SF Symbols non vides, distincts, sans emoji")
    func systemImagesAreDistinctAndValidLookingNames() {
        let symbols = ResponseMode.allCases.map(\.systemImage)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == symbols.count)
        // Un nom de symbole SF valide est composé de lettres ASCII, chiffres et points.
        let validCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.")
        for symbol in symbols {
            #expect(symbol.unicodeScalars.allSatisfy { validCharacters.contains($0) })
        }
    }

    @Test("targetSourceCount strictement positif pour chaque mode")
    func targetSourceCountIsPositive() {
        for mode in ResponseMode.allCases {
            #expect(mode.targetSourceCount > 0)
        }
    }

    @Test("maxSearchIterations strictement positif pour chaque mode")
    func maxSearchIterationsIsPositive() {
        for mode in ResponseMode.allCases {
            #expect(mode.maxSearchIterations > 0)
        }
    }

    @Test("quick est le mode le plus économe en itérations et en sources")
    func quickIsTheCheapestMode() {
        #expect(ResponseMode.quick.maxSearchIterations == 1)
        #expect(ResponseMode.quick.targetSourceCount <= ResponseMode.deep.targetSourceCount)
        #expect(ResponseMode.quick.maxSearchIterations <= ResponseMode.deep.maxSearchIterations)
    }

    @Test("deep reprend les valeurs par défaut historiques de SearchOrchestrator")
    func deepMatchesSearchOrchestratorDefaults() {
        // SearchOrchestrator.init(maxResultsUsedForContext: Int = 5, maxIterations: Int = 3)
        #expect(ResponseMode.deep.targetSourceCount == 5)
        #expect(ResponseMode.deep.maxSearchIterations == 3)
    }

    @Test("Seul reliable restreint aux domaines fiables")
    func onlyReliableRestrictsToTrustedDomains() {
        #expect(ResponseMode.quick.restrictsToTrustedDomains == false)
        #expect(ResponseMode.deep.restrictsToTrustedDomains == false)
        #expect(ResponseMode.reliable.restrictsToTrustedDomains == true)
    }

    /// Encoder un enum `String`-backed seul produit un fragment JSON top-level
    /// dont la prise en charge dépend de la plateforme/version de Foundation.
    /// On passe donc par un conteneur, la forme réaliste dans laquelle
    /// `ResponseMode` sera de toute façon toujours encodé (jamais tout seul).
    private struct Wrapper: Codable, Equatable {
        let mode: ResponseMode
    }

    @Test("Aller-retour Codable préserve le cas", arguments: ResponseMode.allCases)
    func codableRoundTrip(mode: ResponseMode) throws {
        let encoded = try JSONEncoder().encode(Wrapper(mode: mode))
        let decoded = try JSONDecoder().decode(Wrapper.self, from: encoded)
        #expect(decoded.mode == mode)
    }

    @Test("Les valeurs brutes String sont stables — c'est ce dont UserDefaults dépend")
    func rawValuesAreStable() {
        #expect(ResponseMode.quick.rawValue == "quick")
        #expect(ResponseMode.deep.rawValue == "deep")
        #expect(ResponseMode.reliable.rawValue == "reliable")
    }
}

@MainActor
@Suite("ResponseModeSettingsStore")
struct ResponseModeSettingsStoreTests {
    /// `UserDefaults` isolé par test, même principe que
    /// `MLXModelSelectionStoreTests.uniqueDefaults()`.
    private func uniqueDefaults() -> UserDefaults {
        TestDefaults.suite(named: "test.responseModeSettingsStore.\(UUID().uuidString)")!
    }

    @Test(".quick par défaut sans donnée stockée (décision de Ben)")
    func defaultsToQuickWithoutStoredData() {
        let store = ResponseModeSettingsStore(userDefaults: uniqueDefaults())
        #expect(store.selectedMode == .quick)
    }

    @Test("Persiste un mode d'une instance à l'autre")
    func persistsAcrossInit() {
        let defaults = uniqueDefaults()
        let store = ResponseModeSettingsStore(userDefaults: defaults)

        // `.deep` et pas `.quick` : `.quick` étant le défaut, le relire ne
        // prouverait pas que la valeur a été persistée.
        store.selectedMode = .deep

        let reloaded = ResponseModeSettingsStore(userDefaults: defaults)
        #expect(reloaded.selectedMode == .deep)
    }

    @Test("Écrase un mode précédent")
    func overwritesPreviousSelection() {
        let defaults = uniqueDefaults()
        let store = ResponseModeSettingsStore(userDefaults: defaults)
        store.selectedMode = .quick

        store.selectedMode = .reliable

        let reloaded = ResponseModeSettingsStore(userDefaults: defaults)
        #expect(reloaded.selectedMode == .reliable)
    }

    @Test("Une valeur stockée invalide (ex : ancien cas 'debate' retiré) retombe sur .quick")
    func invalidStoredValueFallsBackToDefault() {
        let defaults = uniqueDefaults()
        let storageKey = "chat.responseMode.selected"

        // Contrôle positif : prouve que cette clé est bien celle que le store
        // lit réellement, avant de s'appuyer dessus pour tester le repli —
        // sans ça, une clé qui aurait dérivé ferait passer ce test à vide
        // (le store verrait alors "aucune donnée stockée", pas "une valeur
        // invalide", et retomberait sur .quick pour une tout autre raison).
        // Valeur NON par défaut, sinon le contrôle ne prouverait rien.
        defaults.set("reliable", forKey: storageKey)
        #expect(ResponseModeSettingsStore(userDefaults: defaults).selectedMode == .reliable)

        defaults.set("debate", forKey: storageKey)
        let store = ResponseModeSettingsStore(userDefaults: defaults)

        #expect(store.selectedMode == .quick)
    }
}
