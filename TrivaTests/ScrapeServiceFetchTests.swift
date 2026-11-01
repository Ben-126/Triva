//
//  ScrapeServiceFetchTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublures

/// Lu par une fonction SYNCHRONE : `Thread.isMainThread` est indisponible en
/// contexte async en Swift 6, mais une fonction synchrone s'exécute sur le
/// thread de son appelant — elle répond donc pour lui.
private func isRunningOnMainThread() -> Bool {
    Thread.isMainThread
}

/// Journal de ce que `ScrapeService` a réellement demandé au « réseau ».
/// `@unchecked Sendable` + `NSLock`, même principe que `LockedBox`
/// (`SearXNGClientTests`) : écrit depuis l'exécuteur de `scrape`, lu par le test.
private final class FetchJournal: @unchecked Sendable {
    struct Snapshot {
        var streamRequests = 0
        var fetchRequests = 0
        var pulledBytes = 0
        var cancellations = 0
        var streamRequestedOnMainThread: Bool?
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot {
        lock.withLock { state }
    }

    func record(_ update: (inout Snapshot) -> Void) {
        lock.withLock { update(&state) }
    }
}

/// Corps de réponse PARESSEUX : un octet n'est compté que quand le lecteur
/// le tire — on mesure ce que `ScrapeService` a lu, pas ce que le serveur
/// aurait envoyé. `stallsAtEnd` : corps livré, le flux ne se termine pas et
/// attend (serveur au compte-gouttes) jusqu'à l'annulation de la tâche.
private struct JournaledBytes: AsyncSequence, Sendable {
    let body: [UInt8]
    let stallsAtEnd: Bool
    let journal: FetchJournal

    struct AsyncIterator: AsyncIteratorProtocol {
        let body: [UInt8]
        let stallsAtEnd: Bool
        let journal: FetchJournal
        var index = 0

        mutating func next() async throws -> UInt8? {
            guard index < body.count else {
                if stallsAtEnd {
                    try await Task.sleep(for: .seconds(60))
                }
                return nil
            }
            defer { index += 1 }
            journal.record { $0.pulledBytes += 1 }
            return body[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(body: body, stallsAtEnd: stallsAtEnd, journal: journal)
    }
}

/// `URLFetching` instrumentée qui implémente `streamBytes` ELLE-MÊME : le
/// repli de l'extension passe par `fetch`, qui télécharge tout avant de
/// rendre la main — rien de ce qu'on prouve ici n'y serait observable.
/// `fetch` n'est jamais censé servir au scraping : tout appel est compté.
private struct JournaledFetcher: URLFetching {
    let statusCode: Int
    let contentType: String
    let body: [UInt8]
    var stallsAtEnd = false
    let journal = FetchJournal()

    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        journal.record { $0.fetchRequests += 1 }
        throw URLError(.unsupportedURL)
    }

    /// Le thread est relevé ICI : cette méthode s'exécute sur l'exécuteur de
    /// son appelant, `ScrapeService.scrape(url:)` (exigence `nonisolated`
    /// sans `@concurrent` du protocole, `NonisolatedNonsendingByDefault`) —
    /// c'est donc le thread de tout le scrape, extraction comprise.
    func streamBytes(url: URL, timeout: TimeInterval) async throws -> URLByteStream {
        let onMainThread = isRunningOnMainThread()
        journal.record {
            $0.streamRequests += 1
            $0.streamRequestedOnMainThread = onMainThread
        }
        let headers = ["Content-Type": contentType, "Content-Length": String(body.count)]
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw URLError(.badServerResponse)
        }
        let journal = journal
        return URLByteStream(
            response: response,
            bytes: JournaledBytes(body: body, stallsAtEnd: stallsAtEnd, journal: journal),
            cancel: { journal.record { $0.cancellations += 1 } }
        )
    }
}

// MARK: - Tests

/// `@MainActor` : `ChatViewModel` lance la recherche depuis le main actor —
/// c'est exactement le contexte que le scraping doit quitter.
@MainActor
@Suite("ScrapeService — réseau, bornes et concurrence")
struct ScrapeServiceFetchTests {
    private static let articleHTML = """
    <html><head><title>Rentrée scolaire</title></head><body><div class="content"><p>Les inscriptions à la cantine scolaire \
    pour la rentrée de septembre sont ouvertes jusqu'au 15 juillet inclus, en ligne ou en mairie.</p></div></body></html>
    """

    private static func htmlFetcher(_ html: String, contentType: String = "text/html; charset=utf-8") -> JournaledFetcher {
        JournaledFetcher(statusCode: 200, contentType: contentType, body: Array(html.utf8))
    }

    /// Même principe que `waitUntil` de `ChatViewModelTests` : `Task.sleep`,
    /// jamais `Task.yield()`, qui ne garantit pas la progression de l'autre tâche.
    private func waitUntil(_ timeoutMessage: String, maxAttempts: Int = 2000, _ condition: () -> Bool) async {
        for _ in 0..<maxAttempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timeout en attendant : \(timeoutMessage)")
    }

    // MARK: - Concurrence

    /// SANS `@concurrent` sur `scrape(url:)`, la méthode `nonisolated async`
    /// s'exécuterait sur l'acteur de l'appelant (ici le main actor) : lecture
    /// du corps et extraction regex figeraient l'interface.
    @Test("scrape(url:) appelé depuis le main actor s'exécute HORS du thread principal (type concret et via any ScrapeServing)")
    func scrapeLeavesTheMainThread() async {
        #expect(isRunningOnMainThread(), "prémisse : l'appelant est bien sur le thread principal")

        let concreteFetcher = Self.htmlFetcher(Self.articleHTML)
        let page = await ScrapeService(fetcher: concreteFetcher).scrape(url: "https://example.com/rentree")
        #expect(page.succeeded)
        #expect(concreteFetcher.journal.snapshot.streamRequestedOnMainThread == false)

        // Chemin réel de `SearchOrchestrator` : appel via l'existentiel.
        let existentialFetcher = Self.htmlFetcher(Self.articleHTML)
        let service: any ScrapeServing = ScrapeService(fetcher: existentialFetcher)
        _ = await service.scrape(url: "https://example.com/rentree")
        #expect(existentialFetcher.journal.snapshot.streamRequestedOnMainThread == false)
    }

    // MARK: - Bornes de téléchargement

    /// Le corps est un article HTML valide : s'il était lu malgré les
    /// en-têtes, l'extraction réussirait — le refus vient donc bien des en-têtes.
    @Test(
        "Réponse non HTML (PDF, JSON, image, texte brut) : refusée sur les en-têtes, AUCUN octet du corps lu, requête annulée",
        arguments: ["application/pdf", "application/json", "image/png", "text/plain; charset=utf-8"]
    )
    func nonHTMLResponseIsRejectedWithoutReadingBody(contentType: String) async {
        let fetcher = Self.htmlFetcher(Self.articleHTML, contentType: contentType)

        // URL sans extension (cas arXiv) : la requête part, le refus vient des en-têtes.
        let page = await ScrapeService(fetcher: fetcher).scrape(url: "https://arxiv.org/pdf/2401.00001")

        let journal = fetcher.journal.snapshot
        #expect(!page.succeeded)
        #expect(journal.streamRequests == 1)
        #expect(journal.pulledBytes == 0)
        #expect(journal.cancellations >= 1)
    }

    @Test("Statut HTTP non 2xx : refusé sur les en-têtes, aucun octet du corps lu")
    func errorStatusIsRejectedWithoutReadingBody() async {
        let fetcher = JournaledFetcher(statusCode: 404, contentType: "text/html", body: Array(Self.articleHTML.utf8))

        let page = await ScrapeService(fetcher: fetcher).scrape(url: "https://example.com/introuvable")

        #expect(!page.succeeded)
        #expect(fetcher.journal.snapshot.pulledBytes == 0)
    }

    /// AVANT le correctif : `URLSession.data(for:)` chargeait TOUT le corps
    /// (un PDF de 150 Mo compris) avant de le tronquer.
    @Test("Corps plus gros que maxDownloadBytes : lecture ARRÊTÉE au plafond, requête annulée, début de page exploité")
    func oversizedBodyStopsReadingAtTheCap() async {
        let paragraph = "<p>Les inscriptions à la cantine scolaire sont ouvertes jusqu'au 15 juillet inclus, en ligne ou en mairie.</p>"
        let html = "<html><head><title>Rentrée</title></head><body><div class=\"content\">"
            + String(repeating: paragraph, count: 500) + "</div></body></html>"
        let fetcher = Self.htmlFetcher(html)

        let page = await ScrapeService(fetcher: fetcher, maxDownloadBytes: 1_000).scrape(url: "https://example.com/long")

        let journal = fetcher.journal.snapshot
        #expect(fetcher.body.count > 50_000)
        #expect(journal.pulledBytes == 1_000)
        #expect(journal.cancellations >= 1)
        #expect(page.succeeded)
        #expect(page.content.contains("inscriptions à la cantine scolaire"))
    }

    @Test(
        "URL de fichier binaire (.pdf, .zip, .jpg…) ou schéma non http(s) : écartée SANS aucune requête",
        arguments: [
            "https://arxiv.org/pdf/2401.00001v2.pdf", "https://example.com/Rapport-Annuel.PDF", "https://example.com/archive.zip?version=2",
            "https://example.com/photo.jpg", "file:///etc/passwd", "ftp://example.com/index.html", "data:text/html,bonjour",
        ]
    )
    func binaryOrNonHTTPURLIsRejectedWithoutRequest(url: String) async {
        let fetcher = Self.htmlFetcher(Self.articleHTML)

        let page = await ScrapeService(fetcher: fetcher).scrape(url: url)

        let journal = fetcher.journal.snapshot
        #expect(!page.succeeded)
        #expect(journal.streamRequests == 0)
        #expect(journal.fetchRequests == 0)
    }

    @Test("Session de scraping dédiée : éphémère (ni cookies ni cache partagés), délai d'inactivité ET durée totale bornés")
    func scrapingSessionIsEphemeralAndBounded() {
        let configuration = ScrapeService.scrapingSession.configuration

        #expect(configuration.timeoutIntervalForRequest == ScrapeService.defaultIdleTimeout)
        #expect(configuration.timeoutIntervalForResource == ScrapeService.maxPageLoadDuration)
        #expect(ScrapeService.maxPageLoadDuration <= 15)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    }

    // MARK: - Annulation (bouton Stop)

    /// Le Stop tombe PENDANT la lecture (corps entier déjà reçu, flux en
    /// attente) : sans la vérification d'annulation après lecture, le corps
    /// reçu serait extrait et la page rendue comme un succès.
    @Test("Stop pendant la lecture (serveur au compte-gouttes) : échec immédiat, sans extraction du corps déjà reçu")
    func cancellationDuringReadingReturnsFailure() async {
        var fetcher = Self.htmlFetcher(Self.articleHTML)
        fetcher.stallsAtEnd = true
        let service = ScrapeService(fetcher: fetcher)
        let bodyLength = fetcher.body.count

        let task = Task { await service.scrape(url: "https://example.com/lent") }
        await waitUntil("corps entier livré, flux en attente") { fetcher.journal.snapshot.pulledBytes == bodyLength }
        task.cancel()
        let page = await task.value

        #expect(!page.succeeded)
        #expect(fetcher.journal.snapshot.cancellations >= 1)
    }

    // MARK: - Contenu (bout en bout)

    /// AVANT le correctif : un contenu vide ressortait en SUCCÈS et
    /// consommait une part du budget de contexte (`formatScrapedPages`).
    @Test("Squelette d'app JS (aucun texte hors <script>/<noscript>) : succeeded = false")
    func emptyPageIsReportedAsFailure() async {
        let html = """
        <html><head><title>App</title><script src="/app.js"></script></head>
        <body><div id="root"></div><noscript>Active JavaScript pour continuer.</noscript></body></html>
        """
        let fetcher = Self.htmlFetcher(html)

        let page = await ScrapeService(fetcher: fetcher).scrape(url: "https://example.com/app")

        #expect(!page.succeeded)
        #expect(page.content.isEmpty)
    }

    @Test("Page ASP.NET WebForms (tout le <body> dans <form id=\"aspnetForm\">) : succès avec le vrai contenu")
    func aspNetWebFormsPageSucceeds() async {
        let html = """
        <html><head><title>Mairie</title></head><body><form method="post" action="./Default.aspx" id="aspnetForm">
        <input type="hidden" name="__VIEWSTATE" value="/wEPDwUKLTk2Njk3OTQxNg9kFgJmD2QWAgIDD2Q=">
        <div class="content"><p>Les inscriptions à la cantine scolaire pour la rentrée de septembre sont ouvertes jusqu'au 15 juillet.</p></div>
        </form></body></html>
        """
        let fetcher = Self.htmlFetcher(html)

        let page = await ScrapeService(fetcher: fetcher).scrape(url: "https://mairie.example.fr/Default.aspx")

        #expect(page.succeeded)
        #expect(page.title == "Mairie")
        #expect(page.content.contains("inscriptions à la cantine scolaire"))
    }

    /// iso-8859-15 plutôt que windows-1252 : la détection automatique
    /// retomberait sur windows-1252 (« ½uvre », « ¤ ») — seul le charset lu
    /// dans l'en-tête HTTP donne le bon texte.
    @Test("Charset de l'en-tête HTTP (iso-8859-15) utilisé de bout en bout : œ et € intacts dans le titre et le contenu")
    func httpCharsetIsUsedEndToEnd() async throws {
        let latin9 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin9.rawValue))
        )
        let html = """
        <html><head><title>L'œuvre du mois</title></head><body><div class="content"><p>L'œuvre exposée cet été coûte 5 € \
        l'entrée, gratuite pour les moins de dix-huit ans.</p></div></body></html>
        """
        let body = try #require(html.data(using: latin9))
        let fetcher = JournaledFetcher(statusCode: 200, contentType: "text/html; charset=iso-8859-15", body: Array(body))

        let page = await ScrapeService(fetcher: fetcher).scrape(url: "https://musee.example.fr/expo")

        #expect(page.title == "L'œuvre du mois")
        #expect(page.content.contains("L'œuvre exposée cet été coûte 5 € l'entrée"))
    }
}
