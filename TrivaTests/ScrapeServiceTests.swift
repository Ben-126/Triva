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
/// personnalisé. N'implémente QUE `fetch` : `scrape(url:)` passe donc par le
/// repli `streamBytes` de l'extension `URLFetching` (corps rejoué octet par
/// octet), comme tout mock écrit avant la lecture en flux. Ce que la lecture
/// en flux borne réellement (octets lus, annulation, thread) est prouvé dans
/// `ScrapeServiceFetchTests`, avec un flux instrumenté.
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

/// Générateur pseudo-aléatoire à graine fixe (LCG de Knuth) : des textes
/// variés mais IDENTIQUES à chaque exécution — un échec reste reproductible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// `@MainActor` : même contexte d'appel que `ChatViewModel` en production.
@MainActor
@Suite("ScrapeService")
struct ScrapeServiceTests {
    /// Paragraphe TÉMOIN, positif et sans aucun mot piège. Indispensable aux
    /// tests d'heuristique : `scoreAndSelectMainBlock` renvoie le meilleur
    /// segment quand AUCUN n'est positif — un paragraphe testé seul
    /// reviendrait donc même pénalisé, et le test ne prouverait rien. Avec le
    /// témoin, le paragraphe testé n'est gardé que si son score est positif.
    private static let neutralParagraph =
        "<p>L'opération prend moins d'une minute et libère souvent plusieurs centaines de mégaoctets sur un ordinateur ancien.</p>"
    private static let neutralFragment = "L'opération prend moins d'une minute"

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

    /// Forme réelle de fr.wikipedia.org (mesurée le 2026-11-05) : `data-mw` porte du wikicode avec
    /// ses balises. Le `>` de la valeur fermait la balise pour `<[^>]+>`, et le wikicode devenait
    /// le « contenu » de la page, à la place de l'introduction.
    @Test("Une valeur data-* qui contient des balises ne fuit pas dans le texte (data-mw de Wikipédia)")
    func stripNonContentTagsRemovesMarkupInDataAttributes() {
        let html = """
        <div class="mw-content"><span typeof="mw:Transclusion" data-mw='{"parts":[{"wt":"{{Lien web|titre=Source}}.</ref>"},{"wt":"[[Fichier:x.svg]]</div>"}]}'></span>
        <p>La tour Eiffel est une tour de fer puddlé de 330 mètres de hauteur située à Paris.</p></div>
        """

        let (_, content) = ScrapeService.extractMainContent(fromHTML: html)

        #expect(content.contains("La tour Eiffel est une tour de fer puddlé"))
        #expect(!content.contains("Lien web"))
        #expect(!content.contains("Fichier"))
    }

    @Test("Une valeur data-* sans balise, citée dans le texte d'une documentation, reste intacte")
    func stripNonContentTagsKeepsPlainDataAttributeText() {
        let html = #"<p>Écris data-role="menu" dans la balise pour activer le menu déroulant du site.</p>"#

        let result = ScrapeService.stripNonContentTags(html)

        #expect(result.contains(#"data-role="menu""#))
    }

    @Test("Retire nav, footer, aside et l'en-tête du site ; <form> déballé (balises et champs retirés, contenu gardé)")
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
        #expect(!result.contains("<input"))
        #expect(result.contains("Contenu principal"))
    }

    @Test("<header> d'un <article>/<main> conservé (chapô), en-tête du site hors article retiré")
    func articleHeaderIsKeptButSiteHeaderIsRemoved() {
        let html = """
        <header class="site"><a href="/">Le Journal</a><p>Menu du site et abonnement</p></header>
        <main><article><header><h1>Enquête sur l'eau</h1><p>Le chapô résume l'essentiel de l'enquête en deux phrases.</p></header>
        <p>Le corps de l'article développe ensuite chaque point.</p></article></main>
        """

        let result = ScrapeService.stripNonContentTags(html)

        #expect(!result.contains("Menu du site et abonnement"))
        #expect(result.contains("Le chapô résume l'essentiel"))
        #expect(result.contains("Enquête sur l'eau"))
    }

    @Test("Page ASP.NET WebForms (tout le <body> dans <form id=\"aspnetForm\">) : le contenu survit, le __VIEWSTATE disparaît")
    func aspNetFormPageKeepsItsContent() {
        let html = """
        <html><head><title>Mairie</title></head><body><form method="post" action="./Default.aspx" id="aspnetForm">
        <input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="/wEPDwUKLTk2Njk3OTQxNg9kFgJmD2QWAgIDD2Q=">
        <div class="content"><p>Les inscriptions à la cantine scolaire pour la rentrée de septembre sont ouvertes jusqu'au 15 juillet inclus.</p></div>
        </form></body></html>
        """

        let (title, content) = ScrapeService.extractMainContent(fromHTML: html)

        #expect(title == "Mairie")
        #expect(content.contains("inscriptions à la cantine scolaire"))
        #expect(!content.contains("VIEWSTATE"))
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

    @Test(
        "Mot-clé négatif en PRÉFIXE d'un token class/id (commentaires, sidebar-droite, widget_text, post-comments) : toujours pénalisé",
        arguments: ["class=\"commentaires\"", "id=\"sidebar-droite\"", "class=\"widget_text\"", "class=\"post-comments\""]
    )
    func negativeClassOrIDTokenIsStillPenalized(attribute: String) {
        let html = """
        <div class="content"><p>Texte principal de l'article, suffisamment long et dense pour être reconnu comme le contenu principal.</p></div>
        <div \(attribute)><p>Super article, merci beaucoup pour ce partage très intéressant qui aidera sûrement beaucoup de monde.</p></div>
        """

        let selected = ScrapeService.scoreAndSelectMainBlock(fromCleanedHTML: html)

        #expect(selected.contains("Texte principal de l'article"))
        #expect(!selected.contains("Super article"))
    }

    /// AVANT le correctif : `contains` sur TOUT le segment brut (texte visible
    /// et `href` compris) — « comment » + « nav » (navigateur) valaient -1000.
    @Test(
        "Mot piège dans le TEXTE visible, un href ou au milieu d'un token class (unavailable) : paragraphe conservé",
        arguments: [
            (
                "<p>Voici comment vider le cache de votre navigateur : ouvrez les réglages, choisissez Confidentialité, puis effacez l'historique.</p>",
                "Voici comment vider le cache de votre navigateur"
            ),
            (
                "<p>The minister declined to comment on the navigation data, which remained unavailable to the sponsors of the bill.</p>",
                "declined to comment on the navigation data"
            ),
            (
                "<p>Les réponses des lecteurs sont regroupées sur <a href=\"/comments/42\">une page à part</a>, avec le détail des votes et des corrections de la rédaction.</p>",
                "Les réponses des lecteurs sont regroupées"
            ),
            (
                "<p class=\"entry-unavailable\">Le musée reste ouvert le dimanche matin, mais la galerie des sculptures ferme pour travaux jusqu'en mars.</p>",
                "la galerie des sculptures ferme"
            ),
        ]
    )
    func trapWordsOutsideClassOrIDPrefixesDoNotPenalize(trapParagraph: String, expectedFragment: String) {
        let html = "<div class=\"content\">\(trapParagraph)\n\(Self.neutralParagraph)</div>"

        let selected = ScrapeService.scoreAndSelectMainBlock(fromCleanedHTML: html)

        #expect(selected.contains(expectedFragment))
        #expect(selected.contains(Self.neutralFragment))
    }

    /// AVANT le correctif : densité = HTML BRUT des `<a>` / texte visible —
    /// chaque renvoi `cite_note` (~80 caractères de balisage pour « [3] »)
    /// poussait la densité à ~1 et l'intro disparaissait (score -357).
    @Test("Intro Wikipédia truffée de renvois <a href=\"#cite_note-…\"> : conservée (densité mesurée sur le texte visible des liens)")
    func wikipediaIntroWithCiteNotesIsKept() {
        func citeNote(_ number: Int) -> String {
            "<sup id=\"cite_ref-\(number)\" class=\"reference\"><a href=\"#cite_note-\(number)\"><span class=\"cite-bracket\">&#91;</span>\(number)<span class=\"cite-bracket\">&#93;</span></a></sup>"
        }
        let intro = """
        <p><b>Paris</b> est la <a href="/wiki/Capitale" title="Capitale">capitale</a> de la <a href="/wiki/France" title="France">France</a>\(citeNote(1)). \
        Elle se situe au cœur d'un vaste bassin sédimentaire aux sols fertiles et au climat tempéré, sur une boucle de la Seine\(citeNote(2)), \
        entre les confluents de celle-ci avec la Marne et l'Oise\(citeNote(3)). Ses habitants sont appelés les Parisiens\(citeNote(4)). \
        Paris est aussi le chef-lieu de la région Île-de-France\(citeNote(5)) et l'unique commune française qui est en même temps un département\(citeNote(6)).</p>
        """
        let html = "<div id=\"mw-content-text\" class=\"mw-body-content\">\(intro)\n\(Self.neutralParagraph)</div>"

        let selected = ScrapeService.scoreAndSelectMainBlock(fromCleanedHTML: html)

        #expect(selected.contains("vaste bassin sédimentaire"))
        #expect(selected.contains("chef-lieu de la région Île-de-France"))
        #expect(selected.contains(Self.neutralFragment))
    }

    /// AVANT le correctif : longueur du HTML BRUT comparée à 40 —
    /// `<li>4 œufs</li>` (15 caractères) était jeté avant même d'être noté.
    @Test("Liste d'ingrédients (<li>4 œufs</li>…) : items courts conservés (filtre sur le texte visible)")
    func shortRecipeListItemsAreKept() {
        let html = """
        <div class="content"><p>Pour six crêpes fines, compter dix minutes de préparation et une heure de repos pour la pâte.</p>
        <ul><li>4 œufs</li><li>250 g de farine</li><li>1 pincée de sel</li><li>50 cl de lait</li></ul></div>
        """

        let selected = ScrapeService.scoreAndSelectMainBlock(fromCleanedHTML: html)

        for ingredient in ["4 œufs", "250 g de farine", "1 pincée de sel", "50 cl de lait"] {
            #expect(selected.contains(ingredient), "ingrédient perdu : \(ingredient)")
        }
    }

    @Test("Tableau de prix (<td>1,20 €</td>…) : cellules courtes conservées")
    func shortPriceTableCellsAreKept() {
        let html = """
        <div class="content"><p>Les tarifs ci-dessous s'appliquent du lundi au vendredi, hors jours fériés et vacances scolaires.</p>
        <table><tr><th>Boisson</th><th>Prix</th></tr><tr><td>Café</td><td>1,20 €</td></tr><tr><td>Thé</td><td>1,50 €</td></tr></table></div>
        """

        let selected = ScrapeService.scoreAndSelectMainBlock(fromCleanedHTML: html)

        for cell in ["Café", "1,20 €", "Thé", "1,50 €"] {
            #expect(selected.contains(cell), "cellule perdue : \(cell)")
        }
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

    /// `firstChunk` ne découpe qu'une fenêtre bornée au lieu du contenu entier
    /// d'une page de 2 Mo : ce test prouve que le résultat est IDENTIQUE.
    /// Cas limites choisis pour casser une fenêtre trop courte (frontière
    /// avant la limite + texte plus long), puis 300 textes pseudo-aléatoires.
    @Test("firstChunk (fenêtre bornée) == splitIntoChunks(...).first : cas limites + 300 textes à graine fixe")
    func firstChunkMatchesFirstChunkOfFullSplit() {
        let limit = 40
        var cases: [(text: String, maxCharacters: Int)] = []
        for length in [limit - 1, limit, limit + 1, limit + 32, limit + 33, 500] {
            cases.append((String(repeating: "a", count: length), limit))
            cases.append((String(String(repeating: "Une phrase. ", count: length / 12 + 1).prefix(length)), limit))
        }
        cases.append((String(repeating: "x", count: limit - 2) + ". suite du texte après la limite", limit))
        cases.append((String(repeating: "x", count: limit - 3) + "." + String(repeating: " ", count: 10) + "fin", limit))
        cases.append((String(repeating: "x", count: limit + 29) + "." + String(repeating: " ", count: 10) + "fin", limit))
        cases.append(("Début. " + String(repeating: "é👨‍👩‍👧 ", count: 60), limit))
        cases.append(("", limit))
        cases.append(("texte quelconque", 0))

        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<300 {
            cases.append((Self.randomText(using: &generator), [1, 2, 7, 40, 120].randomElement(using: &generator) ?? 40))
        }

        for (text, maxCharacters) in cases {
            let expected = ScrapeService.splitIntoChunks(text, maxCharacters: maxCharacters, overlapCharacters: 0).first ?? ""
            let actual = ScrapeService.firstChunk(of: text, maxCharacters: maxCharacters)
            #expect(actual == expected, "max=\(maxCharacters) texte=\(text.debugDescription)")
        }
    }

    /// Briques qui déclenchent toutes les frontières de `splitIntoChunks`
    /// (ponctuation + blancs, retours à la ligne, puces) et des graphèmes
    /// multi-scalaires (famille ZWJ) qui décalent UTF-16 et `Character`.
    private static let textPieces = [
        "mot", "phrase", "é", "👨‍👩‍👧", " ", "   ", ". ", "! ", "? ", "; ", ": ", "\n", "\n\n", "- ", "* ", "\t", ",", "a", ".", "  .  ",
    ]

    private static func randomText(using generator: inout SeededGenerator) -> String {
        let pieceCount = Int.random(in: 0...200, using: &generator)
        var text = ""
        for _ in 0..<pieceCount {
            text += textPieces.randomElement(using: &generator) ?? ""
        }
        return text
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

    /// URL SANS extension `.pdf` : avec, elle serait écartée avant toute
    /// requête (`ScrapeService.isScrapable`) et ce test ne vérifierait plus
    /// le Content-Type (voir `ScrapeServiceFetchTests` pour ce refus-là).
    @Test("Content-Type non-HTML (ex. PDF) : succeeded = false, aucune tentative d'extraction")
    func scrapeReturnsFailureOnNonHTMLContentType() async {
        let fetcher = MockURLFetching(behavior: .success(data: Data([0x25, 0x50, 0x44, 0x46]), statusCode: 200, contentType: "application/pdf"))
        let service = ScrapeService(fetcher: fetcher)

        let page = await service.scrape(url: "https://example.com/document")

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
