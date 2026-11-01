//
//  DiscoverViewTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/10/2026.
//

import Foundation
import Testing
@testable import Triva

// MARK: - Outils de test

private enum ScriptError: Error, Sendable, Equatable {
    case offline
    case unexpectedCall
}

/// Résultat SearXNG minimal : l'écran Découvrir ne lit que le titre, l'URL,
/// l'extrait et l'image.
private func searchResult(title: String, url: String) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: title,
        url: url,
        content: nil,
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

/// `@MainActor` : `DiscoverArticle` n'est pas annoté dans
/// `DiscoverService.swift`, donc isolé au main actor côté app, init compris.
@MainActor
private func article(_ topic: DiscoverTopic, title: String = "Titre", url: String) -> DiscoverArticle {
    DiscoverArticle(topic: topic, result: searchResult(title: title, url: url))
}

@MainActor
private func section(_ topic: DiscoverTopic, _ urls: [String]) -> DiscoverTopicSection {
    DiscoverTopicSection(topic: topic, articles: urls.map { article(topic, url: $0) })
}

/// Contenus types, tous composés d'articles affichables : `sanitized(_:)`
/// les laisse intacts, ce qui permet de les comparer tels quels à l'état.
@MainActor
private enum Fixtures {
    static let contentA = DiscoverContent(
        sections: [
            section(.tech, ["https://tech.example/a", "https://tech.example/b"]),
            section(.finance, ["https://finance.example/a"]),
        ],
        failedTopics: [.sports]
    )
    static let contentB = DiscoverContent(
        sections: [section(.art, ["https://art.example/a"])],
        failedTopics: []
    )
    /// Ce que renvoie `fetchTrending` hors ligne : jamais d'erreur levée,
    /// tous les sujets en échec.
    static let allFailed = DiscoverContent(sections: [], failedTopics: DiscoverTopic.allCases)
}

/// Source de contenu pilotée par le test, à la place de
/// `DiscoverService.fetchTrending()` : rend des résultats écrits d'avance,
/// compte les appels, et peut RETENIR un appel jusqu'à `release(with:)` pour
/// observer l'état PENDANT un chargement sans dépendre du temps écoulé.
///
/// Un appel imprévu (plus aucun résultat en réserve) lève
/// `ScriptError.unexpectedCall` au lieu de rester suspendu : un test qui
/// déclenche un chargement de trop échoue sur ses `#expect`, il ne bloque
/// jamais la suite.
@MainActor
private final class ScriptedDiscoverSource {
    private(set) var callCount = 0
    private var outcomes: [Result<DiscoverContent, any Error>]
    private var holdsNextCall: Bool
    private var heldCall: CheckedContinuation<DiscoverContent, any Error>?

    init(outcomes: [Result<DiscoverContent, any Error>], holdsFirstCall: Bool = false) {
        self.outcomes = outcomes
        self.holdsNextCall = holdsFirstCall
    }

    /// Un appel attend `release(with:)`.
    var isHoldingCall: Bool { heldCall != nil }

    func holdNextCall() {
        holdsNextCall = true
    }

    func fetch() async throws -> DiscoverContent {
        callCount += 1
        if holdsNextCall {
            holdsNextCall = false
            return try await withCheckedThrowingContinuation { continuation in
                heldCall = continuation
            }
        }
        guard !outcomes.isEmpty else { throw ScriptError.unexpectedCall }
        return try outcomes.removeFirst().get()
    }

    func release(with outcome: Result<DiscoverContent, any Error>) {
        guard let heldCall else {
            Issue.record("Aucun appel retenu à libérer")
            return
        }
        self.heldCall = nil
        heldCall.resume(with: outcome)
    }
}

/// Attente coopérative bornée, même principe que le helper de
/// `ChatViewModelTests` : `Task.sleep` et JAMAIS `Task.yield()`, qui ne
/// garantit pas la progression de l'autre tâche sous isolation main actor
/// (échecs intermittents).
@MainActor
private func waitUntil(_ timeoutMessage: String, maxAttempts: Int = 500, _ condition: () -> Bool) async {
    var attempts = 0
    while attempts < maxAttempts {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
        attempts += 1
    }
    Issue.record("Timeout en attendant : \(timeoutMessage)")
}

// MARK: - Règle de rafraîchissement

@MainActor
@Suite("DiscoverViewModel — règle de rafraîchissement")
struct DiscoverViewModelUpdateTests {
    @Test("un contenu exploitable remplace l'état")
    func usableContentReplacesState() {
        let update = DiscoverViewModel.update(after: .success(Fixtures.contentA), previous: .idle)
        #expect(update == DiscoverViewModel.Update(phase: .loaded(Fixtures.contentA), refreshDidFail: false))
    }

    @Test("un rafraîchissement en erreur garde l'ancien contenu et le signale")
    func failedRefreshKeepsPreviousContent() {
        let update = DiscoverViewModel.update(after: .failure(ScriptError.offline), previous: .loaded(Fixtures.contentA))
        #expect(update == DiscoverViewModel.Update(phase: .loaded(Fixtures.contentA), refreshDidFail: true))
    }

    /// `fetchTrending` ne lève jamais : hors ligne, il rend tous les sujets en
    /// échec. Pour l'écran, c'est exactement un rafraîchissement raté.
    @Test("un rafraîchissement où tous les sujets échouent vaut une erreur")
    func allTopicsFailedRefreshKeepsPreviousContent() {
        let update = DiscoverViewModel.update(after: .success(Fixtures.allFailed), previous: .loaded(Fixtures.contentA))
        #expect(update == DiscoverViewModel.Update(phase: .loaded(Fixtures.contentA), refreshDidFail: true))
    }

    @Test("sans contenu affiché, rien d'exploitable donne l'état d'erreur")
    func nothingUsableWithoutPreviousContentFails() {
        let failed = DiscoverViewModel.Update(phase: .failed, refreshDidFail: false)
        let previousPhases: [DiscoverViewModel.Phase] = [.idle, .loading, .failed]
        for previous in previousPhases {
            #expect(DiscoverViewModel.update(after: .failure(ScriptError.offline), previous: previous) == failed)
            #expect(DiscoverViewModel.update(after: .success(Fixtures.allFailed), previous: previous) == failed)
        }
    }

    /// Catalogue vide : aucun sujet demandé, donc aucun échec. C'est l'état
    /// « Aucun article », pas « Actualité indisponible ».
    @Test("un contenu sans sujet ni échec donne la liste vide, pas une erreur")
    func emptyContentIsAnEmptyListNotAFailure() {
        let update = DiscoverViewModel.update(after: .success(.empty), previous: .idle)
        #expect(update == DiscoverViewModel.Update(phase: .loaded(.empty), refreshDidFail: false))
    }

    @Test("des articles tous inaffichables comptent comme un échec")
    func undisplayableOnlyContentCountsAsFailure() {
        let unusable = DiscoverContent(sections: [section(.tech, ["tel:0102030405"])], failedTopics: [])
        #expect(
            DiscoverViewModel.update(after: .success(unusable), previous: .idle)
                == DiscoverViewModel.Update(phase: .failed, refreshDidFail: false)
        )
        #expect(
            DiscoverViewModel.update(after: .success(unusable), previous: .loaded(Fixtures.contentA))
                == DiscoverViewModel.Update(phase: .loaded(Fixtures.contentA), refreshDidFail: true)
        )
    }

    @Test("annonces VoiceOver des changements de phase")
    func announcements() {
        #expect(DiscoverViewModel.announcement(from: .loading, to: .loaded(Fixtures.contentA)) == "Actualité chargée")
        #expect(DiscoverViewModel.announcement(from: .loaded(Fixtures.contentA), to: .loaded(Fixtures.contentB)) == "Actualité mise à jour")
        #expect(DiscoverViewModel.announcement(from: .loading, to: .failed) == "Actualité indisponible")
        #expect(DiscoverViewModel.announcement(from: .idle, to: .loading) == nil)
        #expect(DiscoverViewModel.announcement(from: .failed, to: .loading) == nil)
    }
}

// MARK: - Filtrage des articles

@MainActor
@Suite("DiscoverViewModel — filtrage des articles")
struct DiscoverViewModelSanitizeTests {
    @Test("un sujet sans article affichable passe dans les sujets en échec")
    func topicWithoutDisplayableArticleBecomesFailed() {
        let content = DiscoverContent(
            sections: [
                DiscoverTopicSection(topic: .tech, articles: [
                    article(.tech, url: "https://tech.example/ok"),
                    article(.tech, url: "javascript:alert(1)"),
                    article(.tech, title: "   ", url: "https://tech.example/sans-titre"),
                ]),
                section(.art, ["facetime:someone@example.com"]),
            ],
            failedTopics: [.sports]
        )

        let sanitized = DiscoverViewModel.sanitized(content)

        #expect(sanitized.sections.map { $0.topic } == [.tech])
        #expect(sanitized.sections.first?.articles.map { $0.url } == ["https://tech.example/ok"])
        #expect(sanitized.failedTopics == [.sports, .art])
    }

    @Test("un contenu propre traverse le filtre intact")
    func cleanContentIsUnchanged() {
        #expect(DiscoverViewModel.sanitized(Fixtures.contentA) == Fixtures.contentA)
    }

    @Test("un article s'affiche s'il a une URL web avec hôte et un titre")
    func displayableRequiresWebURLAndTitle() {
        #expect(DiscoverViewModel.isDisplayable(article(.tech, url: "https://tech.example/a")))
        #expect(DiscoverViewModel.isDisplayable(article(.tech, url: "http://tech.example/a")))
        #expect(!DiscoverViewModel.isDisplayable(article(.tech, url: "tel:0102030405")))
        #expect(!DiscoverViewModel.isDisplayable(article(.tech, url: "https:chemin-sans-hote")))
        #expect(!DiscoverViewModel.isDisplayable(article(.tech, url: "")))
        #expect(!DiscoverViewModel.isDisplayable(article(.tech, title: " \n\t ", url: "https://tech.example/a")))
    }
}

// MARK: - Chargement et rafraîchissement (le plan : « tester le rafraîchissement »)

@MainActor
@Suite("DiscoverViewModel — chargement et rafraîchissement")
struct DiscoverViewModelLoadingTests {
    @Test("premier affichage : un seul chargement, même si l'écran réapparaît")
    func loadIfNeededLoadsOnce() async {
        let source = ScriptedDiscoverSource(outcomes: [.success(Fixtures.contentA)])
        let model = DiscoverViewModel(fetchContent: { try await source.fetch() })
        #expect(model.phase == .idle)

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        #expect(source.callCount == 1)
        #expect(model.phase == .loaded(Fixtures.contentA))
        #expect(!model.isLoading)
    }

    @Test("après un échec, revenir sur l'écran retente le chargement")
    func loadIfNeededRetriesAfterFailure() async {
        let source = ScriptedDiscoverSource(outcomes: [.failure(ScriptError.offline), .success(Fixtures.contentA)])
        let model = DiscoverViewModel(fetchContent: { try await source.fetch() })

        await model.loadIfNeeded()
        #expect(model.phase == .failed)
        #expect(!model.refreshDidFail)

        await model.loadIfNeeded()
        #expect(source.callCount == 2)
        #expect(model.phase == .loaded(Fixtures.contentA))
    }

    /// Couvre aussi la remise à zéro du chargement en cours : un appel arrivé
    /// APRÈS la fin d'un chargement doit relancer le réseau, pas réattendre
    /// l'ancien.
    @Test("rafraîchir relance les recherches et remplace le contenu")
    func refreshReplacesContent() async {
        let source = ScriptedDiscoverSource(outcomes: [.success(Fixtures.contentA), .success(Fixtures.contentB)])
        let model = DiscoverViewModel(fetchContent: { try await source.fetch() })

        await model.loadIfNeeded()
        await model.refresh()

        #expect(source.callCount == 2)
        #expect(model.phase == .loaded(Fixtures.contentB))
        #expect(!model.refreshDidFail)
        #expect(!model.isRefreshing)
    }

    @Test("rafraîchissement hors ligne : les articles restent, l'échec s'efface au succès suivant")
    func offlineRefreshKeepsArticles() async {
        let source = ScriptedDiscoverSource(outcomes: [
            .success(Fixtures.contentA),
            .success(Fixtures.allFailed),
            .success(Fixtures.contentB),
        ])
        let model = DiscoverViewModel(fetchContent: { try await source.fetch() })

        await model.loadIfNeeded()
        await model.refresh()
        #expect(model.phase == .loaded(Fixtures.contentA))
        #expect(model.refreshDidFail)

        await model.refresh()
        #expect(model.phase == .loaded(Fixtures.contentB))
        #expect(!model.refreshDidFail)
    }

    @Test("pendant un rafraîchissement, le contenu reste affiché")
    func contentStaysVisibleDuringRefresh() async {
        let source = ScriptedDiscoverSource(outcomes: [.success(Fixtures.contentA)])
        let model = DiscoverViewModel(fetchContent: { try await source.fetch() })
        await model.loadIfNeeded()
        source.holdNextCall()

        let refresh = Task { await model.refresh() }
        await waitUntil("rafraîchissement en attente du réseau") { source.isHoldingCall }
        #expect(model.phase == .loaded(Fixtures.contentA))
        #expect(model.isRefreshing)
        #expect(model.isLoading)

        source.release(with: .success(Fixtures.contentB))
        await refresh.value
        #expect(model.phase == .loaded(Fixtures.contentB))
        #expect(!model.isRefreshing)
        #expect(!model.isLoading)
    }

    @Test("tirer pour actualiser pendant le premier chargement le rejoint au lieu d'en lancer un second")
    func requestDuringLoadJoinsIt() async {
        let source = ScriptedDiscoverSource(outcomes: [], holdsFirstCall: true)
        let model = DiscoverViewModel(fetchContent: { try await source.fetch() })

        let firstLoad = Task { await model.loadIfNeeded() }
        await waitUntil("premier chargement en attente du réseau") { source.isHoldingCall }
        #expect(model.phase == .loading)
        #expect(model.isLoading)
        #expect(!model.isRefreshing)

        // Tâche créée AVANT la libération : sur le main actor (file FIFO),
        // elle démarre avant la reprise du chargement libéré, donc pendant
        // qu'il est encore en cours. Si elle lançait malgré tout un second
        // chargement, la source n'a plus rien en réserve : `callCount`
        // passerait à 2 et le test échouerait, sans jamais bloquer.
        let pullToRefresh = Task { await model.refresh() }
        source.release(with: .success(Fixtures.contentA))
        await firstLoad.value
        await pullToRefresh.value

        #expect(source.callCount == 1)
        #expect(model.phase == .loaded(Fixtures.contentA))
    }

    @Test("le sujet choisi survit à un rafraîchissement")
    func selectedTopicSurvivesRefresh() async {
        let source = ScriptedDiscoverSource(outcomes: [.success(Fixtures.contentA), .success(Fixtures.contentB)])
        let model = DiscoverViewModel(selectedTopic: .finance, fetchContent: { try await source.fetch() })
        #expect(model.selectedTopic == .finance)

        await model.loadIfNeeded()
        model.selectedTopic = .tech
        await model.refresh()

        #expect(model.selectedTopic == .tech)
    }
}

// MARK: - Présentation d'un article

@Suite("DiscoverArticlePresentation")
struct DiscoverArticlePresentationTests {
    @Test(
        "seuls les liens web avec un hôte s'ouvrent",
        arguments: ["https://lemonde.fr/article", "http://example.com", "HTTPS://EXAMPLE.COM/A"]
    )
    func webLinksOpen(rawURL: String) {
        #expect(DiscoverArticlePresentation.articleURL(from: rawURL) != nil)
    }

    /// Une URL venue d'une instance publique ne doit jamais lancer une autre
    /// app (appel, FaceTime, lien profond) sur un simple toucher.
    @Test(
        "tout le reste est refusé",
        arguments: [
            "tel:0102030405", "facetime:a@example.com", "javascript:alert(1)", "mailto:a@example.com",
            "ftp://example.com/fichier", "https:chemin-sans-hote", "//cdn.example/article", "lemonde.fr/article", "",
        ]
    )
    func otherLinksAreRejected(rawURL: String) {
        #expect(DiscoverArticlePresentation.articleURL(from: rawURL) == nil)
    }

    @Test("l'URL d'article est rognée avant analyse")
    func articleURLIsTrimmed() {
        #expect(DiscoverArticlePresentation.articleURL(from: "  https://lemonde.fr/a \n")?.absoluteString == "https://lemonde.fr/a")
    }

    @Test("vignettes : https avec hôte ou image data, rien d'autre")
    func thumbnails() {
        #expect(DiscoverArticlePresentation.thumbnailURL(from: URL(string: "https://img.example/a.jpg")) != nil)
        #expect(DiscoverArticlePresentation.thumbnailURL(from: URL(string: "data:image/png;base64,AAAA")) != nil)
        // `http` : bloqué par ATS. Relatif au protocole : aucun schéma.
        #expect(DiscoverArticlePresentation.thumbnailURL(from: URL(string: "http://img.example/a.jpg")) == nil)
        #expect(DiscoverArticlePresentation.thumbnailURL(from: URL(string: "//cdn.example/a.jpg")) == nil)
        #expect(DiscoverArticlePresentation.thumbnailURL(from: URL(string: "data:text/plain,bonjour")) == nil)
        #expect(DiscoverArticlePresentation.thumbnailURL(from: URL(string: "https:sans-hote.jpg")) == nil)
        #expect(DiscoverArticlePresentation.thumbnailURL(from: nil) == nil)
    }

    @Test("texte affiché : blancs fusionnés, bords rognés")
    func displayTextCollapsesWhitespace() {
        #expect(DiscoverArticlePresentation.displayText("  Titre \n sur\tplusieurs   lignes ") == "Titre sur plusieurs lignes")
        #expect(DiscoverArticlePresentation.displayText(" \n\t ").isEmpty)
    }

    @Test("extrait : masqué s'il est vide ou s'il répète le titre")
    func snippetHidesEmptyOrRepeatedText() {
        let title = "Éclipse totale ce soir"
        #expect(DiscoverArticlePresentation.snippet(nil, title: title) == nil)
        #expect(DiscoverArticlePresentation.snippet("  \n ", title: title) == nil)
        #expect(DiscoverArticlePresentation.snippet("eclipse TOTALE\nce  soir", title: title) == nil)
        #expect(DiscoverArticlePresentation.snippet("Visible depuis tout\nle pays.", title: title) == "Visible depuis tout le pays.")
    }

    @Test("domaine de la source : minuscules, sans www")
    func sourceDomain() {
        #expect(DiscoverArticlePresentation.sourceDomain(of: "https://www.lemonde.fr/pixels/article") == "lemonde.fr")
        #expect(DiscoverArticlePresentation.sourceDomain(of: "https://RMCSPORT.bfmtv.com/x") == "rmcsport.bfmtv.com")
        #expect(DiscoverArticlePresentation.sourceDomain(of: "mailto:contact@example.com") == nil)
    }
}

// MARK: - Mise en page

@Suite("DiscoverLayout")
struct DiscoverLayoutTests {
    /// Bornes exactes : (largeur + 24) / (320 + 24) arrondi vers le bas.
    @Test(
        "colonnes selon la largeur : 320 pt minimum par colonne, 3 au plus",
        arguments: zip([319, 320, 663, 664, 1007, 1008, 5000] as [CGFloat], [1, 1, 1, 2, 2, 3, 3])
    )
    func columnCountFollowsWidth(width: CGFloat, expected: Int) {
        #expect(DiscoverLayout.columnCount(availableWidth: width, isAccessibilitySize: false) == expected)
    }

    /// Premier rendu (largeur pas encore mesurée) ou valeur aberrante : une
    /// colonne, jamais de plantage à la conversion en `Int`.
    @Test("largeur inexploitable : une colonne", arguments: [0, -40, .nan, .infinity, -.infinity] as [CGFloat])
    func unusableWidthGivesOneColumn(width: CGFloat) {
        #expect(DiscoverLayout.columnCount(availableWidth: width, isAccessibilitySize: false) == 1)
    }

    @Test("tailles de texte d'accessibilité : toujours une colonne")
    func accessibilitySizesUseOneColumn() {
        #expect(DiscoverLayout.columnCount(availableWidth: 5000, isAccessibilitySize: true) == 1)
    }

    @Test(
        "aperçu de « Tout » : deux rangées pleines, 4 articles au moins",
        arguments: zip([-1, 0, 1, 2, 3, 4, Int.max], [4, 4, 4, 4, 6, 6, 6])
    )
    func overviewArticleLimit(columns: Int, expected: Int) {
        #expect(DiscoverLayout.overviewArticleLimit(columnCount: columns) == expected)
    }

    /// La règle que la vue compose avec `MediaResultsPresentation.listLayout`
    /// : le bouton n'apparaît que s'il cache au moins 2 articles.
    @Test("« Afficher les N autres » n'apparaît que s'il cache au moins 2 articles")
    func showMoreAppearsOnlyWhenHidingTwoOrMore() {
        let oneColumn = DiscoverLayout.overviewArticleLimit(columnCount: 1)
        #expect(MediaResultsPresentation.listLayout(totalCount: 5, limit: oneColumn) == MediaInlineLayout(visibleCount: 5, hiddenCount: 0))
        #expect(MediaResultsPresentation.listLayout(totalCount: 6, limit: oneColumn) == MediaInlineLayout(visibleCount: 4, hiddenCount: 2))
        let threeColumns = DiscoverLayout.overviewArticleLimit(columnCount: 3)
        #expect(MediaResultsPresentation.listLayout(totalCount: 12, limit: threeColumns) == MediaInlineLayout(visibleCount: 6, hiddenCount: 6))
    }

    @Test("libellé du dépliage")
    func showMoreLabels() {
        #expect(DiscoverLayout.showMoreLabel(hiddenCount: 0) == "Tout afficher")
        #expect(DiscoverLayout.showMoreLabel(hiddenCount: -3) == "Tout afficher")
        #expect(DiscoverLayout.showMoreLabel(hiddenCount: 1) == "Afficher 1 autre article")
        #expect(DiscoverLayout.showMoreLabel(hiddenCount: 6) == "Afficher les 6 autres articles")
    }
}
