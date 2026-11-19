//
//  DuoPaneLayoutTests.swift
//  TrivaTests
//
//  Mission I2 (2.0, iPhone Duo déplié) : nombre de volets, barre latérale initiale, réponse ciblée par le
//  volet de sources, et ce que le coordinateur garde de ces choix. Tailles réelles : Duo plié 466 x 678,
//  déplié 669 x 951 (portrait) et 951 x 669 (paysage, environ 870 pt de large une fois les barres sur le côté).
//

import SwiftUI
import Testing
@testable import Triva

@Suite("Duo déplié — DuoPaneLayout.columnCount")
struct DuoPaneColumnCountTests {
    private func columns(
        hinge: Bool, h: UserInterfaceSizeClass?, v: UserInterfaceSizeClass? = .regular, width: CGFloat
    ) -> Int {
        DuoPaneLayout.columnCount(hasHinge: hinge, horizontalSizeClass: h, verticalSizeClass: v, detailWidth: width)
    }

    @Test("iPad 13 pouces en paysage, sans charnière : une colonne, même à 1046 pt")
    func ipadLandscape() { #expect(columns(hinge: false, h: .regular, width: 1046) == 1) }

    @Test("Mac, sans charnière ni classe de taille : une colonne")
    func mac() { #expect(columns(hinge: false, h: nil, v: nil, width: 1200) == 1) }

    @Test("iPhone Pro Max en paysage, sans charnière : une colonne")
    func iphoneProMaxLandscape() { #expect(columns(hinge: false, h: .regular, v: .compact, width: 860) == 1) }

    @Test("Duo déplié en paysage, barre latérale masquée (870 pt) : deux colonnes")
    func duoLandscapeSidebarHidden() { #expect(columns(hinge: true, h: .regular, width: 870) == 2) }

    @Test("Duo déplié en paysage, barre latérale visible (environ 600 pt) : une colonne")
    func duoLandscapeSidebarShown() { #expect(columns(hinge: true, h: .regular, width: 600) == 1) }

    @Test("Duo déplié en portrait (669 pt) : une colonne")
    func duoPortrait() { #expect(columns(hinge: true, h: .regular, width: 669) == 1) }

    @Test("Duo plié (compact), même large : une colonne")
    func duoFolded() {
        #expect(columns(hinge: true, h: .compact, v: .regular, width: 466) == 1)
        #expect(columns(hinge: true, h: .compact, v: .compact, width: 678) == 1)
    }

    @Test("Duo paysage avec une hauteur compacte (870 pt) : deux colonnes, la classe verticale ne bloque pas")
    func duoLandscapeVerticallyCompact() { #expect(columns(hinge: true, h: .regular, v: .compact, width: 870) == 2) }

    @Test("Bornes : 700 pt est le plus petit détail à deux colonnes")
    func boundary() {
        let minimum = 2 * DuoPaneLayout.minimumPaneWidth + DuoPaneLayout.paneSpacing
        #expect(columns(hinge: true, h: .regular, width: minimum) == 2)
        #expect(columns(hinge: true, h: .regular, width: minimum - 1) == 1)
        #expect(columns(hinge: true, h: .regular, width: 0) == 1)
    }
}

@Suite("Duo déplié — barre latérale masquée à l'arrivée")
struct DuoInitialSidebarTests {
    private func hidden(hinge: Bool, h: UserInterfaceSizeClass?, width: CGFloat, height: CGFloat) -> Bool {
        DuoPaneLayout.initialSidebarHidden(hasHinge: hinge, horizontalSizeClass: h, windowWidth: width, windowHeight: height)
    }

    @Test("Vrai seulement pour le Duo déplié en paysage (951 x 669)")
    func duoUnfoldedLandscape() { #expect(hidden(hinge: true, h: .regular, width: 951, height: 669)) }

    @Test("Faux : Duo déplié en portrait (669 x 951)")
    func duoUnfoldedPortrait() { #expect(!hidden(hinge: true, h: .regular, width: 669, height: 951)) }

    @Test("Faux : Duo plié en paysage (678 x 466, classe compacte)")
    func duoFoldedLandscape() { #expect(!hidden(hinge: true, h: .compact, width: 678, height: 466)) }

    @Test("Faux : iPad et Mac (pas de charnière), même en paysage")
    func ipadAndMac() {
        #expect(!hidden(hinge: false, h: .regular, width: 1366, height: 1024))
        #expect(!hidden(hinge: false, h: nil, width: 1440, height: 900))
    }

    @Test("Faux tant que la fenêtre n'est pas mesurée (0 x 0)")
    func notMeasured() { #expect(!hidden(hinge: true, h: .regular, width: 0, height: 0)) }
}

@Suite("Duo déplié — réponse ciblée par le volet de sources")
struct SourcesPaneFocusTests {
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()

    @Test("Par défaut : la dernière réponse")
    func defaultsToLastAnswer() {
        #expect(SourcesPaneFocus.answerID(focusedID: nil, answerIDs: [first, second, third]) == third)
    }

    @Test("Une citation touchée cible sa réponse")
    func focusedAnswerWins() {
        #expect(SourcesPaneFocus.answerID(focusedID: first, answerIDs: [first, second, third]) == first)
    }

    @Test("Une réponse ciblée qui n'est plus dans le fil (nouvelle conversation) retombe sur la dernière")
    func staleFocusFallsBack() {
        #expect(SourcesPaneFocus.answerID(focusedID: UUID(), answerIDs: [second, third]) == third)
    }

    @Test("Aucune réponse : rien")
    func noAnswer() {
        #expect(SourcesPaneFocus.answerID(focusedID: nil, answerIDs: []) == nil)
        #expect(SourcesPaneFocus.answerID(focusedID: first, answerIDs: []) == nil)
    }
}

private struct PaneTestKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { "sk-test" }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@MainActor
private func makePaneStores() throws -> TrivaSharedStores {
    let userDefaults = try #require(TestDefaults.suite(named: "test.duoPane.\(UUID().uuidString)"))
    return TrivaSharedStores(
        userDefaults: userDefaults,
        container: try TrivaModelContainer.makeInMemory(),
        isHistoryStorageVolatile: false,
        searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: userDefaults),
        keyStore: PaneTestKeyStore()
    )
}

@MainActor
@Suite("Duo déplié — barre latérale tenue par le coordinateur")
struct DuoPaneStateTests {
    @Test("Barre latérale : masquée une seule fois à l'arrivée du Duo déplié en paysage, puis le choix est respecté")
    func sidebarHiddenOnlyOnce() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makePaneStores())
        coordinator.hasHinge = true
        #expect(coordinator.columnVisibility == .all)

        // Portrait déplié : rien.
        #expect(!coordinator.applyInitialSidebarIfNeeded(horizontalSizeClass: .regular, windowSize: CGSize(width: 669, height: 951)))
        #expect(coordinator.columnVisibility == .all)

        // Paysage déplié : masquée.
        #expect(coordinator.applyInitialSidebarIfNeeded(horizontalSizeClass: .regular, windowSize: CGSize(width: 951, height: 669)))
        #expect(coordinator.columnVisibility == .detailOnly)

        // L'utilisateur la rouvre ; un nouveau passage en paysage ne la masque pas de nouveau.
        coordinator.columnVisibility = .all
        #expect(!coordinator.applyInitialSidebarIfNeeded(horizontalSizeClass: .regular, windowSize: CGSize(width: 951, height: 669)))
        #expect(coordinator.columnVisibility == .all)
    }

    @Test("Sans charnière (iPad, Mac) : la barre latérale n'est jamais masquée")
    func noHingeNeverHides() throws {
        let coordinator = TrivaRootCoordinator(engine: .appleIntelligence, stores: try makePaneStores())
        #expect(!coordinator.hasHinge)
        #expect(!coordinator.applyInitialSidebarIfNeeded(horizontalSizeClass: .regular, windowSize: CGSize(width: 1366, height: 1024)))
        #expect(coordinator.columnVisibility == .all)
    }
}

@MainActor
@Suite("Duo déplié — volet de sources : réponse ciblée (C3)")
struct SourcesPaneFollowsLastAnswerTests {
    @Test("Une réponse NOUVELLE fait oublier la réponse ciblée : le volet suit la dernière réponse")
    func newAnswerClearsTheFocus() {
        let state = TranscriptScrollState()
        let first = UUID(), second = UUID()
        state.noteLastAnswer(first)
        state.focusedAnswerID = first

        state.noteLastAnswer(second)

        #expect(state.focusedAnswerID == nil)
        #expect(SourcesPaneFocus.answerID(focusedID: state.focusedAnswerID, answerIDs: [first, second]) == second)
    }

    @Test("La même réponse signalée de nouveau (remontage de la vue au pliage) garde la réponse ciblée")
    func sameAnswerKeepsTheFocus() {
        let state = TranscriptScrollState()
        let first = UUID(), second = UUID()
        state.noteLastAnswer(second)
        state.focusedAnswerID = first

        state.noteLastAnswer(second)

        #expect(state.focusedAnswerID == first)
    }

    @Test("Une citation touchée APRÈS l'arrivée de la réponse est respectée, puis la question de suite la remplace")
    func tappedCitationThenFollowUp() {
        let state = TranscriptScrollState()
        let first = UUID(), second = UUID()
        state.noteLastAnswer(first)
        state.focusedAnswerID = first
        #expect(SourcesPaneFocus.answerID(focusedID: state.focusedAnswerID, answerIDs: [first]) == first)

        state.noteLastAnswer(second)
        #expect(SourcesPaneFocus.answerID(focusedID: state.focusedAnswerID, answerIDs: [first, second]) == second)
    }

    @Test("Fil vidé (nouvelle conversation) : plus de réponse, plus de ciblage")
    func emptiedThreadClearsTheFocus() {
        let state = TranscriptScrollState()
        let first = UUID()
        state.noteLastAnswer(first)
        state.focusedAnswerID = first

        state.noteLastAnswer(nil)

        #expect(state.focusedAnswerID == nil)
    }
}

@Suite("Favoris — retirer un favori referme-t-il le détail ? (C1)")
struct FavoriteDetailClosingTests {
    private let opened = UUID()
    private let other = UUID()

    @Test("Deux volets : retirer UN AUTRE favori laisse le détail ouvert")
    func removingAnotherKeepsTheDetail() {
        #expect(!FavoriteDetailClosing.closesDetail(removing: other, opened: opened, hasPushedRoute: true))
    }

    @Test("Retirer le favori ouvert referme le détail")
    func removingTheOpenedOneClosesIt() {
        #expect(FavoriteDetailClosing.closesDetail(removing: opened, opened: opened, hasPushedRoute: true))
    }

    @Test("Aucun favori ouvert et rien de poussé : rien à refermer")
    func nothingOpenNothingToClose() {
        #expect(!FavoriteDetailClosing.closesDetail(removing: other, opened: nil, hasPushedRoute: false))
    }

    @Test("Pile : détail poussé pas encore recopié dans la sélection, c'est forcément le favori retiré")
    func pushedRouteWithoutSelectionIsTheRemovedOne() {
        #expect(FavoriteDetailClosing.closesDetail(removing: other, opened: nil, hasPushedRoute: true))
    }
}
