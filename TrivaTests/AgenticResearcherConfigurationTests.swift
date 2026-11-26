//
//  AgenticResearcherConfigurationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

/// Prompt de l'enquêteur, choix du modèle, drapeau et construction par la session (tâche 2.4, M3).
@MainActor
@Suite("Enquêteur : prompt, modèle, drapeau (2.4)")
struct AgenticResearcherConfigurationTests {
    private static let budget = ResearchBudget(maxSearches: 2, maxReads: 4, maxToolCalls: 8, timeout: .seconds(30))

    // MARK: - Prompt

    @Test("Prompt : question, reformulation, date en français, départ numéroté comme le registre")
    func promptListsSeededEntries() throws {
        let ledger = ResearchLedger(budget: Self.budget, trustedDomainsOnly: false, seeded: agenticSeededResults())
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-26T12:00:00Z"))
        let prompt = ResearchInvestigatorPrompt.prompt(
            question: "Quelle hauteur ?", searchQuery: "hauteur tour", seeded: ledger.snapshot.seededEntries, today: date
        )
        #expect(prompt.contains("Question : Quelle hauteur ?"))
        #expect(prompt.contains("Question reformulée : hauteur tour"))
        #expect(prompt.contains("26 novembre 2026"))
        #expect(prompt.contains("[1] Départ A — a.example"))
        #expect(prompt.contains("[3] Départ C — c.example"))
    }

    @Test("Prompt sans départ : le dit ; titre long coupé à 80 caractères")
    func promptEdgeCases() throws {
        let date = Date(timeIntervalSince1970: 0)
        #expect(ResearchInvestigatorPrompt.prompt(question: "q", searchQuery: "q", seeded: [], today: date).contains("Résultats de départ : aucun."))
        let long = SearchOrchestratorTests.makeResult(title: String(repeating: "x", count: 200), url: "https://long.example", content: nil)
        let ledger = ResearchLedger(budget: Self.budget, trustedDomainsOnly: false, seeded: [long])
        let prompt = ResearchInvestigatorPrompt.prompt(question: "q", searchQuery: "q", seeded: ledger.snapshot.seededEntries, today: date)
        let line = try #require(prompt.split(separator: "\n").first { $0.hasPrefix("[1]") })
        #expect(!line.contains(String(repeating: "x", count: 81)))
    }

    @Test("Date : format long français, fuseau donné")
    func dateFormatting() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-01-01T23:30:00Z"))
        #expect(ResearchInvestigatorPrompt.formattedDate(date, timeZone: try #require(TimeZone(identifier: "UTC"))) == "1 janvier 2026")
        #expect(ResearchInvestigatorPrompt.formattedDate(date, timeZone: try #require(TimeZone(identifier: "Europe/Paris"))) == "2 janvier 2026")
    }

    @Test("Budget restant : pluriel et singulier, jamais négatif")
    func remainingBudget() throws {
        let ledger = ResearchLedger(budget: Self.budget, trustedDomainsOnly: false, seeded: [])
        #expect(ResearchInvestigatorPrompt.remainingBudget(ledger.snapshot, budget: Self.budget) == "Budget restant : 2 recherches, 4 lectures.")
        _ = try ledger.beginSearch(query: "une requête")
        #expect(ResearchInvestigatorPrompt.remainingBudget(ledger.snapshot, budget: Self.budget) == "Budget restant : 1 recherche, 4 lectures.")
        let none = ResearchBudget(maxSearches: 0, maxReads: 0, maxToolCalls: 1, timeout: .seconds(1))
        #expect(ResearchInvestigatorPrompt.remainingBudget(ledger.snapshot, budget: none) == "Budget restant : 0 recherche, 0 lecture.")
    }

    // MARK: - Modèle

    @Test("Choix du modèle : cloud privé SEULEMENT avec route cloud ET entitlement")
    func modelChoice() {
        #expect(AgenticResearcherFactory.modelChoice(route: .onDevice, isEntitlementGranted: false) == .onDevice)
        #expect(AgenticResearcherFactory.modelChoice(route: .onDevice, isEntitlementGranted: true) == .onDevice)
        #expect(AgenticResearcherFactory.modelChoice(route: .privateCloud, isEntitlementGranted: false) == .onDevice)
        #expect(AgenticResearcherFactory.modelChoice(route: .privateCloud, isEntitlementGranted: true) == .privateCloud)
        #expect(!PrivateCloudComputeEntitlement.isGranted)
    }

    @Test("Cloud sans entitlement (cas de -debug.simulatePrivateCloud) : le modèle cloud n'est JAMAIS construit")
    func privateCloudModelNeverBuiltWithoutEntitlement() {
        var built = 0
        let researcher = AgenticResearcherFactory.researcher(
            route: .privateCloud,
            isEntitlementGranted: false,
            makePrivateCloudModel: { built += 1; return SystemLanguageModel.default },
            onPrivateCloudFailure: { _ in }
        )
        #expect(built == 0)
        #expect(researcher.onPrivateCloudFailure == nil)
        #expect(researcher.model is SystemLanguageModel)
    }

    @Test("Cloud avec entitlement : modèle cloud construit une fois, échecs signalés ; enquête gloutonne")
    func privateCloudModelBuiltWithEntitlement() {
        var built = 0
        let researcher = AgenticResearcherFactory.researcher(
            route: .privateCloud,
            isEntitlementGranted: true,
            makePrivateCloudModel: { built += 1; return SystemLanguageModel.default },
            onPrivateCloudFailure: { _ in }
        )
        #expect(built == 1)
        #expect(researcher.onPrivateCloudFailure != nil)
        #expect(researcher.sampling == .greedy)
    }

    // MARK: - Drapeau

    @Test("Drapeau : éteint par défaut, allumé seulement par la clé de débogage")
    func flagDefaultsOff() throws {
        let defaults = try #require(TestDefaults.suite(named: "test.agentic.\(UUID().uuidString)"))
        #expect(!AgenticResearchSetting.isEnabled(in: defaults))
        #expect(!AgenticResearchSetting.isEnabled)
        defaults.set(true, forKey: AgenticResearchSetting.defaultsKey)
        #expect(AgenticResearchSetting.isEnabled(in: defaults))
        #expect(AgenticResearchSetting.defaultsKey == "research.agentic")
    }

    // MARK: - Session

    @Test("Règle : Apple Intelligence et drapeau allumé, rien d'autre", arguments: AIEngineOption.allCases)
    func sessionRule(engine: AIEngineOption) {
        #expect(!SearchSession.usesAgenticResearch(engine: engine, isEnabled: false))
        #expect(SearchSession.usesAgenticResearch(engine: engine, isEnabled: true) == (engine == .appleIntelligence))
    }

    @Test("Session : MLX et clés cloud jamais d'enquêteur ; Apple Intelligence seulement drapeau allumé, sur l'appareil")
    func sessionBuildsResearcherOnlyForAppleIntelligence() throws {
        let stores = try Self.makeStores()
        let coordinator = AppleIntelligenceModelCoordinator(
            probe: FixedPrivateCloudProbe(status: .unavailable),
            preferenceStore: AppleIntelligenceModelPreference(userDefaults: try #require(TestDefaults.suite(named: "test.agentic.model.\(UUID().uuidString)")))
        )
        #expect(SearchSession(engine: .mlxLocal, stores: stores, appleModel: coordinator).agenticResearcherForSending(isEnabled: true) == nil)
        #expect(SearchSession(engine: .cloudBYOK, stores: stores, appleModel: coordinator).agenticResearcherForSending(isEnabled: true) == nil)
        let apple = SearchSession(engine: .appleIntelligence, stores: stores, appleModel: coordinator)
        #expect(apple.agenticResearcherForSending(isEnabled: false) == nil)
        let researcher = try #require(apple.agenticResearcherForSending(isEnabled: true) as? AppleAgenticResearcher)
        #expect(researcher.model is SystemLanguageModel)
        #expect(researcher.onPrivateCloudFailure == nil)
    }

    private static func makeStores() throws -> TrivaSharedStores {
        let defaults = try #require(TestDefaults.suite(named: "test.agentic.stores.\(UUID().uuidString)"))
        return TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: AgenticTestKeyStore()
        )
    }
}

/// Trousseau vide : la session ne lit aucune clé dans ces tests.
private struct AgenticTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}
