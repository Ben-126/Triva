//
//  HeadlessQuestionSetupTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission B) : la préparation d'une question sans fenêtre lit les VRAIS stores (conteneur en
//  mémoire, trousseau factice) et la session qu'elle bâtit. Aucune question n'est envoyée ici.
//

import Foundation
import Testing
@testable import Triva

private struct SetupKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
@Suite("Préparation de la question sans fenêtre")
struct HeadlessQuestionSetupTests {
    private func makeStores(engine: AIEngineOption?) throws -> TrivaSharedStores {
        let defaults = try #require(TestDefaults.suite(named: "test.headlessSetup.\(UUID().uuidString)"))
        let stores = TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: SetupKeyStore()
        )
        stores.engineSettings.selectedOption = engine
        return stores
    }

    @Test("Aucun moteur choisi : il faut ouvrir Triva, aucune session, aucun lanceur")
    func noEngine() throws {
        let setup = HeadlessQuestionSetup.prepare(stores: try makeStores(engine: nil), responseMode: nil)
        #expect(setup.decision == .needsEngineChoice)
        #expect(setup.session == nil)
        #expect(setup.runner == nil)
    }

    @Test("Apple Intelligence : prêt, avec un lanceur")
    func appleIntelligence() throws {
        let setup = HeadlessQuestionSetup.prepare(stores: try makeStores(engine: .appleIntelligence), responseMode: nil, platform: .iOS)
        #expect(setup.decision == .run(.standard))
        #expect(setup.runner != nil)
    }

    @Test("Modèle local non choisi : il faut ouvrir Triva")
    func mlxWithoutModel() throws {
        let setup = HeadlessQuestionSetup.prepare(stores: try makeStores(engine: .mlxLocal), responseMode: nil)
        #expect(setup.decision == .needsEngineChoice)
        #expect(setup.runner == nil)
    }

    @Test("Modèle local choisi : GPU demandé sur iPhone et iPad, pas sur Mac")
    func mlxWithModel() throws {
        let stores = try makeStores(engine: .mlxLocal)
        let entry = try #require(try MLXModelCatalog.load().first)
        stores.mlxSelection.selectedModelID = entry.id
        #expect(HeadlessQuestionSetup.prepare(stores: stores, responseMode: nil, platform: .iOS).decision == .run(.backgroundWithGPU))
        #expect(HeadlessQuestionSetup.prepare(stores: stores, responseMode: nil, platform: .mac).decision == .run(.standard))
    }

    @Test("Cloud sans fournisseur choisi : il faut ouvrir Triva")
    func cloudWithoutProvider() throws {
        let setup = HeadlessQuestionSetup.prepare(stores: try makeStores(engine: .cloudBYOK), responseMode: nil)
        #expect(setup.decision == .needsEngineChoice)
        #expect(setup.runner == nil)
    }

    @Test("Cloud sans accord : on s'arrête, le fournisseur est nommé, AUCUN lanceur n'existe")
    func cloudWithoutConsent() throws {
        let stores = try makeStores(engine: .cloudBYOK)
        stores.cloudSelection.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        let setup = HeadlessQuestionSetup.prepare(stores: stores, responseMode: nil)
        let name = try #require(CloudAIConsentCatalog.request(providerID: "claude", customPresets: []))
        #expect(setup.decision == .needsCloudConsent(providerName: name.displayName))
        #expect(setup.runner == nil)
    }

    @Test("Cloud avec accord : prêt")
    func cloudWithConsent() throws {
        let stores = try makeStores(engine: .cloudBYOK)
        stores.cloudSelection.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        stores.cloudConsent.grant(providerID: "claude")
        let setup = HeadlessQuestionSetup.prepare(stores: stores, responseMode: nil)
        #expect(setup.decision == .run(.standard))
        #expect(setup.runner != nil)
    }

    @Test("Le mode choisi dans l'intent est celui de la session, sans toucher au mode mémorisé")
    func modeOverrideStaysInSession() throws {
        let setup = HeadlessQuestionSetup.prepare(stores: try makeStores(engine: .appleIntelligence), responseMode: .reliable)
        let session = try #require(setup.session)
        #expect(session.responseModeOverride == .reliable)
        #expect(session.chatViewModel?.readResponseMode() == .reliable)
    }

    @Test("Sans mode dans l'intent : la session lit le mode mémorisé, à chaque envoi")
    func noOverrideUsesRememberedMode() throws {
        let setup = HeadlessQuestionSetup.prepare(stores: try makeStores(engine: .appleIntelligence), responseMode: nil)
        let session = try #require(setup.session)
        #expect(session.responseModeOverride == nil)
        #expect(session.chatViewModel?.readResponseMode() == ChatViewModel.persistedResponseMode())
    }

    @Test("La session sans fenêtre ne génère pas de pistes « À creuser »")
    func sessionSkipsSuggestions() throws {
        let setup = HeadlessQuestionSetup.prepare(stores: try makeStores(engine: .appleIntelligence), responseMode: nil)
        #expect(setup.session?.generatesSuggestions == false)
    }

    @Test("La fabrique de TrivaAppServices passe par la même préparation")
    func servicesFactory() throws {
        let stores = try makeStores(engine: nil)
        let services = TrivaAppServices(stores: stores, routes: SystemRouteCenter(windowLauncher: nil))
        #expect(services.prepareHeadlessQuestion(responseMode: nil).decision == .needsEngineChoice)
    }
}
