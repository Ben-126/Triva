//
//  AgenticResearchLedgerTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/11/2026.
//

import Testing
import Foundation
import Synchronization
@testable import Triva

// MARK: - Doublures partagées par les suites de l'enquêteur (tâche 2.4)

/// Résultat factice d'URL `https://site<n>.example.org/page<n>` (domaine NON fiable).
nonisolated func agenticResult(_ number: Int, title: String? = nil, host: String? = nil) -> SearXNGSearchResult {
    makeSourceResult(
        url: "https://\(host ?? "site\(number).example.org")/page\(number)",
        title: title ?? "Titre \(number)",
        content: "Extrait \(number)"
    )
}

/// Résultat factice d'un domaine fiable (`wikipedia.org`, liste de `SourceRanker`).
nonisolated func agenticTrustedResult(_ number: Int, title: String? = nil) -> SearXNGSearchResult {
    agenticResult(number, title: title, host: "fr.wikipedia.org")
}

/// Journal d'appels `Sendable`, pour compter ce que font les closures injectées dans les outils.
nonisolated final class AgenticCallLog: Sendable {
    private let entries = Mutex<[String]>([])
    private let mainThreadFlags = Mutex<[Bool]>([])

    func record(_ entry: String) {
        entries.withLock { $0.append(entry) }
        mainThreadFlags.withLock { $0.append(pthread_main_np() != 0) }
    }

    var all: [String] { entries.withLock { $0 } }
    var count: Int { entries.withLock { $0.count } }
    var anyOnMainThread: Bool { mainThreadFlags.withLock { $0.contains(true) } }
}

private let pipelineConfiguration = SearchPipelineConfiguration.appleIntelligence

private func makeBudget(searches: Int = 2, reads: Int = 4, calls: Int = 8) -> ResearchBudget {
    ResearchBudget(maxSearches: searches, maxReads: reads, maxToolCalls: calls, timeout: .seconds(30))
}

// MARK: - ResearchBudget

@MainActor
@Suite("ResearchBudget : plafonds par mode")
struct ResearchBudgetTests {
    @Test("Rapide : aucun enquêteur")
    func quickHasNoInvestigator() {
        let budget = ResearchBudget.for(mode: .quick, configuration: pipelineConfiguration)
        #expect(budget == .disabled)
        #expect(!budget.isEnabled)
    }

    @Test("Approfondie : 2 recherches, 4 lectures, 8 appels, 30 s")
    func deepBudget() {
        let budget = ResearchBudget.for(mode: .deep, configuration: pipelineConfiguration)
        #expect(budget.maxSearches == 2)
        #expect(budget.maxReads == 4)
        #expect(budget.maxToolCalls == 8)
        #expect(budget.timeout == .seconds(30))
        #expect(budget.isEnabled)
    }

    @Test("Fiable : 2 recherches, 3 lectures, 6 appels, 25 s")
    func reliableBudget() {
        let budget = ResearchBudget.for(mode: .reliable, configuration: pipelineConfiguration)
        #expect(budget.maxSearches == 2)
        #expect(budget.maxReads == 3)
        #expect(budget.maxToolCalls == 6)
        #expect(budget.timeout == .seconds(25))
    }

    @Test("Les lectures ne dépassent jamais le nombre de sources affichées")
    func readsAreCappedByDisplayedSources() {
        let cloud = ResearchBudget.for(mode: .deep, configuration: .cloud)
        #expect(cloud.maxReads <= SearchPipelineConfiguration.cloud.maxResultsUsedForContext)
        for mode in ResponseMode.allCases {
            for configuration in [SearchPipelineConfiguration.cloud, .appleIntelligence, .mlxCompact, .mlx] {
                let budget = ResearchBudget.for(mode: mode, configuration: configuration)
                #expect(budget.maxReads <= configuration.maxResultsUsedForContext)
                #expect(budget.maxReads <= budget.maxToolCalls)
                #expect(budget.maxSearches <= budget.maxToolCalls)
            }
        }
    }
}

// MARK: - ResearchLedger : numérotation

@Suite("ResearchLedger : numérotation des résultats")
struct ResearchLedgerNumberingTests {
    @Test("Le départ reçoit les numéros 1 à 5, dans l'ordre du moteur, pas davantage")
    func seededResultsAreNumberedFromOne() {
        let seeded = (1...8).map { agenticResult($0) }
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: seeded)
        let snapshot = ledger.snapshot
        #expect(snapshot.entries.map(\.number) == [1, 2, 3, 4, 5])
        #expect(snapshot.entries.map(\.result.url) == seeded.prefix(5).map(\.url))
        #expect(snapshot.seededCount == 5)
        #expect(snapshot.seededEntries == snapshot.entries)
        #expect(!snapshot.hasFindings)
    }

    @Test("Deux adresses équivalentes au départ ne reçoivent qu'un numéro")
    func seededDuplicatesShareANumber() {
        let seeded = [
            makeSourceResult(url: "https://www.exemple.fr/a/"),
            makeSourceResult(url: "https://exemple.fr/a"),
            makeSourceResult(url: "https://autre.fr/b"),
        ]
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: seeded)
        #expect(ledger.snapshot.entries.map(\.number) == [1, 2])
    }

    @Test("Une adresse sans hôte n'a jamais de numéro")
    func hostlessURLIsNeverNumbered() {
        let seeded = [makeSourceResult(url: "pas une adresse"), agenticResult(1)]
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: seeded)
        #expect(ledger.snapshot.entries.map(\.number) == [1])
        #expect(ledger.snapshot.entries.first?.result.url == agenticResult(1).url)
    }

    @Test("Fiable : un résultat non fiable n'a JAMAIS de numéro, le suivant fiable prend sa place")
    func reliableModeNeverNumbersUntrustedResults() {
        let seeded = [agenticResult(1), agenticTrustedResult(2), agenticResult(3), agenticTrustedResult(4)]
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: true, seeded: seeded)
        let snapshot = ledger.snapshot
        #expect(snapshot.entries.map(\.number) == [1, 2])
        #expect(snapshot.entries.allSatisfy { SourceRanker.isTrustedDomain($0.result.url) })
    }

    @Test("Les résultats d'une recherche continuent la numérotation, un résultat connu garde son numéro")
    func searchResultsContinueNumbering() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [agenticResult(1), agenticResult(2)])
        _ = try ledger.beginSearch(query: "premiere requete")
        let shown = ledger.recordSearch(results: [agenticResult(2), agenticResult(3), agenticResult(4)])
        #expect(shown.map(\.number) == [2, 3, 4])
        #expect(ledger.snapshot.entries.map(\.number) == [1, 2, 3, 4])
        #expect(ledger.snapshot.hasFindings)
    }

    @Test("Une recherche ne montre que 5 résultats au plus, les suivants ne sont pas numérotés")
    func searchShowsAtMostFiveResults() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [])
        _ = try ledger.beginSearch(query: "requete")
        let shown = ledger.recordSearch(results: (1...9).map { agenticResult($0) })
        #expect(shown.count == ResearchLedger.maxShownResults)
        #expect(ledger.snapshot.entries.count == 5)
    }

    @Test("Fiable : les résultats non fiables d'une recherche ne sont ni montrés ni numérotés")
    func reliableModeFiltersSearchResults() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: true, seeded: [])
        _ = try ledger.beginSearch(query: "requete")
        let shown = ledger.recordSearch(results: [agenticResult(1), agenticTrustedResult(2), agenticResult(3)])
        #expect(shown.map(\.number) == [1])
        #expect(shown.first?.result.url == agenticTrustedResult(2).url)
        #expect(ledger.snapshot.entries.count == 1)
    }

    @Test("Le même résultat deux fois dans une réponse n'est montré qu'une fois")
    func duplicateInOneResponseIsShownOnce() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [])
        _ = try ledger.beginSearch(query: "requete")
        let shown = ledger.recordSearch(results: [agenticResult(1), agenticResult(1), agenticResult(2)])
        #expect(shown.map(\.number) == [1, 2])
    }
}

// MARK: - ResearchLedger : recherches

@Suite("ResearchLedger : réservation des recherches")
struct ResearchLedgerSearchTests {
    @Test("Une recherche consomme une recherche ET un appel, et garde la requête")
    func searchConsumesBudget() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [])
        #expect(try ledger.beginSearch(query: "  la tour Eiffel \n") == .proceed)
        let snapshot = ledger.snapshot
        #expect(snapshot.searchCount == 1)
        #expect(snapshot.toolCallCount == 1)
        #expect(snapshot.queries == ["la tour Eiffel"])
    }

    @Test("Requête déjà faite (casse, accents, blancs ignorés) : pas de recherche, un appel compté")
    func duplicateQueryIsDetected() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [])
        #expect(try ledger.beginSearch(query: "Électricité   statique") == .proceed)
        #expect(try ledger.beginSearch(query: "electricite statique") == .duplicate)
        #expect(try ledger.beginSearch(query: "ÉLECTRICITÉ STATIQUE ") == .duplicate)
        let snapshot = ledger.snapshot
        #expect(snapshot.searchCount == 1)
        #expect(snapshot.toolCallCount == 3)
        #expect(snapshot.queries.count == 1)
    }

    @Test("Requête vide : aucune recherche, un appel compté")
    func emptyQueryIsDetected() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [])
        #expect(try ledger.beginSearch(query: " \n\t ") == .empty)
        #expect(try ledger.beginSearch(query: "") == .empty)
        #expect(ledger.snapshot.searchCount == 0)
        #expect(ledger.snapshot.toolCallCount == 2)
    }

    @Test("La 3e recherche est refusée en Approfondie (plafond de 2)")
    func searchCeilingIsEnforced() throws {
        let ledger = ResearchLedger(budget: makeBudget(searches: 2), trustedDomainsOnly: false, seeded: [])
        _ = try ledger.beginSearch(query: "un")
        _ = try ledger.beginSearch(query: "deux")
        #expect(throws: ResearchBudgetExceeded(limit: .searches)) { try ledger.beginSearch(query: "trois") }
        #expect(ledger.snapshot.searchCount == 2)
        #expect(ledger.snapshot.toolCallCount == 2)
        #expect(!ledger.canSearch)
    }

    @Test("Le plafond d'appels borne aussi les requêtes en double : une boucle de doublons s'arrête")
    func toolCallCeilingBoundsDuplicateLoops() throws {
        let ledger = ResearchLedger(budget: makeBudget(searches: 2, reads: 4, calls: 3), trustedDomainsOnly: false, seeded: [])
        _ = try ledger.beginSearch(query: "un")
        _ = try ledger.beginSearch(query: "un")
        _ = try ledger.beginSearch(query: "un")
        #expect(throws: ResearchBudgetExceeded(limit: .toolCalls)) { try ledger.beginSearch(query: "un") }
        #expect(ledger.snapshot.toolCallCount == 3)
    }

    @Test("Un refus ne compte rien")
    func refusalCountsNothing() throws {
        let ledger = ResearchLedger(budget: makeBudget(searches: 1, reads: 1, calls: 1), trustedDomainsOnly: false, seeded: [agenticResult(1)])
        _ = try ledger.beginSearch(query: "un")
        #expect(throws: ResearchBudgetExceeded.self) { try ledger.beginSearch(query: "deux") }
        #expect(throws: ResearchBudgetExceeded.self) { try ledger.beginRead(number: 1) }
        #expect(ledger.snapshot.toolCallCount == 1)
        #expect(ledger.snapshot.readCount == 0)
    }

    @Test("Une requête refusée pour plafond de recherches ne mémorise pas la requête")
    func refusedQueryIsNotRemembered() throws {
        let ledger = ResearchLedger(budget: makeBudget(searches: 1, reads: 1, calls: 8), trustedDomainsOnly: false, seeded: [])
        _ = try ledger.beginSearch(query: "un")
        #expect(throws: ResearchBudgetExceeded(limit: .searches)) { try ledger.beginSearch(query: "deux") }
        #expect(ledger.snapshot.queries == ["un"])
    }
}

// MARK: - ResearchLedger : lectures

@Suite("ResearchLedger : réservation des lectures")
struct ResearchLedgerReadTests {
    private func makeLedger(reads: Int = 4, calls: Int = 8, seeded: Int = 3) -> ResearchLedger {
        ResearchLedger(
            budget: makeBudget(searches: 2, reads: reads, calls: calls),
            trustedDomainsOnly: false,
            seeded: (1...seeded).map { agenticResult($0) }
        )
    }

    @Test("Une lecture consomme une lecture ET un appel et rend l'entrée du registre")
    func readConsumesBudget() throws {
        let ledger = makeLedger()
        guard case .proceed(let entry) = try ledger.beginRead(number: 2) else {
            Issue.record("lecture attendue")
            return
        }
        #expect(entry.number == 2)
        #expect(entry.result.url == agenticResult(2).url)
        #expect(ledger.snapshot.readCount == 1)
        #expect(ledger.snapshot.toolCallCount == 1)
    }

    @Test("Numéro inconnu (0, négatif, trop grand) : aucune lecture, un appel compté")
    func unknownNumberIsRefused() throws {
        let ledger = makeLedger(seeded: 3)
        for number in [0, -1, 4, 99] {
            #expect(try ledger.beginRead(number: number) == .unknownNumber)
        }
        #expect(ledger.snapshot.readCount == 0)
        #expect(ledger.snapshot.toolCallCount == 4)
    }

    @Test("Page déjà demandée : pas de deuxième lecture, un appel compté")
    func alreadyReadIsRefused() throws {
        let ledger = makeLedger()
        _ = try ledger.beginRead(number: 1)
        guard case .alreadyRead(let entry) = try ledger.beginRead(number: 1) else {
            Issue.record("« déjà lue » attendu")
            return
        }
        #expect(entry.number == 1)
        #expect(ledger.snapshot.readCount == 1)
        #expect(ledger.snapshot.toolCallCount == 2)
    }

    @Test("Un échec de lecture consomme aussi une lecture : on ne réessaie pas la même page")
    func failedReadStillCounts() throws {
        let ledger = makeLedger()
        _ = try ledger.beginRead(number: 1)
        ledger.recordRead(number: 1, page: ScrapedPage(url: agenticResult(1).url, title: "", content: "", succeeded: false))
        #expect(ledger.snapshot.readCount == 1)
        #expect(ledger.snapshot.successfulPages.isEmpty)
        #expect(ledger.snapshot.readPages.count == 1)
        #expect(try ledger.beginRead(number: 1) != .proceed(ledger.snapshot.entries[0]))
    }

    @Test("La 5e lecture est refusée en Approfondie (plafond de 4), la 4e en Fiable (plafond de 3)")
    func readCeilingIsEnforced() throws {
        let deep = makeLedger(reads: 4, calls: 8, seeded: 5)
        for number in 1...4 { _ = try deep.beginRead(number: number) }
        #expect(throws: ResearchBudgetExceeded(limit: .reads)) { try deep.beginRead(number: 5) }
        #expect(deep.snapshot.readCount == 4)

        let reliable = makeLedger(reads: 3, calls: 6, seeded: 5)
        for number in 1...3 { _ = try reliable.beginRead(number: number) }
        #expect(throws: ResearchBudgetExceeded(limit: .reads)) { try reliable.beginRead(number: 4) }
    }

    @Test("Le plafond d'appels borne une boucle de numéros invalides")
    func invalidNumberLoopIsBounded() throws {
        let ledger = makeLedger(reads: 4, calls: 3)
        for _ in 0..<3 { #expect(try ledger.beginRead(number: 42) == .unknownNumber) }
        #expect(throws: ResearchBudgetExceeded(limit: .toolCalls)) { try ledger.beginRead(number: 42) }
    }

    @Test("Fiable : le numéro d'une page non fiable n'existe pas")
    func untrustedNumberDoesNotExistInReliableMode() throws {
        let ledger = ResearchLedger(
            budget: makeBudget(),
            trustedDomainsOnly: true,
            seeded: [agenticResult(1), agenticTrustedResult(2)]
        )
        #expect(try ledger.beginRead(number: 2) == .unknownNumber)
        guard case .proceed(let entry) = try ledger.beginRead(number: 1) else {
            Issue.record("lecture attendue")
            return
        }
        #expect(SourceRanker.isTrustedDomain(entry.result.url))
    }

    @Test("Les pages lues gardent l'ordre de lecture et le texte complet")
    func readPagesKeepReadingOrder() throws {
        let ledger = makeLedger()
        _ = try ledger.beginRead(number: 3)
        _ = try ledger.beginRead(number: 1)
        ledger.recordRead(number: 3, page: ScrapedPage(url: agenticResult(3).url, title: "t3", content: String(repeating: "x", count: 5000), succeeded: true))
        ledger.recordRead(number: 1, page: ScrapedPage(url: agenticResult(1).url, title: "t1", content: "contenu un", succeeded: true))
        let snapshot = ledger.snapshot
        #expect(snapshot.readPages.map(\.number) == [3, 1])
        #expect(snapshot.readPages.first?.page.content.count == 5000)
        #expect(snapshot.successfulPages.map(\.title) == ["t3", "t1"])
        #expect(snapshot.hasFindings)
    }
}

// MARK: - ResearchLedger : fin, contrôle sans effet, concurrence

@Suite("ResearchLedger : fin, contrôles purs, concurrence")
struct ResearchLedgerLifecycleTests {
    @Test("finish n'est jamais refusé, même budget épuisé, et ne compte pas dans les appels")
    func finishIsNeverRefused() throws {
        let ledger = ResearchLedger(budget: makeBudget(searches: 1, reads: 1, calls: 1), trustedDomainsOnly: false, seeded: [])
        _ = try ledger.beginSearch(query: "un")
        #expect(ledger.snapshot.toolCallCount == 1)
        try ledger.precheck(.finish)
        ledger.finish()
        #expect(ledger.isFinished)
        #expect(ledger.snapshot.finished)
        #expect(ledger.snapshot.toolCallCount == 1)
    }

    @Test("Après finish, une recherche ou une lecture lève la sentinelle ResearchFinished")
    func toolsAfterFinishThrowSentinel() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [agenticResult(1)])
        ledger.finish()
        #expect(throws: ResearchFinished()) { try ledger.beginSearch(query: "x") }
        #expect(throws: ResearchFinished()) { try ledger.beginRead(number: 1) }
        #expect(throws: ResearchFinished()) { try ledger.precheck(.search) }
        #expect(!ledger.canSearch)
        #expect(!ledger.canRead)
    }

    @Test("precheck contrôle sans RIEN compter, y compris répété")
    func precheckDoesNotConsume() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [agenticResult(1)])
        for _ in 0..<20 {
            try ledger.precheck(.search)
            try ledger.precheck(.read)
            try ledger.precheck(.finish)
        }
        let snapshot = ledger.snapshot
        #expect(snapshot.toolCallCount == 0)
        #expect(snapshot.searchCount == 0)
        #expect(snapshot.readCount == 0)
    }

    @Test("precheck refuse un outil dont le plafond est atteint")
    func precheckRefusesExhaustedTools() throws {
        let ledger = ResearchLedger(budget: makeBudget(searches: 1, reads: 1, calls: 8), trustedDomainsOnly: false, seeded: [agenticResult(1), agenticResult(2)])
        _ = try ledger.beginSearch(query: "un")
        _ = try ledger.beginRead(number: 1)
        #expect(throws: ResearchBudgetExceeded(limit: .searches)) { try ledger.precheck(.search) }
        #expect(throws: ResearchBudgetExceeded(limit: .reads)) { try ledger.precheck(.read) }
        try ledger.precheck(.finish)
    }

    @Test("canSearch et canRead reflètent le budget restant, sans effet de bord")
    func canFlagsFollowTheBudget() throws {
        let ledger = ResearchLedger(budget: makeBudget(searches: 1, reads: 2, calls: 8), trustedDomainsOnly: false, seeded: [agenticResult(1), agenticResult(2)])
        for _ in 0..<5 {
            #expect(ledger.canSearch)
            #expect(ledger.canRead)
        }
        _ = try ledger.beginSearch(query: "un")
        #expect(!ledger.canSearch)
        _ = try ledger.beginRead(number: 1)
        #expect(ledger.canRead)
        _ = try ledger.beginRead(number: 2)
        #expect(!ledger.canRead)
    }

    @Test("canRead est faux quand toutes les pages numérotées ont déjà été demandées, ou quand aucune n'existe")
    func canReadNeedsAnUnreadPage() throws {
        let empty = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [])
        #expect(!empty.canRead)
        let one = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [agenticResult(1)])
        #expect(one.canRead)
        _ = try one.beginRead(number: 1)
        #expect(!one.canRead)
    }

    @Test("Le mode Rapide (budget nul) n'autorise rien")
    func disabledBudgetAllowsNothing() throws {
        let ledger = ResearchLedger(budget: .disabled, trustedDomainsOnly: false, seeded: [agenticResult(1)])
        #expect(!ledger.canSearch)
        #expect(!ledger.canRead)
        #expect(throws: ResearchBudgetExceeded(limit: .toolCalls)) { try ledger.beginSearch(query: "x") }
        #expect(throws: ResearchBudgetExceeded(limit: .toolCalls)) { try ledger.beginRead(number: 1) }
    }

    @Test("Une copie du registre rendue par snapshot ne bouge plus après coup")
    func snapshotIsAValueCopy() throws {
        let ledger = ResearchLedger(budget: makeBudget(), trustedDomainsOnly: false, seeded: [agenticResult(1)])
        let before = ledger.snapshot
        _ = try ledger.beginSearch(query: "un")
        #expect(before.searchCount == 0)
        #expect(ledger.snapshot.searchCount == 1)
    }

    @Test("Accès concurrents : jamais plus de lectures ni d'appels que le plafond")
    func concurrentAccessNeverExceedsCeilings() async {
        let ledger = ResearchLedger(
            budget: makeBudget(searches: 2, reads: 4, calls: 8),
            trustedDomainsOnly: false,
            seeded: (1...5).map { agenticResult($0) }
        )
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = try? ledger.beginSearch(query: "requete \(index)")
                    } else {
                        _ = try? ledger.beginRead(number: (index % 5) + 1)
                    }
                }
            }
        }
        let snapshot = ledger.snapshot
        #expect(snapshot.searchCount <= 2)
        #expect(snapshot.readCount <= 4)
        #expect(snapshot.toolCallCount == 8)
        #expect(snapshot.queries.count == snapshot.searchCount)
    }
}
