//
//  SpotlightWordingTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission I, décision de Ben du 25/11) : « Historique dans la recherche de l'appareil » devient
//  « Historique dans Spotlight », et le même mot « Spotlight » remplace « la recherche de l'appareil » partout où
//  l'app en parle (les pages de confidentialité sont vérifiées par grep : l'app de test est dans un bac à sable). Nouveaux textes de l'activité en direct (« à valider par Ben »).
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Spotlight : un seul mot partout")
struct SpotlightWordingTests {
    private let oldPhrase = "recherche de l'appareil"

    @Test("Le réglage s'appelle « Historique dans Spotlight »")
    func spotlightTitle() {
        #expect(SystemIntegrationsText.spotlightTitle == "Historique dans Spotlight")
    }

    @Test("Aucun texte des Réglages ne parle encore de « la recherche de l'appareil »")
    func settingsTextsUseSpotlight() {
        let texts = [
            SystemIntegrationsText.spotlightTitle,
            SystemIntegrationsText.spotlightDetail,
            SystemIntegrationsText.widgetDetail,
            SystemIntegrationsText.liveActivityDetail,
            SystemIntegrationsText.questionTitle,
            SystemIntegrationsText.questionDetail,
            SystemIntegrationsText.footer,
            LocalDataEraseSection.confirmationMessage,
            LocalDataEraseSection.idleFooterMessage,
            LocalDataEraseSection.incompleteMessage(failedSteps: [.systemIntegrations]),
        ]
        for text in texts {
            #expect(!text.localizedLowercase.contains(oldPhrase), "« \(text) »")
        }
        #expect(SystemIntegrationsText.spotlightDetail.contains("Spotlight"))
        #expect(SystemIntegrationsText.footer.contains("Spotlight"))
        #expect(LocalDataEraseSection.confirmationMessage.contains("Spotlight"))
        #expect(LocalDataEraseSection.idleFooterMessage.contains("Spotlight"))
        #expect(LocalDataEraseSection.incompleteMessage(failedSteps: [.systemIntegrations]).contains("Spotlight"))
    }

    @Test("Le réglage de la question de l'activité en direct dit ce qu'il fait, dans les deux états")
    func questionTexts() {
        #expect(SystemIntegrationsText.questionTitle == "Afficher la question")
        // Allumé : la question se lit sans déverrouiller. Éteint : seule l'étape s'affiche.
        #expect(SystemIntegrationsText.questionDetail.contains("sans déverrouiller"))
        #expect(SystemIntegrationsText.questionDetail.localizedLowercase.contains("étape"))
        // L'activité elle-même ne promet plus d'afficher la question : c'est le réglage dédié qui le dit.
        #expect(!SystemIntegrationsText.liveActivityDetail.localizedLowercase.contains("ta question"))
    }
}
