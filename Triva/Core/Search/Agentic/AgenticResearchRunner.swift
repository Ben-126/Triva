//
//  AgenticResearchRunner.swift
//  Triva
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
import FoundationModels

/// Exécution d'une enquête sous le délai du mode, et classement de sa fin (spec 2.4 §2.6). Séparé
/// d'`AppleAgenticResearcher` pour être testé SANS modèle : `operation` est la session (`respond`) en
/// production, un double dans les tests.
nonisolated enum AgenticResearchRunner {
    /// Comment une erreur levée par la session doit être comprise.
    nonisolated enum Ending: Sendable, Equatable {
        /// Sentinelle `ResearchFinished` (levée par `onToolOutput` après `finish`, ou par le registre).
        case finished
        /// Plafond du registre (`ResearchBudgetExceeded`) : succès partiel.
        case budgetReached
        /// Annulation : remonte telle quelle, aucun repli.
        case cancellation
        /// Échec : repli sur la boucle actuelle.
        case failure(AgenticFallbackReason)
    }

    private nonisolated enum Event: Sendable {
        case completed
        case timedOut
    }

    /// Lance `operation` sous `timeout` (mesuré sur `clock`, injectée), puis lit le registre UNE fois le
    /// groupe refermé (il attend ses tâches : plus aucun outil n'écrit à ce moment-là).
    ///
    /// - Fin normale de `operation` (texte rendu sans `finish`) : `.finished`.
    /// - Délai écoulé : `operation` est annulée, `.timedOut` (le registre garde ce qui a été trouvé).
    ///   L'annulation que CE délai provoque dans `operation` n'est pas une annulation de l'utilisateur.
    /// - Annulation de la tâche appelante (Stop) : `CancellationError`, vérifiée AVANT tout classement.
    /// - Autre erreur : classée par `ending(for:)` ; un échec lève `AgenticResearchFailure`.
    static func run<C: Clock<Duration>>(
        ledger: ResearchLedger,
        timeout: Duration,
        clock: C,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws -> AgenticResearchOutcome {
        let stop: AgenticStop
        do {
            let event = try await withThrowingTaskGroup(of: Event.self) { group in
                group.addTask {
                    try await operation()
                    return .completed
                }
                group.addTask {
                    try await clock.sleep(for: timeout)
                    return .timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
            try Task.checkCancellation()
            stop = event == .timedOut ? .timedOut : .finished
        } catch {
            try Task.checkCancellation()
            stop = try stopOrThrow(for: error)
        }
        return AgenticResearchOutcome(snapshot: ledger.snapshot, stop: stop)
    }

    private static func stopOrThrow(for error: any Error) throws -> AgenticStop {
        switch ending(for: error) {
        case .finished: return .finished
        case .budgetReached: return .budgetReached
        case .cancellation: throw CancellationError()
        case .failure(let reason): throw AgenticResearchFailure(reason: reason)
        }
    }

    /// Classement pur d'une erreur de la session. Ce qu'un OUTIL lève arrive enveloppé dans
    /// `LanguageModelSession.ToolCallError` (doc d'Apple) ; la sentinelle levée par `onToolOutput` arrive
    /// nue (prototype A1) : les deux formes sont acceptées pour chaque cas.
    static func ending(for error: any Error) -> Ending {
        let cause = unwrapped(error)
        if cause is ResearchFinished { return .finished }
        if cause is ResearchBudgetExceeded { return .budgetReached }
        if SearchOrchestrator.isCancellation(cause) { return .cancellation }
        // Erreur inattendue d'un outil (les nôtres ne lèvent que les sentinelles ou l'annulation).
        if error is LanguageModelSession.ToolCallError { return .failure(.toolFailed) }
        return .failure(reason(for: cause))
    }

    /// L'erreur d'origine d'un outil, ou l'erreur telle quelle.
    static func unwrapped(_ error: any Error) -> any Error {
        if let toolError = error as? LanguageModelSession.ToolCallError { return toolError.underlyingError }
        return error
    }

    /// Raison de repli d'une erreur qui n'est ni une sentinelle ni une annulation. Les erreurs du modèle
    /// (`LanguageModelError`) sont lues AVANT celles du cloud privé : `PrivateCloudFailure.classify` range
    /// aussi `rateLimited` en échec du cloud, faux pour le modèle sur l'appareil.
    static func reason(for error: any Error) -> AgenticFallbackReason {
        if let modelError = error as? LanguageModelError { return reason(for: modelError) }
        if let failure = PrivateCloudFailure.classify(error) { return .privateCloud(failure) }
        if error is SystemLanguageModel.Error { return .modelUnavailable }
        return .other
    }

    private static func reason(for error: LanguageModelError) -> AgenticFallbackReason {
        switch error {
        case .contextSizeExceeded: .contextExceeded
        case .guardrailViolation: .guardrail
        case .refusal: .refusal
        case .rateLimited: .rateLimited
        case .timeout: .modelTimeout
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
            .unsupported
        // Cas ajouté par un futur SDK.
        @unknown default: .other
        }
    }
}
