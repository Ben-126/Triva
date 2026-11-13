//
//  SearchArtifactsOffTopicReliableTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Mission E2a, trou 4 (décision de Ben, 2026-11-12) : « En Fiable, refuser le hors-sujet. »
/// Quand AUCUNE source fiable ne passe le test lexical (`LexicalRelevance`, porté par
/// `webSearchReport.matchesQuestion`), l'issue est `.noReliableSources`, même si le modèle cite
/// une source fiable.
@MainActor
@Suite("SearchArtifacts — hors-sujet refusé en mode Fiable (mission E2a)")
struct SearchArtifactsOffTopicReliableTests {
    private static let sources = ["a", "b"].map { name in
        SearXNGSearchResult(
            title: "Titre \(name)", url: "https://fr.wikipedia.org/wiki/\(name)", content: "Extrait \(name)",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    private static func artifacts(
        mode: ResponseMode = .reliable,
        matchesQuestion: Bool,
        attachmentSourceCount: Int = 0,
        webSourceKind: WebSearchSourceKind? = .searxng,
        widgets: [SearchWidgetOutput] = []
    ) -> SearchArtifacts {
        SearchArtifacts(
            sources: sources, attachmentSourceCount: attachmentSourceCount, widgets: widgets,
            images: .notRequested, videos: .notRequested, mode: mode, promptComplexity: .full,
            citableSourceCount: sources.count, searchPerformed: true, searchQuery: "q",
            webSourceKind: webSourceKind,
            webSearchReport: WebSearchChainReport(passedOver: [], matchesQuestion: matchesQuestion)
        )
    }

    private static let citedAnswer = "La tour Eiffel mesure 330 mètres[1]."

    @Test("Source fiable hors sujet : rien n'est généré (lacksReliableSources) et la réponse citée est rejetée")
    func offTopicReliableSourceIsRefused() {
        let offTopic = Self.artifacts(matchesQuestion: false)

        #expect(offTopic.hasOnlyOffTopicWebSources)
        #expect(offTopic.lacksReliableSources)
        #expect(offTopic.rejectsReliableAnswer(Self.citedAnswer))
        #expect(ChatViewModel.lacksReliableSources(offTopic))
    }

    @Test("Source fiable pertinente : acceptée, la réponse citée n'est pas rejetée")
    func relevantReliableSourceIsAccepted() {
        let relevant = Self.artifacts(matchesQuestion: true)

        #expect(!relevant.hasOnlyOffTopicWebSources)
        #expect(!relevant.lacksReliableSources)
        #expect(!relevant.rejectsReliableAnswer(Self.citedAnswer))
    }

    @Test("Hors Fiable, le hors-sujet n'est jamais refusé (Rapide et Approfondie gardent l'avertissement du rédacteur)")
    func offTopicIsOnlyRefusedInReliableMode() {
        for mode in [ResponseMode.quick, .deep] {
            let offTopic = Self.artifacts(mode: mode, matchesQuestion: false)
            #expect(!offTopic.lacksReliableSources)
            #expect(!offTopic.rejectsReliableAnswer(Self.citedAnswer))
        }
    }

    @Test("Un widget abouti suspend le refus : sa donnée est une source")
    func widgetSuspendsTheOffTopicRefusal() {
        let widget = SearchWidgetOutput(kind: .calculation, llmContext: "1284 × 37 = 47508")
        let offTopic = Self.artifacts(matchesQuestion: false, widgets: [widget])

        #expect(!offTopic.lacksReliableSources)
        #expect(!offTopic.rejectsReliableAnswer("Le résultat est 47 508."))
    }

    @Test("Fichiers joints parmi les sources : jamais hors sujet, ils sont les documents de l'utilisateur")
    func attachmentsAreNeverOffTopic() {
        let withDocuments = Self.artifacts(matchesQuestion: false, attachmentSourceCount: 1)

        #expect(!withDocuments.hasOnlyOffTopicWebSources)
        #expect(!withDocuments.lacksReliableSources)
    }

    @Test("Sans constat de la chaîne (rapport par défaut), rien n'est jugé hors sujet")
    func defaultReportJudgesNothing() {
        let defaultReport = SearchArtifacts(
            sources: Self.sources, attachmentSourceCount: 0, widgets: [],
            images: .notRequested, videos: .notRequested, mode: .reliable, promptComplexity: .full,
            citableSourceCount: Self.sources.count, searchPerformed: true, searchQuery: "q"
        )

        #expect(!defaultReport.hasOnlyOffTopicWebSources)
        #expect(!defaultReport.lacksReliableSources)
    }

    // MARK: - Limite assumée : le test compare des mots, pas le sens

    private static func verdict(question: String, title: String, content: String, url: String) -> LexicalRelevance.Verdict {
        LexicalRelevance(query: question).assess([
            SearXNGSearchResult(
                title: title, url: url, content: content,
                imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
            ),
        ])
    }

    @Test("Question française, source anglaise : retenue si assez de mots communs (nom propre, chiffre, terme commun)")
    func frenchQuestionEnglishSourceIsKeptWhenWordsAreShared() {
        let verdict = Self.verdict(
            question: "Quand est sortie la version 3.14 de Python ?",
            title: "What's new in Python 3.14",
            content: "Python 3.14 is the latest version, released in October 2025.",
            url: "https://docs.python.org/3.14/whatsnew/3.14.html"
        )

        #expect(verdict == .relevant)
    }

    @Test("LIMITE CONNUE : un seul nom propre en commun ne suffit pas, la source anglaise sur le même sujet est refusée à tort")
    func frenchQuestionEnglishSourceWithOnlyAProperNounIsRefused() {
        let verdict = Self.verdict(
            question: "Quelle est la hauteur de la tour Eiffel ?",
            title: "Eiffel Tower",
            content: "The Eiffel Tower is 330 metres tall, about the same height as an 81-storey building.",
            url: "https://en.wikipedia.org/wiki/Eiffel_Tower"
        )

        // « hauteur » et « tour » n'ont pas d'équivalent lexical (« height », « tower ») : seul
        // « eiffel » correspond, 1 mot pour 2 exigés. À corriger seulement sur arbitrage de Ben.
        #expect(verdict == .offTopic(bestMatchCount: 1))
    }

    @Test("Source fiable sur un autre sujet : hors sujet, y compris quand elle partage un mot isolé")
    func trulyOffTopicSourceIsOffTopic() {
        let verdict = Self.verdict(
            question: "Quelle est la hauteur de la tour Eiffel ?",
            title: "Équipe de France de football",
            content: "Histoire de la sélection nationale française depuis 1904.",
            url: "https://fr.wikipedia.org/wiki/%C3%89quipe_de_France_de_football"
        )

        if case .offTopic = verdict { return }
        Issue.record("Une source sans rapport devait être jugée hors sujet : \(verdict)")
    }
}

// MARK: - Câblage : chaîne réelle -> orchestrateur -> artefacts

extension SearchOrchestratorTests {
    private func reliableOrchestrator(
        provider: ScriptedWebSearchProvider,
        ai: PipelineMockAIGenerating
    ) -> SearchOrchestrator {
        let chain = WebSearchChain(keyedProviders: [provider], searxng: nil, openSourceProviders: { _ in [] })
        return SearchOrchestrator(
            failoverManager: FailoverManager(client: PipelineMockSearXNGClient(), instances: [Self.instance]),
            aiProvider: ai,
            responseMode: .reliable,
            scrapeService: PipelineMockScrapeService(succeeded: true),
            sourceRanker: pipelineOrderPreservingRanker(),
            widgets: [],
            webSearchChain: chain
        )
    }

    private func streamedText(_ streaming: StreamingAnswer) async throws -> String {
        var text = ""
        for try await chunk in streaming.textStream { text += chunk }
        return text
    }

    @Test("E2a : source fiable hors sujet -> aucune génération et lacksReliableSources ; fiable pertinente -> génération")
    func reliableOffTopicSourceStopsGenerationEndToEnd() async throws {
        let question = "Quelle est la hauteur de la tour Eiffel ?"
        let offTopic = ScriptedWebSearchProvider(kind: .braveSearch, outcome: .results([
            ChainFixtures.result(
                "Équipe de France de football", url: "https://fr.wikipedia.org/wiki/Equipe_de_France",
                content: "Histoire de la sélection nationale depuis 1904."
            ),
        ]))
        let relevant = ScriptedWebSearchProvider(kind: .braveSearch, outcome: .results([
            ChainFixtures.result(
                "Tour Eiffel", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel",
                content: "La tour Eiffel mesure 330 mètres de hauteur."
            ),
        ]))
        let classification = Self.classificationJSON(standaloneFollowUp: question)

        let refusedAI = PipelineMockAIGenerating(classifyResponse: classification, finalAnswerResponse: "RÉPONSE[1]")
        let refused = try await reliableOrchestrator(provider: offTopic, ai: refusedAI).streamAnswer(query: question)
        let acceptedAI = PipelineMockAIGenerating(classifyResponse: classification, finalAnswerResponse: "RÉPONSE[1]")
        let accepted = try await reliableOrchestrator(provider: relevant, ai: acceptedAI).streamAnswer(query: question)

        #expect(!refused.artifacts.webSearchReport.matchesQuestion)
        #expect(refused.artifacts.lacksReliableSources)
        #expect(try await streamedText(refused).isEmpty)
        #expect(accepted.artifacts.webSearchReport.matchesQuestion)
        #expect(!accepted.artifacts.lacksReliableSources)
        #expect(try await streamedText(accepted) == "RÉPONSE[1]")
    }
}
