//
//  ResearchToolsTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/11/2026.
//

import Testing
import Foundation
import Synchronization
@testable import Triva

private struct SearchFailure: Error {}

private func makeBudget(searches: Int = 2, reads: Int = 4, calls: Int = 8) -> ResearchBudget {
    ResearchBudget(maxSearches: searches, maxReads: reads, maxToolCalls: calls, timeout: .seconds(30))
}

private func makeLedger(
    seeded: [SearXNGSearchResult] = (1...3).map { agenticResult($0) },
    budget: ResearchBudget = makeBudget(),
    trustedDomainsOnly: Bool = false
) -> ResearchLedger {
    ResearchLedger(budget: budget, trustedDomainsOnly: trustedDomainsOnly, seeded: seeded)
}

private func makeSearchTool(
    ledger: ResearchLedger,
    log: AgenticCallLog,
    results: [SearXNGSearchResult] = []
) -> WebSearchTool {
    WebSearchTool(ledger: ledger) { query in
        log.record(query)
        return results
    }
}

private func makeReadTool(
    ledger: ResearchLedger,
    log: AgenticCallLog,
    content: String = "Le texte de la page.",
    succeeded: Bool = true,
    refused: Bool = false
) -> ReadPageTool {
    ReadPageTool(ledger: ledger, scrape: { url in
        log.record(url)
        return ScrapedPage(url: url, title: "Page lue", content: content, succeeded: succeeded, refusedBySite: refused)
    }, focusQuery: "tour Eiffel hauteur")
}

// MARK: - webSearch

@Suite("WebSearchTool")
struct WebSearchToolTests {
    @Test("Le nom et la description sont ceux du contrat")
    func contract() {
        let tool = makeSearchTool(ledger: makeLedger(), log: AgenticCallLog())
        #expect(tool.name == "webSearch")
        #expect(!tool.description.isEmpty)
    }

    @Test("5 lignes au plus « [k] titre — domaine », numéros du registre, titre coupé à 80 caractères")
    func outputFormat() async throws {
        let ledger = makeLedger(seeded: [agenticResult(1)])
        let longTitle = String(repeating: "mot ", count: 40)
        let results = [agenticResult(2, title: longTitle)] + (3...8).map { agenticResult($0) }
        let tool = makeSearchTool(ledger: ledger, log: AgenticCallLog(), results: results)
        let output = try await tool.run(query: "tour eiffel hauteur")
        let lines = output.split(separator: "\n")
        #expect(lines.count == 5)
        #expect(lines.first?.hasPrefix("[2] ") == true)
        #expect(lines.first?.hasSuffix(" — site2.example.org") == true)
        let titlePart = try #require(lines.first).dropFirst("[2] ".count).dropLast(" — site2.example.org".count)
        #expect(titlePart.count <= ResearchToolOutput.maxTitleCharacters)
        #expect(titlePart.hasSuffix("…"))
        #expect(lines.last?.hasPrefix("[6] ") == true)
    }

    @Test("Une requête en double ne touche pas le réseau")
    func duplicateQueryDoesNotHitNetwork() async throws {
        let log = AgenticCallLog()
        let tool = makeSearchTool(ledger: makeLedger(), log: log, results: [agenticResult(9)])
        _ = try await tool.run(query: "La Tour Eiffel")
        let second = try await tool.run(query: "  la tour EIFFEL ")
        #expect(second == ResearchToolOutput.duplicateSearch)
        #expect(log.count == 1)
    }

    @Test("Une requête vide ne touche pas le réseau")
    func emptyQueryDoesNotHitNetwork() async throws {
        let log = AgenticCallLog()
        let tool = makeSearchTool(ledger: makeLedger(), log: log)
        let output = try await tool.run(query: "   ")
        #expect(output == ResearchToolOutput.emptyQuery)
        #expect(log.count == 0)
    }

    @Test("Une requête trop longue est coupée avant d'être envoyée au moteur")
    func longQueryIsClipped() async throws {
        let log = AgenticCallLog()
        let tool = makeSearchTool(ledger: makeLedger(), log: log)
        _ = try await tool.run(query: String(repeating: "a", count: 5000))
        #expect(log.all.first?.count == ResearchLedger.maxQueryCharacters)
    }

    @Test("Aucun résultat : un texte pour le modèle, pas une erreur")
    func noResults() async throws {
        let tool = makeSearchTool(ledger: makeLedger(), log: AgenticCallLog(), results: [])
        #expect(try await tool.run(query: "introuvable") == ResearchToolOutput.noResults)
    }

    @Test("Échec de la recherche : un texte pour le modèle, la recherche reste comptée")
    func searchFailureBecomesText() async throws {
        let ledger = makeLedger()
        let tool = WebSearchTool(ledger: ledger) { _ in throw SearchFailure() }
        let output = try await tool.run(query: "panne")
        #expect(output == ResearchToolOutput.searchFailed)
        #expect(ledger.snapshot.searchCount == 1)
    }

    @Test("L'annulation du moteur est relancée telle quelle, jamais avalée en texte")
    func cancellationFromSearchIsRethrown() async {
        let tool = WebSearchTool(ledger: makeLedger()) { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await tool.run(query: "stop") }
    }

    @Test("Une tâche déjà annulée ne lance aucune recherche et ne consomme rien")
    func cancelledTaskDoesNothing() async {
        let log = AgenticCallLog()
        let ledger = makeLedger()
        let tool = makeSearchTool(ledger: ledger, log: log)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.run(query: "annulée")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.count == 0)
        #expect(ledger.snapshot.toolCallCount == 0)
    }

    @Test("Annulation pendant la recherche : rien n'est numéroté")
    func cancellationDuringSearchRecordsNothing() async {
        let ledger = makeLedger(seeded: [])
        let tool = WebSearchTool(ledger: ledger) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return [agenticResult(1)]
        }
        let task = Task { try await tool.run(query: "en cours") }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ledger.snapshot.entries.isEmpty)
    }

    @Test("Plafond atteint : ResearchBudgetExceeded, aucun réseau")
    func ceilingStopsTheTool() async throws {
        let log = AgenticCallLog()
        let tool = makeSearchTool(ledger: makeLedger(budget: makeBudget(searches: 1)), log: log)
        _ = try await tool.run(query: "un")
        await #expect(throws: ResearchBudgetExceeded(limit: .searches)) { try await tool.run(query: "deux") }
        #expect(log.count == 1)
    }

    @Test("Fiable : seuls les domaines fiables sont montrés")
    func reliableModeShowsTrustedOnly() async throws {
        let ledger = makeLedger(seeded: [], trustedDomainsOnly: true)
        let tool = makeSearchTool(
            ledger: ledger, log: AgenticCallLog(),
            results: [agenticResult(1), agenticTrustedResult(2), agenticResult(3)]
        )
        let output = try await tool.run(query: "requete")
        #expect(output.split(separator: "\n").count == 1)
        #expect(output.contains("wikipedia.org"))
        #expect(!output.contains("example.org"))
    }

    @MainActor
    @Test("La recherche et le registre tournent hors du fil principal (appel depuis le main actor)")
    func runsOffTheMainThread() async throws {
        #expect(pthread_main_np() != 0, "le test part du fil principal : seul le saut @concurrent de l'outil peut l'en sortir")
        let log = AgenticCallLog()
        let tool = makeSearchTool(ledger: makeLedger(), log: log, results: [agenticResult(7)])
        _ = try await tool.run(query: "hors main")
        #expect(log.count == 1)
        #expect(!log.anyOnMainThread)
    }
}

// MARK: - readPage

@Suite("ReadPageTool")
struct ReadPageToolTests {
    @Test("Le nom et la description sont ceux du contrat")
    func contract() {
        let tool = makeReadTool(ledger: makeLedger(), log: AgenticCallLog())
        #expect(tool.name == "readPage")
        #expect(tool.description.contains("NUMÉRO"))
    }

    @Test("Lit l'URL EXACTE du registre et garde la page entière au registre")
    func readsTheRegistryURL() async throws {
        let ledger = makeLedger()
        let log = AgenticCallLog()
        let content = String(repeating: "La tour Eiffel mesure 330 mètres. ", count: 100)
        let tool = makeReadTool(ledger: ledger, log: log, content: content)
        _ = try await tool.run(number: 2)
        #expect(log.all == [agenticResult(2).url])
        let pages = ledger.snapshot.readPages
        #expect(pages.count == 1)
        #expect(pages.first?.number == 2)
        #expect(pages.first?.page.url == agenticResult(2).url)
        #expect(pages.first?.page.content == content)
    }

    @Test("Le modèle ne reçoit qu'un accusé et un passage de 300 caractères au plus")
    func modelSeesOnlyAShortPassage() async throws {
        let content = String(repeating: "La tour Eiffel mesure 330 mètres de hauteur. ", count: 200)
        let tool = makeReadTool(ledger: makeLedger(), log: AgenticCallLog(), content: content)
        let output = try await tool.run(number: 1)
        #expect(output.hasPrefix("[1] lue, \(content.count) caractères."))
        let passage = try #require(output.components(separatedBy: "Passage : ").last)
        #expect(passage.count <= ResearchToolOutput.maxPassageCharacters)
        #expect(output.count < 400)
    }

    @Test("Numéro inconnu : AUCUNE lecture réseau, un texte pour le modèle")
    func unknownNumberDoesNotScrape() async throws {
        let log = AgenticCallLog()
        let ledger = makeLedger()
        let tool = makeReadTool(ledger: ledger, log: log)
        for number in [0, 4, -3, 999] {
            #expect(try await tool.run(number: number) == ResearchToolOutput.unknownNumber(number))
        }
        #expect(log.count == 0)
        #expect(ledger.snapshot.readPages.isEmpty)
    }

    @Test("Le modèle ne peut désigner que des numéros du registre : aucune URL libre n'existe dans l'outil")
    func onlyRegistryURLsAreEverScraped() async throws {
        let log = AgenticCallLog()
        let ledger = makeLedger(seeded: [agenticResult(1), agenticResult(2)])
        let tool = makeReadTool(ledger: ledger, log: log)
        for number in -2...10 { _ = try? await tool.run(number: number) }
        let allowed = Set(ledger.snapshot.entries.map(\.result.url))
        #expect(!log.all.isEmpty)
        #expect(Set(log.all).isSubset(of: allowed))
    }

    @Test("Page déjà lue : pas de deuxième lecture")
    func alreadyReadDoesNotScrapeTwice() async throws {
        let log = AgenticCallLog()
        let tool = makeReadTool(ledger: makeLedger(), log: log)
        _ = try await tool.run(number: 1)
        #expect(try await tool.run(number: 1) == ResearchToolOutput.alreadyRead(1))
        #expect(log.count == 1)
    }

    @Test("Page illisible : accusé « illisible », l'échec est gardé au registre")
    func unreadablePage() async throws {
        let ledger = makeLedger()
        let tool = makeReadTool(ledger: ledger, log: AgenticCallLog(), content: "", succeeded: false)
        #expect(try await tool.run(number: 1) == "[1] illisible.")
        #expect(ledger.snapshot.readPages.count == 1)
        #expect(ledger.snapshot.successfulPages.isEmpty)
    }

    @Test("Page refusée par le site : accusé « refusée par le site »")
    func refusedPage() async throws {
        let ledger = makeLedger()
        let tool = makeReadTool(ledger: ledger, log: AgenticCallLog(), content: "", succeeded: false, refused: true)
        #expect(try await tool.run(number: 1) == "[1] refusée par le site.")
        #expect(ledger.snapshot.readPages.first?.page.refusedBySite == true)
    }

    @Test("Plafond de lectures atteint : ResearchBudgetExceeded, aucun réseau")
    func readCeilingStopsTheTool() async throws {
        let log = AgenticCallLog()
        let tool = makeReadTool(ledger: makeLedger(budget: makeBudget(reads: 1)), log: log)
        _ = try await tool.run(number: 1)
        await #expect(throws: ResearchBudgetExceeded(limit: .reads)) { try await tool.run(number: 2) }
        #expect(log.count == 1)
    }

    @Test("Fiable : une page non fiable ne se lit jamais, son numéro n'existe pas")
    func untrustedPageIsNeverRead() async throws {
        let log = AgenticCallLog()
        let ledger = makeLedger(seeded: [agenticResult(1), agenticTrustedResult(2)], trustedDomainsOnly: true)
        let tool = makeReadTool(ledger: ledger, log: log)
        #expect(try await tool.run(number: 2) == ResearchToolOutput.unknownNumber(2))
        _ = try await tool.run(number: 1)
        #expect(log.all == [agenticTrustedResult(2).url])
    }

    @Test("Annulation avant la lecture : rien n'est lu ni compté")
    func cancellationBeforeReading() async {
        let log = AgenticCallLog()
        let ledger = makeLedger()
        let tool = makeReadTool(ledger: ledger, log: log)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tool.run(number: 1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.count == 0)
        #expect(ledger.snapshot.toolCallCount == 0)
    }

    @Test("Annulation pendant la lecture : la page n'est pas gardée")
    func cancellationDuringReadingKeepsNothing() async {
        let ledger = makeLedger()
        let tool = ReadPageTool(ledger: ledger, scrape: { url in
            withUnsafeCurrentTask { $0?.cancel() }
            return ScrapedPage(url: url, title: "t", content: "contenu", succeeded: true)
        }, focusQuery: "x")
        let task = Task { try await tool.run(number: 1) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ledger.snapshot.readPages.isEmpty)
    }

    @MainActor
    @Test("La lecture tourne hors du fil principal (appel depuis le main actor)")
    func runsOffTheMainThread() async throws {
        #expect(pthread_main_np() != 0, "le test part du fil principal : seul le saut @concurrent de l'outil peut l'en sortir")
        let log = AgenticCallLog()
        let tool = makeReadTool(ledger: makeLedger(), log: log)
        _ = try await tool.run(number: 1)
        #expect(log.count == 1)
        #expect(!log.anyOnMainThread)
    }
}

// MARK: - finish

@Suite("FinishResearchTool")
struct FinishResearchToolTests {
    @Test("Marque le registre fini et répond « ok »")
    func marksTheLedgerFinished() {
        let ledger = makeLedger()
        let tool = FinishResearchTool(ledger: ledger)
        #expect(tool.name == "finish")
        #expect(tool.run() == "ok")
        #expect(ledger.isFinished)
    }

    @Test("Jamais refusé, même budget épuisé, et ne compte pas dans les appels")
    func neverRefused() async throws {
        let ledger = makeLedger(budget: makeBudget(searches: 1, reads: 1, calls: 1))
        let search = makeSearchTool(ledger: ledger, log: AgenticCallLog())
        _ = try await search.run(query: "un")
        let before = ledger.snapshot.toolCallCount
        _ = FinishResearchTool(ledger: ledger).run()
        #expect(ledger.snapshot.toolCallCount == before)
        #expect(ledger.snapshot.finished)
    }

    @Test("Après finish, les autres outils lèvent la sentinelle")
    func otherToolsThrowAfterFinish() async {
        let ledger = makeLedger()
        _ = FinishResearchTool(ledger: ledger).run()
        let search = makeSearchTool(ledger: ledger, log: AgenticCallLog())
        let read = makeReadTool(ledger: ledger, log: AgenticCallLog())
        await #expect(throws: ResearchFinished()) { try await search.run(query: "x") }
        await #expect(throws: ResearchFinished()) { try await read.run(number: 1) }
    }

    @Test("Les trois noms d'outil du registre correspondent aux outils")
    func toolKindsMatchTools() {
        let ledger = makeLedger()
        let names = [
            makeSearchTool(ledger: ledger, log: AgenticCallLog()).name,
            makeReadTool(ledger: ledger, log: AgenticCallLog()).name,
            FinishResearchTool(ledger: ledger).name,
        ]
        #expect(names.compactMap { ResearchToolKind(toolName: $0) } == [.search, .read, .finish])
        #expect(ResearchToolKind(toolName: "autre") == nil)
    }
}
