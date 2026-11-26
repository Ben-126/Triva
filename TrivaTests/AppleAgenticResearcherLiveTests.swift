//
//  AppleAgenticResearcherLiveTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

/// Essai du VRAI profil de l'enquêteur avec le modèle Apple Intelligence de la machine (tâche 2.4, M3), sur des
/// recherches et des lectures factices : aucun réseau. Désactivé par défaut ; lancé à la main avec
/// `TEST_RUNNER_TRIVA_AGENTIC_LIVE=1` (le modèle doit être disponible). Ne vérifie que la mécanique (outils
/// appelés, sentinelle, délai), jamais la qualité des choix du modèle : c'est le rôle du banc M4.
nonisolated enum AgenticLiveGate {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["TRIVA_AGENTIC_LIVE"] == "1" && SystemLanguageModel.default.isAvailable
    }
}

@Suite("Enquêteur réel (manuel, 2.4)", .serialized, .enabled(if: AgenticLiveGate.enabled))
struct AppleAgenticResearcherLiveTests {
    private static let pageText = """
    La tour Eiffel mesure 330 mètres de haut depuis l'installation d'une nouvelle antenne en 2022. \
    Elle a été construite par Gustave Eiffel pour l'Exposition universelle de 1889 et pèse environ 10 100 tonnes.
    """

    private func request(budget: ResearchBudget) -> AgenticResearchRequest {
        let seeded = (1...3).map {
            investigatorTestResult(title: "Tour Eiffel, page \($0)", url: "https://site\($0).example/tour", content: nil)
        }
        return AgenticResearchRequest(
            question: "Quelle est la hauteur de la tour Eiffel ?",
            searchQuery: "hauteur tour Eiffel",
            seeded: seeded,
            budget: budget,
            trustedDomainsOnly: false,
            search: { query in
                (1...3).map {
                    investigatorTestResult(title: "\(query) — résultat \($0)", url: "https://found\($0).example/\(query.count)", content: nil)
                }
            },
            scrape: { url in ScrapedPage(url: url, title: "Tour Eiffel", content: Self.pageText, succeeded: true) },
            today: Date()
        )
    }

    @Test("Approfondie : le modèle enquête avec les outils et l'enquête se termine sans erreur")
    func deepInvestigationRuns() async throws {
        let budget = ResearchBudget(maxSearches: 2, maxReads: 4, maxToolCalls: 8, timeout: .seconds(60))
        let start = ContinuousClock.now
        let outcome = try await AppleAgenticResearcher().investigate(request(budget: budget))
        let snapshot = outcome.snapshot
        print("LIVE| stop=\(outcome.stop) searches=\(snapshot.searchCount) reads=\(snapshot.readCount) calls=\(snapshot.toolCallCount) finished=\(snapshot.finished) queries=\(snapshot.queries) durée=\(ContinuousClock.now - start)")
        #expect(snapshot.searchCount <= budget.maxSearches)
        #expect(snapshot.readCount <= budget.maxReads)
        #expect(snapshot.toolCallCount <= budget.maxToolCalls)
        #expect(snapshot.toolCallCount > 0)
    }

    @Test("Délai très court : rend la main vite, sans erreur, avec ce qui a été trouvé")
    func shortTimeoutReturns() async throws {
        let budget = ResearchBudget(maxSearches: 2, maxReads: 4, maxToolCalls: 8, timeout: .milliseconds(300))
        let start = ContinuousClock.now
        let outcome = try await AppleAgenticResearcher().investigate(request(budget: budget))
        let elapsed = ContinuousClock.now - start
        print("LIVE| délai court stop=\(outcome.stop) durée=\(elapsed)")
        #expect(elapsed < .seconds(10))
    }
}
