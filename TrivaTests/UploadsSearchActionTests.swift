//
//  UploadsSearchActionTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublures

/// Journal des requêtes reçues par le scorer : prouve QUELLES requêtes (et
/// combien) atteignent réellement l'index.
private actor QueryLog {
    private(set) var references: [String] = []

    func record(_ reference: String) {
        references.append(reference)
    }
}

/// Scorer factice DÉTERMINISTE : score fixé par couple (requête, fragment),
/// 0 pour tout couple absent. Jamais de vrai modèle ici — le classement doit
/// être entièrement prévisible.
private struct TableScorer: TextSimilarityScoring {
    let table: [String: [String: Double]]
    let log: QueryLog

    init(_ table: [String: [String: Double]], log: QueryLog = QueryLog()) {
        self.table = table
        self.log = log
    }

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        await log.record(reference)
        return candidates.map { table[reference]?[$0] ?? 0 }
    }
}

/// Client SearXNG qui compte ses appels : l'action ne doit JAMAIS sortir sur
/// le réseau, même si on lui passe un `FailoverManager` fonctionnel.
private actor CountingSearXNGClient: SearXNGSearching {
    private(set) var callCount = 0

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        return SearXNGSearchResponse(results: [], suggestions: [])
    }
}

private struct UnusedScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

/// Préparateur factice : rend toujours la même pièce jointe, sans disque.
private struct FixedPreparer: AttachmentPreparing {
    let attachment: IndexedAttachment

    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        attachment
    }
}

// MARK: - Fabriques

private func makeAttachment(_ fileName: String, chunks: [String], pages: [ClosedRange<Int>?]? = nil) -> IndexedAttachment {
    let built = chunks.enumerated().map { index, text in
        AttachmentChunk(index: index, text: text, pageRange: pages?[index])
    }
    return IndexedAttachment(
        fileName: fileName,
        kind: pages == nil ? .plainText : .pdf,
        pageCount: pages == nil ? nil : pages?.compactMap { $0?.upperBound }.max(),
        characterCount: chunks.reduce(0) { $0 + $1.count },
        isTruncated: false,
        isCopyRestricted: false,
        chunks: built
    )
}

private func makeMatch(
    _ attachmentID: UUID,
    fileName: String = "doc.txt",
    chunkIndex: Int,
    text: String,
    pageRange: ClosedRange<Int>? = nil,
    score: Double = 0.5
) -> AttachmentSearchMatch {
    AttachmentSearchMatch(
        attachmentID: attachmentID,
        fileName: fileName,
        chunkIndex: chunkIndex,
        pageRange: pageRange,
        text: text,
        score: score
    )
}

private let testInstance = URL(string: "https://searx.example")!

private func results(of output: SearchActionOutput) -> [SearXNGSearchResult]? {
    if case .searchResults(let results) = output { return results }
    return nil
}

// MARK: - Logique pure

@Suite("Recherche dans les fichiers joints — requêtes")
struct UploadsSearchQueryTests {
    @Test("Requêtes nettoyées, blanches et doublons retirés, ordre conservé")
    func cleansQueries() {
        let queries = UploadsSearchResultBuilder.effectiveQueries(["  impôts ", "", "impôts", "\n", "salaire"])

        #expect(queries == ["impôts", "salaire"])
    }

    @Test("Au plus 3 requêtes, APRÈS dédoublonnage (un doublon ne vole pas la place d'une vraie requête)")
    func capsAtThreeAfterDeduplication() {
        let queries = UploadsSearchResultBuilder.effectiveQueries(["a", "a", "b", " ", "c", "d"])

        #expect(queries == ["a", "b", "c"])
        #expect(UploadsSearchResultBuilder.maxQueries == 3)
    }
}

@Suite("Recherche dans les fichiers joints — URL synthétique")
struct UploadsSearchSourceURLTests {
    @Test("Sans hôte : la liste des sources n'en fait jamais un lien mort")
    func sourceURLHasNoHost() throws {
        let url = UploadsSearchResultBuilder.sourceURL(for: UUID())

        let parsed = try #require(URL(string: url))
        #expect(parsed.host == nil)
        #expect(parsed.scheme == UploadsSearchResultBuilder.attachmentURLScheme)
    }

    @Test("Unique par pièce jointe, et réversible")
    func sourceURLIsUniqueAndReversible() {
        let first = UUID()
        let second = UUID()

        #expect(UploadsSearchResultBuilder.sourceURL(for: first) != UploadsSearchResultBuilder.sourceURL(for: second))
        #expect(UploadsSearchResultBuilder.attachmentID(fromSourceURL: UploadsSearchResultBuilder.sourceURL(for: first)) == first)
    }

    @Test("Une URL web ou mal formée n'est pas prise pour une pièce jointe")
    func rejectsForeignURLs() {
        #expect(UploadsSearchResultBuilder.attachmentID(fromSourceURL: "https://exemple.fr/page") == nil)
        #expect(UploadsSearchResultBuilder.attachmentID(fromSourceURL: "triva-attachment:pas-un-uuid") == nil)
        #expect(UploadsSearchResultBuilder.attachmentID(fromSourceURL: "") == nil)
    }
}

@Suite("Recherche dans les fichiers joints — fusion et déduplication")
struct UploadsSearchMergeTests {
    @Test("Un résultat par fichier, fichiers ordonnés par leur meilleur fragment, fragments dans l'ordre de classement")
    func mergesPerFileByRank() throws {
        let report = UUID()
        let notes = UUID()
        let matches = [
            makeMatch(notes, fileName: "notes.txt", chunkIndex: 4, text: "N4"),
            makeMatch(report, fileName: "rapport.txt", chunkIndex: 0, text: "R0"),
            makeMatch(notes, fileName: "notes.txt", chunkIndex: 1, text: "N1"),
        ]

        let built = UploadsSearchResultBuilder.makeResults(from: matches)

        #expect(built.map(\.title) == ["notes.txt", "rapport.txt"])
        #expect(built.map(\.content) == ["N4\n\nN1", "R0"])
        #expect(built.map(\.url) == [
            UploadsSearchResultBuilder.sourceURL(for: notes),
            UploadsSearchResultBuilder.sourceURL(for: report),
        ])
    }

    @Test("Même position ou même texte (fichier joint deux fois) : un seul exemplaire, le mieux classé")
    func deduplicatesByPositionAndText() {
        let original = UUID()
        let copy = UUID()
        let matches = [
            makeMatch(original, fileName: "a.txt", chunkIndex: 0, text: "Même paragraphe."),
            makeMatch(copy, fileName: "a copie.txt", chunkIndex: 0, text: "Même paragraphe."),
            makeMatch(original, fileName: "a.txt", chunkIndex: 0, text: "Même paragraphe."),
            makeMatch(original, fileName: "a.txt", chunkIndex: 1, text: "Autre paragraphe."),
        ]

        let kept = UploadsSearchResultBuilder.deduplicated(matches)

        #expect(kept.map(\.chunkIndex) == [0, 1])
        #expect(kept.allSatisfy { $0.attachmentID == original })
    }

    @Test("Un fragment blanc est écarté")
    func dropsBlankFragments() {
        let id = UUID()

        let built = UploadsSearchResultBuilder.makeResults(from: [makeMatch(id, chunkIndex: 0, text: "  \n ")])

        #expect(built.isEmpty)
    }

    @Test("Repère de page pour un PDF, rien hors PDF")
    func formatsPageMarkers() {
        let id = UUID()

        #expect(UploadsSearchResultBuilder.formattedFragment(makeMatch(id, chunkIndex: 0, text: "texte", pageRange: 3...3)) == "(p. 3) texte")
        #expect(UploadsSearchResultBuilder.formattedFragment(makeMatch(id, chunkIndex: 0, text: "texte", pageRange: 3...4)) == "(p. 3–4) texte")
        #expect(UploadsSearchResultBuilder.formattedFragment(makeMatch(id, chunkIndex: 0, text: " texte ")) == "texte")
    }

    @Test("Au plus maxFragments fragments, les mieux classés")
    func capsFragmentCount() {
        let id = UUID()
        let matches = (0..<5).map { makeMatch(id, chunkIndex: $0, text: "F\($0)") }

        let built = UploadsSearchResultBuilder.makeResults(from: matches, maxFragments: 2)

        #expect(built.map(\.content) == ["F0\n\nF1"])
    }
}

@Suite("Recherche dans les fichiers joints — budget de caractères")
struct UploadsSearchBudgetTests {
    @Test("Un fragment plus long que le budget est tronqué au budget")
    func truncatesOversizedFragment() throws {
        let id = UUID()
        let long = String(repeating: "x", count: 500)

        let built = UploadsSearchResultBuilder.makeResults(from: [makeMatch(id, chunkIndex: 0, text: long)], maxTotalCharacters: 20)

        let only = try #require(built.first)
        #expect(built.count == 1)
        #expect(only.content == String(repeating: "x", count: 20))
    }

    @Test("Budget partagé à parts égales entre deux fichiers longs")
    func splitsBudgetEvenly() {
        let first = UUID()
        let second = UUID()
        let matches = [
            makeMatch(first, fileName: "a.txt", chunkIndex: 0, text: String(repeating: "a", count: 100)),
            makeMatch(second, fileName: "b.txt", chunkIndex: 0, text: String(repeating: "b", count: 100)),
        ]

        let built = UploadsSearchResultBuilder.makeResults(from: matches, maxTotalCharacters: 60)

        #expect(built.map { $0.content?.count } == [30, 30])
    }

    @Test("Ce qu'un fichier court n'utilise pas revient aux autres")
    func redistributesUnusedShare() {
        let short = UUID()
        let long = UUID()
        let matches = [
            makeMatch(long, fileName: "long.txt", chunkIndex: 0, text: String(repeating: "l", count: 100)),
            makeMatch(short, fileName: "court.txt", chunkIndex: 0, text: "0123456789"),
        ]

        let built = UploadsSearchResultBuilder.makeResults(from: matches, maxTotalCharacters: 60)

        #expect(built.map { $0.content?.count } == [50, 10])
    }

    @Test("Le total, séparateurs et repères de page compris, ne dépasse jamais le budget", arguments: [1, 7, 50, 333, 6000])
    func neverExceedsBudget(budget: Int) {
        let ids = (0..<3).map { _ in UUID() }
        let matches = (0..<10).map { position in
            makeMatch(
                ids[position % 3],
                fileName: "f\(position % 3).pdf",
                chunkIndex: position,
                text: "Fragment numéro \(position) " + String(repeating: "é", count: 90 + position),
                pageRange: position...(position + 1)
            )
        }

        let built = UploadsSearchResultBuilder.makeResults(from: matches, maxTotalCharacters: budget)

        let total = built.reduce(0) { $0 + ($1.content?.count ?? 0) }
        #expect(total <= budget)
        #expect(!built.isEmpty)
        #expect(built.allSatisfy { $0.content?.last?.isWhitespace == false })
    }

    @Test("Budget nul, fragments nuls ou aucun fragment : aucun résultat")
    func degenerateBudgets() {
        let id = UUID()
        let matches = [makeMatch(id, chunkIndex: 0, text: "texte")]

        #expect(UploadsSearchResultBuilder.makeResults(from: matches, maxTotalCharacters: 0).isEmpty)
        #expect(UploadsSearchResultBuilder.makeResults(from: matches, maxFragments: 0).isEmpty)
        #expect(UploadsSearchResultBuilder.makeResults(from: []).isEmpty)
    }

    @Test("Partage équitable : somme bornée, part bornée par la longueur, au moins 1 chacun si le budget le permet")
    func fairSharesInvariants() {
        #expect(UploadsSearchResultBuilder.fairShares(of: [100, 100], budget: 60) == [30, 30])
        #expect(UploadsSearchResultBuilder.fairShares(of: [10, 100], budget: 60) == [10, 50])
        #expect(UploadsSearchResultBuilder.fairShares(of: [5, 5], budget: 60) == [5, 5])
        #expect(UploadsSearchResultBuilder.fairShares(of: [100, 100, 100], budget: 3) == [1, 1, 1])
        #expect(UploadsSearchResultBuilder.fairShares(of: [100, 100], budget: 0) == [0, 0])
        #expect(UploadsSearchResultBuilder.fairShares(of: [], budget: 10).isEmpty)
    }
}

// MARK: - Action

@MainActor
@Suite("Action de recherche dans les fichiers joints")
struct UploadsSearchActionTests {
    private func makeFailoverManager(_ client: CountingSearXNGClient) -> FailoverManager {
        FailoverManager(client: client, instances: [testInstance])
    }

    @Test("Nom stable et description pour le planner")
    func identity() {
        let action = UploadsSearchAction(searchIndex: AttachmentSearchIndex(attachments: [], scorer: TableScorer([:])))

        #expect(action.name == "uploadsSearch")
        #expect(!action.descriptionForPlanner.isEmpty)
    }

    @Test("Aucune pièce jointe : résultat vide, jamais une erreur, scorer et réseau jamais sollicités")
    func noAttachmentsYieldsEmptyResults() async throws {
        let log = QueryLog()
        let client = CountingSearXNGClient()
        let action = UploadsSearchAction(searchIndex: AttachmentSearchIndex(attachments: [], scorer: TableScorer([:], log: log)))

        let output = try await action.execute(query: "impôts", urls: [], failoverManager: makeFailoverManager(client), scrapeService: UnusedScrapeService())

        #expect(results(of: output) == [])
        #expect(await log.references.isEmpty)
        #expect(await client.callCount == 0)
    }

    @Test("Store vide : résultat vide")
    func emptyStoreYieldsEmptyResults() async throws {
        let store = AttachmentStore(scorer: TableScorer([:]), preparer: FixedPreparer(attachment: makeAttachment("a.txt", chunks: ["x"])))
        let action = UploadsSearchAction(attachmentStore: store)

        let output = try await action.execute(query: "q", urls: [], failoverManager: makeFailoverManager(CountingSearXNGClient()), scrapeService: UnusedScrapeService())

        #expect(results(of: output) == [])
    }

    @Test("Requête blanche : résultat vide, scorer jamais appelé")
    func blankQueryYieldsEmptyResults() async throws {
        let log = QueryLog()
        let index = AttachmentSearchIndex(attachments: [makeAttachment("a.txt", chunks: ["texte"])], scorer: TableScorer([:], log: log))

        let output = try await UploadsSearchAction(searchIndex: index).execute(
            query: "   ",
            urls: [],
            failoverManager: makeFailoverManager(CountingSearXNGClient()),
            scrapeService: UnusedScrapeService()
        )

        #expect(results(of: output) == [])
        #expect(await log.references.isEmpty)
    }

    @Test("Une requête : fragments du fichier classés, sans aucun appel réseau, URLs passées ignorées")
    func singleQuerySearchesAttachments() async throws {
        let attachment = makeAttachment("rapport.pdf", chunks: ["alpha", "beta", "gamma"], pages: [1...1, 2...2, 3...4])
        let scorer = TableScorer(["q1": ["alpha": 0.2, "beta": 0.9, "gamma": 0.5]])
        let client = CountingSearXNGClient()

        let output = try await UploadsSearchAction(searchIndex: AttachmentSearchIndex(attachments: [attachment], scorer: scorer)).execute(
            query: "q1",
            urls: ["https://ignore.example"],
            failoverManager: makeFailoverManager(client),
            scrapeService: UnusedScrapeService()
        )

        let built = try #require(results(of: output))
        #expect(built.count == 1)
        #expect(built.first?.title == "rapport.pdf")
        #expect(built.first?.url == UploadsSearchResultBuilder.sourceURL(for: attachment.id))
        #expect(built.first?.content == "(p. 2) beta\n\n(p. 3–4) gamma\n\n(p. 1) alpha")
        #expect(await client.callCount == 0)
    }

    @Test("Plusieurs requêtes : fusion par rangs réciproques, ordre différent d'une requête seule")
    func multipleQueriesAreFused() async throws {
        let attachment = makeAttachment("notes.txt", chunks: ["a", "b", "c"])
        let scorer = TableScorer([
            "q1": ["a": 0.9, "b": 0.8, "c": 0.1],
            "q2": ["b": 0.9, "c": 0.8, "a": 0.1],
        ])
        let action = UploadsSearchAction(searchIndex: AttachmentSearchIndex(attachments: [attachment], scorer: scorer))

        let single = try await action.search(queries: ["q1"])
        let fused = try await action.search(queries: ["q1", "q2"])

        #expect(single.map(\.content) == ["a\n\nb\n\nc"])
        #expect(fused.map(\.content) == ["b\n\na\n\nc"])
    }

    @Test("Au plus 3 requêtes distinctes atteignent le scorer")
    func onlyThreeDistinctQueriesReachScorer() async throws {
        let log = QueryLog()
        let index = AttachmentSearchIndex(attachments: [makeAttachment("a.txt", chunks: ["texte"])], scorer: TableScorer([:], log: log))

        _ = try await UploadsSearchAction(searchIndex: index).search(queries: ["q1", "q1", "q2", "q3", "q4", "q5"])

        #expect(await log.references == ["q1", "q2", "q3"])
    }

    @Test("Budget appliqué de bout en bout : fragments plus longs que le budget tronqués")
    func budgetAppliesEndToEnd() async throws {
        let long = String(repeating: "m", count: 900)
        let attachment = makeAttachment("long.txt", chunks: [long, long + "n"])
        let action = UploadsSearchAction(
            searchIndex: AttachmentSearchIndex(attachments: [attachment], scorer: TableScorer([:])),
            maxTotalCharacters: 100
        )

        let built = try await action.search(queries: ["q"])

        #expect(built.count == 1)
        #expect(built.first?.content?.count == 100)
    }

    @Test("Instantané pris à la construction : vider le store ensuite ne change pas la recherche en cours")
    func storeIsSnapshottedAtConstruction() async throws {
        let attachment = makeAttachment("a.txt", chunks: ["contenu"])
        let store = AttachmentStore(scorer: TableScorer([:]), preparer: FixedPreparer(attachment: attachment))
        try await store.attach(fileAt: URL(fileURLWithPath: "/dev/null/a.txt"))

        let action = UploadsSearchAction(attachmentStore: store)
        store.removeAll()
        let built = try await action.search(queries: ["q"])

        #expect(built.map(\.content) == ["contenu"])
        #expect(try await UploadsSearchAction(attachmentStore: store).search(queries: ["q"]).isEmpty)
    }

    @Test("Paramètres négatifs ramenés à 0 : résultat vide, jamais de plantage")
    func negativeLimitsAreClamped() async throws {
        let index = AttachmentSearchIndex(attachments: [makeAttachment("a.txt", chunks: ["texte"])], scorer: TableScorer([:]))

        #expect(try await UploadsSearchAction(searchIndex: index, maxFragments: -1).search(queries: ["q"]).isEmpty)
        #expect(try await UploadsSearchAction(searchIndex: index, maxTotalCharacters: -5).search(queries: ["q"]).isEmpty)
    }
}

// MARK: - Fichiers joints dans le pipeline de recherche (I1b)

/// Provider IA factice du pipeline : réponse choisie selon la NATURE du
/// prompt, comme `MockAIGenerating` de `SearchOrchestratorTests.swift`
/// (dupliqué : `private` est scopé au fichier) — `<user_query>` pour la
/// classification, `<planner_context>` pour le planner, le reste pour la
/// réponse finale.
private final class PipelineAIProvider: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let classifyResponse: String
    private var plannerResponses: [String]

    init(classifyResponse: String, plannerResponses: [String] = []) {
        self.classifyResponse = classifyResponse
        self.plannerResponses = plannerResponses
    }

    var plannerPrompts: [String] {
        receivedPrompts.filter { $0.contains("<planner_context>") }
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        if prompt.contains("<user_query>") { return classifyResponse }
        if prompt.contains("<planner_context>") { return plannerResponses.isEmpty ? "" : plannerResponses.removeFirst() }
        return "réponse"
    }
}

/// Client SearXNG à réponse fixe, qui compte ses appels.
private actor FixedSearXNGClient: SearXNGSearching {
    private let results: [SearXNGSearchResult]
    private(set) var callCount = 0

    init(results: [SearXNGSearchResult] = []) {
        self.results = results
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        return SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Classement déterministe : similarité constante (l'ordre du moteur
/// décide), jamais de quasi-doublon, aucune langue reconnue.
private struct ConstantScorer: TextSimilarityScoring {
    let score: Double

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: score, count: candidates.count)
    }
}

private struct NoLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

private func webResult(_ name: String) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: "Web \(name)",
        url: "https://\(name).example",
        content: "Extrait \(name)",
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

private func classificationJSON(personalSearch: Bool, standaloneFollowUp: String) -> String {
    #"{"classification":{"skipSearch":false,"personalSearch":\#(personalSearch),"academicSearch":false,"discussionSearch":false,"#
        + #""showWeatherWidget":false,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"\#(standaloneFollowUp)"}"#
}

@MainActor
private func makePipeline(client: FixedSearXNGClient, aiProvider: PipelineAIProvider, responseMode: ResponseMode) -> SearchOrchestrator {
    SearchOrchestrator(
        failoverManager: FailoverManager(client: client, instances: [testInstance]),
        aiProvider: aiProvider,
        responseMode: responseMode,
        scrapeService: UnusedScrapeService(),
        sourceRanker: SourceRanker(
            relevanceScorer: ConstantScorer(score: 0.5),
            duplicateScorer: ConstantScorer(score: 0),
            languageIdentifier: NoLanguageIdentifier()
        ),
        widgets: []
    )
}

@MainActor
@Suite("Fichiers joints dans le pipeline de recherche")
struct UploadsSearchPipelineTests {
    @Test("personalSearch + fichier joint : seuls les fichiers sont consultés — aucun appel SearXNG ni planner, document cité en [1]")
    func personalSearchWithAttachmentsSearchesOnlyTheFiles() async throws {
        let attachment = makeAttachment("contrat.pdf", chunks: ["Le préavis est de trois mois.", "La clause 7 traite des pénalités."], pages: [1...1, 2...2])
        let scorer = TableScorer(["préavis du contrat": ["Le préavis est de trois mois.": 0.9, "La clause 7 traite des pénalités.": 0.1]])
        let client = FixedSearXNGClient(results: [webResult("a")])
        let aiProvider = PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: true, standaloneFollowUp: "préavis du contrat"))
        let orchestrator = makePipeline(client: client, aiProvider: aiProvider, responseMode: .deep)

        let result = try await orchestrator.answer(
            query: "Quel est le préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: scorer)
        )

        #expect(await client.callCount == 0)
        #expect(aiProvider.plannerPrompts.isEmpty)
        #expect(result.sources.map(\.url) == [UploadsSearchResultBuilder.sourceURL(for: attachment.id)])
        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(result.artifacts.citableSourceCount == 1)
        #expect(result.artifacts.searchPerformed)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("[1] contrat.pdf"))
        #expect(finalPrompt.contains("Le préavis est de trois mois."))
    }

    @Test("Mode Fiable : les fichiers joints restent des sources — le filtre « domaines fiables » ne concerne que le web")
    func reliableModeKeepsAttachmentSources() async throws {
        let attachment = makeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let client = FixedSearXNGClient()
        let aiProvider = PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: true, standaloneFollowUp: "préavis"))
        let orchestrator = makePipeline(client: client, aiProvider: aiProvider, responseMode: .reliable)

        let result = try await orchestrator.answer(
            query: "Quel préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: TableScorer([:]))
        )

        #expect(result.sources.map(\.title) == ["notes.txt"])
        #expect(await client.callCount == 0)
    }

    /// Décision (b) de Ben : les fichiers joints sont consultés dès le tour
    /// seedé, avec la reformulation, et le planner ne les propose plus — avant,
    /// ils n'étaient lus que si le planner choisissait `uploadsSearch`.
    @Test("Recherche web + fichiers joints sans personalSearch : fichiers consultés dès le tour seedé (reformulation), jamais par le planner ; documents en tête, puis le web")
    func webRouteConsultsAttachmentsFromTheSeedNotThePlanner() async throws {
        let attachment = makeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let log = QueryLog()
        let scorer = TableScorer(["durée du préavis": ["Le préavis est de trois mois.": 0.9]], log: log)
        let client = FixedSearXNGClient(results: [webResult("a"), webResult("b")])
        let aiProvider = PipelineAIProvider(
            classifyResponse: classificationJSON(personalSearch: false, standaloneFollowUp: "durée du préavis"),
            plannerResponses: [#"{"action":"done","urls":[]}"#]
        )
        let orchestrator = makePipeline(client: client, aiProvider: aiProvider, responseMode: .deep)

        let result = try await orchestrator.answer(
            query: "Quelle est la durée du préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: scorer)
        )

        #expect(await client.callCount == 1)
        #expect(result.sources.map(\.url) == [UploadsSearchResultBuilder.sourceURL(for: attachment.id), "https://a.example", "https://b.example"])
        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(await log.references == ["durée du préavis"])
        let plannerPrompts = aiProvider.plannerPrompts
        #expect(plannerPrompts.count == 1)
        #expect(plannerPrompts.allSatisfy { !$0.contains("uploadsSearch") })
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("[1] notes.txt"))
        #expect(finalPrompt.contains("[2] Web a"))
    }

    @Test("Budget des fichiers joints : 6 000 caractères quand ils sont seuls, la moitié quand ils s'ajoutent à une recherche web")
    func attachmentBudgetDependsOnTheRoute() async throws {
        let longText = String(repeating: "Le préavis est de trois mois. ", count: 400)
        let attachment = makeAttachment("long.txt", chunks: [longText])
        let index = AttachmentSearchIndex(attachments: [attachment], scorer: TableScorer([:]))

        let alone = makePipeline(
            client: FixedSearXNGClient(),
            aiProvider: PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: true, standaloneFollowUp: "préavis")),
            responseMode: .deep
        )
        let aloneResult = try await alone.answer(query: "Quel préavis ?", attachments: index)

        let mixed = makePipeline(
            client: FixedSearXNGClient(results: [webResult("a")]),
            aiProvider: PipelineAIProvider(
                classifyResponse: classificationJSON(personalSearch: false, standaloneFollowUp: "préavis"),
                plannerResponses: [#"{"action":"uploadsSearch","queries":["préavis"]}"#]
            ),
            responseMode: .deep
        )
        let mixedResult = try await mixed.answer(query: "Quel préavis ?", attachments: index)

        let aloneCount = try #require(aloneResult.sources.first?.content?.count)
        let mixedCount = try #require(mixedResult.sources.first?.content?.count)
        #expect(aloneCount > UploadsSearchResultBuilder.defaultMaxTotalCharacters / 2)
        #expect(aloneCount <= UploadsSearchResultBuilder.defaultMaxTotalCharacters)
        #expect(mixedCount <= UploadsSearchResultBuilder.defaultMaxTotalCharacters / 2)
    }

    /// Décision (b) de Ben (2026-10-29) : le classifieur ne sait pas que des
    /// fichiers sont joints, et le mode Rapide n'a pas de planner. Avant, ce
    /// test figeait « fichiers joints non consultés » ; ils le sont désormais
    /// toujours, sans couper la recherche web que la classification demande.
    @Test("Mode Rapide sans personalSearch : fichiers joints consultés quand même, à côté de la recherche web")
    func quickModeConsultsAttachmentsAlongsideTheWeb() async throws {
        let attachment = makeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let log = QueryLog()
        let client = FixedSearXNGClient(results: [webResult("a")])
        let orchestrator = makePipeline(
            client: client,
            aiProvider: PipelineAIProvider(classifyResponse: classificationJSON(personalSearch: false, standaloneFollowUp: "préavis")),
            responseMode: .quick
        )

        let result = try await orchestrator.answer(
            query: "Quel préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: TableScorer([:], log: log))
        )

        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(result.sources.map(\.url) == [UploadsSearchResultBuilder.sourceURL(for: attachment.id), "https://a.example"])
        #expect(await log.references == ["préavis"])
        #expect(await client.callCount == 1)
    }

    @Test("Question sans recherche (skipSearch) avec un fichier joint : fichiers consultés, aucun appel SearXNG")
    func skippedSearchStillConsultsAttachments() async throws {
        let attachment = makeAttachment("notes.txt", chunks: ["Le préavis est de trois mois."])
        let client = FixedSearXNGClient(results: [webResult("a")])
        let skipJSON = #"{"classification":{"skipSearch":true,"personalSearch":false,"academicSearch":false,"discussionSearch":false,"#
            + #""showWeatherWidget":false,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"résume"}"#
        let orchestrator = makePipeline(client: client, aiProvider: PipelineAIProvider(classifyResponse: skipJSON), responseMode: .quick)

        let result = try await orchestrator.answer(
            query: "Résume-le",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: TableScorer([:]))
        )

        #expect(await client.callCount == 0)
        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(result.artifacts.searchPerformed)
    }

    @Test("Routage (b) : seule la route « aucune recherche » change, et seulement avec des fichiers joints")
    func routeConsultingAttachmentsOnlyRewritesTheNoSearchRoute() {
        #expect(SearchOrchestrator.routeConsultingAttachments(.none, hasAttachments: true) == .attachments)
        #expect(SearchOrchestrator.routeConsultingAttachments(.none, hasAttachments: false) == SearchRoute.none)
        #expect(SearchOrchestrator.routeConsultingAttachments(.web(.academic), hasAttachments: true) == .web(.academic))
        #expect(SearchOrchestrator.routeConsultingAttachments(.webUnlessWeatherAnswered, hasAttachments: true) == .webUnlessWeatherAnswered)
        #expect(SearchOrchestrator.routeConsultingAttachments(.attachments, hasAttachments: true) == .attachments)
    }
}

// MARK: - Budget Apple Intelligence avec fichiers joints ET widgets (I1b, bug 6)

/// Pages scrapées pleines : le plafond par page de `ScrapeService`.
private struct FullPageScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        let content = String(String(repeating: "Contenu complet de la page scrapée. ", count: 200).prefix(ScrapeService.defaultMaxContentCharactersPerPage))
        return ScrapedPage(url: url, title: "Page \(url)", content: content, succeeded: true)
    }
}

/// Widget toujours exécuté, au contexte fixe.
private struct AlwaysOnWidget: SearchWidget {
    let kind: SearchWidgetKind
    let llmContext: String

    func shouldExecute(for classification: QueryClassification) -> Bool { true }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        SearchWidgetOutput(kind: kind, llmContext: llmContext)
    }
}

extension UploadsSearchPipelineTests {
    /// Les deux plus longs contextes que les vrais services peuvent produire :
    /// nom de lieu long (« ville, région, pays » d'Open-Meteo) et expression
    /// au plafond de `CalculationExpressionEvaluator` (256 caractères).
    private static func longestWidgetContexts() -> (weather: String, calculation: String) {
        let weather = WeatherWidgetService.llmContext(for: WeatherWidgetData(
            location: WeatherLocation(name: String(repeating: "Saint-Rémy-en-Bouzemont ", count: 3) + ", Grand Est, France", latitude: 48.6, longitude: 4.6),
            condition: WeatherCondition(label: "Orage avec grêle forte", systemImageName: "cloud.bolt.rain"),
            currentTemperatureCelsius: -40,
            apparentTemperatureCelsius: -48,
            relativeHumidityPercent: 100,
            windSpeedKmh: 150,
            isDaytime: true,
            todayMinTemperatureCelsius: -45,
            todayMaxTemperatureCelsius: -38
        ))
        let calculation = CalculationWidgetService.llmContext(for: CalculationWidgetData(
            expression: String(repeating: "12+", count: 85) + "1",
            result: 1021,
            formattedResult: "123 456 789 012,0123456789"
        ))
        return (weather, calculation)
    }

    /// Le pire cas de `appleIntelligenceWorstCaseFitsTheContextWindow`
    /// (PromptTemplatesTests) — historique long, question et reformulation de
    /// 300 caractères, extraits de 300 caractères, pages scrapées pleines —,
    /// mené de bout en bout, PLUS ce qu'I1b ajoute au prompt : 10 fichiers
    /// joints, consultés dès le tour seedé depuis la décision (b) de Ben (5
    /// extraits au plus entrent dans le prompt,
    /// `SearchOrchestrator.attachmentFragmentLimit`), et les deux widgets à
    /// leur plus long. Même borne que le pire cas d'I1a. Avant le partage du
    /// budget des pages (`scrapedContextBudget`) et ce plancher d'extraits :
    /// 11 269 caractères mesurés, 10 documents de 150 caractères. Après :
    /// 9 328 (mesure du 29/10/2026, fichiers alors lus par le planner — même
    /// budget, moitié de `maxScrapedContextCharacters`).
    @Test("Apple Intelligence, pire cas avec fichiers joints (tour seedé) et deux widgets : prompt final sous 10 000 caractères")
    func appleIntelligenceWorstCaseWithAttachmentsAndWidgetsFits() async throws {
        let long = String(repeating: "La photosynthèse convertit l'énergie lumineuse en énergie chimique. ", count: 30)
        let snippet = String(long.prefix(300))
        let webResults = (1...7).map { index in
            SearXNGSearchResult(
                title: "Source web \(index)", url: "https://\(index).example", content: snippet,
                imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
            )
        }
        // Un texte DISTINCT par fichier : `UploadsSearchResultBuilder.deduplicated`
        // retire les fragments au texte identique (même document joint deux
        // fois). Avec dix fragments identiques, un seul document survivait et le
        // test mesurait un cas bien plus léger que le pire cas annoncé.
        let attachments = (1...10).map { index in
            makeAttachment("document-\(index).txt", chunks: ["Document \(index). " + String(long.prefix(600))])
        }
        let standalone = String(repeating: "rendement photosynthèse ", count: 15)
        let classifyResponse = #"{"classification":{"skipSearch":false,"personalSearch":false,"academicSearch":false,"discussionSearch":false,"#
            + #""showWeatherWidget":true,"showStockWidget":false,"showCalculationWidget":true},"standaloneFollowUp":"\#(standalone)"}"#
        let aiProvider = PipelineAIProvider(
            classifyResponse: classifyResponse,
            plannerResponses: [#"{"action":"scrapeURL","urls":["https://1.example","https://2.example"]}"#]
        )
        let contexts = Self.longestWidgetContexts()
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: FixedSearXNGClient(results: webResults), instances: [testInstance]),
            aiProvider: aiProvider,
            responseMode: .deep,
            configuration: .appleIntelligence,
            scrapeService: FullPageScrapeService(),
            sourceRanker: SourceRanker(
                relevanceScorer: ConstantScorer(score: 0.5),
                duplicateScorer: ConstantScorer(score: 0),
                languageIdentifier: NoLanguageIdentifier()
            ),
            widgets: [
                AlwaysOnWidget(kind: .weather, llmContext: contexts.weather),
                AlwaysOnWidget(kind: .calculation, llmContext: contexts.calculation),
            ]
        )
        let history = (0..<10).map { ClassifierChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: long) }

        let result = try await orchestrator.answer(
            query: String(long.prefix(300)),
            chatHistory: history,
            attachments: AttachmentSearchIndex(attachments: attachments, scorer: TableScorer([:]))
        )

        // Le pire cas est bien atteint : autant de documents que le budget en
        // admet (1 500 caractères ÷ 300), pages et widgets.
        #expect(result.artifacts.attachmentSourceCount == 5)
        #expect(result.artifacts.widgets.count == 2)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Contenu de la page : "))
        #expect(finalPrompt.contains("<donnees_widgets>"))
        #expect(finalPrompt.count < 10_000, "pire cas mesuré : \(finalPrompt.count) caractères")
    }

    @Test("Budget long partagé : le contenu des fichiers joints est retranché du budget des pages scrapées, jamais sous 0")
    func attachmentContentIsDeductedFromTheScrapedBudget() {
        let document = SearXNGSearchResult(
            title: "notes.txt", url: UploadsSearchResultBuilder.sourceURL(for: UUID()), content: String(repeating: "a", count: 1_200),
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )

        #expect(SearchOrchestrator.scrapedContextBudget(total: 3_000, attachmentSources: []) == 3_000)
        #expect(SearchOrchestrator.scrapedContextBudget(total: 3_000, attachmentSources: [document]) == 1_800)
        #expect(SearchOrchestrator.scrapedContextBudget(total: 1_000, attachmentSources: [document]) == 0)
    }

    @Test("Extraits de fichiers joints : 300 caractères au moins chacun — 5 sous 1 500 (Apple Intelligence + web), 8 sous 2 500, 10 dès 3 000, jamais 0")
    func attachmentFragmentLimitKeepsExcerptsUseful() {
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 1_500) == 5)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 2_500) == 8)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 3_000) == UploadsSearchResultBuilder.defaultMaxFragments)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 6_000) == UploadsSearchResultBuilder.defaultMaxFragments)
        #expect(SearchOrchestrator.attachmentFragmentLimit(forBudget: 100) == 1)
    }
}
