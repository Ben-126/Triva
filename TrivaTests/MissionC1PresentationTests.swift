//
//  MissionC1PresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Règles pures de la mission C1 (barre de saisie, en-tête moteur, sources, mode Fiable), testées
/// sans interface ni pipeline.
@MainActor
@Suite("Mission C1 — barre de saisie, en-tête, sources")
struct MissionC1PresentationTests {

    // MARK: - Fixtures

    private static func result(_ title: String, _ url: String, content: String? = "Extrait") -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: content,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    private static let webSources = [
        result("A", "https://www.lemonde.fr/a"),
        result("B", "https://docs.searxng.org/b"),
    ]

    private static let attachment = result("rapport.pdf", UploadsSearchResultBuilder.sourceURL(for: UUID()))

    private static let calculation = SearchWidgetOutput(kind: .calculation, llmContext: "1284 × 37 = 47508")

    private static func artifacts(
        mode: ResponseMode = .reliable,
        sources: [SearXNGSearchResult] = webSources,
        attachmentCount: Int = 0,
        widgets: [SearchWidgetOutput] = [],
        citableCount: Int? = nil,
        searched: Bool = true,
        webSourceKind: WebSearchSourceKind? = nil,
        report: WebSearchChainReport = WebSearchChainReport()
    ) -> SearchArtifacts {
        SearchArtifacts(
            sources: sources, attachmentSourceCount: attachmentCount, widgets: widgets,
            images: .notRequested, videos: .notRequested, mode: mode, promptComplexity: .full,
            citableSourceCount: citableCount ?? sources.count, searchPerformed: searched, searchQuery: "q",
            webSourceKind: webSourceKind, webSearchReport: report
        )
    }

    // MARK: - Barre de saisie

    @Test("Le champ passe seul sur sa ligne aux seules tailles d'accessibilité")
    func fieldStacksOnlyAtAccessibilitySizes() {
        #expect(ChatComposerPresentation.stacksField(isAccessibilitySize: true))
        #expect(!ChatComposerPresentation.stacksField(isAccessibilitySize: false))
        // iPhone en paysage : la hauteur manque, pas la largeur, le champ reste sur la rangée.
        #expect(!ChatComposerPresentation.stacksField(isAccessibilitySize: true, isVerticallyCompact: true))
    }

    @Test("Retour tapé dans le champ multiligne : envoie le texte, sans le saut de ligne")
    func returnKeySubmitsInMultilineField() {
        #expect(ChatComposerPresentation.submittedText(old: "Bonjour", new: "Bonjour\n") == "Bonjour")
    }

    @Test("Ni frappe ordinaire, ni collage de plusieurs lignes, ni saut de ligne au milieu n'envoient")
    func otherEditsDoNotSubmit() {
        #expect(ChatComposerPresentation.submittedText(old: "Bonjou", new: "Bonjour") == nil)
        #expect(ChatComposerPresentation.submittedText(old: "a", new: "a\nb\n") == nil)
        #expect(ChatComposerPresentation.submittedText(old: "ab", new: "a\nb") == nil)
        #expect(ChatComposerPresentation.submittedText(old: "a\n", new: "a") == nil)
    }

    // MARK: - En-tête moteur

    @Test("Hauteur pas encore mesurée, ou moteur à configurer : l'en-tête reste déplié")
    func headerStaysExpandedWithoutMeasureOrWhenSetupIsNeeded() {
        #expect(!EngineHeaderLayout.isCollapsed(availableHeight: 0, hasMessages: true, needsSetup: false, isAccessibilitySize: true))
        #expect(!EngineHeaderLayout.isCollapsed(availableHeight: 200, hasMessages: true, needsSetup: true, isAccessibilitySize: true))
    }

    @Test("Hauteurs transitoires de la première mise en page (24 pt, 12 pt) : jamais prises pour une mesure")
    func headerIgnoresTransientFirstLayoutHeights() {
        for height in [CGFloat(1), 12, 24, EngineHeaderLayout.minimumMeasuredHeight - 1] {
            #expect(!EngineHeaderLayout.isCollapsed(availableHeight: height, hasMessages: false, needsSetup: false, isAccessibilitySize: false))
            #expect(!EngineHeaderLayout.isCollapsed(availableHeight: height, hasMessages: true, needsSetup: false, isAccessibilitySize: true))
        }
        #expect(EngineHeaderLayout.isCollapsed(availableHeight: EngineHeaderLayout.minimumMeasuredHeight, hasMessages: false, needsSetup: false, isAccessibilitySize: false))
    }

    @Test("Conversation : repliée à AX, ou quand la hauteur manque (clavier ouvert, Duo plié)")
    func conversationCollapsesOnAccessibilityOrShortHeight() {
        #expect(EngineHeaderLayout.isCollapsed(availableHeight: 780, hasMessages: true, needsSetup: false, isAccessibilitySize: true))
        #expect(EngineHeaderLayout.isCollapsed(availableHeight: 400, hasMessages: true, needsSetup: false, isAccessibilitySize: false))
        #expect(!EngineHeaderLayout.isCollapsed(availableHeight: 700, hasMessages: true, needsSetup: false, isAccessibilitySize: false))
    }

    @Test("Écran vide : replié seulement quand il ne reste presque rien")
    func emptyScreenCollapsesOnlyWhenTiny() {
        #expect(!EngineHeaderLayout.isCollapsed(availableHeight: 400, hasMessages: false, needsSetup: false, isAccessibilitySize: false))
        // Texte AX : l'en-tête déplié chasserait la barre de saisie sous le clavier (mission AX3).
        #expect(EngineHeaderLayout.isCollapsed(availableHeight: 440, hasMessages: false, needsSetup: false, isAccessibilitySize: true))
        #expect(!EngineHeaderLayout.isCollapsed(availableHeight: 700, hasMessages: false, needsSetup: false, isAccessibilitySize: true))
        #expect(EngineHeaderLayout.isCollapsed(availableHeight: 300, hasMessages: false, needsSetup: false, isAccessibilitySize: false))
    }

    // MARK: - Sources

    @Test("Domaine affiché sans www, jamais l'URL brute")
    func sourceShowsBareDomain() {
        #expect(SourcesListPresentation.displayDomain(for: Self.result("t", "https://www.lemonde.fr/culture/d%C3%A9sormais")) == "lemonde.fr")
        #expect(SourcesListPresentation.displayDomain(for: Self.result("t", "pas une url")) == nil)
    }

    @Test("Libellé VoiceOver : numéro, titre, domaine, et « non lue » le cas échéant")
    func webAccessibilityLabelCarriesNumberAndUnread() {
        #expect(SourcesListPresentation.webAccessibilityLabel(number: 2, title: "T", domain: "d.fr", isUnread: false) == "Source 2, T, d.fr")
        #expect(SourcesListPresentation.webAccessibilityLabel(number: 3, title: "T", domain: "d.fr", isUnread: true) == "Source 3, T, d.fr, non lue")
    }

    @Test("Une citation vers une source non lue reste du texte, le texte d'origine est intact")
    func unreadCitationStaysText() {
        let text = "A[1] et B[2]."
        let parsed = CitationParser.parse(text, sourceCount: 2, unread: [2])
        #expect(parsed.citationIndices == [1])
        #expect(parsed.reconstructedText == text)
        #expect(CitationParser.parse(text, sourceCount: 2, unread: []).citationIndices == [1, 2])
    }

    // MARK: - Réponse

    @Test("Widget : sources web retirées, fichiers joints gardés en tête")
    func widgetAnswerHidesWebSources() {
        let mixed = [Self.attachment] + Self.webSources
        #expect(ChatViewModel.displayedSources(of: Self.artifacts(sources: mixed, attachmentCount: 1, widgets: [Self.calculation])) == [Self.attachment])
        #expect(ChatViewModel.displayedSources(of: Self.artifacts(sources: mixed, attachmentCount: 1)) == mixed)
    }

    @Test("Météo accompagnée d'une recherche web : sources et suggestions gardées (parcours UI 10)")
    func weatherWithWebSearchKeepsSources() {
        let weather = SearchWidgetOutput(kind: .weather, llmContext: "Paris : 12 °C")
        let withSearch = Self.artifacts(widgets: [weather], webSourceKind: .wikipedia)
        #expect(!ChatViewModel.widgetAnswered(withSearch))
        #expect(ChatViewModel.displayedSources(of: withSearch) == Self.webSources)
        #expect(ChatViewModel.offersSuggestions(question: "Cherche la hauteur de la tour Eiffel", artifacts: withSearch))
        let alone = Self.artifacts(sources: [], widgets: [weather], citableCount: 0, searched: false)
        #expect(ChatViewModel.widgetAnswered(alone))
    }

    @Test("« À creuser » : jamais sous une salutation ni sous un widget")
    func suggestionsSkippedForGreetingsAndWidgets() {
        #expect(ChatViewModel.offersSuggestions(question: "Quelle est la hauteur de la tour Eiffel ?", artifacts: Self.artifacts()))
        #expect(!ChatViewModel.offersSuggestions(question: "Bonjour !", artifacts: Self.artifacts()))
        #expect(!ChatViewModel.offersSuggestions(question: "Combien font 1284 × 37 ?", artifacts: Self.artifacts(widgets: [Self.calculation])))
    }

    @Test("SearXNG injoignable : seulement un échec de SearXNG lui-même")
    func searXNGUnreachableOnlyOnItsOwnFailure() {
        let failed = WebSearchChainReport(passedOver: [WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable))])
        let emptyAnswer = WebSearchChainReport(passedOver: [WebSearchSourceFailure(source: .searxng, reason: .noUsableAnswer)])
        let otherFailed = WebSearchChainReport(passedOver: [WebSearchSourceFailure(source: .braveSearch, reason: .searchFailed(.unavailable))])
        #expect(ChatViewModel.searXNGUnreachable(failed))
        #expect(!ChatViewModel.searXNGUnreachable(emptyAnswer))
        #expect(!ChatViewModel.searXNGUnreachable(otherFailed))
        #expect(!ChatViewModel.searXNGUnreachable(WebSearchChainReport()))
    }

    @Test("Boutons images et vidéos masqués quand SearXNG n'a pas répondu, sauf recherche déjà lancée")
    func mediaButtonsHiddenWithoutSearXNG() {
        var answer = MessageBubblePresentation.AnswerSnapshot(state: .completed, hasBody: true, sourceCount: 2, webSourceCount: 2)
        #expect(MessageBubblePresentation.showsMediaSearch(answer))
        answer.searXNGUnreachable = true
        #expect(!MessageBubblePresentation.showsMediaSearch(answer))
        answer.isMediaSearchStarted = true
        #expect(MessageBubblePresentation.showsMediaSearch(answer))
    }

    @Test("Le message garde les sources non lues et l'état de SearXNG ; l'état « aucune source fiable » les vide")
    func messageCarriesUnreadAndSearXNGState() {
        var message = ChatViewModel.Message(role: .assistant, isStreaming: true)
        var artifacts = Self.artifacts(
            report: WebSearchChainReport(passedOver: [WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable))])
        )
        artifacts.uncitableSourceNumbers = [2]
        message.attach(artifacts)
        #expect(message.uncitableSourceNumbers == [2])
        #expect(message.searXNGUnreachable)
        message.markNoReliableSources(searchQuery: "q", at: .now)
        #expect(message.uncitableSourceNumbers.isEmpty)
        #expect(!message.searXNGUnreachable)
    }

    @Test("Ligne d'état de la génération : réflexion, recherche, puis rédaction")
    func generationStageTexts() {
        #expect(ChatViewModel.Message(role: .assistant, isStreaming: true).generationStage == .analyzing)
        #expect(GenerationStage.analyzing.statusText == "Réflexion…")
        #expect(GenerationStage.searching.statusText == "Recherche des sources…")
        #expect(GenerationStage.writing.statusText == "Rédaction…")
    }

    // MARK: - Mode Fiable

    @Test("Fichiers joints seuls : ni état « aucune source fiable », ni contrôle de citation")
    func attachmentsOnlyRouteIsNotControlled() {
        let attachmentsOnly = Self.artifacts(sources: [Self.attachment], attachmentCount: 1, citableCount: 0)
        #expect(!attachmentsOnly.controlsReliableSearch)
        #expect(!attachmentsOnly.lacksReliableSources)
        #expect(!attachmentsOnly.requiresCitedAnswer)
        #expect(!attachmentsOnly.rejectsReliableAnswer("Le rapport parle de chiffres."))
    }

    @Test("Fichiers joints et recherche web : le contrôle s'applique, le fichier compte comme source")
    func attachmentsWithWebSearchAreControlled() {
        let mixed = Self.artifacts(sources: [Self.attachment], attachmentCount: 1, webSourceKind: .searxng)
        #expect(mixed.controlsReliableSearch)
        #expect(!mixed.lacksReliableSources)
        #expect(mixed.requiresCitedAnswer)
        #expect(!mixed.rejectsReliableAnswer("Le rapport le dit[1]."))
    }

    @Test("Sans recherche (salutation, écriture), rien n'est contrôlé")
    func noSearchIsNotControlled() {
        let none = Self.artifacts(sources: [], citableCount: 0, searched: false)
        #expect(!none.controlsReliableSearch)
        #expect(!none.lacksReliableSources)
        #expect(!none.rejectsReliableAnswer("Bonjour !"))
    }

    // MARK: - Validateur

    @Test("Citation vers un numéro sauté (source non lue) : signalée comme inventée")
    func validatorFlagsSkippedNumber() {
        let validator = ResponseStructureValidator()
        let text = "La tour mesure 330 m[2]."
        let withHole = validator.validate(text, mode: .quick, citableSourceCount: 3, uncitableNumbers: [2])
        #expect(withHole.contains(.citationOutOfRange))
        let withoutHole = validator.validate(text, mode: .quick, citableSourceCount: 3)
        #expect(!withoutHole.contains(.citationOutOfRange))
    }
}
