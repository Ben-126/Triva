//
//  AgenticComparisonDoubles.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
import Synchronization
@testable import Triva

// Enregistreurs du banc 2.4 : ils entourent les VRAIS services (modèle, lecture de pages, enquêteur) sans rien
// changer à leur conduite, et comptent ce qui passe. Les deux côtés du banc utilisent les mêmes.

/// Compteur de ce qui traverse le fournisseur IA (appels et taille des prompts).
nonisolated final class EvalModelCounter: Sendable {
    private let state = Mutex((calls: 0, characters: 0))

    func record(prompt: String) {
        state.withLock { $0 = ($0.calls + 1, $0.characters + prompt.count) }
    }

    var calls: Int { state.withLock { $0.calls } }
    var promptCharacters: Int { state.withLock { $0.characters } }
}

/// Fournisseur IA réel (Apple Intelligence) entouré d'un compteur : classification, widgets, planner et rédaction.
struct RecordingGenerator: AIGenerating {
    let inner: any AIGenerating
    let counter: EvalModelCounter

    func generate(prompt: String) async throws -> String {
        counter.record(prompt: prompt)
        return try await inner.generate(prompt: prompt)
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        counter.record(prompt: prompt)
        return inner.streamGenerate(prompt: prompt)
    }
}

/// Lecture de pages réelle (`ScrapeService`) qui note les pages lues AVEC succès. Passe par ce service la lecture
/// de la boucle actuelle (préparation, planner) comme celle de l'enquêteur : même mesure des deux côtés.
nonisolated final class RecordingScraper: ScrapeServing {
    private let inner: any ScrapeServing
    private let readKeys = Mutex<Set<String>>([])

    init(inner: any ScrapeServing) { self.inner = inner }

    func scrape(url: String) async -> ScrapedPage {
        let page = await inner.scrape(url: url)
        if page.succeeded { readKeys.withLock { _ = $0.insert(SearchOrchestrator.urlKey(url)) } }
        return page
    }

    func hasRead(_ url: String) -> Bool { readKeys.withLock { $0.contains(SearchOrchestrator.urlKey(url)) } }
    var readCount: Int { readKeys.withLock { $0.count } }
}

/// Enquêteur réel entouré d'un enregistreur : nombre d'appels, compteurs du registre, requêtes, fin, échec.
nonisolated final class RecordingResearcher: AgenticResearching {
    private struct State {
        var calls = 0
        var outcome: AgenticResearchOutcome?
        var failure: String?
    }

    private let inner: any AgenticResearching
    private let state = Mutex(State())

    init(inner: any AgenticResearching) { self.inner = inner }

    var calls: Int { state.withLock { $0.calls } }

    func investigate(_ request: AgenticResearchRequest) async throws -> AgenticResearchOutcome {
        state.withLock { $0.calls += 1 }
        do {
            let outcome = try await inner.investigate(request)
            state.withLock { $0.outcome = outcome }
            return outcome
        } catch {
            state.withLock { $0.failure = AgenticEvalError.describe(error) }
            throw error
        }
    }

    /// `nil` si l'enquêteur n'a jamais été appelé.
    var summary: AgenticEvalRecord.Investigator? {
        state.withLock { state in
            guard state.calls > 0 else { return nil }
            let snapshot = state.outcome?.snapshot
            return AgenticEvalRecord.Investigator(
                calls: state.calls,
                searches: snapshot?.searchCount ?? 0,
                reads: snapshot?.readCount ?? 0,
                toolCalls: snapshot?.toolCallCount ?? 0,
                queries: snapshot?.queries ?? [],
                stop: state.outcome.map { String(describing: $0.stop) } ?? "none",
                failure: state.failure
            )
        }
    }
}
