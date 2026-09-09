//
//  SearchOrchestrator.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Résultat du pipeline minimal (0.7) : le texte généré, accompagné des
/// résultats de recherche effectivement utilisés comme contexte — utile pour
/// la tâche 0.8, qui affichera une liste de sources sous la réponse sans
/// avoir à refaire une recherche.
struct SearchOrchestratorResult: Sendable, Equatable {
    let answer: String
    let sources: [SearXNGSearchResult]
}

/// Résultat du pipeline en streaming (0.8) : les sources sont déjà connues
/// (la recherche est terminée et awaited) au moment où l'appelant les reçoit,
/// seul le texte de réponse arrive progressivement via `textStream`.
/// `Equatable` non conformé volontairement : un `AsyncThrowingStream` ne l'est
/// pas.
struct StreamingAnswer: Sendable {
    let sources: [SearXNGSearchResult]
    let textStream: AsyncThrowingStream<String, Error>
}

/// Pipeline recherche -> génération **minimal** (0.7) : requête -> recherche
/// SearXNG (via `FailoverManager`, déjà résilient aux instances en panne) ->
/// contexte simple à partir des N premiers résultats -> appel au provider IA
/// déjà résolu et prêt à l'emploi -> réponse.
///
/// Volontairement dépourvu de classification de requête et de scoring des
/// sources : ces étapes arrivent en V1 (tâches 1.1 et 1.3). Ici, on se
/// contente de "chercher puis répondre". `aiProvider` doit déjà être prêt à
/// générer (un `MLXProvider` doit avoir reçu `prepare()` avant d'être injecté
/// ici — ce n'est pas le rôle de ce type, voir `ActiveAIProviderResolver`).
struct SearchOrchestrator: Sendable {
    private let failoverManager: FailoverManager
    private let aiProvider: any AIGenerating
    private let maxResultsUsedForContext: Int

    /// `maxResultsUsedForContext` par défaut à 5, cohérent avec le futur
    /// top-5 de la tâche 1.3 — même si aucun scoring n'est fait ici, cette
    /// limite évite déjà de saturer le contexte du modèle avec tous les
    /// résultats bruts renvoyés par SearXNG.
    init(failoverManager: FailoverManager, aiProvider: any AIGenerating, maxResultsUsedForContext: Int = 5) {
        self.failoverManager = failoverManager
        self.aiProvider = aiProvider
        self.maxResultsUsedForContext = maxResultsUsedForContext
    }

    func answer(query: String) async throws -> SearchOrchestratorResult {
        let response = try await failoverManager.search(query: query)
        let sources = Array(response.results.prefix(maxResultsUsedForContext))
        let prompt = Self.buildPrompt(query: query, sources: sources)
        let answer = try await aiProvider.generate(prompt: prompt)
        return SearchOrchestratorResult(answer: answer, sources: sources)
    }

    /// Même pipeline que `answer(query:)` jusqu'à la construction du prompt
    /// (recherche et prompt sont awaited ici, pas dans le flux renvoyé) ; seule
    /// la génération elle-même est déléguée à `aiProvider.streamGenerate(prompt:)`
    /// pour un affichage progressif côté UI (0.8).
    func streamAnswer(query: String) async throws -> StreamingAnswer {
        let response = try await failoverManager.search(query: query)
        let sources = Array(response.results.prefix(maxResultsUsedForContext))
        let prompt = Self.buildPrompt(query: query, sources: sources)
        let textStream = aiProvider.streamGenerate(prompt: prompt)
        return StreamingAnswer(sources: sources, textStream: textStream)
    }

    /// Construction du prompt isolée dans une fonction pure et testable
    /// directement (pas `private`), pour vérifier précisément le format
    /// envoyé au provider IA sans dépendre du reste du pipeline. Le format
    /// de chaque résultat s'inspire de la construction de contexte de
    /// `src/lib/agents/search/index.ts` (web) — sans porter le reste de ce
    /// fichier (classification, widgets, streaming), hors scope de 0.7.
    ///
    /// Volontairement sans règle anti-remplissage ni exigence de citation
    /// `[n]` : ça, c'est le prompt writer de la tâche 1.4.
    static func buildPrompt(query: String, sources: [SearXNGSearchResult]) -> String {
        let context = sources.enumerated()
            .map { index, result in
                "<result index=\(index + 1) title=\"\(result.title)\">\(result.content ?? "")</result>"
            }
            .joined(separator: "\n")

        return """
        Réponds à la question de l'utilisateur en te basant sur le contexte de recherche ci-dessous.

        Contexte de recherche :
        \(context)

        Question : \(query)
        """
    }
}
