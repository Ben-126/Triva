//
//  HeadlessQuestionPolicyTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission B) : ce que « Poser une question à Triva » peut faire sans fenêtre. Logique pure. Règle
//  d'or : aucun chemin n'envoie à une IA cloud sans accord.
//

import Foundation
import Testing
@testable import Triva

@Suite("Politique de la question sans fenêtre")
struct HeadlessQuestionPolicyTests {
    private func context(
        engine: AIEngineOption?,
        ready: Bool = true,
        consent: HeadlessCloudConsent = .notApplicable,
        platform: HeadlessPlatform = .iOS
    ) -> HeadlessQuestionContext {
        HeadlessQuestionContext(engine: engine, isEngineReady: ready, cloudConsent: consent, platform: platform)
    }

    @Test("Aucun moteur choisi : il faut ouvrir Triva")
    func noEngine() {
        #expect(HeadlessQuestionPolicy.decide(context(engine: nil)) == .needsEngineChoice)
    }

    @Test("Moteur choisi mais pas utilisable (modèle local absent, fournisseur cloud absent) : ouvrir Triva")
    func engineNotReady() {
        #expect(HeadlessQuestionPolicy.decide(context(engine: .mlxLocal, ready: false)) == .needsEngineChoice)
        #expect(HeadlessQuestionPolicy.decide(context(engine: .cloudBYOK, ready: false, consent: .granted)) == .needsEngineChoice)
    }

    @Test("Apple Intelligence : exécution normale sur iPhone, iPad et Mac")
    func appleIntelligenceRuns() {
        #expect(HeadlessQuestionPolicy.decide(context(engine: .appleIntelligence, platform: .iOS)) == .run(.standard))
        #expect(HeadlessQuestionPolicy.decide(context(engine: .appleIntelligence, platform: .mac)) == .run(.standard))
    }

    @Test("Modèle local : GPU demandé sur iPhone et iPad, pas sur Mac")
    func localModelNeedsGPUOnIOSOnly() {
        #expect(HeadlessQuestionPolicy.decide(context(engine: .mlxLocal, platform: .iOS)) == .run(.backgroundWithGPU))
        #expect(HeadlessQuestionPolicy.decide(context(engine: .mlxLocal, platform: .mac)) == .run(.standard))
    }

    @Test("Cloud avec accord : exécution normale")
    func cloudWithConsentRuns() {
        #expect(HeadlessQuestionPolicy.decide(context(engine: .cloudBYOK, consent: .granted)) == .run(.standard))
    }

    @Test("Cloud sans accord : on s'arrête, le fournisseur est nommé")
    func cloudWithoutConsentStops() {
        let decision = HeadlessQuestionPolicy.decide(context(engine: .cloudBYOK, consent: .missing(providerName: "OpenAI")))
        #expect(decision == .needsCloudConsent(providerName: "OpenAI"))
    }

    @Test("Cloud dont l'accord est « sans objet » (erreur de contexte) : on s'arrête aussi, jamais d'envoi")
    func cloudWithInapplicableConsentFailsClosed() {
        let decision = HeadlessQuestionPolicy.decide(context(engine: .cloudBYOK, consent: .notApplicable))
        #expect(decision == .needsCloudConsent(providerName: HeadlessQuestionPolicy.unknownProviderName))
    }

    @Test("Toutes les combinaisons : un moteur cloud ne part JAMAIS sans accord « granted »",
          arguments: [AIEngineOption?.none, .appleIntelligence, .mlxLocal, .cloudBYOK],
          [HeadlessPlatform.iOS, .mac])
    func neverRunsCloudWithoutConsent(engine: AIEngineOption?, platform: HeadlessPlatform) {
        let consents: [HeadlessCloudConsent] = [.notApplicable, .missing(providerName: "X"), .granted]
        for ready in [true, false] {
            for consent in consents {
                let decision = HeadlessQuestionPolicy.decide(
                    HeadlessQuestionContext(engine: engine, isEngineReady: ready, cloudConsent: consent, platform: platform)
                )
                guard engine == .cloudBYOK else { continue }
                if consent != .granted || !ready {
                    if case .run = decision {
                        Issue.record("Cloud autorisé sans accord ou sans fournisseur : \(consent) prêt=\(ready) \(platform)")
                    }
                }
            }
        }
    }

    @Test("Les phrases lues à l'utilisateur sont celles de la spec")
    func dialogs() {
        #expect(HeadlessQuestionPolicy.engineChoiceDialog == "Ouvre Triva pour choisir ton moteur d'IA.")
        #expect(HeadlessQuestionPolicy.consentDialog(providerName: "OpenAI") == "Ouvre Triva pour autoriser l'envoi à OpenAI.")
    }
}
