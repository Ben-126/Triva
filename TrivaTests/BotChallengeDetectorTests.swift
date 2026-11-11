//
//  BotChallengeDetectorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// `URLFetching` minimal : une réponse HTTP 200 `text/html` fixe, via le
/// repli `streamBytes` de l'extension (suffisant, aucune borne à prouver ici).
private struct FixedPageFetcher: URLFetching {
    let html: String

    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ))
        return (Data(html.utf8), response)
    }
}

@MainActor
@Suite("BotChallengeDetector — pages de vérification anti-robot (mission A5)")
struct BotChallengeDetectorTests {
    // MARK: Fixtures (textes réels de ces pages de vérification)

    nonisolated static let anubisFrench = """
    <html lang="fr"><head><title>Je m’assure que vous n’êtes pas un robot !</title></head><body>\
    <h1 id="title">Je m’assure que vous n’êtes pas un robot !</h1>\
    <p>Merci de patienter un instant pendant que nous vérifions la sécurité de votre connexion.</p>\
    <p><small>Protégé par Anubis de Techaro. Hébergé par un administrateur de ce site.</small></p></body></html>
    """

    nonisolated static let anubisEnglish = """
    <html><head><title>Making sure you're not a bot!</title></head><body>\
    <h1>Making sure you're not a bot!</h1><p>Please wait a moment while we ensure the security of your connection.</p>\
    <p>Protected by Anubis from Techaro.</p></body></html>
    """

    nonisolated static let cloudflare = """
    <html><head><title>Just a moment...</title></head><body><div class="main-wrapper">\
    <h1>example.org</h1><h2>Checking your browser before accessing the website.</h2>\
    <p>Enable JavaScript and cookies to continue</p></div></body></html>
    """

    nonisolated static let cloudflareFrench = """
    <html><head><title>Un instant…</title></head><body><h1>exemple.org</h1>\
    <p>Vérification de sécurité en cours, veuillez patienter quelques secondes avant de poursuivre.</p></body></html>
    """

    nonisolated static let ddosGuard = """
    <html><head><title>DDoS-Guard</title></head><body><h1>Checking your browser before accessing example.net</h1>\
    <p>This process is automatic. Your browser will redirect to your requested content shortly.</p></body></html>
    """

    nonisolated static let paragraph = """
    La photosynthèse est le processus par lequel les plantes, les algues et certaines bactéries convertissent \
    l'énergie lumineuse en énergie chimique, en produisant du glucose et du dioxygène à partir d'eau et de dioxyde de carbone.
    """

    nonisolated static func realArticle(title: String = "Photosynthèse", extra: String = "") -> String {
        "<html><head><title>\(title)</title></head><body><div class=\"content\"><p>\(paragraph)</p><p>\(extra)</p></div></body></html>"
    }

    private func isChallenge(_ html: String) -> Bool {
        let (title, content) = ScrapeService.extractMainContent(fromHTML: html)
        return BotChallengeDetector.isChallenge(html: html, title: title, content: content)
    }

    // MARK: Détecteur pur

    @Test("Anubis, en français et en anglais, est reconnu", arguments: [anubisFrench, anubisEnglish])
    func anubis(html: String) {
        #expect(isChallenge(html))
    }

    @Test("Cloudflare (anglais et français) et DDoS-Guard sont reconnus", arguments: [cloudflare, cloudflareFrench, ddosGuard])
    func cloudflareAndDDoSGuard(html: String) {
        #expect(isChallenge(html))
    }

    @Test("Signature du HTML brut (_cf_chl_opt, anubis_version) : reconnue même si le texte visible semble banal")
    func rawSignature() {
        let cloudflareScript = "<html><head><title>exemple.org</title><script>window._cf_chl_opt={cvId:'3'};</script></head>"
            + "<body><p>\(Self.paragraph)</p></body></html>"
        let anubisScript = "<html><head><title>Accès</title><script id=\"anubis_version\" type=\"application/json\">\"1.15\"</script></head>"
            + "<body><p>\(Self.paragraph)</p></body></html>"
        #expect(isChallenge(cloudflareScript))
        #expect(isChallenge(anubisScript))
    }

    @Test("Un vrai article n'est pas pris pour un défi")
    func realArticleIsNotAChallenge() {
        #expect(!isChallenge(Self.realArticle()))
    }

    @Test("Un titre qui commence comme celui de Cloudflare mais est un vrai titre n'est pas un défi")
    func similarTitleIsNotAChallenge() {
        #expect(!isChallenge(Self.realArticle(title: "Un instant de bonheur")))
        #expect(!isChallenge(Self.realArticle(title: "Just a moment in time : histoire d'une chanson")))
    }

    @Test("Un long article dont le titre ressemble à celui d'une page de défi n'en est pas une", arguments: [
        "DDoS-Guard", "Un instant", "Just a moment...", "Attention Required",
    ])
    func longArticleWithChallengeLikeTitleIsNotAChallenge(title: String) {
        let extra = String(repeating: "Ce service protège des sites web contre les attaques par déni de service. ", count: 25)
        #expect(extra.count > BotChallengeDetector.maxChallengeContentCharacters)
        #expect(!isChallenge(Self.realArticle(title: title, extra: extra)))
    }

    @Test("Un long article qui PARLE de ces protections n'est pas un défi (phrases du corps seulement sur contenu court)")
    func longArticleMentioningChallengesIsNotAChallenge() {
        let extra = String(repeating: "Anubis est le dieu égyptien de l'embaumement. Techaro édite un logiciel libre. ", count: 30)
            + "Cloudflare affiche « Checking your browser before accessing » avant de laisser passer."
        #expect(extra.count > BotChallengeDetector.maxChallengeContentCharacters)
        #expect(!isChallenge(Self.realArticle(title: "Protections anti-robot", extra: extra)))
    }

    @Test("Le texte brut est décisif quand il est court, avec apostrophe typographique ou droite")
    func plainTextBodyPhrases() {
        #expect(BotChallengeDetector.isChallenge(html: "", title: "", content: "Je m’assure que vous n’êtes pas un robot. Merci de patienter."))
        #expect(BotChallengeDetector.isChallenge(html: "", title: "", content: "Je m'assure que vous n'êtes pas un robot. Merci de patienter."))
        #expect(!BotChallengeDetector.isChallenge(html: "", title: "Bienvenue", content: Self.paragraph))
    }

    // MARK: Intégration avec le scraping

    @Test("scrape : une page de vérification donne une page en échec, non citable, au contenu vide")
    func scrapeReturnsFailedPage() async {
        for html in [Self.anubisFrench, Self.anubisEnglish, Self.cloudflare, Self.cloudflareFrench, Self.ddosGuard] {
            let page = await ScrapeService(fetcher: FixedPageFetcher(html: html)).scrape(url: "https://exemple.org/article")
            #expect(!page.succeeded)
            #expect(page.content.isEmpty)
            #expect(page.title == "https://exemple.org/article")
        }
    }

    @Test("scrape : témoin positif, un vrai article du même site reste un succès")
    func scrapeKeepsRealArticle() async {
        let page = await ScrapeService(fetcher: FixedPageFetcher(html: Self.realArticle())).scrape(url: "https://exemple.org/article")
        #expect(page.succeeded)
        #expect(page.title == "Photosynthèse")
        #expect(page.content.contains("photosynthèse"))
    }
}
