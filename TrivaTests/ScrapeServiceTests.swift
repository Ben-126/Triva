//
//  ScrapeServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 14/09/2026.
//

import Testing
import Foundation
@testable import Triva

private enum MockFetchError: Error, Sendable {
    case network
    case timeout
}

/// `URLFetching` factice : simule un statut HTTP + Content-Type + corps
/// donnés, ou une erreur de transport — sans réseau réel ni `URLProtocol`
/// personnalisé.
private struct MockURLFetching: URLFetching {
    enum Behavior: Sendable {
        case success(data: Data, statusCode: Int, contentType: String)
        case failure(MockFetchError)
    }

    let behavior: Behavior

    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        switch behavior {
        case .success(let data, let statusCode, let contentType):
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

@Suite("ScrapeService")
struct ScrapeServiceTests {
    // MARK: - stripNonContentTags

    @Test("Retire script/style/noscript et les commentaires HTML")
    func stripNonContentTagsRemovesScriptStyleNoscriptComments() {
        let html = """
        <html><head><script>var x = 1;</script><style>body{color:red}</style></head>
        <body><noscript>Active JS</noscript><!-- un commentaire --><p>Contenu réel</p></body></html>
        """

        let result = ScrapeService.stripNonContentTags(html)

        #expect(!result.contains("var x = 1"))
        #expect(!result.contains("color:red"))
        #expect(!result.contains("Active JS"))
        #expect(!result.contains("un commentaire"))
        #expect(result.contains("<p>Contenu réel</p>"))
    }

    @Test("Retire les conteneurs structurels nav/header/footer/aside/form")
    func stripNonContentTagsRemovesStructuralContainers() {
        let html = """
        <nav><a href="/">Accueil</a></nav>
        <header><h1>Titre du site</h1></header>
        <div class="content"><p>Contenu principal</p></div>
        <aside class="sidebar"><p>Liens sponsorisés</p></aside>
        <footer><p>Copyright 2026</p></footer>
        <form><input type="text"></form>
        """

        let result = ScrapeService.stripNonContentTags(html)

        #expect(!result.contains("Accueil"))
        #expect(!result.contains("Titre du site"))
        #expect(!result.contains("Liens sponsorisés"))
        #expect(!result.contains("Copyright 2026"))
        #expect(!result.contains("<form>"))
        #expect(result.contains("Contenu principal"))
    }

    // MARK: - decodeHTMLEntities

    @Test("Décode les entités nommées courantes")
    func decodeHTMLEntitiesHandlesNamedEntities() {
        let decoded = ScrapeService.decodeHTMLEntities("Tom &amp; Jerry &lt;3 &quot;chats&quot; &nbsp;fin&nbsp;")
        #expect(decoded.contains("Tom & Jerry"))
        #expect(decoded.contains("<3"))
        #expect(decoded.contains("\"chats\""))
    }

    @Test("Décode les entités numériques décimales et hexadécimales")
    func decodeHTMLEntitiesHandlesNumericEntities() {
        // &#233; = é (decimal), &#x20AC; = € (hex)
        let decoded = ScrapeService.decodeHTMLEntities("caf&#233; co&#251;te 5&#x20AC;")
        #expect(decoded.contains("café"))
        #expect(decoded.contains("coûte"))
        #expect(decoded.contains("5€"))
    }

    // MARK: - scoreAndSelectMainBlock

    @Test("Choisit le bloc de texte dense plutôt qu'un bloc dominé par des liens (densité de liens élevée)")
    func scoreAndSelectMainBlockPrefersDenseTextOverLinkHeavyBlock() {
        let html = """
        <div class="related-links"><a href="/1">Lien 1</a> <a href="/2">Lien 2</a> <a href="/3">Lien 3</a> <a href="/4">Lien 4</a> <a href="/5">Lien 5</a> <a href="/6">Lien 6</a> <a href="/7">Lien 7</a> <a href="/8">Lien 8</a> <a href="/9">Lien 9</a> <a href="/10">Lien 10</a> <a href="/11">Lien 11</a> <a href="/12">Lien 12</a></div>
        <div class="content"><p>Voici un article complet et dense en texte informatif qui explique en détail le sujet traité, avec de nombreuses phrases riches en contenu pour dépasser largement la liste de liens ci-dessus en termes de valeur informationnelle réelle pour le lecteur.</p></div>
        """

        let selected = ScrapeService.scoreAndSelectMainBlock(fromCleanedHTML: html)

        #expect(selected.contains("article complet et dense"))
        #expect(!selected.contains("Lien 1"))
    }

    @Test("Pénalise fortement les segments dont la classe/id porte un mot-clé négatif (comments/sidebar/widget), même denses en texte")
    func scoreAndSelectMainBlockPenalizesNegativeKeywords() {
        let html = """
        <div class="content"><p>Texte principal de l'article, suffisamment long et dense en informations utiles pour être reconnu comme le contenu principal par notre heuristique de scoring basée sur la densité de texte réelle.</p></div>
        <div class="comments"><p>Super article, merci beaucoup pour ce partage très intéressant qui va sûrement aider beaucoup de monde à comprendre le sujet abordé ici en détail.</p></div>
        """

        let selected = ScrapeService.scoreAndSelectMainBlock(fromCleanedHTML: html)

        #expect(selected.contains("Texte principal de l'article"))
        #expect(!selected.contains("Super article"))
    }

    @Test("Contenu réparti sur des <div> imbriqués sur plusieurs niveaux : préservé en entier (pas tronqué à la première fermeture rencontrée)")
    func extractMainContentPreservesNestedDivContent() {
        let html = """
        <html><head><title>Article imbriqué</title></head><body>
        <div class="content"><div class="para"><p>Premier paragraphe avec du texte suffisant pour être scoré positivement et dépasser le seuil des quarante caractères minimum requis pour ce test.</p></div><div class="para"><p>Deuxième paragraphe également riche en texte, complétant le premier avec des informations supplémentaires utiles pour le lecteur de cet article.</p></div></div>
        </body></html>
        """

        let (title, content) = ScrapeService.extractMainContent(fromHTML: html)

        #expect(title == "Article imbriqué")
        #expect(content.contains("Premier paragraphe"))
        #expect(content.contains("Deuxième paragraphe"))
    }

    // MARK: - splitIntoChunks

    @Test("Respecte maxCharacters et coupe sur une frontière de phrase, jamais au milieu d'un mot")
    func splitIntoChunksCutsOnSentenceBoundary() {
        let text = "Phrase un. Phrase deux. Phrase trois."

        let chunks = ScrapeService.splitIntoChunks(text, maxCharacters: 20, overlapCharacters: 0)

        #expect(chunks == ["Phrase un. ", "Phrase deux. ", "Phrase trois."])
        for chunk in chunks {
            #expect(chunk.count <= 20)
        }
    }

    @Test("Applique le chevauchement demandé entre deux chunks consécutifs")
    func splitIntoChunksAppliesOverlap() {
        let text = "Phrase un. Phrase deux. Phrase trois."

        let chunks = ScrapeService.splitIntoChunks(text, maxCharacters: 20, overlapCharacters: 5)

        #expect(chunks.count >= 2)
        let overlapExpected = String(chunks[0].suffix(5))
        #expect(chunks[1].hasPrefix(overlapExpected))
    }

    @Test("Un texte long sans AUCUNE frontière de phrase (pas de ponctuation ni de retour à la ligne) termine sans blocage : coupe dure à maxCharacters")
    func splitIntoChunksTerminatesOnBoundarylessText() {
        let text = String(repeating: "a", count: 10_000)

        let chunks = ScrapeService.splitIntoChunks(text, maxCharacters: 500, overlapCharacters: 50)

        // La simple complétion de cet appel (pas de timeout du test) prouve
        // l'absence de blocage ; on vérifie en plus un résultat cohérent.
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.count <= 500)
        }
        #expect(chunks.reduce(0) { $0 + $1.count } >= text.count)
    }

    @Test("Chaîne vide : aucun chunk")
    func splitIntoChunksWithEmptyStringReturnsNoChunks() {
        #expect(ScrapeService.splitIntoChunks("", maxCharacters: 100, overlapCharacters: 10).isEmpty)
    }

    @Test("maxCharacters <= 0 : renvoie le texte entier tel quel, sans crash")
    func splitIntoChunksWithNonPositiveMaxCharactersReturnsWholeText() {
        let chunks = ScrapeService.splitIntoChunks("un texte quelconque", maxCharacters: 0, overlapCharacters: 0)
        #expect(chunks == ["un texte quelconque"])
    }

    // MARK: - decodeBoundedHTML (troncature UTF-8, régression)

    @Test("Troncature en plein milieu d'un caractère UTF-8 multi-octets (é, 0xC3 0xA9 coupé au premier octet) : recule jusqu'à la dernière frontière valide plutôt que produire du mojibake via un repli Latin-1 direct")
    func decodeBoundedHTMLBacktracksOnIncompleteMultiByteSequenceAtTruncationBoundary() {
        var bytes = Array("Texte avant caf".utf8)
        bytes.append(0xC3) // premier octet de 'é' — le second (0xA9) est absent, coupé par la troncature
        let boundedData = Data(bytes)

        let decoded = ScrapeService.decodeBoundedHTML(boundedData, isTruncated: true)

        // AVANT le fix : `String(data:encoding:.utf8)` échoue sur l'octet 0xC3
        // orphelin, et le repli direct sur Latin-1 le décodait en "Ã" (U+00C3)
        // -> "Texte avant cafÃ", un caractère corrompu greffé sur du texte
        // par ailleurs valide. APRÈS le fix : recul d'un octet, caractère
        // incomplet simplement absent du résultat, aucune corruption.
        #expect(decoded == "Texte avant caf")
        #expect(decoded?.contains("Ã") == false)
    }

    @Test("Page non tronquée mais authentiquement non-UTF-8 : repli direct sur Latin-1, sans tentative de réparation (réservée aux troncatures)")
    func decodeBoundedHTMLFallsBackToLatin1WhenNotTruncated() {
        let bytes: [UInt8] = Array("Caf".utf8) + [0xE9] // 'é' en Latin-1 seul, invalide en UTF-8
        let boundedData = Data(bytes)

        let decoded = ScrapeService.decodeBoundedHTML(boundedData, isTruncated: false)

        #expect(decoded == "Café")
    }

    @Test("Contenu authentiquement non-UTF-8 même une fois tronqué (octet invalide loin de la fin du buffer) : la réparation à 3 octets ne suffit pas, repli Latin-1 correct")
    func decodeBoundedHTMLFallsBackToLatin1WhenInvalidByteIsFarFromTheEnd() {
        var bytes: [UInt8] = [0xE9] // 'é' en Latin-1, invalide en UTF-8, en tête de buffer
        bytes.append(contentsOf: Array("caf, suivi d'un texte ASCII largement plus long que trois octets".utf8))
        let boundedData = Data(bytes)

        let decoded = ScrapeService.decodeBoundedHTML(boundedData, isTruncated: true)

        #expect(decoded?.hasPrefix("é") == true)
    }

    // MARK: - scrape(url:) — jamais de throw, statut HTTP / Content-Type / erreurs de transport

    @Test("Statut HTTP non-2xx : succeeded = false, sans extraction")
    func scrapeReturnsFailureOnNonSuccessStatusCode() async {
        let fetcher = MockURLFetching(behavior: .success(data: Data("<html></html>".utf8), statusCode: 404, contentType: "text/html"))
        let service = ScrapeService(fetcher: fetcher)

        let page = await service.scrape(url: "https://example.com/introuvable")

        #expect(page.succeeded == false)
        #expect(page.content.isEmpty)
    }

    @Test("Content-Type non-HTML (ex. PDF) : succeeded = false, aucune tentative d'extraction")
    func scrapeReturnsFailureOnNonHTMLContentType() async {
        let fetcher = MockURLFetching(behavior: .success(data: Data([0x25, 0x50, 0x44, 0x46]), statusCode: 200, contentType: "application/pdf"))
        let service = ScrapeService(fetcher: fetcher)

        let page = await service.scrape(url: "https://example.com/document.pdf")

        #expect(page.succeeded == false)
    }

    @Test("Erreur de transport (timeout) : succeeded = false, jamais de throw propagé à l'appelant")
    func scrapeReturnsFailureOnTransportErrorWithoutThrowing() async {
        let fetcher = MockURLFetching(behavior: .failure(.timeout))
        let service = ScrapeService(fetcher: fetcher)

        let page = await service.scrape(url: "https://example.com/lent")

        #expect(page.succeeded == false)
    }

    @Test("Téléchargement au-delà de maxDownloadBytes : tronqué avant traitement, sans crash")
    func scrapeTruncatesOversizedDownloadWithoutCrashing() async {
        let hugeHTML = "<html><body><div class=\"content\"><p>" + String(repeating: "Contenu très long. ", count: 5000) + "</p></div></body></html>"
        let fetcher = MockURLFetching(behavior: .success(data: Data(hugeHTML.utf8), statusCode: 200, contentType: "text/html; charset=utf-8"))
        let service = ScrapeService(fetcher: fetcher, maxDownloadBytes: 1000, maxContentCharactersPerPage: 4000)

        let page = await service.scrape(url: "https://example.com/enorme")

        // Ne crashe pas, produit un résultat borné (la troncature à 1000
        // octets coupe potentiellement au milieu d'une balise, d'où
        // `succeeded` non garanti true — seul le "pas de crash" est vérifié
        // ici, cohérent avec le contrat "jamais de throw" de `scrape(url:)`).
        #expect(page.content.count <= 4000)
    }

    @Test("Cas nominal : titre et contenu principal extraits d'une page HTML valide")
    func scrapeExtractsTitleAndContentOnSuccess() async {
        let html = """
        <html><head><title>Mon Article</title></head><body>
        <nav><a href="/">Accueil</a></nav>
        <div class="content"><p>Ceci est un paragraphe de contenu riche et informatif, avec suffisamment de texte pour être détecté comme le bloc principal de la page selon notre heuristique de densité.</p></div>
        </body></html>
        """
        let fetcher = MockURLFetching(behavior: .success(data: Data(html.utf8), statusCode: 200, contentType: "text/html; charset=utf-8"))
        let service = ScrapeService(fetcher: fetcher)

        let page = await service.scrape(url: "https://example.com/article")

        #expect(page.succeeded == true)
        #expect(page.title == "Mon Article")
        #expect(page.content.contains("paragraphe de contenu riche"))
        #expect(!page.content.contains("Accueil"))
    }

    @Test("URL invalide : succeeded = false, sans crash")
    func scrapeReturnsFailureOnInvalidURL() async {
        let service = ScrapeService(fetcher: MockURLFetching(behavior: .failure(.network)))

        let page = await service.scrape(url: "")

        #expect(page.succeeded == false)
    }
}
