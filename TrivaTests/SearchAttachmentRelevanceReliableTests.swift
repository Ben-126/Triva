//
//  SearchAttachmentRelevanceReliableTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Mission C1, R1-1 (option (a), arbitrage provisoire à confirmer par Ben) : en Fiable, un fichier
/// joint ne compte comme source que si ses extraits parlent de la question. `AttachmentSearchIndex`
/// rend toujours ses N meilleurs fragments, sans seuil : avant ce correctif, un PDF sans rapport
/// rendait `attachmentSourceCount > 0` et désactivait le refus du hors-sujet ET « aucune source fiable ».
@MainActor
@Suite("Fichiers joints en mode Fiable — pertinence (mission C1, R1-1)")
struct SearchAttachmentRelevanceReliableTests {
    private static let question = "Quelle est la hauteur de la tour Eiffel ?"

    private static func document(title: String, content: String) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: UploadsSearchResultBuilder.sourceURL(for: UUID()), content: content,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    private func answer(mode: ResponseMode, chunk: String) async throws -> SearchOrchestratorResult {
        let attachment = uploadsMakeAttachment("document.txt", chunks: [chunk])
        let index = AttachmentSearchIndex(attachments: [attachment], scorer: UploadsTableScorer([:]))
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: PipelineMockSearXNGClient(), instances: [SearchOrchestratorTests.instance]),
            aiProvider: PipelineMockAIGenerating(),
            responseMode: mode
        )
        return try await orchestrator.answer(query: Self.question, attachments: index)
    }

    // MARK: Fonction pure

    @Test("Fiable : seul le fichier qui reprend des mots de la question est gardé")
    func reliableKeepsOnlyRelevantDocuments() async {
        let relevant = Self.document(title: "tour.txt", content: "La tour Eiffel mesure 330 mètres de hauteur.")
        let unrelated = Self.document(title: "impots.pdf", content: "Déclaration de revenus et barème de l'impôt.")

        let kept = await SearchOrchestrator.documentsCountingAsSources([unrelated, relevant], query: Self.question, mode: .reliable)

        #expect(kept == [relevant])
    }

    @Test("Rapide et Approfondie : tous les fichiers sont gardés, comme avant", arguments: [ResponseMode.quick, .deep])
    func otherModesKeepEveryDocument(mode: ResponseMode) async {
        let unrelated = Self.document(title: "impots.pdf", content: "Déclaration de revenus et barème de l'impôt.")

        #expect(await SearchOrchestrator.documentsCountingAsSources([unrelated], query: Self.question, mode: mode) == [unrelated])
    }

    @Test("Question sans mot plein (« Et toi ? ») : rien à juger, les fichiers sont gardés")
    func questionWithoutFullWordsKeepsDocuments() async {
        let document = Self.document(title: "a.txt", content: "texte")

        #expect(await SearchOrchestrator.documentsCountingAsSources([document], query: "Et toi ?", mode: .reliable) == [document])
    }

    // MARK: Pipeline

    @Test("Fiable : un PDF sans rapport ne compte pas, la réponse est refusée « aucune source fiable » (échoue sans le correctif)")
    func unrelatedAttachmentDoesNotDisableTheReliableChecks() async throws {
        let result = try await answer(mode: .reliable, chunk: "Déclaration de revenus et barème de l'impôt 2026.")

        #expect(result.artifacts.attachmentSourceCount == 0)
        #expect(result.artifacts.lacksReliableSources)
        #expect(result.answer.isEmpty)
    }

    @Test("Fiable : un fichier qui parle de la question reste une source fiable")
    func relevantAttachmentStaysAReliableSource() async throws {
        let result = try await answer(mode: .reliable, chunk: "La tour Eiffel mesure 330 mètres de hauteur.")

        #expect(result.artifacts.attachmentSourceCount == 1)
        #expect(!result.artifacts.lacksReliableSources)
    }

    @Test("Rapide : le même PDF sans rapport reste dans les sources (comportement inchangé)")
    func quickModeKeepsTheUnrelatedAttachment() async throws {
        let result = try await answer(mode: .quick, chunk: "Déclaration de revenus et barème de l'impôt 2026.")

        #expect(result.artifacts.attachmentSourceCount == 1)
    }
}
