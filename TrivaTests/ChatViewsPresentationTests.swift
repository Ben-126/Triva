//
//  ChatViewsPresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/10/2026.
//

import Testing
import Foundation
import SwiftUI
@testable import Triva

/// Logique pure des vues de chat des tâches 1.7, 1.12 et 1.14 :
/// - `SuggestionsPresentation` (`Triva/Features/Chat/SuggestionsView.swift`) ;
/// - `CitationPresentation` (`Triva/Features/Chat/CitationView.swift`) ;
/// - `ReasoningTiming` et `ThinkBoxPresentation`
///   (`Triva/Features/Chat/ThinkBoxView.swift`).
///
/// Suites NON isolées : tout ce qu'elles testent est `nonisolated`, et la
/// target de tests n'a pas d'isolation par défaut. Les valeurs `CGFloat`,
/// `CGRect` et `CGSize` attendues sont construites HORS de `#expect` : la
/// macro capture les littéraux à part et peut leur faire perdre leur type
/// (voir `MediaResultsKindTests.thumbnailAspectRatios`).

// MARK: - Fabriques

private func makeSource(_ index: Int, title: String? = nil, url: String? = nil, content: String? = nil) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: title ?? "Source \(index)",
        url: url ?? "https://exemple\(index).fr/article",
        content: content,
        imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
    )
}

private func makeSources(_ count: Int) -> [SearXNGSearchResult] {
    (0..<count).map { makeSource($0 + 1) }
}

/// Texte rendu, sans attributs.
private func renderedString(_ text: String, sourceCount: Int, isStreaming: Bool = false) -> String {
    String(rendered(text, sourceCount: sourceCount, isStreaming: isStreaming).characters)
}

private func rendered(_ text: String, sourceCount: Int, isStreaming: Bool = false) -> AttributedString {
    let parsed = CitationParser.parse(text, sources: makeSources(sourceCount))
    return CitationPresentation.attributedText(for: parsed, isStreaming: isStreaming)
}

/// Indices des liens internes portés par le texte rendu, dans l'ordre.
private func badgeIndices(in text: AttributedString) -> [Int] {
    text.runs.compactMap { run in run.link.flatMap(CitationPresentation.citationIndex(from:)) }
}

private let nbsp = "\u{00A0}"
private let narrowNbsp = "\u{202F}"

// MARK: - SuggestionsPresentation

@Suite("SuggestionsPresentation")
struct SuggestionsPresentationTests {

    // MARK: Nettoyage

    @Test("Blancs internes ramenés à une espace, blancs de bord retirés")
    func whitespaceIsCollapsedAndTrimmed() {
        let visible = SuggestionsPresentation.visibleSuggestions(["  Quelle  est\nla\tpopulation ?  "])
        #expect(visible == ["Quelle est la population ?"])
    }

    @Test("Entrées vides ou faites de blancs écartées")
    func blankEntriesAreDropped() {
        #expect(SuggestionsPresentation.visibleSuggestions(["", "   ", "\n\t"]).isEmpty)
        #expect(SuggestionsPresentation.visibleSuggestions([]).isEmpty)
    }

    @Test("Doublons écartés sans tenir compte de la casse, première occurrence gardée")
    func duplicatesIgnoreCaseAndKeepFirst() {
        let visible = SuggestionsPresentation.visibleSuggestions(["Paris ?", "paris ?", "PARIS ?"])
        #expect(visible == ["Paris ?"])
    }

    @Test("Doublons détectés APRÈS nettoyage des blancs")
    func duplicatesAreDetectedAfterNormalization() {
        let visible = SuggestionsPresentation.visibleSuggestions(["Et  Lyon ?", " et lyon ?\n"])
        #expect(visible == ["Et Lyon ?"])
    }

    @Test("Ordre reçu conservé")
    func orderIsPreserved() {
        let visible = SuggestionsPresentation.visibleSuggestions(["B", "A", "b", "C"])
        #expect(visible == ["B", "A", "C"])
    }

    @Test("Aucun plafond de nombre ni de longueur côté vue")
    func noCapIsApplied() {
        let long = String(repeating: "mot ", count: 100).trimmingCharacters(in: .whitespaces)
        let many = (1...12).map { "Question \($0) ?" }
        #expect(SuggestionsPresentation.visibleSuggestions(many).count == 12)
        #expect(SuggestionsPresentation.visibleSuggestions([long]) == [long])
    }

    // MARK: Disposition en flux

    @Test("Flux : liste vide, taille nulle")
    func flowWithNoItemIsEmpty() {
        let arrangement = SuggestionsPresentation.flowArrangement(itemSizes: [], maxWidth: 300, spacing: 8)
        #expect(arrangement.frames.isEmpty)
        #expect(arrangement.size == CGSize.zero)
    }

    @Test("Flux : retour à la ligne dès qu'une puce ne tient plus")
    func flowWrapsWhenItemDoesNotFit() {
        let item = CGSize(width: 100, height: 30)
        let arrangement = SuggestionsPresentation.flowArrangement(itemSizes: [item, item, item], maxWidth: 250, spacing: 8)
        let expectedFrames = [
            CGRect(x: 0, y: 0, width: 100, height: 30),
            CGRect(x: 108, y: 0, width: 100, height: 30),
            CGRect(x: 0, y: 38, width: 100, height: 30),
        ]
        let expectedSize = CGSize(width: 208, height: 68)
        #expect(arrangement.frames == expectedFrames)
        #expect(arrangement.size == expectedSize)
    }

    @Test("Flux : une puce qui tient pile reste sur la ligne")
    func flowKeepsItemThatFitsExactly() {
        let item = CGSize(width: 100, height: 30)
        let arrangement = SuggestionsPresentation.flowArrangement(itemSizes: [item, item], maxWidth: 208, spacing: 8)
        let expectedFrames = [
            CGRect(x: 0, y: 0, width: 100, height: 30),
            CGRect(x: 108, y: 0, width: 100, height: 30),
        ]
        let expectedSize = CGSize(width: 208, height: 30)
        #expect(arrangement.frames == expectedFrames)
        #expect(arrangement.size == expectedSize)
    }

    @Test("Flux : une puce trop large est ramenée à la largeur disponible")
    func flowClampsTooWideItem() {
        let sizes = [CGSize(width: 50, height: 20), CGSize(width: 300, height: 30)]
        let arrangement = SuggestionsPresentation.flowArrangement(itemSizes: sizes, maxWidth: 200, spacing: 8)
        let expectedFrames = [
            CGRect(x: 0, y: 0, width: 50, height: 20),
            CGRect(x: 0, y: 28, width: 200, height: 30),
        ]
        let expectedSize = CGSize(width: 200, height: 58)
        #expect(arrangement.frames == expectedFrames)
        #expect(arrangement.size == expectedSize)
    }

    @Test("Flux : une puce seule trop large ne change pas de ligne")
    func flowNeverWrapsAnItemAloneOnItsRow() {
        let arrangement = SuggestionsPresentation.flowArrangement(
            itemSizes: [CGSize(width: 300, height: 30)], maxWidth: 200, spacing: 8
        )
        let expectedFrames = [CGRect(x: 0, y: 0, width: 200, height: 30)]
        #expect(arrangement.frames == expectedFrames)
    }

    @Test("Flux : largeur infinie, tout sur une seule ligne")
    func flowWithInfiniteWidthUsesOneRow() {
        let sizes = [CGSize(width: 100, height: 30), CGSize(width: 200, height: 30), CGSize(width: 300, height: 30)]
        let arrangement = SuggestionsPresentation.flowArrangement(itemSizes: sizes, maxWidth: .infinity, spacing: 8)
        let expectedOrigins = [CGFloat(0), 108, 316]
        let expectedSize = CGSize(width: 616, height: 30)
        #expect(arrangement.frames.map(\.minX) == expectedOrigins)
        #expect(arrangement.frames.allSatisfy { $0.minY == 0 })
        #expect(arrangement.size == expectedSize)
    }

    @Test("Flux : une ligne prend la hauteur de sa puce la plus haute")
    func flowRowHeightIsTallestItem() {
        let sizes = [CGSize(width: 50, height: 20), CGSize(width: 50, height: 40), CGSize(width: 150, height: 10)]
        let arrangement = SuggestionsPresentation.flowArrangement(itemSizes: sizes, maxWidth: 200, spacing: 8)
        let expectedThirdOriginY: CGFloat = 48
        let expectedSize = CGSize(width: 150, height: 58)
        #expect(arrangement.frames[2].minY == expectedThirdOriginY)
        #expect(arrangement.size == expectedSize)
    }

    @Test("Flux : nan et valeurs négatives ramenées à zéro, jamais de cadre aberrant")
    func flowSanitizesDegenerateInputs() {
        let sizes = [
            CGSize(width: -5, height: -5),
            CGSize(width: CGFloat.nan, height: CGFloat.nan),
            CGSize(width: 40, height: 20),
        ]
        for maxWidth in [CGFloat.nan, -10, 0] {
            let arrangement = SuggestionsPresentation.flowArrangement(itemSizes: sizes, maxWidth: maxWidth, spacing: .nan)
            #expect(arrangement.frames.count == sizes.count)
            for frame in arrangement.frames {
                #expect(frame.minX.isFinite && frame.minY.isFinite)
                #expect(frame.width >= 0 && frame.height >= 0)
            }
            #expect(arrangement.size.width.isFinite && arrangement.size.height.isFinite)
        }
    }
}

// MARK: - CitationPresentation

@Suite("CitationPresentation")
struct CitationPresentationTests {

    // MARK: Liens internes

    @Test("Lien interne : triva-citation://source/n")
    func urlForCitationIndex() {
        #expect(CitationPresentation.url(forCitationIndex: 3)?.absoluteString == "triva-citation://source/3")
        #expect(CitationPresentation.url(forCitationIndex: 0) == nil)
        #expect(CitationPresentation.url(forCitationIndex: -1) == nil)
    }

    @Test("Aller-retour lien ↔ indice", arguments: [1, 2, 42, 9999])
    func citationIndexRoundTrip(index: Int) throws {
        let url = try #require(CitationPresentation.url(forCitationIndex: index))
        #expect(CitationPresentation.citationIndex(from: url) == index)
    }

    @Test(
        "Liens forgés ou étrangers rejetés",
        arguments: [
            "triva-citation://source/12345",
            "triva-citation://source/abc",
            "triva-citation://source/0",
            "triva-citation://source/",
            "triva-citation://source/3/4",
            "triva-citation://source/-3",
            "triva-citation://source/\u{0663}",
            "triva-citation://autre/3",
            "https://source/3",
            "https://exemple.fr/source/3",
        ]
    )
    func forgedLinksAreRejected(raw: String) throws {
        guard let url = URL(string: raw) else { return }
        #expect(CitationPresentation.citationIndex(from: url) == nil)
    }

    @Test("Schéma et hôte comparés sans tenir compte de la casse")
    func citationIndexIgnoresSchemeAndHostCase() throws {
        let url = try #require(URL(string: "TRIVA-CITATION://SOURCE/7"))
        #expect(CitationPresentation.citationIndex(from: url) == 7)
    }

    @Test("Liste blanche des liens de la réponse : http, https, mailto")
    func allowedExternalLinks() throws {
        for raw in ["http://exemple.fr", "https://exemple.fr/a", "HTTPS://EXEMPLE.FR", "mailto:contact@exemple.fr"] {
            let url = try #require(URL(string: raw))
            #expect(CitationPresentation.isAllowedExternalLink(url), "\(raw) devrait être accepté")
        }
        for raw in ["shortcuts://run-shortcut?name=x", "javascript:alert(1)", "file:///etc/passwd", "tel:0102030405", "page.html"] {
            let url = try #require(URL(string: raw))
            #expect(!CitationPresentation.isAllowedExternalLink(url), "\(raw) devrait être refusé")
        }
    }

    @Test("Feuille en compact, bulle en regular et sans classe de taille")
    func presentationStyleFollowsSizeClass() {
        #expect(CitationPresentation.presentationStyle(for: .compact) == .sheet)
        #expect(CitationPresentation.presentationStyle(for: .regular) == .popover)
        #expect(CitationPresentation.presentationStyle(for: nil) == .popover)
    }

    // MARK: Fragment retenu (streaming)

    @Test("Pendant le streaming, le fragment « [1 » est ignoré")
    func pendingSuffixIsHiddenWhileStreaming() {
        #expect(renderedString("330 mètres[1", sourceCount: 2, isStreaming: true) == "330 mètres")
    }

    @Test("Après le streaming, le fragment est ajouté en texte brut")
    func pendingSuffixIsAppendedAfterStreaming() {
        let text = rendered("330 mètres[1", sourceCount: 2, isStreaming: false)
        #expect(String(text.characters) == "330 mètres[1")
        #expect(badgeIndices(in: text).isEmpty)
    }

    // MARK: Badges

    @Test("Badge collé au mot : espace fine insécable ajoutée devant")
    func gluedBadgeGetsNarrowNoBreakSpace() {
        #expect(CitationPresentation.narrowNoBreakSpace == narrowNbsp)
        #expect(renderedString("330 mètres[1].", sourceCount: 1) == "330 mètres\(narrowNbsp)[1].")
    }

    @Test("Badge déjà précédé d'un blanc, en tête ou après « ( » : pas d'espace ajoutée")
    func noSpaceWhenNotGlued() {
        #expect(renderedString("330 mètres [1].", sourceCount: 1) == "330 mètres [1].")
        #expect(renderedString("[1] en tête", sourceCount: 1) == "[1] en tête")
        #expect(renderedString("Voir ([1]).", sourceCount: 1) == "Voir ([1]).")
    }

    @Test("Badges collés : une espace fine entre chacun")
    func adjacentBadgesAreSeparated() {
        let text = rendered("fait[1][2].", sourceCount: 2)
        #expect(String(text.characters) == "fait\(narrowNbsp)[1]\(narrowNbsp)[2].")
        #expect(badgeIndices(in: text) == [1, 2])
    }

    @Test("Badge : lien interne et police dédiée")
    func badgeCarriesLinkAndFont() throws {
        let text = rendered("Elle mesure 330 mètres[3].", sourceCount: 3)
        let run = try #require(text.runs.first { $0.link != nil })
        #expect(run.link == CitationPresentation.url(forCitationIndex: 3))
        #expect(run.font == CitationPresentation.badgeFont)
        #expect(String(text[run.range].characters) == "\(narrowNbsp)[3]")
    }

    @Test("Police du badge : footnote medium")
    func badgeFontIsFootnoteMedium() {
        #expect(CitationPresentation.badgeFont == Font.footnote.weight(.medium))
    }

    @Test("Gras qui enjambe une citation : interprété, sans astérisques orphelins")
    func boldSpanningACitationIsParsed() throws {
        let text = rendered("**330 mètres[1].** Fin", sourceCount: 1)
        let plain = String(text.characters)
        #expect(plain == "330 mètres\(narrowNbsp)[1]. Fin")
        #expect(!plain.contains("*"))
        let boldRun = try #require(text.runs.first { String(text[$0.range].characters).hasPrefix("330") })
        #expect(boldRun.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(badgeIndices(in: text) == [1])
    }

    @Test("[1] dans du code reste du code, sans badge")
    func citationInsideCodeStaysCode() throws {
        let text = rendered("Utilise `liste[1]` ici.", sourceCount: 2)
        #expect(String(text.characters) == "Utilise liste[1] ici.")
        #expect(badgeIndices(in: text).isEmpty)
        let codeRun = try #require(text.runs.first { String(text[$0.range].characters).contains("[1]") })
        #expect(codeRun.inlinePresentationIntent?.contains(.code) == true)
    }

    @Test("Aucune source : [1] reste un texte littéral, sans lien")
    func noSourceLeavesMarkerLiteral() {
        let text = rendered("Une affirmation [1].", sourceCount: 0)
        #expect(String(text.characters) == "Une affirmation [1].")
        #expect(badgeIndices(in: text).isEmpty)
    }

    @Test("Repli segment par segment si le texte contient déjà la sentinelle")
    func fallsBackToSegmentwiseRendering() {
        let text = rendered("a [\u{E000}] b[1]", sourceCount: 1)
        #expect(String(text.characters) == "a [\u{E000}] b\(narrowNbsp)[1]")
        #expect(badgeIndices(in: text) == [1])
    }

    @Test("Liens Markdown ordinaires conservés tels quels")
    func ordinaryMarkdownLinkIsKept() throws {
        let text = rendered("Voir [le site](https://exemple.fr) [1].", sourceCount: 1)
        let links = text.runs.compactMap(\.link)
        let expected = try #require(URL(string: "https://exemple.fr"))
        #expect(links.contains(expected))
        #expect(badgeIndices(in: text) == [1])
    }

    // MARK: VoiceOver

    @Test("Texte lu : « mètres, source 1 » pour un badge collé")
    func accessibilityTextForGluedBadge() {
        let text = rendered("330 mètres[1].", sourceCount: 1)
        #expect(CitationPresentation.accessibilityText(fromRendered: text) == "330 mètres, source 1.")
    }

    @Test("Texte lu : badge espacé sans virgule, Markdown déjà interprété")
    func accessibilityTextForSpacedBadgeAndMarkdown() {
        let text = rendered("**Début** [2] fin", sourceCount: 2)
        #expect(CitationPresentation.accessibilityText(fromRendered: text) == "Début source 2 fin")
    }

    // MARK: Fiche source

    @Test("Sources citées : dédoublonnées, ordre de première apparition, hors bornes ignorées")
    func citedSourcesAreDeduplicatedInReadingOrder() {
        let sources = makeSources(3)
        let parsed = CitationParser.parse("A[2] B[1] C[2] D[9]", sources: sources)
        let cited = CitationPresentation.citedSources(in: parsed, sources: sources)
        #expect(cited.map(\.citationIndex) == [2, 1])
        #expect(cited.map(\.source.url) == [sources[1].url, sources[0].url])
    }

    @Test("Titre : titre nettoyé, sinon hôte, sinon libellé neutre")
    func displayTitleFallsBack() {
        #expect(CitationPresentation.displayTitle(for: makeSource(1, title: "  Le   Monde \n")) == "Le Monde")
        #expect(CitationPresentation.displayTitle(for: makeSource(1, title: "  ", url: "https://www.lemonde.fr/x")) == "lemonde.fr")
        #expect(CitationPresentation.displayTitle(for: makeSource(1, title: "", url: "pas une url")) == CitationPresentation.untitledSourceTitle)
    }

    @Test("Hôte : minuscules, sans www.")
    func displayHostIsNormalized() {
        #expect(CitationPresentation.displayHost(for: makeSource(1, url: "https://WWW.LeMonde.fr/a")) == "lemonde.fr")
        #expect(CitationPresentation.displayHost(for: makeSource(1, url: "https://fr.wikipedia.org/wiki/Chat")) == "fr.wikipedia.org")
    }

    @Test("Extrait : nil sans contenu utile, blancs ramenés à une espace")
    func excerptCollapsesOrRefuses() {
        #expect(CitationPresentation.excerpt(from: nil) == nil)
        #expect(CitationPresentation.excerpt(from: " \n ") == nil)
        #expect(CitationPresentation.excerpt(from: "texte", maxLength: 0) == nil)
        #expect(CitationPresentation.excerpt(from: "  court \n  texte ") == "court texte")
    }

    @Test("Extrait long : coupé sur une fin de mot, suivi de « … »")
    func longExcerptIsCutOnWordBoundary() throws {
        let content = String(repeating: "mot ", count: 200)
        let excerpt = try #require(CitationPresentation.excerpt(from: content))
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.count <= CitationPresentation.maxExcerptLength + 1)
        #expect(excerpt.dropLast().split(separator: " ").allSatisfy { $0 == "mot" })
    }

    @Test("Extrait coupé : ponctuation retirée avant « … »")
    func trailingPunctuationIsRemovedBeforeEllipsis() {
        #expect(CitationPresentation.excerpt(from: "alpha, beta, gamma, delta", maxLength: 13) == "alpha, beta…")
    }

    @Test("Extrait d'un seul mot trop long : coupé net")
    func singleLongWordIsCutHard() {
        let content = String(repeating: "a", count: 500)
        #expect(CitationPresentation.excerpt(from: content, maxLength: 280) == String(repeating: "a", count: 280) + "…")
    }

    @Test("URL ouvrable : http(s) avec hôte seulement")
    func openableURLAcceptsOnlyWebWithHost() {
        #expect(CitationPresentation.openableURL(for: makeSource(1, url: "https://exemple.fr/a"))?.absoluteString == "https://exemple.fr/a")
        #expect(CitationPresentation.openableURL(for: makeSource(1, url: "  http://exemple.fr  ")) != nil)
        for raw in ["javascript:alert(1)", "ftp://exemple.fr/f", "https://", "/relatif", "mailto:a@b.fr", ""] {
            #expect(CitationPresentation.openableURL(for: makeSource(1, url: raw)) == nil, "\(raw) ne doit pas s'ouvrir")
        }
    }

    @Test("Libellés de la fiche et des actions VoiceOver")
    func cardAndActionLabels() {
        #expect(CitationPresentation.sourceLabel(citationIndex: 3) == "SOURCE 3")
        let selection = CitationSelection(citationIndex: 3, source: makeSource(3, title: "Tour Eiffel"))
        #expect(CitationPresentation.accessibilityActionName(for: selection) == "Source 3 : Tour Eiffel")
        #expect(selection.id == 3)
    }
}

// MARK: - ReasoningTiming

@Suite("ReasoningTiming")
struct ReasoningTimingTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Par défaut : aucune borne, durée inconnue")
    func defaultHasNoBounds() {
        let timing = ReasoningTiming()
        #expect(timing.startedAt == nil)
        #expect(timing.endedAt == nil)
        #expect(timing.duration == nil)
    }

    @Test("Début fixé par le premier .inProgress, jamais décalé ensuite")
    func startIsWrittenOnce() {
        let first = ReasoningTiming().updated(for: .inProgress, at: start)
        let replayed = first.updated(for: .inProgress, at: start.addingTimeInterval(5))
        #expect(first.startedAt == start)
        #expect(replayed == first)
    }

    @Test("Fin fixée par .completed, jamais décalée ensuite ; durée calculée")
    func endIsWrittenOnce() {
        let end = start.addingTimeInterval(12)
        let finished = ReasoningTiming()
            .updated(for: .inProgress, at: start)
            .updated(for: .completed, at: end)
        let replayed = finished.updated(for: .completed, at: end.addingTimeInterval(30))
        #expect(finished.endedAt == end)
        #expect(finished.duration == 12)
        #expect(replayed == finished)
    }

    @Test(".interrupted fixe aussi la fin")
    func interruptedSetsEnd() {
        let timing = ReasoningTiming(startedAt: start).updated(for: .interrupted, at: start.addingTimeInterval(3))
        #expect(timing.duration == 3)
    }

    @Test(".absent ne change rien")
    func absentChangesNothing() {
        let timing = ReasoningTiming(startedAt: start)
        #expect(timing.updated(for: .absent, at: start.addingTimeInterval(9)) == timing)
        #expect(ReasoningTiming().updated(for: .absent, at: start) == ReasoningTiming())
    }

    @Test("Passage direct à .completed : début inconnu, durée nil (jamais « 0 s »)")
    func directCompletionHasUnknownDuration() {
        let timing = ReasoningTiming().updated(for: .completed, at: start)
        #expect(timing.startedAt == nil)
        #expect(timing.endedAt == start)
        #expect(timing.duration == nil)
    }

    @Test("Fin antérieure au début (horloge recalée) : durée 0, jamais négative")
    func endBeforeStartGivesZero() {
        let timing = ReasoningTiming(startedAt: start, endedAt: start.addingTimeInterval(-4))
        #expect(timing.duration == 0)
    }
}

// MARK: - ThinkBoxPresentation

@Suite("ThinkBoxPresentation")
struct ThinkBoxPresentationTests {

    // MARK: Durées

    @Test("Secondes entières : arrondi vers le bas, nil hors plage ou non fini")
    func wholeSecondsRoundsDownOrRefuses() {
        #expect(ThinkBoxPresentation.wholeSeconds(12.9) == 12)
        #expect(ThinkBoxPresentation.wholeSeconds(0) == 0)
        #expect(ThinkBoxPresentation.wholeSeconds(-3) == 0)
        #expect(ThinkBoxPresentation.wholeSeconds(.nan) == nil)
        #expect(ThinkBoxPresentation.wholeSeconds(.infinity) == nil)
        #expect(ThinkBoxPresentation.wholeSeconds(1e30) == nil)
    }

    @Test("Battement du chronomètre : arrondi au plus proche, pas de bégaiement")
    func elapsedAtTickRoundsToNearest() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ThinkBoxPresentation.elapsedAtTick(start.addingTimeInterval(6.9999), since: start) == 7)
        #expect(ThinkBoxPresentation.elapsedAtTick(start.addingTimeInterval(7.2), since: start) == 7)
        #expect(ThinkBoxPresentation.elapsedAtTick(start, since: start) == 0)
    }

    @Test("Durée affichée : « 12 s », « 1 min », « 1 min 5 s », espaces insécables")
    func durationTextFormats() {
        #expect(ThinkBoxPresentation.numberUnitSeparator == nbsp)
        #expect(ThinkBoxPresentation.durationText(seconds: 0) == "0\(nbsp)s")
        #expect(ThinkBoxPresentation.durationText(seconds: 12) == "12\(nbsp)s")
        #expect(ThinkBoxPresentation.durationText(seconds: 60) == "1\(nbsp)min")
        #expect(ThinkBoxPresentation.durationText(seconds: 65) == "1\(nbsp)min 5\(nbsp)s")
        #expect(ThinkBoxPresentation.durationText(seconds: 125) == "2\(nbsp)min 5\(nbsp)s")
        #expect(ThinkBoxPresentation.durationText(seconds: -5) == "0\(nbsp)s")
    }

    @Test("Durée lue : en toutes lettres, singulier sous 2")
    func spokenDurationAgreesInNumber() {
        #expect(ThinkBoxPresentation.spokenDuration(seconds: 0) == "0 seconde")
        #expect(ThinkBoxPresentation.spokenDuration(seconds: 1) == "1 seconde")
        #expect(ThinkBoxPresentation.spokenDuration(seconds: 12) == "12 secondes")
        #expect(ThinkBoxPresentation.spokenDuration(seconds: 60) == "1 minute")
        #expect(ThinkBoxPresentation.spokenDuration(seconds: 65) == "1 minute 5 secondes")
        #expect(ThinkBoxPresentation.spokenDuration(seconds: 121) == "2 minutes 1 seconde")
    }

    // MARK: Libellés

    @Test("En-tête en cours : « Réflexion… », compteur dès la première seconde pleine")
    func headerTitleInProgress() {
        #expect(ThinkBoxPresentation.headerTitle(phase: .inProgress, elapsed: nil, duration: nil) == "Réflexion…")
        #expect(ThinkBoxPresentation.headerTitle(phase: .inProgress, elapsed: 0.5, duration: nil) == "Réflexion…")
        #expect(ThinkBoxPresentation.headerTitle(phase: .inProgress, elapsed: 12.3, duration: nil) == "Réflexion… 12\(nbsp)s")
    }

    @Test("En-tête terminé : durée au moins 1 s, libellé sobre sans durée connue")
    func headerTitleCompleted() {
        #expect(ThinkBoxPresentation.headerTitle(phase: .completed, elapsed: nil, duration: 12) == "A réfléchi pendant 12\(nbsp)s")
        #expect(ThinkBoxPresentation.headerTitle(phase: .completed, elapsed: nil, duration: 0.2) == "A réfléchi pendant 1\(nbsp)s")
        #expect(ThinkBoxPresentation.headerTitle(phase: .completed, elapsed: nil, duration: nil) == ThinkBoxPresentation.unknownDurationTitle)
        #expect(ThinkBoxPresentation.unknownDurationTitle == "Raisonnement")
    }

    @Test("En-tête : interrompu et absent")
    func headerTitleInterruptedAndAbsent() {
        #expect(ThinkBoxPresentation.headerTitle(phase: .interrupted, elapsed: 4, duration: 4) == "Réflexion interrompue")
        #expect(ThinkBoxPresentation.headerTitle(phase: .absent, elapsed: nil, duration: nil) == "")
    }

    @Test("Valeur VoiceOver : état de dépliage puis état du raisonnement")
    func accessibilityValueCombinesStates() {
        #expect(ThinkBoxPresentation.accessibilityValue(phase: .completed, isExpanded: false, duration: 12) == "replié, a réfléchi pendant 12 secondes")
        #expect(ThinkBoxPresentation.accessibilityValue(phase: .completed, isExpanded: true, duration: nil) == "déplié")
        #expect(ThinkBoxPresentation.accessibilityValue(phase: .inProgress, isExpanded: true, duration: nil) == "déplié, réflexion en cours")
        #expect(ThinkBoxPresentation.accessibilityValue(phase: .interrupted, isExpanded: true, duration: nil) == "déplié, réflexion interrompue")
        #expect(ThinkBoxPresentation.accessibilityValue(phase: .absent, isExpanded: false, duration: nil) == "replié")
    }

    @Test("Indice VoiceOver selon le dépliage")
    func accessibilityHintFollowsExpansion() {
        #expect(ThinkBoxPresentation.accessibilityHint(isExpanded: true) == "Masque le raisonnement")
        #expect(ThinkBoxPresentation.accessibilityHint(isExpanded: false) == "Affiche le raisonnement complet")
    }

    // MARK: Aperçu

    @Test("Aperçu : rien pour un texte vide ou fait de blancs")
    func previewLineIsNilForBlankText() {
        #expect(ThinkBoxPresentation.previewLine(of: "") == nil)
        #expect(ThinkBoxPresentation.previewLine(of: "  \n\t ") == nil)
        #expect(ThinkBoxPresentation.previewLine(of: "Texte", scanLimit: 0) == nil)
    }

    @Test("Aperçu : la dernière phrase, celle en cours d'écriture")
    func previewLineIsLastSentence() {
        #expect(ThinkBoxPresentation.previewLine(of: "Première phrase. Deuxième phrase en cours") == "Deuxième phrase en cours")
        #expect(ThinkBoxPresentation.previewLine(of: "Phrase un ! Phrase deux.") == "Phrase deux.")
        #expect(ThinkBoxPresentation.previewLine(of: "Ligne un\nLigne deux") == "Ligne deux")
        #expect(ThinkBoxPresentation.previewLine(of: "Fin de phrase.") == "Fin de phrase.")
    }

    @Test("Aperçu : « 3.5 » ou « e.g. » au milieu d'un mot ne coupent rien")
    func previewLineIgnoresInnerDots() {
        #expect(ThinkBoxPresentation.previewLine(of: "La version 3.5 du modèle, e.g.ceci") == "La version 3.5 du modèle, e.g.ceci")
    }

    @Test("Aperçu : blancs ramenés à une espace")
    func previewLineCollapsesWhitespace() {
        #expect(ThinkBoxPresentation.previewLine(of: "A. B   c\td  ") == "B c d")
    }

    @Test("Aperçu : fenêtre coupée sans frontière, signalée par « … »")
    func previewLineMarksMidSentenceStart() throws {
        let reasoning = String(repeating: "mot ", count: 100)
        let preview = try #require(ThinkBoxPresentation.previewLine(of: reasoning, scanLimit: 20))
        #expect(preview.hasPrefix("…"))
        #expect(preview.count <= 21)
    }

    @Test("Aperçu : fenêtre coupée mais frontière trouvée, pas de « … »")
    func previewLineWithBoundaryInWindowHasNoEllipsis() {
        let reasoning = String(repeating: "début ", count: 100) + "Fin. Dernière idée"
        #expect(ThinkBoxPresentation.previewLine(of: reasoning, scanLimit: 30) == "Dernière idée")
    }

    // MARK: Dépliage

    @Test("Dépliage par défaut : seul .interrupted est déplié", arguments: ReasoningPhase.allCases)
    func defaultExpansionOnlyForInterrupted(phase: ReasoningPhase) {
        #expect(ThinkBoxPresentation.defaultExpansion(for: phase) == (phase == .interrupted))
    }

    @Test("Le choix de l'utilisateur est effacé à la fin ou à l'interruption, une seule fois")
    func resetsUserExpansionOnlyOnTransitions() {
        #expect(ThinkBoxPresentation.resetsUserExpansion(from: .inProgress, to: .completed))
        #expect(ThinkBoxPresentation.resetsUserExpansion(from: .inProgress, to: .interrupted))
        #expect(ThinkBoxPresentation.resetsUserExpansion(from: .absent, to: .completed))
        #expect(!ThinkBoxPresentation.resetsUserExpansion(from: .completed, to: .completed))
        #expect(!ThinkBoxPresentation.resetsUserExpansion(from: .interrupted, to: .interrupted))
        #expect(!ThinkBoxPresentation.resetsUserExpansion(from: .absent, to: .inProgress))
        #expect(!ThinkBoxPresentation.resetsUserExpansion(from: .inProgress, to: .absent))
    }
}
