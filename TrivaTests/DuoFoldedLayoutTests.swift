//
//  DuoFoldedLayoutTests.swift
//  TrivaTests
//
//  Mission I1 (2.0, iPhone Duo plié) : règles pures de mise en page, aux tailles réelles.
//  Duo plié 466 x 678 pt ; iPhone 18 Pro 402 x 874 pt ; iPad Pro 13" 1032 x 1376 pt.
//

import SwiftUI
import Testing
@testable import Triva

@MainActor
@Suite("Duo plié — en-tête moteur (P5)")
struct DuoEngineHeaderTests {
    private func collapsed(height: CGFloat, sizeClass: UserInterfaceSizeClass?, messages: Bool = true, hasHinge: Bool = true) -> Bool {
        EngineHeaderLayout.isCollapsed(
            availableHeight: height,
            hasMessages: messages,
            needsSetup: false,
            isAccessibilitySize: false,
            horizontalSizeClass: sizeClass,
            hasHinge: hasHinge
        )
    }

    /// Hauteur MESURÉE de l'écran de Recherche clavier fermé : voir le rapport I1.
    private static let duoFoldedHeight: CGFloat = 562
    private static let iPhone18ProHeight: CGFloat = 675

    @Test("Compact, hauteur du Duo plié, une conversation : l'en-tête se replie")
    func foldedDuoCollapsesWithAConversation() {
        #expect(collapsed(height: Self.duoFoldedHeight, sizeClass: .compact))
    }

    @Test("Compact SANS charnière (iPad Split View, petit iPhone) à 580 pt : déplié, seuil historique (C6)")
    func compactWithoutHingeKeepsTheHistoricalThreshold() {
        #expect(!collapsed(height: 580, sizeClass: .compact, hasHinge: false))
        #expect(!collapsed(height: Self.duoFoldedHeight, sizeClass: .compact, hasHinge: false))
        #expect(collapsed(height: 559, sizeClass: .compact, hasHinge: false))
        #expect(!collapsed(height: 560, sizeClass: .compact, hasHinge: false))
    }

    @Test("Compact, hauteur de l'iPhone 18 Pro : l'en-tête reste déplié (inchangé)")
    func iPhone18ProKeepsItsHeader() {
        #expect(!collapsed(height: Self.iPhone18ProHeight, sizeClass: .compact))
    }

    @Test("Regular 650 pt avec une conversation : déplié (iPad et Duo déplié inchangés)")
    func regularKeepsTheHeaderAt650() {
        #expect(!collapsed(height: 650, sizeClass: .regular))
    }

    @Test("Sans classe de taille (Mac) 650 pt : déplié")
    func nilKeepsTheHeaderAt650() {
        #expect(!collapsed(height: 650, sizeClass: nil))
    }

    @Test("Regular et nil gardent le seuil historique de 560 pt")
    func regularAndNilKeepTheHistoricalThreshold() {
        #expect(collapsed(height: 559, sizeClass: .regular))
        #expect(!collapsed(height: 560, sizeClass: .regular))
        #expect(collapsed(height: 559, sizeClass: nil))
        #expect(!collapsed(height: 560, sizeClass: nil))
    }

    @Test("Le seuil compact est juste au-dessus de 560 et sous l'iPhone 18 Pro")
    func compactThresholdBounds() {
        #expect(EngineHeaderLayout.compactConversationMinimumHeight > EngineHeaderLayout.conversationMinimumHeight)
        #expect(EngineHeaderLayout.compactConversationMinimumHeight < Self.iPhone18ProHeight)
    }

    @Test("Écran vide : le seuil compact ne s'applique pas (seule une conversation replie plus tôt)")
    func emptyScreenIsUnchanged() {
        #expect(!collapsed(height: Self.duoFoldedHeight, sizeClass: .compact, messages: false))
        #expect(collapsed(height: 359, sizeClass: .compact, messages: false))
    }
}

@MainActor
@Suite("Duo plié — boutons du premier lancement (P8)")
struct OnboardingActionPlacementTests {
    @Test("Le contenu et les boutons ne tiennent pas ensemble : épinglés")
    func overflowPins() {
        #expect(OnboardingActionPlacement.isPinned(contentHeight: 620, actionsHeight: 140, viewportHeight: 678))
    }

    @Test("Tout tient : les boutons restent à leur place")
    func fitDoesNotPin() {
        #expect(!OnboardingActionPlacement.isPinned(contentHeight: 500, actionsHeight: 140, viewportHeight: 678))
    }

    @Test("Bornes : égalité = tient ; un point de plus = déborde")
    func boundaries() {
        #expect(!OnboardingActionPlacement.isPinned(contentHeight: 538, actionsHeight: 140, viewportHeight: 678))
        #expect(OnboardingActionPlacement.isPinned(contentHeight: 539, actionsHeight: 140, viewportHeight: 678))
    }

    @Test("Rien de mesuré : jamais épinglés (pas d'oscillation au premier rendu)")
    func unmeasuredNeverPins() {
        #expect(!OnboardingActionPlacement.isPinned(contentHeight: 0, actionsHeight: 140, viewportHeight: 678))
        #expect(!OnboardingActionPlacement.isPinned(contentHeight: 900, actionsHeight: 0, viewportHeight: 678))
        #expect(!OnboardingActionPlacement.isPinned(contentHeight: 900, actionsHeight: 140, viewportHeight: 0))
        #expect(!OnboardingActionPlacement.isPinned(contentHeight: 900, actionsHeight: 140, viewportHeight: 24))
    }

    @Test("iPad : un contenu bien plus bas que l'écran ne déborde pas")
    func iPadDoesNotPin() {
        #expect(!OnboardingActionPlacement.isPinned(contentHeight: 700, actionsHeight: 140, viewportHeight: 1_376))
    }
}

@MainActor
@Suite("Duo plié — « Fermer le clavier » (P9)")
struct ComposerKeyboardLayoutTests {
    @Test("Duo plié, clavier ouvert (220 pt mesurés) : le bouton est montré ; fermé (504 pt) : non")
    func shownOnTheFoldedDuo() {
        #expect(ComposerKeyboardLayout.showsDismissButton(hasHinge: true, isVerticallyCompact: false, availableHeight: 220))
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: true, isVerticallyCompact: false, availableHeight: 504))
    }

    @Test("Sans charnière (iPad en Split View, petit iPhone, Mac), même à 220 pt : jamais")
    func neverShownWithoutHinge() {
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: false, isVerticallyCompact: false, availableHeight: 220))
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: false, isVerticallyCompact: false, availableHeight: 100))
    }

    @Test("iPhone 18 Pro portrait, clavier ouvert (285 pt mesurés) ou fermé (544 pt) : rien n'est ajouté")
    func notShownOnAnOrdinaryIPhone() {
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: true, isVerticallyCompact: false, availableHeight: 285))
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: true, isVerticallyCompact: false, availableHeight: 544))
    }

    @Test("Hauteur compacte (iPhone en paysage) : jamais")
    func notShownWhenVerticallyCompact() {
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: true, isVerticallyCompact: true, availableHeight: 100))
    }

    @Test("Hauteur pas encore mesurée : jamais")
    func notShownBeforeMeasure() {
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: true, isVerticallyCompact: false, availableHeight: 0))
        #expect(!ComposerKeyboardLayout.showsDismissButton(hasHinge: true, isVerticallyCompact: false, availableHeight: 24))
    }
}
