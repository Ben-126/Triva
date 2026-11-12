//
//  UploadsSearchActionTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
@testable import Triva

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
            uploadsMakeMatch(notes, fileName: "notes.txt", chunkIndex: 4, text: "N4"),
            uploadsMakeMatch(report, fileName: "rapport.txt", chunkIndex: 0, text: "R0"),
            uploadsMakeMatch(notes, fileName: "notes.txt", chunkIndex: 1, text: "N1"),
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
            uploadsMakeMatch(original, fileName: "a.txt", chunkIndex: 0, text: "Même paragraphe."),
            uploadsMakeMatch(copy, fileName: "a copie.txt", chunkIndex: 0, text: "Même paragraphe."),
            uploadsMakeMatch(original, fileName: "a.txt", chunkIndex: 0, text: "Même paragraphe."),
            uploadsMakeMatch(original, fileName: "a.txt", chunkIndex: 1, text: "Autre paragraphe."),
        ]

        let kept = UploadsSearchResultBuilder.deduplicated(matches)

        #expect(kept.map(\.chunkIndex) == [0, 1])
        #expect(kept.allSatisfy { $0.attachmentID == original })
    }

    @Test("Un fragment blanc est écarté")
    func dropsBlankFragments() {
        let id = UUID()

        let built = UploadsSearchResultBuilder.makeResults(from: [uploadsMakeMatch(id, chunkIndex: 0, text: "  \n ")])

        #expect(built.isEmpty)
    }

    @Test("Repère de page pour un PDF, rien hors PDF")
    func formatsPageMarkers() {
        let id = UUID()

        #expect(UploadsSearchResultBuilder.formattedFragment(uploadsMakeMatch(id, chunkIndex: 0, text: "texte", pageRange: 3...3)) == "(p. 3) texte")
        #expect(UploadsSearchResultBuilder.formattedFragment(uploadsMakeMatch(id, chunkIndex: 0, text: "texte", pageRange: 3...4)) == "(p. 3–4) texte")
        #expect(UploadsSearchResultBuilder.formattedFragment(uploadsMakeMatch(id, chunkIndex: 0, text: " texte ")) == "texte")
    }

    @Test("Au plus maxFragments fragments, les mieux classés")
    func capsFragmentCount() {
        let id = UUID()
        let matches = (0..<5).map { uploadsMakeMatch(id, chunkIndex: $0, text: "F\($0)") }

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

        let built = UploadsSearchResultBuilder.makeResults(from: [uploadsMakeMatch(id, chunkIndex: 0, text: long)], maxTotalCharacters: 20)

        let only = try #require(built.first)
        #expect(built.count == 1)
        #expect(only.content == String(repeating: "x", count: 20))
    }

    @Test("Budget partagé à parts égales entre deux fichiers longs")
    func splitsBudgetEvenly() {
        let first = UUID()
        let second = UUID()
        let matches = [
            uploadsMakeMatch(first, fileName: "a.txt", chunkIndex: 0, text: String(repeating: "a", count: 100)),
            uploadsMakeMatch(second, fileName: "b.txt", chunkIndex: 0, text: String(repeating: "b", count: 100)),
        ]

        let built = UploadsSearchResultBuilder.makeResults(from: matches, maxTotalCharacters: 60)

        #expect(built.map { $0.content?.count } == [30, 30])
    }

    @Test("Ce qu'un fichier court n'utilise pas revient aux autres")
    func redistributesUnusedShare() {
        let short = UUID()
        let long = UUID()
        let matches = [
            uploadsMakeMatch(long, fileName: "long.txt", chunkIndex: 0, text: String(repeating: "l", count: 100)),
            uploadsMakeMatch(short, fileName: "court.txt", chunkIndex: 0, text: "0123456789"),
        ]

        let built = UploadsSearchResultBuilder.makeResults(from: matches, maxTotalCharacters: 60)

        #expect(built.map { $0.content?.count } == [50, 10])
    }

    @Test("Le total, séparateurs et repères de page compris, ne dépasse jamais le budget", arguments: [1, 7, 50, 333, 6000])
    func neverExceedsBudget(budget: Int) {
        let ids = (0..<3).map { _ in UUID() }
        let matches = (0..<10).map { position in
            uploadsMakeMatch(
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
        let matches = [uploadsMakeMatch(id, chunkIndex: 0, text: "texte")]

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
    private func makeFailoverManager(_ client: UploadsCountingSearXNGClient) -> FailoverManager {
        FailoverManager(client: client, instances: [uploadsTestInstance])
    }

    @Test("Nom stable et description pour le planner")
    func identity() {
        let action = UploadsSearchAction(searchIndex: AttachmentSearchIndex(attachments: [], scorer: UploadsTableScorer([:])))

        #expect(action.name == "uploadsSearch")
        #expect(!action.descriptionForPlanner.isEmpty)
    }

    @Test("Aucune pièce jointe : résultat vide, jamais une erreur, scorer et réseau jamais sollicités")
    func noAttachmentsYieldsEmptyResults() async throws {
        let log = UploadsQueryLog()
        let client = UploadsCountingSearXNGClient()
        let action = UploadsSearchAction(searchIndex: AttachmentSearchIndex(attachments: [], scorer: UploadsTableScorer([:], log: log)))

        let output = try await action.execute(query: "impôts", urls: [], failoverManager: makeFailoverManager(client), scrapeService: UploadsUnusedScrapeService())

        #expect(uploadsResults(of: output) == [])
        #expect(await log.references.isEmpty)
        #expect(await client.callCount == 0)
    }

    @Test("Store vide : résultat vide")
    func emptyStoreYieldsEmptyResults() async throws {
        let store = AttachmentStore(scorer: UploadsTableScorer([:]), preparer: UploadsFixedPreparer(attachment: uploadsMakeAttachment("a.txt", chunks: ["x"])))
        let action = UploadsSearchAction(attachmentStore: store)

        let output = try await action.execute(query: "q", urls: [], failoverManager: makeFailoverManager(UploadsCountingSearXNGClient()), scrapeService: UploadsUnusedScrapeService())

        #expect(uploadsResults(of: output) == [])
    }

    @Test("Requête blanche : résultat vide, scorer jamais appelé")
    func blankQueryYieldsEmptyResults() async throws {
        let log = UploadsQueryLog()
        let index = AttachmentSearchIndex(attachments: [uploadsMakeAttachment("a.txt", chunks: ["texte"])], scorer: UploadsTableScorer([:], log: log))

        let output = try await UploadsSearchAction(searchIndex: index).execute(
            query: "   ",
            urls: [],
            failoverManager: makeFailoverManager(UploadsCountingSearXNGClient()),
            scrapeService: UploadsUnusedScrapeService()
        )

        #expect(uploadsResults(of: output) == [])
        #expect(await log.references.isEmpty)
    }

    @Test("Une requête : fragments du fichier classés, sans aucun appel réseau, URLs passées ignorées")
    func singleQuerySearchesAttachments() async throws {
        let attachment = uploadsMakeAttachment("rapport.pdf", chunks: ["alpha", "beta", "gamma"], pages: [1...1, 2...2, 3...4])
        let scorer = UploadsTableScorer(["q1": ["alpha": 0.2, "beta": 0.9, "gamma": 0.5]])
        let client = UploadsCountingSearXNGClient()

        let output = try await UploadsSearchAction(searchIndex: AttachmentSearchIndex(attachments: [attachment], scorer: scorer)).execute(
            query: "q1",
            urls: ["https://ignore.example"],
            failoverManager: makeFailoverManager(client),
            scrapeService: UploadsUnusedScrapeService()
        )

        let built = try #require(uploadsResults(of: output))
        #expect(built.count == 1)
        #expect(built.first?.title == "rapport.pdf")
        #expect(built.first?.url == UploadsSearchResultBuilder.sourceURL(for: attachment.id))
        #expect(built.first?.content == "(p. 2) beta\n\n(p. 3–4) gamma\n\n(p. 1) alpha")
        #expect(await client.callCount == 0)
    }

    @Test("Plusieurs requêtes : fusion par rangs réciproques, ordre différent d'une requête seule")
    func multipleQueriesAreFused() async throws {
        let attachment = uploadsMakeAttachment("notes.txt", chunks: ["a", "b", "c"])
        let scorer = UploadsTableScorer([
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
        let log = UploadsQueryLog()
        let index = AttachmentSearchIndex(attachments: [uploadsMakeAttachment("a.txt", chunks: ["texte"])], scorer: UploadsTableScorer([:], log: log))

        _ = try await UploadsSearchAction(searchIndex: index).search(queries: ["q1", "q1", "q2", "q3", "q4", "q5"])

        #expect(await log.references == ["q1", "q2", "q3"])
    }

    @Test("Budget appliqué de bout en bout : fragments plus longs que le budget tronqués")
    func budgetAppliesEndToEnd() async throws {
        let long = String(repeating: "m", count: 900)
        let attachment = uploadsMakeAttachment("long.txt", chunks: [long, long + "n"])
        let action = UploadsSearchAction(
            searchIndex: AttachmentSearchIndex(attachments: [attachment], scorer: UploadsTableScorer([:])),
            maxTotalCharacters: 100
        )

        let built = try await action.search(queries: ["q"])

        #expect(built.count == 1)
        #expect(built.first?.content?.count == 100)
    }

    @Test("Instantané pris à la construction : vider le store ensuite ne change pas la recherche en cours")
    func storeIsSnapshottedAtConstruction() async throws {
        let attachment = uploadsMakeAttachment("a.txt", chunks: ["contenu"])
        let store = AttachmentStore(scorer: UploadsTableScorer([:]), preparer: UploadsFixedPreparer(attachment: attachment))
        try await store.attach(fileAt: URL(fileURLWithPath: "/dev/null/a.txt"))

        let action = UploadsSearchAction(attachmentStore: store)
        store.removeAll()
        let built = try await action.search(queries: ["q"])

        #expect(built.map(\.content) == ["contenu"])
        #expect(try await UploadsSearchAction(attachmentStore: store).search(queries: ["q"]).isEmpty)
    }

    @Test("Paramètres négatifs ramenés à 0 : résultat vide, jamais de plantage")
    func negativeLimitsAreClamped() async throws {
        let index = AttachmentSearchIndex(attachments: [uploadsMakeAttachment("a.txt", chunks: ["texte"])], scorer: UploadsTableScorer([:]))

        #expect(try await UploadsSearchAction(searchIndex: index, maxFragments: -1).search(queries: ["q"]).isEmpty)
        #expect(try await UploadsSearchAction(searchIndex: index, maxTotalCharacters: -5).search(queries: ["q"]).isEmpty)
    }
}
