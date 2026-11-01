//
//  MessageBubblePresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 31/10/2026.
//

import Testing
import Foundation
import SwiftUI
@testable import Triva

/// Logique pure du fil de chat (mission I3) :
/// - `MessageBubblePresentation` (`Triva/Features/Chat/MessageBubbleView.swift`) :
///   bug 13 de la revue (Markdown et VoiceOver), révélation par paliers
///   pendant le streaming, ce que montre une réponse ;
/// - `ChatScrollFollowing` (`Triva/Features/Chat/ChatView.swift`) : bug 7
///   (suivi du bas de liste déduit du geste, pas de la position).
///
/// Suites NON isolées : tout ce qu'elles testent est `nonisolated`, et la
/// target de tests n'a pas d'isolation par défaut. Les `CGFloat` attendus
/// sont construits HORS de `#expect` (voir `ChatViewsPresentationTests`).

// MARK: - Arithmétique (bug 13)

@Suite("MessageBubblePresentation — arithmétique")
struct MessageBubbleArithmeticTests {

    private func rendered(_ markdown: String) -> AttributedString {
        CitationPresentation.markdown(markdown)
    }

    private func hasEmphasis(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }
    }

    @Test("Témoin : sans protection, CommonMark mange les astérisques de « 5*4*3 »")
    func unprotectedArithmeticLosesItsAsterisks() {
        let raw = rendered("5*4*3 = 60")
        #expect(String(raw.characters) == "543 = 60")
        #expect(hasEmphasis(raw))
    }

    @Test("Multiplication entre chiffres : astérisques échappés, texte rendu intact")
    func digitsKeepTheirAsterisks() {
        let protected = MessageBubblePresentation.protectingArithmetic("5*4*3 = 60")
        #expect(protected == #"5\*4\*3 = 60"#)

        let shown = rendered(protected)
        #expect(String(shown.characters) == "5*4*3 = 60")
        #expect(!hasEmphasis(shown))
    }

    @Test("Puissance, variable collée à un chiffre : protégées aussi")
    func powersAndMixedOperandsArePreserved() {
        let protected = MessageBubblePresentation.protectingArithmetic("2**10 et x*2*y")
        #expect(protected == #"2\*\*10 et x\*2\*y"#)
        #expect(String(rendered(protected).characters) == "2**10 et x*2*y")
    }

    @Test("Gras, italique et emphase entre lettres : interprétés comme avant", arguments: [
        "**Tokyo** et *Kyoto*",
        "un mot **important**, puis *un autre*",
        "a*b*c",
        "2 * 3 * 4",
    ])
    func ordinaryMarkdownIsUntouched(markdown: String) {
        #expect(MessageBubblePresentation.protectingArithmetic(markdown) == markdown)
    }

    @Test("Code entre accents graves : jamais modifié (un \\* y resterait visible)", arguments: [
        "`5*4*3`",
        "```\nx = 5*4\n```",
        "`a*b` puis ``c*2``",
    ])
    func codeSpansAreUntouched(markdown: String) {
        #expect(MessageBubblePresentation.protectingArithmetic(markdown) == markdown)
    }

    @Test("Code puis arithmétique : seul ce qui suit le code est protégé")
    func arithmeticAfterCodeIsProtected() {
        let protected = MessageBubblePresentation.protectingArithmetic("`a*b` puis 3*4*5")
        #expect(protected == #"`a*b` puis 3\*4\*5"#)
        #expect(String(rendered(protected).characters) == "a*b puis 3*4*5")
    }

    @Test("Accent grave sans fermeture : simple texte, la suite est traitée")
    func unclosedBacktickIsPlainText() {
        #expect(MessageBubblePresentation.protectingArithmetic("`5*4") == #"`5\*4"#)
    }

    @Test("Échappement déjà présent : conservé tel quel")
    func existingEscapesAreKept() {
        let markdown = #"déjà 5\*4"#
        #expect(MessageBubblePresentation.protectingArithmetic(markdown) == markdown)
    }

    @Test("Texte de réponse : protégé, et complet hors streaming")
    func answerTextIsProtectedAndComplete() {
        let body = "Il y a 5*4*3 = 60 cas."
        #expect(MessageBubblePresentation.answerText(body, isStreaming: false) == #"Il y a 5\*4\*3 = 60 cas."#)
    }
}

// MARK: - Révélation par paliers (perf du streaming)

@Suite("MessageBubblePresentation — révélation par paliers")
struct MessageBubbleRevealTests {

    private static let sample = "La capitale du Japon est Tokyo [1]. Elle compte 14 millions d'habitants et 23 arrondissements spéciaux[2]."

    @Test("Hors streaming : le corps entier, toujours")
    func settledBodyIsComplete() {
        #expect(MessageBubblePresentation.displayedBody(Self.sample, isStreaming: false) == Self.sample)
    }

    @Test("Moins d'un palier : rien encore (l'indicateur d'attente reste)")
    func belowTheFirstStepShowsNothing() {
        #expect(MessageBubblePresentation.displayedBody("abc def", isStreaming: true, revealStep: 8) == "")
    }

    @Test("Coupé au dernier blanc du palier atteint : jamais un demi-mot")
    func cutsAtTheLastBlankOfTheReachedStep() {
        #expect(MessageBubblePresentation.displayedBody("abc def ghi jkl", isStreaming: true, revealStep: 8) == "abc def")
        #expect(MessageBubblePresentation.displayedBody("abc def ghi jklm", isStreaming: true, revealStep: 8) == "abc def ghi")
    }

    @Test("Sans aucun blanc (URL longue) : coupe nette au palier")
    func hardCutWithoutBlank() {
        #expect(MessageBubblePresentation.displayedBody("abcdefghijk", isStreaming: true, revealStep: 8) == "abcdefgh")
    }

    @Test("Pas de palier (≤ 1) : texte en direct")
    func disabledStepIsLive() {
        #expect(MessageBubblePresentation.displayedBody("abc", isStreaming: true, revealStep: 1) == "abc")
    }

    @Test("Monotone : d'un snapshot au suivant, le texte affiché ne fait que grandir")
    func revealIsMonotonic() {
        var previous = ""
        for length in 0...Self.sample.count {
            let snapshot = String(Self.sample.prefix(length))
            let shown = MessageBubblePresentation.displayedBody(snapshot, isStreaming: true, revealStep: 8)
            #expect(shown.hasPrefix(previous))
            #expect(Self.sample.hasPrefix(shown))
            previous = shown
        }
    }

    @Test("Le palier par défaut divise le nombre de rendus distincts")
    func defaultStepCoalescesSnapshots() {
        let snapshots = (0...Self.sample.count).map { String(Self.sample.prefix($0)) }
        let distinct = Set(snapshots.map { MessageBubblePresentation.displayedBody($0, isStreaming: true) })
        #expect(distinct.count <= Self.sample.count / MessageBubblePresentation.streamingRevealStep + 1)
    }
}

// MARK: - Accessibilité et favori (bug 13)

@Suite("MessageBubblePresentation — libellés")
struct MessageBubbleLabelTests {

    @Test("Question : le texte exact de l'écran, astérisques compris")
    func questionLabelIsVerbatim() {
        let label = MessageBubblePresentation.questionAccessibilityLabel(text: "Combien font 12*3*2 ?", attachedFileNames: [])
        #expect(label == "Question, Combien font 12*3*2 ?")
    }

    @Test("Question : syntaxe Markdown jamais interprétée")
    func questionLabelKeepsMarkdownSyntax() {
        let text = "Que fait __init__.py et **ceci** ? [lien](https://exemple.fr)"
        let label = MessageBubblePresentation.questionAccessibilityLabel(text: text, attachedFileNames: [])
        #expect(label == "Question, \(text)")
    }

    @Test("Question : fichiers joints nommés, au singulier puis au pluriel")
    func questionLabelListsAttachedFiles() {
        let one = MessageBubblePresentation.questionAccessibilityLabel(text: "Résume ce document", attachedFileNames: ["rapport.pdf"])
        #expect(one == "Question, Résume ce document. Fichier joint : rapport.pdf")

        let two = MessageBubblePresentation.questionAccessibilityLabel(text: "Compare-les ?", attachedFileNames: ["a.pdf", "b.md"])
        #expect(two == "Question, Compare-les ? Fichiers joints : a.pdf, b.md")
    }

    @Test("Favori : titre et symbole suivent l'état")
    func favoriteTitleAndSymbol() {
        #expect(MessageBubblePresentation.favoriteTitle(isFavorite: false) == "Ajouter aux favoris")
        #expect(MessageBubblePresentation.favoriteTitle(isFavorite: true) == "Retirer des favoris")
        #expect(MessageBubblePresentation.favoriteSymbolName(isFavorite: false) == "star")
        #expect(MessageBubblePresentation.favoriteSymbolName(isFavorite: true) == "star.fill")
    }
}

// MARK: - Ce que montre une réponse

@Suite("MessageBubblePresentation — contenu d'une réponse")
struct MessageBubbleAnswerLayoutTests {

    typealias Answer = MessageBubblePresentation.AnswerSnapshot

    @Test("Bulle vide (échec ou arrêt avant tout contenu) : pas dessinée", arguments: [
        MessageBubblePresentation.AnswerState.failed,
        .interrupted,
        .completed,
    ])
    func emptySettledAnswerHasNoBubble(state: MessageBubblePresentation.AnswerState) {
        #expect(!MessageBubblePresentation.showsBubble(Answer(state: state)))
    }

    @Test("Bulle dessinée dès qu'il y a quelque chose à montrer")
    func bubbleIsShownWithAnyContent() {
        #expect(MessageBubblePresentation.showsBubble(Answer(state: .streaming)))
        #expect(MessageBubblePresentation.showsBubble(Answer(state: .noReliableSources)))
        #expect(MessageBubblePresentation.showsBubble(Answer(state: .failed, sourceCount: 2, webSourceCount: 2)))
        #expect(MessageBubblePresentation.showsBubble(Answer(state: .interrupted, reasoningPhase: .interrupted)))
        #expect(MessageBubblePresentation.showsBubble(Answer(state: .completed, hasTLDR: true)))
        #expect(MessageBubblePresentation.showsBubble(Answer(state: .completed, hasBody: true)))
    }

    @Test("Indicateur d'attente : seulement tant que rien de lisible n'est là")
    func progressOnlyWhileNothingReadable() {
        #expect(MessageBubblePresentation.showsProgress(Answer(state: .streaming), displayedBodyIsEmpty: true))
        #expect(MessageBubblePresentation.showsProgress(
            Answer(state: .streaming, reasoningPhase: .completed),
            displayedBodyIsEmpty: true
        ))
        #expect(!MessageBubblePresentation.showsProgress(
            Answer(state: .streaming, reasoningPhase: .inProgress),
            displayedBodyIsEmpty: true
        ))
        #expect(!MessageBubblePresentation.showsProgress(Answer(state: .streaming, hasTLDR: true), displayedBodyIsEmpty: true))
        #expect(!MessageBubblePresentation.showsProgress(Answer(state: .streaming, hasBody: true), displayedBodyIsEmpty: false))
        #expect(!MessageBubblePresentation.showsProgress(Answer(state: .completed), displayedBodyIsEmpty: true))
    }

    @Test("Médias à la demande : réponse posée, avec un texte et des sources web")
    func mediaSearchNeedsASettledWebAnswer() {
        #expect(MessageBubblePresentation.showsMediaSearch(Answer(state: .completed, hasBody: true, sourceCount: 3, webSourceCount: 3)))
        #expect(MessageBubblePresentation.showsMediaSearch(Answer(state: .interrupted, hasBody: true, sourceCount: 1, webSourceCount: 1)))

        #expect(!MessageBubblePresentation.showsMediaSearch(Answer(state: .completed, hasBody: true)))
        #expect(!MessageBubblePresentation.showsMediaSearch(Answer(state: .completed, hasBody: true, sourceCount: 2, webSourceCount: 0)))
        #expect(!MessageBubblePresentation.showsMediaSearch(Answer(state: .completed, sourceCount: 3, webSourceCount: 3)))
        #expect(!MessageBubblePresentation.showsMediaSearch(Answer(state: .streaming, hasBody: true, sourceCount: 3, webSourceCount: 3)))
        #expect(!MessageBubblePresentation.showsMediaSearch(Answer(state: .failed, hasBody: true, sourceCount: 3, webSourceCount: 3)))
        #expect(!MessageBubblePresentation.showsMediaSearch(Answer(state: .noReliableSources)))
    }

    @Test("Recherche média déjà lancée : toujours visible")
    func startedMediaSearchStaysVisible() {
        #expect(MessageBubblePresentation.showsMediaSearch(Answer(state: .failed, isMediaSearchStarted: true)))
    }
}

// MARK: - Sources tirées d'un fichier joint

@Suite("SourcesListPresentation")
struct SourcesListPresentationTests {

    private func source(title: String, url: String) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: nil,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    @Test("URL synthétique d'un fichier joint : reconnue, jamais un lien")
    func attachmentSourceIsRecognized() {
        let attachment = source(title: "rapport.pdf", url: UploadsSearchResultBuilder.sourceURL(for: UUID()))
        #expect(SourcesListPresentation.isAttachment(attachment))
        #expect(!SourcesListPresentation.isAttachment(source(title: "Tokyo", url: "https://fr.wikipedia.org/wiki/Tokyo")))
    }

    @Test("Libellé VoiceOver : le nom du fichier, puis « fichier joint »")
    func attachmentAccessibilityLabel() {
        #expect(SourcesListPresentation.attachmentAccessibilityLabel(title: "rapport.pdf") == "rapport.pdf, fichier joint")
    }
}

// MARK: - Suivi du bas de liste (bug 7)

@Suite("ChatScrollFollowing")
struct ChatScrollFollowingTests {

    typealias Metrics = ChatScrollFollowing.Metrics

    /// Contenu de 2 000 pt dans un conteneur de 600 pt : en bas, l'offset
    /// vaut 1 400.
    private func metrics(offset: CGFloat, content: CGFloat = 2000, container: CGFloat = 600) -> Metrics {
        Metrics(offsetY: offset, contentHeight: content, containerHeight: container)
    }

    // MARK: Geste

    @Test("Le doigt qui fait défiler arrête le suivi, même tout près du bas")
    func interactingUnpins() {
        #expect(!ChatScrollFollowing.isPinnedAfterPhaseChange(from: .tracking, to: .interacting, distanceFromBottom: 0, wasPinned: true))
    }

    @Test("Un simple toucher (badge de citation) ne coupe pas le suivi")
    func trackingKeepsFollowing() {
        #expect(ChatScrollFollowing.isPinnedAfterPhaseChange(from: .idle, to: .tracking, distanceFromBottom: 0, wasPinned: true))
    }

    @Test("Fin de geste près du bas : le suivi reprend ; loin : la vue reste où elle est", arguments: [
        ScrollPhase.interacting,
        .decelerating,
    ])
    func gestureEndDecidesFromDistance(endingPhase: ScrollPhase) {
        let near = ChatScrollFollowing.nearBottomThreshold - 1
        let far = ChatScrollFollowing.nearBottomThreshold + 200
        #expect(ChatScrollFollowing.isPinnedAfterPhaseChange(from: endingPhase, to: .idle, distanceFromBottom: near, wasPinned: false))
        #expect(!ChatScrollFollowing.isPinnedAfterPhaseChange(from: endingPhase, to: .idle, distanceFromBottom: far, wasPinned: true))
    }

    @Test("Fin d'un défilement animé : un échange tout neuf reste suivi, même loin du bas")
    func animationEndKeepsANewExchangePinned() {
        let far = ChatScrollFollowing.nearBottomThreshold + 200
        #expect(ChatScrollFollowing.isPinnedAfterPhaseChange(from: .animating, to: .idle, distanceFromBottom: far, wasPinned: true))
    }

    @Test("Rattrapage après un toucher ou une animation, jamais après un geste")
    func catchUpOnlyAfterTapOrAnimation() {
        #expect(ChatScrollFollowing.needsCatchUp(from: .tracking, to: .idle, isPinned: true, distanceFromBottom: 30))
        #expect(ChatScrollFollowing.needsCatchUp(from: .animating, to: .idle, isPinned: true, distanceFromBottom: 30))
        #expect(!ChatScrollFollowing.needsCatchUp(from: .decelerating, to: .idle, isPinned: true, distanceFromBottom: 30))
        #expect(!ChatScrollFollowing.needsCatchUp(from: .tracking, to: .idle, isPinned: false, distanceFromBottom: 30))
        #expect(!ChatScrollFollowing.needsCatchUp(from: .tracking, to: .idle, isPinned: true, distanceFromBottom: 0))
    }

    // MARK: Géométrie

    @Test("Le contenu qui grandit ne décroche jamais le suivi (le défaut du bug 7)")
    func contentGrowthNeverUnpins() {
        // 5 sources d'un coup : +230 pt, offset inchangé, distance 230 > 80.
        let before = metrics(offset: 1400)
        let after = metrics(offset: 1400, content: 2230)
        #expect(ChatScrollFollowing.isPinnedAfterGeometryChange(from: before, to: after, phase: .idle, wasPinned: true))
        #expect(ChatScrollFollowing.shouldFollowContent(from: before, to: after, phase: .idle, isPinned: true))
    }

    @Test("Molette ou clavier vers le haut, loin du bas : le suivi s'arrête")
    func scrollingUpWithoutGestureUnpins() {
        #expect(!ChatScrollFollowing.isPinnedAfterGeometryChange(from: metrics(offset: 1400), to: metrics(offset: 1200), phase: .idle, wasPinned: true))
    }

    @Test("Contenu qui rétrécit en bas : l'offset recule mais la vue reste en bas, suivi conservé")
    func shrinkingContentKeepsFollowing() {
        let before = metrics(offset: 1400)
        let after = metrics(offset: 1150, content: 1750)
        #expect(ChatScrollFollowing.isPinnedAfterGeometryChange(from: before, to: after, phase: .idle, wasPinned: true))
        #expect(!ChatScrollFollowing.shouldFollowContent(from: before, to: after, phase: .idle, isPinned: true))
    }

    @Test("Retour en bas à la molette : le suivi reprend ; pas pendant un geste")
    func scrollingBackDownRepins() {
        let away = metrics(offset: 1000)
        let back = metrics(offset: 1350)
        #expect(ChatScrollFollowing.isPinnedAfterGeometryChange(from: away, to: back, phase: .idle, wasPinned: false))
        #expect(!ChatScrollFollowing.isPinnedAfterGeometryChange(from: away, to: back, phase: .interacting, wasPinned: false))
        #expect(!ChatScrollFollowing.isPinnedAfterGeometryChange(from: away, to: metrics(offset: 1100), phase: .idle, wasPinned: false))
    }

    @Test("Clavier ouvert (conteneur réduit) : la fin du dernier message est suivie")
    func shrinkingContainerIsFollowed() {
        let before = metrics(offset: 1400)
        let keyboard = metrics(offset: 1400, container: 300)
        #expect(ChatScrollFollowing.isPinnedAfterGeometryChange(from: before, to: keyboard, phase: .idle, wasPinned: true))
        #expect(ChatScrollFollowing.shouldFollowContent(from: before, to: keyboard, phase: .idle, isPinned: true))
    }

    @Test("Jamais de défilement programmatique pendant un geste ni hors suivi", arguments: [
        ScrollPhase.tracking,
        .interacting,
        .decelerating,
    ])
    func noProgrammaticScrollDuringGesture(phase: ScrollPhase) {
        let before = metrics(offset: 1400)
        let after = metrics(offset: 1400, content: 2300)
        #expect(!ChatScrollFollowing.shouldFollowContent(from: before, to: after, phase: phase, isPinned: true))
        #expect(!ChatScrollFollowing.allowsProgrammaticScroll(during: phase))
    }

    @Test("Hors suivi, le contenu qui grandit ne déplace pas la vue")
    func unpinnedContentGrowthIsNotFollowed() {
        #expect(!ChatScrollFollowing.shouldFollowContent(from: metrics(offset: 900), to: metrics(offset: 900, content: 2300), phase: .idle, isPinned: false))
    }

    @Test("Distance au bas et hauteur défilable")
    func metricsArithmetic() {
        let atBottom = metrics(offset: 1400)
        let expectedZero: CGFloat = 0
        let expectedScrollable: CGFloat = 1400
        #expect(atBottom.distanceFromBottom == expectedZero)
        #expect(atBottom.scrollableHeight == expectedScrollable)
    }
}
