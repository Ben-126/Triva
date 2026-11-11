//
//  PromptTemplatesNumberedContextTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 10/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Mission A1 : un document sans contenu (ni extrait, ni page lue) n'est plus
/// montré au rédacteur, et garde son numéro (invariant `sources[i]` = `[i + 1]`).
/// Rapport T2, scénario t7 : « [2] www.ryzlabs.com — URL » suffisait à une
/// réponse écrite de tête, citée sur des pages jamais lues.
@MainActor
@Suite("PromptTemplates — contexte numéroté, documents sans contenu (mission A1)")
struct PromptTemplatesNumberedContextTests {
    private static func source(_ name: String, content: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: "Titre \(name)", url: "https://\(name).example", content: content,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    private static func page(_ name: String, content: String = "Texte lu sur la page.", succeeded: Bool = true) -> ScrapedPage {
        ScrapedPage(url: "https://\(name).example", title: "Page \(name)", content: content, succeeded: succeeded)
    }

    @Test("Source sans extrait ni page lue : omise (ni titre ni URL), numéro sauté, note de trou en tête")
    func documentWithoutContentIsOmittedWithoutRenumbering() {
        let sources = [Self.source("a", content: "Extrait A"), Self.source("b", content: nil), Self.source("c", content: "Extrait C")]

        let context = PromptTemplates.numberedContext(sources: sources)

        #expect(context.hasPrefix(PromptTemplates.numberingGapNote + "\n\n[1] Titre a — https://a.example"))
        #expect(context.contains("[3] Titre c — https://c.example\nExtrait : Extrait C"))
        #expect(!context.contains("[2]"))
        #expect(!context.contains("Titre b"))
        #expect(!context.contains("https://b.example"))
        // Plus grand numéro citable, pas un compte : [3] doit rester valide pour le validateur.
        #expect(PromptTemplates.citableDocumentCount(sources: sources) == 3)
        #expect(PromptTemplates.uncitableDocumentNumbers(sources: sources) == [2])
    }

    @Test("Extrait fait de seuls blancs : comme aucun extrait")
    func blankExcerptCountsAsNoContent() {
        let sources = [Self.source("a", content: " \n\t "), Self.source("b", content: "Extrait B")]

        #expect(PromptTemplates.uncitableDocumentNumbers(sources: sources) == [1])
        #expect(!PromptTemplates.numberedContext(sources: sources).contains("Titre a"))
    }

    @Test("Source sans extrait dont la page a été lue : citable à son rang ; page en échec : reste non citable")
    func readPageMakesASourceCitable() {
        let sources = [Self.source("a", content: nil), Self.source("b", content: nil), Self.source("c", content: "Extrait C")]
        let pages = [Self.page("a"), Self.page("b", content: "", succeeded: false)]

        let context = PromptTemplates.numberedContext(sources: sources, scrapedPages: pages)

        #expect(context.contains("[1] Titre a — https://a.example\nContenu de la page : Texte lu sur la page."))
        #expect(!context.contains("Titre b"))
        #expect(context.contains("[3] Titre c"))
        #expect(PromptTemplates.citableDocumentCount(sources: sources, scrapedPages: pages) == 3)
        #expect(PromptTemplates.uncitableDocumentNumbers(sources: sources, scrapedPages: pages) == [2])
    }

    @Test("Seul le dernier document est illisible : numérotation continue, donc aucune note")
    func trailingUnreadableDocumentAddsNoGapNote() {
        let sources = [Self.source("a", content: "Extrait A"), Self.source("b", content: nil)]

        let context = PromptTemplates.numberedContext(sources: sources)

        #expect(context == "[1] Titre a — https://a.example\nExtrait : Extrait A")
        #expect(PromptTemplates.citableDocumentCount(sources: sources) == 1)
        #expect(PromptTemplates.uncitableDocumentNumbers(sources: sources) == [2])
    }

    @Test("Toutes les sources illisibles : exactement « Aucune source disponible. », zéro document citable")
    func allUnreadableSourcesGiveTheNoSourcesContext() {
        let sources = [Self.source("a", content: nil), Self.source("b", content: "")]

        #expect(PromptTemplates.numberedContext(sources: sources) == PromptTemplates.noSourcesContext)
        #expect(PromptTemplates.citableDocumentCount(sources: sources) == 0)
        #expect(PromptTemplates.uncitableDocumentNumbers(sources: sources) == [1, 2])
    }

    @Test("Sans document illisible : contexte identique à celui d'avant A1, aucune note, aucun numéro non citable")
    func continuousContextIsUnchanged() {
        let sources = [Self.source("a", content: "Extrait A"), Self.source("b", content: "Extrait B")]

        #expect(PromptTemplates.numberedContext(sources: sources)
            == "[1] Titre a — https://a.example\nExtrait : Extrait A\n\n[2] Titre b — https://b.example\nExtrait : Extrait B")
        #expect(PromptTemplates.citableDocumentCount(sources: sources) == 2)
        #expect(PromptTemplates.uncitableDocumentNumbers(sources: sources).isEmpty)
    }

    @Test("Le budget des pages n'est partagé qu'entre les documents montrés")
    func scrapedBudgetIgnoresOmittedDocuments() {
        let long = String(repeating: "a", count: 300)
        let sources = [Self.source("a", content: nil), Self.source("b", content: nil)]
        let pages = [Self.page("a", content: long), Self.page("b", content: "", succeeded: false)]

        let context = PromptTemplates.numberedContext(sources: sources, scrapedPages: pages, maxScrapedContextCharacters: 200)

        // Un seul document lu : il reçoit tout le budget (200), pas la moitié.
        #expect(context.contains("Contenu de la page : \(String(repeating: "a", count: 200))"))
        #expect(!context.contains(String(repeating: "a", count: 201)))
    }
}
