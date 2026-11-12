//
//  MissionC2PresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Textes et règles d'affichage de la mission C2 : ce qui est écrit à l'écran doit rester vrai.
@MainActor
@Suite("Mission C2 — textes vrais à l'écran")
struct MissionC2PresentationTests {
    @Test("La carte Clé API dit où vont les questions et où reste la clé, sans promettre « uniquement sur cet appareil »")
    func cloudKeyCardIsTruthful() {
        let text = AIEngineSelectionView.cloudKeyCardSubtitle
        #expect(text.contains("Payant"))
        #expect(text.contains("envoyées"))
        #expect(text.contains("Trousseau"))
        #expect(!text.contains("uniquement sur cet appareil"))
    }

    @Test("Le catalogue MLX ne contient plus de jargon (MoE, paramètres actifs, token)")
    func catalogHasNoJargon() throws {
        let catalog = try MLXModelCatalog.load()
        #expect(!catalog.isEmpty)
        for entry in catalog {
            let texts = [entry.displayName, entry.summary] + entry.strengths + entry.tradeoffs
            for text in texts {
                #expect(!text.contains("MoE"), "\(entry.id) : \(text)")
                #expect(!text.contains("par token"), "\(entry.id) : \(text)")
                #expect(!text.contains("paramètres actifs"), "\(entry.id) : \(text)")
            }
        }
    }

    @Test("Le catalogue écrit ses tailles en « Go » comme l'interface, jamais « GB »")
    func catalogSizesUseFrenchUnits() throws {
        let catalog = try MLXModelCatalog.load()
        for entry in catalog {
            for text in entry.tradeoffs + [entry.summary] {
                #expect(!text.contains(" GB"), "\(entry.id) : \(text)")
            }
        }
    }
}
