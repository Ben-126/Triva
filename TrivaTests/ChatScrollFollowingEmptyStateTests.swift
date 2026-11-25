//
//  ChatScrollFollowingEmptyStateTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission I, capture de Ben sur Mac, 25/11) : dans une petite fenêtre, après le collage d'une image, la
//  zone de saisie grandit, la liste rétrécit, et le suivi du bas de liste faisait défiler l'ÉCRAN VIDE jusqu'à son
//  dernier exemple : « Que veux-tu savoir ? » et « ESSAIE » sortaient du cadre, le dernier exemple restait seul, estompé
//  par le fondu du haut. Un écran vide se lit depuis le haut ; seul un fil qui a des messages suit son bas.
//

import SwiftUI
import Testing
@testable import Triva

@Suite("Liste de la Recherche : l'écran vide se lit depuis le haut")
struct ChatScrollFollowingEmptyStateTests {
    private typealias Following = ChatScrollFollowing

    /// Le conteneur rétrécit (image collée dans la saisie) : le défilement possible grandit.
    private let before = Following.Metrics(offsetY: 0, contentHeight: 400, containerHeight: 380)
    private let after = Following.Metrics(offsetY: 0, contentHeight: 400, containerHeight: 300)

    @Test("Écran vide : un conteneur qui rétrécit ne fait PAS défiler vers le bas")
    func emptyStateDoesNotFollow() {
        #expect(!Following.shouldFollowContent(from: before, to: after, phase: .idle, isPinned: true, hasMessages: false))
        #expect(!Following.shouldFollowContent(from: before, to: after, phase: .animating, isPinned: true, hasMessages: false))
    }

    @Test("Avec des messages, le suivi du bas est inchangé")
    func conversationStillFollows() {
        #expect(Following.shouldFollowContent(from: before, to: after, phase: .idle, isPinned: true, hasMessages: true))
        #expect(Following.shouldFollowContent(from: before, to: after, phase: .idle, isPinned: true))
        #expect(!Following.shouldFollowContent(from: before, to: after, phase: .idle, isPinned: false, hasMessages: true))
        #expect(!Following.shouldFollowContent(from: before, to: after, phase: .interacting, isPinned: true, hasMessages: true))
    }

    @Test("La liste s'ouvre en haut sans message, en bas sinon")
    func initialAnchor() {
        #expect(Following.initialScrollAnchor(hasMessages: false) == .top)
        #expect(Following.initialScrollAnchor(hasMessages: true) == .bottom)
    }

    @Test("Quand le nombre de messages change : écran vide en haut, échange en cours en bas, conversation rouverte au début de la réponse")
    func countChange() {
        #expect(Following.action(afterMessageCountChange: false, hasMessages: false) == .showTop)
        #expect(Following.action(afterMessageCountChange: true, hasMessages: false) == .showTop)
        #expect(Following.action(afterMessageCountChange: true, hasMessages: true) == .followBottom)
        #expect(Following.action(afterMessageCountChange: false, hasMessages: true) == .showLastAnswerStart)
    }
}
