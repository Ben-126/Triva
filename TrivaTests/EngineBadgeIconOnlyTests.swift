//
//  EngineBadgeIconOnlyTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import SwiftUI
import Testing
@testable import Triva

/// Badge moteur réduit à son icône (mission E2c) : iPhone en paysage, texte AX3 ou plus, clavier
/// ouvert, et nulle part ailleurs. Mesures iPhone 18 Pro, paysage, AX3 : 260 pt offerts clavier
/// fermé, 100 pt clavier ouvert.
@MainActor
@Suite("Badge moteur en icône seule (E2c)")
struct EngineBadgeIconOnlyTests {

    private static let keyboardClosedHeight: CGFloat = 260
    private static let keyboardOpenHeight: CGFloat = 100

    private func iconOnly(
        compact: Bool = true,
        size: DynamicTypeSize = .accessibility3,
        height: CGFloat = EngineBadgeIconOnlyTests.keyboardOpenHeight
    ) -> Bool {
        EngineHeaderLayout.badgeIsIconOnly(isVerticallyCompact: compact, dynamicTypeSize: size, availableHeight: height)
    }

    @Test("Paysage, AX3, clavier ouvert : icône seule")
    func landscapeAX3KeyboardOpen() {
        #expect(iconOnly())
    }

    @Test("AX4 et AX5 aussi", arguments: [DynamicTypeSize.accessibility4, .accessibility5])
    func largerSizes(size: DynamicTypeSize) {
        #expect(iconOnly(size: size))
    }

    @Test("Clavier fermé : le badge garde son texte")
    func keyboardClosed() {
        #expect(!iconOnly(height: Self.keyboardClosedHeight))
    }

    @Test("Portrait, clavier fermé (700 pt) : le badge garde son texte")
    func portraitKeyboardClosed() {
        #expect(!iconOnly(compact: false, height: 700))
    }

    @Test("Portrait, AX3, clavier ouvert (440 pt, mission AX3) : icône seule")
    func portraitAX3KeyboardOpen() {
        #expect(iconOnly(compact: false, height: 440))
    }

    @Test("Portrait, sous AX3 ou grande hauteur (iPad, Mac) : le badge garde son texte")
    func portraitOtherCases() {
        #expect(!iconOnly(compact: false, size: .accessibility2, height: 440))
        #expect(!iconOnly(compact: false, height: 900))
    }

    @Test("Sous AX3 (AX1, AX2, tailles normales) : le badge garde son texte",
          arguments: [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility2])
    func belowAX3(size: DynamicTypeSize) {
        #expect(!iconOnly(size: size))
    }

    @Test("Hauteur pas encore mesurée (premier rendu) : le badge garde son texte", arguments: [CGFloat(0), 24, 39])
    func unmeasuredHeight(height: CGFloat) {
        #expect(!iconOnly(height: height))
    }

    @Test("Le seuil clavier tombe entre les deux mesures")
    func thresholdBetweenMeasures() {
        #expect(Self.keyboardOpenHeight < EngineHeaderLayout.keyboardOpenMaximumHeight)
        #expect(EngineHeaderLayout.keyboardOpenMaximumHeight < Self.keyboardClosedHeight)
    }
}
