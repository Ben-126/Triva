//
//  SystemIntegrationPreferencesTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission A) : réglages de la section « Intégrations ». Défauts décidés par Ben le 2026-11-24.
//

import Foundation
import Testing
@testable import Triva

@Suite("Réglages des intégrations système")
struct SystemIntegrationPreferencesTests {
    private func makePreferences() throws -> (SystemIntegrationPreferences, UserDefaults) {
        let defaults = try #require(TestDefaults.suite(named: "test.systemPreferences.\(UUID().uuidString)"))
        return (SystemIntegrationPreferences(defaults: defaults), defaults)
    }

    @Test("Défauts : Spotlight allumé, activité en direct allumée, dernière question du widget ÉTEINTE")
    func defaults() throws {
        let (preferences, _) = try makePreferences()
        #expect(preferences.isSpotlightEnabled)
        #expect(preferences.isLiveActivityEnabled)
        #expect(!preferences.showsLastQuestionInWidget)
    }

    @Test("Chaque réglage s'écrit et se relit, sans toucher aux autres")
    func writesAreIndependent() throws {
        let (preferences, _) = try makePreferences()

        preferences.isSpotlightEnabled = false
        #expect(!preferences.isSpotlightEnabled)
        #expect(preferences.isLiveActivityEnabled)
        #expect(!preferences.showsLastQuestionInWidget)

        preferences.showsLastQuestionInWidget = true
        #expect(preferences.showsLastQuestionInWidget)
        #expect(!preferences.isSpotlightEnabled)

        preferences.isLiveActivityEnabled = false
        #expect(!preferences.isLiveActivityEnabled)
    }

    @Test("Les clés sont celles de la spec 2.1 §4.8 et les réglages se relisent par une autre instance")
    func keysAreStable() throws {
        let (preferences, defaults) = try makePreferences()
        preferences.isSpotlightEnabled = false
        preferences.showsLastQuestionInWidget = true
        preferences.isLiveActivityEnabled = false

        #expect(defaults.object(forKey: "system.spotlight.enabled") as? Bool == false)
        #expect(defaults.object(forKey: "system.widget.showsLastQuestion") as? Bool == true)
        #expect(defaults.object(forKey: "system.liveActivity.enabled") as? Bool == false)
        #expect(!SystemIntegrationPreferences(defaults: defaults).isSpotlightEnabled)
    }

    @Test("Une valeur d'un autre type ne vaut pas « faux » : retour au défaut")
    func wrongTypeFallsBackToDefault() throws {
        let (preferences, defaults) = try makePreferences()
        defaults.set("oui", forKey: SystemIntegrationPreferences.spotlightKey)
        defaults.set("non", forKey: SystemIntegrationPreferences.widgetLastQuestionKey)

        #expect(preferences.isSpotlightEnabled)
        #expect(!preferences.showsLastQuestionInWidget)
    }
}
