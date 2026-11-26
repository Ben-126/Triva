//
//  AgenticResearchRunnerTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

/// Horloge dont l'échéance arrive tout de suite : le délai de l'enquête « expire » sans attente réelle.
nonisolated struct ImmediateDeadlineClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws { try Task.checkCancellation() }
}

/// Délai et classement de fin de l'enquête (tâche 2.4, M3), sans modèle. PAS `@MainActor` : une suite qui
/// attend une annulation réelle ne doit pas partager l'exécuteur sérialisé des autres (voir WidgetExecutorTests).
@Suite("AgenticResearchRunner (2.4)")
struct AgenticResearchRunnerTests {
    private static let deep = ResearchBudget(maxSearches: 2, maxReads: 4, maxToolCalls: 8, timeout: .seconds(30))

    private func ledger() -> ResearchLedger {
        ResearchLedger(budget: Self.deep, trustedDomainsOnly: false, seeded: agenticSeededResults())
    }

    private func run(_ ledger: ResearchLedger, operation: @escaping @Sendable () async throws -> Void) async throws -> AgenticResearchOutcome {
        try await AgenticResearchRunner.run(ledger: ledger, timeout: .seconds(30), clock: ContinuousClock(), operation: operation)
    }

    @Test("Fin normale (texte rendu sans finish) : .finished, registre relu après coup")
    func completionIsFinished() async throws {
        let ledger = ledger()
        let outcome = try await run(ledger) {
            _ = try ledger.beginSearch(query: "une requête")
            _ = ledger.recordSearch(results: agenticFoundResults())
        }
        #expect(outcome.stop == .finished)
        #expect(outcome.snapshot.searchCount == 1)
        #expect(outcome.snapshot == ledger.snapshot)
    }

    @Test("Sentinelle nue (onToolOutput) ou enveloppée par un outil : .finished")
    func sentinelFinishes() async throws {
        let ledger = ledger()
        #expect(try await run(ledger) { throw ResearchFinished() }.stop == .finished)
        #expect(try await run(ledger) {
            throw LanguageModelSession.ToolCallError(tool: FinishResearchTool(ledger: ledger), underlyingError: ResearchFinished())
        }.stop == .finished)
    }

    @Test("Plafond du registre, nu ou enveloppé : succès partiel .budgetReached")
    func budgetExceededIsPartialSuccess() async throws {
        let ledger = ledger()
        #expect(try await run(ledger) { throw ResearchBudgetExceeded(limit: .reads) }.stop == .budgetReached)
        #expect(try await run(ledger) {
            throw LanguageModelSession.ToolCallError(tool: FinishResearchTool(ledger: ledger), underlyingError: ResearchBudgetExceeded(limit: .searches))
        }.stop == .budgetReached)
    }

    @Test("Délai écoulé : l'opération est annulée, .timedOut, ce qui a été trouvé est gardé")
    func timeoutKeepsFindings() async throws {
        let ledger = ledger()
        let outcome = try await AgenticResearchRunner.run(ledger: ledger, timeout: .seconds(30), clock: ImmediateDeadlineClock()) {
            _ = try ledger.beginSearch(query: "une requête")
            _ = ledger.recordSearch(results: agenticFoundResults())
            try await Task.sleep(for: .seconds(60))
        }
        #expect(outcome.stop == .timedOut)
        #expect(outcome.snapshot.foundResults.count == 5)
    }

    @Test("Stop de l'utilisateur pendant l'enquête : CancellationError, jamais un délai ni un repli")
    func parentCancellationPropagates() async throws {
        let ledger = ledger()
        let task = Task {
            try await AgenticResearchRunner.run(ledger: ledger, timeout: .seconds(30), clock: ContinuousClock()) {
                try await Task.sleep(for: .seconds(60))
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("Erreur du modèle : AgenticResearchFailure avec la raison (contexte dépassé)")
    func modelErrorIsFailure() async throws {
        await #expect(throws: AgenticResearchFailure(reason: .contextExceeded)) {
            _ = try await run(ledger()) {
                throw LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "test"))
            }
        }
    }

    @Test("Classement : cloud privé, outil, annulation enveloppée, inconnu")
    func endingClassification() {
        let ledger = ledger()
        #expect(AgenticResearchRunner.ending(for: PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "x"))) == .failure(.privateCloud(.networkFailure)))
        #expect(AgenticResearchRunner.ending(for: PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "x"))) == .failure(.privateCloud(.quotaReached)))
        let toolFailure = LanguageModelSession.ToolCallError(tool: FinishResearchTool(ledger: ledger), underlyingError: URLError(.badURL))
        #expect(AgenticResearchRunner.ending(for: toolFailure) == .failure(.toolFailed))
        let toolCancel = LanguageModelSession.ToolCallError(tool: FinishResearchTool(ledger: ledger), underlyingError: CancellationError())
        #expect(AgenticResearchRunner.ending(for: toolCancel) == .cancellation)
        #expect(AgenticResearchRunner.ending(for: URLError(.timedOut)) == .failure(.other))
    }

    @Test("Cloud privé : échecs à signaler au coordinateur (rateLimited compris), rien pour le reste")
    func privateCloudFailureToReport() {
        #expect(AppleAgenticResearcher.privateCloudFailure(for: .privateCloud(.serviceUnavailable)) == .serviceUnavailable)
        #expect(AppleAgenticResearcher.privateCloudFailure(for: .rateLimited) == .rateLimited)
        #expect(AppleAgenticResearcher.privateCloudFailure(for: .contextExceeded) == nil)
        #expect(AppleAgenticResearcher.privateCloudFailure(for: .noFindings) == nil)
    }
}
