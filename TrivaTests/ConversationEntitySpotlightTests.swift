//
//  ConversationEntitySpotlightTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : ce qu'une conversation donne à Spotlight : son titre et sa date, jamais son contenu.
//

import AppIntents
import CoreSpotlight
import Foundation
import Testing
@testable import Triva

@Suite("Spotlight : attributs d'une conversation")
struct ConversationEntitySpotlightTests {
    private let entity = ConversationEntity(
        id: UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!,
        title: "Recette de crêpes",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    @Test("Le titre et la date de dernière modification sont donnés à Spotlight")
    func titleAndDate() {
        let attributes = entity.attributeSet
        #expect(attributes.title == "Recette de crêpes")
        #expect(attributes.displayName == "Recette de crêpes")
        #expect(attributes.contentModificationDate == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Aucun contenu de conversation n'est donné : pas de texte, pas de mots-clés")
    func noContent() {
        let attributes = entity.attributeSet
        #expect(attributes.textContent == nil)
        #expect(attributes.keywords == nil)
    }

    @Test("La conversation n'est pas masquée de Spotlight")
    func notHidden() {
        #expect(entity.hideInSpotlight == false)
    }
}
