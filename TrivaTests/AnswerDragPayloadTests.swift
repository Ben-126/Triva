//
//  AnswerDragPayloadTests.swift
//  TrivaTests
//
//  Chantier 2.2 (G2), glisser sortant : la charge d'une réponse garde la mention « générée par IA », celle
//  d'une source est son adresse web, et rien ne part pour une pièce jointe. Logique pure, sans interface.
//

import Testing
import Foundation
@testable import Triva

struct AnswerDragPayloadTests {
    private func source(_ title: String, _ url: String) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: nil,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    // MARK: Réponse

    @Test("Le texte glissé est exactement le texte de Copier / Partager, mention comprise")
    func draggedTextIsTheShareText() throws {
        let shareText = try #require(AnswerShareText.text(
            tldr: "En bref.", body: "Détail[1].", sources: [source("Wikipédia", "https://fr.wikipedia.org/wiki/Tokyo")]
        ))
        let dragged = try #require(AnswerDragPayload.text(fromShareText: shareText))
        #expect(dragged == shareText)
        #expect(dragged.hasSuffix(AIGeneratedMarking.footer))
        #expect(dragged.contains("[1] Wikipédia — https://fr.wikipedia.org/wiki/Tokyo"))
    }

    @Test("Un texte sans la mention ne part pas : aucun chemin ne contourne le marquage")
    func unmarkedTextIsRefused() {
        #expect(AnswerDragPayload.text(fromShareText: "Tokyo est la capitale du Japon.") == nil)
        #expect(AnswerDragPayload.text(fromShareText: "") == nil)
        // La mention au milieu du texte ne suffit pas : elle doit le terminer.
        #expect(AnswerDragPayload.text(fromShareText: "\(AIGeneratedMarking.footer)\n\nSuite") == nil)
    }

    @Test("Un texte marqué suivi d'espaces ou d'un saut de ligne part tel quel")
    func trailingWhitespaceAfterMarkingIsAccepted() throws {
        let marked = AIGeneratedMarking.marked("Bonjour") + "\n"
        #expect(AnswerDragPayload.text(fromShareText: marked) == marked)
    }

    @Test("L'extrait de l'image de glisser : premier paragraphe, sans la mention ni les sources, borné")
    func previewExcerpt() throws {
        let shareText = try #require(AnswerShareText.text(
            tldr: "En bref.", body: "Détail.", sources: [source("Site", "https://site.example")]
        ))
        #expect(AnswerDragPayload.previewExcerpt(of: shareText) == "En bref.")

        let long = String(repeating: "mot ", count: 100)
        let excerpt = AnswerDragPayload.previewExcerpt(of: AIGeneratedMarking.marked(long))
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.count <= AnswerDragPayload.previewLimit + 1)
        #expect(!excerpt.contains(AIGeneratedMarking.footer))
    }

    @Test("La poignée n'est proposée ni sur iPhone ; elle l'est sur Mac et iPad")
    func handleIsNotOfferedOnPhone() {
        #expect(AnswerDragPayload.offersHandle(isPhone: true) == false)
        #expect(AnswerDragPayload.offersHandle(isPhone: false) == true)
    }

    // MARK: Sources

    @Test("Une source web emporte son adresse, http et https seulement")
    func webSourceCarriesItsURL() {
        #expect(SourceDragPayload.url(for: source("A", "https://fr.wikipedia.org/wiki/Tokyo"))
            == URL(string: "https://fr.wikipedia.org/wiki/Tokyo"))
        #expect(SourceDragPayload.url(for: source("B", "http://exemple.fr/page")) == URL(string: "http://exemple.fr/page"))
        for unsafe in ["facetime://x", "tel://0102030405", "shortcuts://run-shortcut", "mailto:a@b.fr", "javascript:alert(1)", "file:///etc/hosts", "pas une url"] {
            #expect(SourceDragPayload.url(for: source("C", unsafe)) == nil, "« \(unsafe) » ne doit pas être glissable")
        }
    }

    @Test("Une pièce jointe n'emporte rien : le fichier est à l'utilisateur")
    func attachmentCarriesNothing() {
        let attachment = source("rapport.pdf", UploadsSearchResultBuilder.sourceURL(for: UUID()))
        #expect(SourceDragPayload.url(for: attachment) == nil)
    }
}
