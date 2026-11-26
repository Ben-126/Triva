//
//  AgenticTokenUsageTests.swift
//  TrivaTests
//
//  F3 (26/11) : les tokens de l'enquêteur (`LanguageModelSession.Usage`) remontent dans `AgenticResearchOutcome`, pour le
//  banc de comparaison, quelle que soit la fin de l'enquête. Testé au niveau du lanceur avec une opération factice qui
//  rapporte son usage : `AppleAgenticResearcher` lui-même ne tourne pas sans modèle.
//

import Testing
import Foundation
@testable import Triva

@Suite("Enquêteur : tokens (F3)")
struct AgenticTokenUsageTests {
    private static let deep = ResearchBudget(maxSearches: 2, maxReads: 4, maxToolCalls: 8, timeout: .seconds(30))
    private static let sample = AgenticTokenUsage(inputTokens: 1_200, cachedInputTokens: 800, outputTokens: 150, reasoningTokens: 40)

    private func ledger() -> ResearchLedger {
        ResearchLedger(budget: Self.deep, trustedDomainsOnly: false, seeded: agenticSeededResults())
    }

    @Test("Total : entrée + sortie (le raisonnement et le cache sont déjà compris)")
    func totalIsInputPlusOutput() {
        #expect(Self.sample.totalTokens == 1_350)
        #expect(AgenticTokenUsage.zero.totalTokens == 0)
    }

    @Test("Sans enregistreur : aucune mesure (comportement d'avant)")
    func noRecorderMeansNoUsage() async throws {
        let outcome = try await AgenticResearchRunner.run(ledger: ledger(), timeout: .seconds(30), clock: ContinuousClock()) {}
        #expect(outcome.tokenUsage == nil)
    }

    @Test("Fin normale : l'usage rapporté par l'opération est dans le résultat")
    func usageSurvivesNormalCompletion() async throws {
        let recorder = AgenticUsageRecorder()
        let outcome = try await AgenticResearchRunner.run(
            ledger: ledger(), timeout: .seconds(30), clock: ContinuousClock(), usage: recorder
        ) { recorder.record(Self.sample) }
        #expect(outcome.stop == .finished)
        #expect(outcome.tokenUsage == Self.sample)
    }

    @Test("Sentinelle de fin et plafond du registre : l'usage est gardé aussi")
    func usageSurvivesSentinelAndBudgetStops() async throws {
        let finished = AgenticUsageRecorder()
        let first = try await AgenticResearchRunner.run(
            ledger: ledger(), timeout: .seconds(30), clock: ContinuousClock(), usage: finished
        ) {
            finished.record(Self.sample)
            throw ResearchFinished()
        }
        #expect(first.stop == .finished)
        #expect(first.tokenUsage == Self.sample)

        let capped = AgenticUsageRecorder()
        let second = try await AgenticResearchRunner.run(
            ledger: ledger(), timeout: .seconds(30), clock: ContinuousClock(), usage: capped
        ) {
            capped.record(Self.sample)
            throw ResearchBudgetExceeded(limit: .reads)
        }
        #expect(second.stop == .budgetReached)
        #expect(second.tokenUsage == Self.sample)
    }

    @Test("Délai écoulé : ce qui avait été consommé avant l'annulation est gardé")
    func usageSurvivesTimeout() async throws {
        let recorder = AgenticUsageRecorder()
        let outcome = try await AgenticResearchRunner.run(
            ledger: ledger(), timeout: .seconds(30), clock: ImmediateDeadlineClock(), usage: recorder
        ) {
            recorder.record(Self.sample)
            try await Task.sleep(for: .seconds(60))
        }
        #expect(outcome.stop == .timedOut)
        #expect(outcome.tokenUsage == Self.sample)
    }

    @Test("Opération qui n'a rien rapporté : aucune mesure (nil), jamais un zéro inventé")
    func recorderWithoutReportStaysNil() async throws {
        let recorder = AgenticUsageRecorder()
        let outcome = try await AgenticResearchRunner.run(
            ledger: ledger(), timeout: .seconds(30), clock: ContinuousClock(), usage: recorder
        ) {}
        #expect(outcome.tokenUsage == nil)
    }

    @Test("L'enregistreur garde la dernière valeur : l'usage d'une session est cumulatif")
    func recorderKeepsTheLatestCumulativeValue() {
        let recorder = AgenticUsageRecorder()
        recorder.record(AgenticTokenUsage(inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, reasoningTokens: 0))
        recorder.record(Self.sample)
        #expect(recorder.value == Self.sample)
    }
}
