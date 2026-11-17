//
//  AnswerShareTextTests.swift
//  TrivaTests
//
//  Mission C5 : Copier / Partager marquent TOUJOURS la réponse comme générée par IA ; la mention
//  « clé API payante » est une seule constante, texte exact validé par Ben.
//

import Testing
import Foundation
@testable import Triva

struct AnswerShareTextTests {
    private func source(_ title: String, _ url: String) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: nil,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    @Test("Le texte copié ou partagé se termine par la mention « générée par IA »")
    func textCarriesTheMarking() throws {
        let text = try #require(AnswerShareText.text(tldr: nil, body: "Tokyo est la capitale du Japon[1].", sources: []))
        #expect(text.hasSuffix(AIGeneratedMarking.footer))
        #expect(text.hasPrefix("Tokyo est la capitale du Japon[1]."))
    }

    @Test("TL;DR puis corps, sources numérotées comme les renvois, mention en dernier ; jamais de double marquage")
    func tldrBodySourcesThenMarking() throws {
        let text = try #require(AnswerShareText.text(
            tldr: "En bref.", body: "Détail[1][2].",
            sources: [source("Wikipédia", "https://fr.wikipedia.org/wiki/Tokyo"), source("Autre", "https://autre.example")]
        ))
        #expect(text == """
        En bref.

        Détail[1][2].

        [1] Wikipédia — https://fr.wikipedia.org/wiki/Tokyo
        [2] Autre — https://autre.example

        \(AIGeneratedMarking.footer)
        """)
        #expect(text.components(separatedBy: AIGeneratedMarking.footer).count == 2)
    }

    @Test("Un fichier joint n'apparaît pas dans les sources copiées, les numéros restent ceux des renvois")
    func attachmentsAreNotListedAndNumbersAreKept() throws {
        let attachment = source("rapport.pdf", UploadsSearchResultBuilder.sourceURL(for: UUID()))
        let text = try #require(AnswerShareText.text(
            tldr: nil, body: "Texte[2].", sources: [attachment, source("Site", "https://site.example")]
        ))
        #expect(!text.contains("rapport.pdf"))
        #expect(text.contains("[2] Site — https://site.example"))
    }

    @Test("Sans texte, rien à copier ; les boutons ne sont offerts que sous une réponse terminée")
    func nothingToShareWithoutText() {
        #expect(AnswerShareText.text(tldr: nil, body: "  \n", sources: []) == nil)
        #expect(AnswerShareText.text(tldr: " ", body: "", sources: []) == nil)
        #expect(AnswerShareText.isOffered(state: .completed, hasText: true))
        #expect(!AnswerShareText.isOffered(state: .completed, hasText: false))
        #expect(!AnswerShareText.isOffered(state: .streaming, hasText: true))
        #expect(!AnswerShareText.isOffered(state: .failed, hasText: true))
        #expect(!AnswerShareText.isOffered(state: .noReliableSources, hasText: false))
    }

    @Test("Mention « clé API payante » : texte exact validé par Ben, une seule constante")
    func paidKeyNoticeIsTheValidatedText() {
        #expect(PaidKeyNotice.text == "Avec ta propre clé, chaque question est payée chez le fournisseur (OpenAI, Anthropic…), sur ton compte chez lui. Triva est gratuite et ne reçoit jamais d'argent. Apple Intelligence et les modèles sur l'appareil sont gratuits.")
    }

    @Test("La fiche d'une citation montre la même mention de licence que la liste des sources")
    func citationCardUsesTheSameLicense() {
        let wikipedia = source("Tokyo", "https://fr.wikipedia.org/wiki/Tokyo")
        let license = SourcesListPresentation.licenseAttribution(for: wikipedia)
        #expect(license?.licenseName == "CC BY-SA 4.0")
        #expect(SourcesListPresentation.licenseAttribution(for: source("Autre", "https://autre.example")) == nil)
    }

    @Test("Métadonnée de provenance du bouton Copier : type personnalisé et JSON IPTC « trainedAlgorithmicMedia »")
    func provenanceMetadata() throws {
        #expect(AIProvenanceMetadata.pasteboardType == "app.triva.ai-provenance")
        let object = try #require(try JSONSerialization.jsonObject(with: AIProvenanceMetadata.jsonData()) as? [String: String])
        #expect(object == [
            "generator": "Triva",
            "digitalSourceType": "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia",
        ])
    }
}
