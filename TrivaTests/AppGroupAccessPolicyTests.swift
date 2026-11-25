//
//  AppGroupAccessPolicyTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : sur Mac, l'app ne touche pas le conteneur de l'App Group tant que le réglage du widget
//  n'a jamais été allumé (un groupe hors préfixe d'équipe peut y déclencher une invite d'accès).
//

import Foundation
import Testing
@testable import Triva

@Suite("Accès au conteneur de l'App Group")
struct AppGroupAccessPolicyTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "TrivaPolicyTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Mac, réglage jamais allumé : ni le widget ni la boîte de partage ne touchent le conteneur")
    func macNeverEnabled() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = AppGroupAccessPolicy(isMac: true, defaults: defaults)
        #expect(policy.mayTouchWidgetContainer == false)
        #expect(policy.mayTouchShareInbox == false)
    }

    @Test("Mac, réglage allumé une fois : le widget peut toucher le conteneur (même éteint ensuite) ; la boîte de partage jamais")
    func macAfterEnabling() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = AppGroupAccessPolicy(isMac: true, defaults: defaults)
        policy.noteWidgetEnabled()
        #expect(policy.mayTouchWidgetContainer)
        #expect(policy.mayTouchShareInbox == false)
        // Un autre objet sur les mêmes réglages le voit aussi (le drapeau est dans les réglages de l'app).
        #expect(AppGroupAccessPolicy(isMac: true, defaults: defaults).mayTouchWidgetContainer)
    }

    @Test("iPhone et iPad : toujours permis, sans drapeau")
    func iosAlwaysAllowed() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = AppGroupAccessPolicy(isMac: false, defaults: defaults)
        #expect(policy.mayTouchWidgetContainer)
        #expect(policy.mayTouchShareInbox)
    }

    @Test("Le drapeau n'est posé que par noteWidgetEnabled()")
    func flagIsOnlySetExplicitly() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = AppGroupAccessPolicy(isMac: true, defaults: defaults).mayTouchWidgetContainer
        #expect(defaults.object(forKey: AppGroupAccessPolicy.widgetEverEnabledKey) == nil)
    }
}
