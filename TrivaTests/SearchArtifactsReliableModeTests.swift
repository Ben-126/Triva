//
//  SearchArtifactsReliableModeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 10/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Critères du mode Fiable partagés par l'orchestrateur et le ViewModel
/// (mission A1) : avant la génération (rien de citable), et à la fin du flux
/// (refus exact, ou aucune page lue citée).
@MainActor
@Suite("SearchArtifacts — garde-fous du mode Fiable (mission A1)")
struct SearchArtifactsReliableModeTests {
    private static let sources = ["a", "b", "c"].map { name in
        SearXNGSearchResult(
            title: "Titre \(name)", url: "https://\(name).example", content: "Extrait \(name)",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    private static func artifacts(
        mode: ResponseMode = .reliable,
        searched: Bool = true,
        sources: [SearXNGSearchResult] = Self.sources,
        citableCount: Int? = nil,
        uncitable: Set<Int> = [],
        widgets: [SearchWidgetOutput] = []
    ) -> SearchArtifacts {
        SearchArtifacts(
            sources: sources, attachmentSourceCount: 0, widgets: widgets,
            images: .notRequested, videos: .notRequested, mode: mode, promptComplexity: .full,
            citableSourceCount: citableCount ?? sources.count, searchPerformed: searched, searchQuery: "q",
            uncitableSourceNumbers: uncitable
        )
    }

    private static let widget = SearchWidgetOutput(kind: .calculation, llmContext: "1284 × 37 = 47508")

    // MARK: - Avant la génération

    @Test("Rien de citable : vrai en Fiable même avec des sources affichées (toutes illisibles), jamais sinon")
    func lacksReliableSourcesReadsCitableDocuments() {
        #expect(Self.artifacts(sources: [], citableCount: 0).lacksReliableSources)
        #expect(Self.artifacts(citableCount: 0, uncitable: [1, 2, 3]).lacksReliableSources)
        #expect(!Self.artifacts().lacksReliableSources)
        #expect(!Self.artifacts(mode: .quick, citableCount: 0).lacksReliableSources)
        #expect(!Self.artifacts(mode: .deep, citableCount: 0).lacksReliableSources)
        #expect(!Self.artifacts(searched: false, sources: [], citableCount: 0).lacksReliableSources)
        #expect(!Self.artifacts(citableCount: 0, widgets: [Self.widget]).lacksReliableSources)
        // Le ViewModel lit le même critère, défini une seule fois.
        #expect(ChatViewModel.lacksReliableSources(Self.artifacts(citableCount: 0)))
    }

    // MARK: - Fin de flux

    @Test("Contrôle de fin de flux : seulement en Fiable, après recherche, sans widget")
    func citedAnswerIsRequiredOnlyInReliableSearchWithoutWidget() {
        #expect(Self.artifacts().requiresCitedAnswer)
        #expect(!Self.artifacts(mode: .quick).requiresCitedAnswer)
        #expect(!Self.artifacts(mode: .deep).requiresCitedAnswer)
        #expect(!Self.artifacts(searched: false).requiresCitedAnswer)
        #expect(!Self.artifacts(widgets: [Self.widget]).requiresCitedAnswer)
    }

    @Test("Citation d'une page lue : numéro affiché et lu ; ni hors bornes, ni page omise, ni dans <think>")
    func citesReadSourceCountsOnlyVisibleCitationsOfReadPages() {
        let artifacts = Self.artifacts(uncitable: [2])

        #expect(artifacts.citesReadSource(in: "TypeScript ajoute des types[1]."))
        #expect(artifacts.citesReadSource(in: "<tldr>Oui[3].</tldr>"))
        #expect(!artifacts.citesReadSource(in: "Page jamais lue[2]."))
        #expect(!artifacts.citesReadSource(in: "Source inventée[4]."))
        #expect(!artifacts.citesReadSource(in: "Aucune citation."))
        #expect(!artifacts.citesReadSource(in: "<think>Voir [1].</think>Réponse sans citation."))
        // Instantané en cours : un marqueur pas encore refermé n'est pas une citation.
        #expect(!artifacts.citesReadSource(in: "TypeScript ajoute des types[1", isStreaming: true))
    }

    @Test("Rejet Fiable : refus exact (même cité, entre guillemets) ou aucune page lue citée")
    func rejectsReliableAnswerOnRefusalOrMissingCitation() {
        let refusal = PromptTemplates.noRelevantInformationAnswer
        let artifacts = Self.artifacts(uncitable: [2])

        #expect(artifacts.rejectsReliableAnswer(refusal))
        #expect(artifacts.rejectsReliableAnswer("« \(refusal) »"))
        #expect(artifacts.rejectsReliableAnswer("\(refusal)[1]"))
        #expect(artifacts.rejectsReliableAnswer("TypeScript ajoute des types."))
        #expect(artifacts.rejectsReliableAnswer("Affirmation tirée d'une page jamais lue[2]."))
        #expect(!artifacts.rejectsReliableAnswer("TypeScript ajoute des types[1]. Les sources disponibles ne donnent pas d'information précise sur la vitesse."))
    }

    @Test("Hors du contrôle (autre mode, widget, sans recherche) : rien n'est jamais rejeté")
    func nothingIsRejectedOutsideTheReliableCheck() {
        let uncited = "Le résultat est 47 508."

        #expect(!Self.artifacts(mode: .quick).rejectsReliableAnswer(uncited))
        #expect(!Self.artifacts(mode: .deep).rejectsReliableAnswer(PromptTemplates.noRelevantInformationAnswer))
        #expect(!Self.artifacts(widgets: [Self.widget]).rejectsReliableAnswer(uncited))
        #expect(!Self.artifacts(searched: false).rejectsReliableAnswer("Bonjour !"))
    }
}
