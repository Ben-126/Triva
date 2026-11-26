//
//  HandoffPlanTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H1) : quand Triva diffuse une activité Handoff. Réglage éteint, rien à dire ou texte vide :
//  `nil`, donc `isActive == false` côté SwiftUI et plus rien n'est proposé.
//

import Foundation
import Testing
@testable import Triva

@Suite("Handoff : quand diffuser")
struct HandoffPlanTests {
    private let id = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!

    @Test("Réglage éteint : rien n'est diffusé, quel que soit le texte")
    func disabledAdvertisesNothing() {
        let payload = HandoffPlan.payload(isEnabled: false, draft: "Un texte", lastQuestion: "Une question", conversationID: id)
        #expect(payload == nil)
        #expect(!HandoffPlan.isActive(isEnabled: false, draft: "Un texte", lastQuestion: nil))
    }

    @Test("Allumé avec un texte dans la barre : c'est ce texte qui part, marqué comme texte tapé")
    func draftWins() {
        let payload = HandoffPlan.payload(isEnabled: true, draft: "Brouillon", lastQuestion: "Question d'avant", conversationID: nil)
        #expect(payload?.draft == "Brouillon")
        #expect(payload?.draftIsTyped == true)
        #expect(HandoffPlan.isActive(isEnabled: true, draft: "Brouillon", lastQuestion: "Question d'avant"))
    }

    @Test("Barre vide ou blanche : à défaut, la dernière question, marquée comme telle (elle est déjà dans la discussion)")
    func lastQuestionIsTheFallback() {
        for empty in ["", "   \n", nil] {
            let payload = HandoffPlan.payload(isEnabled: true, draft: empty, lastQuestion: "Question d'avant", conversationID: nil)
            #expect(payload?.draft == "Question d'avant")
            #expect(payload?.draftIsTyped == false)
        }
    }

    @Test("Ni brouillon ni question : rien à proposer")
    func nothingToSay() {
        let payload = HandoffPlan.payload(isEnabled: true, draft: "  ", lastQuestion: nil, conversationID: id)
        #expect(payload == nil)
        #expect(!HandoffPlan.isActive(isEnabled: true, draft: "", lastQuestion: " "))
    }

    @Test("Décision de Ben (26/11) : l'identifiant de la conversation part toujours avec le texte, il annonce la discussion")
    func conversationIsAlwaysOffered() {
        let withConversation = HandoffPlan.payload(isEnabled: true, draft: "Texte", lastQuestion: nil, conversationID: id)
        let noConversation = HandoffPlan.payload(isEnabled: true, draft: "Texte", lastQuestion: nil, conversationID: nil)
        #expect(withConversation?.conversationID == id)
        #expect(noConversation?.conversationID == nil)
    }

    @Test("Interrupteur de code : éteint, on retrouve exactement le comportement de H1 (le texte seul, jamais d'identifiant)")
    func killSwitchRestoresDraftOnly() {
        #expect(HandoffPlan.offersConversation == true)
        let payload = HandoffPlan.payload(
            isEnabled: true, draft: "Texte", lastQuestion: nil, conversationID: id, offersConversation: false
        )
        #expect(payload?.conversationID == nil)
        #expect(Set(payload?.userInfo.keys.map { $0 } ?? []) == ["v", "draft"])
    }

    @Test("L'en-tête ne porte jamais la réponse : la version, le texte, son genre et l'identifiant, rien d'autre")
    func headerNeverCarriesTheAnswer() throws {
        let payload = try #require(HandoffPlan.payload(isEnabled: true, draft: "Question", lastQuestion: nil, conversationID: id))
        #expect(Set(payload.userInfo.keys).isSubset(of: ["v", "draft", "conversationID", "typed"]))
    }
}

@Suite("Handoff : réglage")
struct HandoffPreferenceTests {
    private func makePreferences() throws -> SystemIntegrationPreferences {
        let defaults = try #require(TestDefaults.suite(named: "test.handoffPreference.\(UUID().uuidString)"))
        return SystemIntegrationPreferences(defaults: defaults)
    }

    @Test("Allumé par défaut (recommandation de la spec 2.3, Q4 : à valider par Ben)")
    func onByDefault() throws {
        #expect(SystemIntegrationPreferences.handoffDefault)
        #expect(try makePreferences().isHandoffEnabled)
    }

    @Test("La clé est stable et le réglage s'écrit sans toucher aux autres")
    func keyAndIndependence() throws {
        #expect(SystemIntegrationPreferences.handoffKey == "system.handoff.enabled")
        let preferences = try makePreferences()
        preferences.isHandoffEnabled = false
        #expect(!preferences.isHandoffEnabled)
        #expect(preferences.isSpotlightEnabled)
        #expect(preferences.isLiveActivityEnabled)
        #expect(!preferences.showsLastQuestionInWidget)
        preferences.isHandoffEnabled = true
        #expect(preferences.isHandoffEnabled)
    }
}
