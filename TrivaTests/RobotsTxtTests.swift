//
//  RobotsTxtTests.swift
//  TrivaTests
//
//  Mission C4 : robots.txt (RFC 9309), signaux d'opposition, User-Agent honnête, « Lire cette page ».
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublure réseau routée

private final class RouteJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    func record(_ url: URL) { lock.withLock { urls.append(url.absoluteString) } }
    var requested: [String] { lock.withLock { urls } }
    func count(of url: String) -> Int { requested.filter { $0 == url }.count }
}

private struct RoutedFetcher: URLFetching {
    struct Route {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        var fails = false
    }

    let routes: [String: Route]
    let journal: RouteJournal

    init(_ routes: [String: Route], journal: RouteJournal = RouteJournal()) {
        self.routes = routes
        self.journal = journal
    }

    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        journal.record(url)
        guard let route = routes[url.absoluteString] else {
            let missing = try #require(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil))
            return (Data(), missing)
        }
        if route.fails { throw URLError(.notConnectedToInternet) }
        var headers = route.headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "text/html; charset=utf-8" }
        let response = try #require(HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: headers))
        return (Data(route.body.utf8), response)
    }
}

private let articleHTML = "<html><head><title>Photosynthèse</title></head><body><article>"
    + String(repeating: "<p>La photosynthèse transforme la lumière en énergie chimique dans les feuilles des plantes vertes.</p>", count: 6)
    + "</article></body></html>"

private let siteRobots = "https://exemple.org/robots.txt"
private let sitePage = "https://exemple.org/article"

@Suite("RobotsRules — lecture et décision selon la RFC 9309")
struct RobotsRulesTests {
    @Test("Groupe * : Disallow bloque, le reste passe")
    func wildcardGroup() {
        let rules = RobotsRules.parse("User-agent: *\nDisallow: /prive/\n")
        #expect(!rules.isAllowed(pathAndQuery: "/prive/page"))
        #expect(rules.isAllowed(pathAndQuery: "/public/page"))
        #expect(rules.isAllowed(pathAndQuery: "/"))
    }

    @Test("Un groupe « Triva » l'emporte entièrement sur le groupe *")
    func specificGroupWins() {
        let text = """
        User-agent: *
        Disallow: /

        User-agent: Triva
        Disallow: /secret/
        """
        let rules = RobotsRules.parse(text)
        #expect(rules.isAllowed(pathAndQuery: "/article"))
        #expect(!rules.isAllowed(pathAndQuery: "/secret/x"))
    }

    @Test("Triva interdit nommément alors que * autorise")
    func specificDisallowAll() {
        let rules = RobotsRules.parse("User-agent: *\nAllow: /\n\nuser-AGENT: triva\nDisallow: /\n")
        #expect(!rules.isAllowed(pathAndQuery: "/n-importe-quoi"))
    }

    @Test("Règle la plus longue gagnante ; à égalité, Allow")
    func longestMatchWins() {
        let rules = RobotsRules.parse("User-agent: *\nDisallow: /docs/\nAllow: /docs/public/\n")
        #expect(rules.isAllowed(pathAndQuery: "/docs/public/a"))
        #expect(!rules.isAllowed(pathAndQuery: "/docs/interne"))
        let tie = RobotsRules.parse("User-agent: *\nDisallow: /page\nAllow: /page\n")
        #expect(tie.isAllowed(pathAndQuery: "/page"))
    }

    @Test("Jokers * et $")
    func wildcards() {
        let rules = RobotsRules.parse("User-agent: *\nDisallow: /*.pdf$\nDisallow: /tmp*/cache\n")
        #expect(!rules.isAllowed(pathAndQuery: "/a/b.pdf"))
        #expect(rules.isAllowed(pathAndQuery: "/a/b.pdf?x=1"))
        #expect(rules.isAllowed(pathAndQuery: "/a/b.pdfx"))
        #expect(!rules.isAllowed(pathAndQuery: "/tmp42/cache"))
        #expect(rules.isAllowed(pathAndQuery: "/tmp42/autre"))
    }

    @Test("Disallow vide n'interdit rien ; commentaires et fins de ligne variées")
    func emptyDisallowAndComments() {
        let rules = RobotsRules.parse("\u{FEFF}# tout est permis\r\nUser-agent: * # tous\r\nDisallow:\r\nSitemap: https://exemple.org/s.xml\r\n")
        #expect(rules.isAllowed(pathAndQuery: "/n-importe-quoi"))
    }

    @Test("Plusieurs User-agent consécutifs partagent le groupe")
    func stackedAgents() {
        let rules = RobotsRules.parse("User-agent: googlebot\nUser-agent: triva\nDisallow: /x\n")
        #expect(!rules.isAllowed(pathAndQuery: "/x"))
    }

    @Test("Aucun groupe applicable, ou fichier vide : tout est permis")
    func noApplicableGroup() {
        #expect(RobotsRules.parse("User-agent: googlebot\nDisallow: /").isAllowed(pathAndQuery: "/a"))
        #expect(RobotsRules.parse("").isAllowed(pathAndQuery: "/a"))
        #expect(RobotsRules.disallowAll.isAllowed(pathAndQuery: "/a") == false)
    }

    @Test("La requête fait partie de l'adresse comparée")
    func queryString() throws {
        let rules = RobotsRules.parse("User-agent: *\nDisallow: /*?session=\n")
        #expect(!rules.isAllowed(try #require(URL(string: "https://exemple.org/p?session=1"))))
        #expect(rules.isAllowed(try #require(URL(string: "https://exemple.org/p?page=1"))))
    }
}

@Suite("SiteReadSignals — opposition portée par la réponse")
struct SiteReadSignalsTests {
    private func response(_ headers: [String: String]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: URL(string: "https://exemple.org/")!, statusCode: 200, httpVersion: nil, headerFields: headers))
    }

    @Test("tdm-reservation: 1 et X-Robots-Tag: noai refusent ; noindex seul ne refuse pas")
    func headers() throws {
        #expect(SiteReadSignals.optsOutOfAI(try response(["tdm-reservation": "1"])))
        #expect(!SiteReadSignals.optsOutOfAI(try response(["tdm-reservation": "0"])))
        #expect(SiteReadSignals.optsOutOfAI(try response(["X-Robots-Tag": "noai"])))
        #expect(SiteReadSignals.optsOutOfAI(try response(["X-Robots-Tag": "noindex, noai"])))
        #expect(!SiteReadSignals.optsOutOfAI(try response(["X-Robots-Tag": "noindex, nofollow"])))
        #expect(!SiteReadSignals.optsOutOfAI(try response([:])))
    }

    @Test("Directive adressée à un autre agent : ignorée ; adressée à Triva : appliquée")
    func agentScoped() {
        #expect(!SiteReadSignals.xRobotsTagForbidsAI("googlebot: noai"))
        #expect(SiteReadSignals.xRobotsTagForbidsAI("triva: noai"))
        #expect(SiteReadSignals.xRobotsTagForbidsAI("noai, googlebot: noindex"))
        #expect(!SiteReadSignals.xRobotsTagForbidsAI("unavailable_after: 25 Jun 2030 15:00:00 PST"))
    }
}

@Suite("RobotsTxtChecker — robots.txt, états HTTP et cache")
struct RobotsTxtCheckerTests {
    private func checker(_ routes: [String: RoutedFetcher.Route], journal: RouteJournal = RouteJournal(),
                         cache: RobotsRulesCache = RobotsRulesCache(),
                         now: @escaping @Sendable () -> Date = { Date() }) -> RobotsTxtChecker {
        RobotsTxtChecker(fetcher: RoutedFetcher(routes, journal: journal), cache: cache, now: now)
    }

    @Test("200 : le fichier est appliqué")
    func appliesFile() async throws {
        let checker = checker([siteRobots: .init(body: "User-agent: *\nDisallow: /article\n")])
        #expect(await checker.isAllowed(try #require(URL(string: sitePage))) == false)
        #expect(await checker.isAllowed(try #require(URL(string: "https://exemple.org/autre"))))
    }

    @Test("404 : pas de fichier, tout est permis")
    func notFoundAllowsAll() async throws {
        let checker = checker([:])
        #expect(await checker.isAllowed(try #require(URL(string: sitePage))))
    }

    @Test("5xx ou réseau en échec : prudence, la page n'est pas lue")
    func unavailableIsCautious() async throws {
        let url = try #require(URL(string: sitePage))
        #expect(await checker([siteRobots: .init(status: 503)]).isAllowed(url) == false)
        #expect(await checker([siteRobots: .init(fails: true)]).isAllowed(url) == false)
    }

    @Test("Mis en cache : un seul téléchargement par site ; expire après 24 h")
    func cachesPerOrigin() async throws {
        let journal = RouteJournal()
        let clock = LockedDate(Date(timeIntervalSince1970: 1_000_000))
        let checker = checker([siteRobots: .init(body: "User-agent: *\nDisallow: /nope\n")], journal: journal, now: { clock.value })
        _ = await checker.isAllowed(try #require(URL(string: "https://exemple.org/a")))
        _ = await checker.isAllowed(try #require(URL(string: "https://exemple.org/b")))
        #expect(journal.count(of: siteRobots) == 1)
        clock.value = clock.value.addingTimeInterval(RobotsRulesCache.rulesLifetime + 1)
        _ = await checker.isAllowed(try #require(URL(string: "https://exemple.org/c")))
        #expect(journal.count(of: siteRobots) == 2)
    }

    @Test("Un fichier injoignable n'est gardé que 5 minutes")
    func unavailableShortCache() async throws {
        let journal = RouteJournal()
        let clock = LockedDate(Date(timeIntervalSince1970: 2_000_000))
        let checker = checker([siteRobots: .init(status: 500)], journal: journal, now: { clock.value })
        let url = try #require(URL(string: sitePage))
        _ = await checker.isAllowed(url)
        _ = await checker.isAllowed(url)
        #expect(journal.count(of: siteRobots) == 1)
        clock.value = clock.value.addingTimeInterval(RobotsRulesCache.unavailableLifetime + 1)
        _ = await checker.isAllowed(url)
        #expect(journal.count(of: siteRobots) == 2)
    }

    @Test("Origine : schéma, hôte et port distincts")
    func origins() throws {
        #expect(RobotsTxtChecker.origin(of: try #require(URL(string: "https://Exemple.org/x"))) == "https://exemple.org")
        #expect(RobotsTxtChecker.origin(of: try #require(URL(string: "http://exemple.org:8080/x"))) == "http://exemple.org:8080")
        #expect(RobotsTxtChecker.origin(of: try #require(URL(string: "file:///etc/passwd"))) == nil)
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

@Suite("ScrapeService — respect de robots.txt et lecture à la demande", .serialized)
struct ScrapeServiceRobotsTests {
    private func service(_ routes: [String: RoutedFetcher.Route], robots: Bool = true) -> (ScrapeService, RouteJournal) {
        let journal = RouteJournal()
        let fetcher = RoutedFetcher(routes, journal: journal)
        let checker = robots ? RobotsTxtChecker(fetcher: fetcher, cache: RobotsRulesCache()) : nil
        return (ScrapeService(fetcher: fetcher, robots: checker), journal)
    }

    @Test("Page autorisée par robots.txt : lue normalement")
    func allowedPageIsRead() async {
        let (service, _) = service([siteRobots: .init(body: "User-agent: *\nDisallow: /prive\n"), sitePage: .init(body: articleHTML)])
        let page = await service.scrape(url: sitePage)
        #expect(page.succeeded)
        #expect(!page.refusedBySite)
    }

    @Test("Page refusée par robots.txt : jamais téléchargée, marquée refusée")
    func refusedPageIsNotFetched() async {
        let (service, journal) = service([siteRobots: .init(body: "User-agent: *\nDisallow: /\n"), sitePage: .init(body: articleHTML)])
        let page = await service.scrape(url: sitePage)
        #expect(!page.succeeded)
        #expect(page.refusedBySite)
        #expect(page.content.isEmpty)
        #expect(journal.count(of: sitePage) == 0)
    }

    @Test("En-tête noai ou tdm-reservation : corps non lu, page marquée refusée")
    func headerOptOut() async {
        for header in [["X-Robots-Tag": "noai"], ["tdm-reservation": "1"]] {
            let (service, _) = service([sitePage: .init(body: articleHTML, headers: header)])
            let page = await service.scrape(url: sitePage)
            #expect(page.refusedBySite && !page.succeeded)
        }
    }

    @Test("Lecture à la demande : robots.txt non appliqué, page lue puis servie aux lectures suivantes")
    func readOnUserRequest() async {
        UserReadPages.removeAll()
        defer { UserReadPages.removeAll() }
        let (service, journal) = service([siteRobots: .init(body: "User-agent: *\nDisallow: /\n"), sitePage: .init(body: articleHTML)])
        let page = await service.readOnUserRequest(url: sitePage)
        #expect(page.succeeded)
        #expect(journal.count(of: siteRobots) == 0)
        UserReadPages.store(page)
        let later = await service.scrape(url: sitePage)
        #expect(later.succeeded)
        #expect(journal.count(of: sitePage) == 1)
    }

    @Test("Sans robots (constructeur de test) : comportement inchangé")
    func noRobotsChecker() async {
        let (service, journal) = service([sitePage: .init(body: articleHTML)], robots: false)
        let page = await service.scrape(url: sitePage)
        #expect(page.succeeded)
        #expect(journal.count(of: siteRobots) == 0)
    }

    @Test("User-Agent honnête : « Triva », jamais un navigateur")
    func honestUserAgent() {
        let agent = URLSessionFetcher.userAgent
        #expect(agent.hasPrefix("Triva/"))
        #expect(!agent.contains("Mozilla") && !agent.contains("Chrome") && !agent.contains("Safari"))
        #expect(agent == OpenSourceSearchHTTP.userAgent)
    }
}

@MainActor
@Suite("SiteReadRefusals et licences affichées", .serialized)
struct SiteReadRefusalsTests {
    @Test("Une source refusée est marquée, puis lue à la demande")
    func refusalThenRead() async {
        UserReadPages.removeAll()
        defer { UserReadPages.removeAll() }
        let refusals = SiteReadRefusals()
        refusals.markRefused([sitePage])
        #expect(refusals.state(for: sitePage) == .refused)
        #expect(SourcesListPresentation.offersReadButton(for: refusals.state(for: sitePage)))
        #expect(refusals.state(for: "https://autre.org/") == nil)

        let fetcher = RoutedFetcher([sitePage: .init(body: articleHTML)])
        await refusals.readPage(url: sitePage, service: ScrapeService(fetcher: fetcher))
        #expect(refusals.state(for: sitePage) == .read)
        #expect(!SourcesListPresentation.offersReadButton(for: refusals.state(for: sitePage)))
        #expect(UserReadPages.page(for: sitePage) != nil)
    }

    @Test("Lecture qui échoue : le bouton reste proposé")
    func failedReadKeepsButton() async {
        let refusals = SiteReadRefusals()
        refusals.markRefused([sitePage])
        await refusals.readPage(url: sitePage, service: ScrapeService(fetcher: RoutedFetcher([sitePage: .init(status: 500)])))
        #expect(refusals.state(for: sitePage) == .readFailed)
        #expect(SourcesListPresentation.offersReadButton(for: .readFailed))
    }

    @Test("Mentions de licence : Wikipédia, Marginalia (clé), arXiv ; rien ailleurs")
    func licenses() {
        func source(_ url: String, key: String? = nil) -> SearXNGSearchResult {
            var result = SearXNGSearchResult(title: "t", url: url, content: nil, imgSrc: nil, thumbnailSrc: nil,
                                             thumbnail: nil, author: nil, iframeSrc: nil)
            result.licenseKey = key
            return result
        }
        #expect(SourcesListPresentation.licenseAttribution(for: source("https://fr.wikipedia.org/wiki/Paris"))?.text == "Wikipédia · CC BY-SA 4.0")
        #expect(SourcesListPresentation.licenseAttribution(for: source("https://petit-site.org/", key: "marginalia"))?.text
            == "Résultat Marginalia Search · CC BY-NC-SA 4.0")
        #expect(SourcesListPresentation.licenseAttribution(for: source("https://arxiv.org/abs/2401.00001"))?.licenseURL == nil)
        #expect(SourcesListPresentation.licenseAttribution(for: source("https://lemonde.fr/")) == nil)
    }

    @Test("licenseKey survit à l'encodage ; l'ancien historique sans clé se relit")
    func licenseKeyCodable() throws {
        var result = SearXNGSearchResult(title: "t", url: "https://a.org/", content: "c", imgSrc: nil, thumbnailSrc: nil,
                                         thumbnail: nil, author: nil, iframeSrc: nil)
        result.licenseKey = "marginalia"
        let decoded = try JSONDecoder().decode(SearXNGSearchResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.licenseKey == "marginalia")
        let legacy = try JSONDecoder().decode(SearXNGSearchResult.self, from: Data(#"{"title":"t","url":"https://a.org/"}"#.utf8))
        #expect(legacy.licenseKey == nil)
    }
}

@Suite("Mentions : météo et marquage IA")
struct AttributionTextTests {
    @Test("Attribution météo : texte et deux liens (Open-Meteo, CC BY 4.0)")
    func weatherAttribution() {
        let text = WeatherAttribution.attributedText
        #expect(String(text.characters) == "Données météo : Open-Meteo.com (CC BY 4.0)")
        let links = text.runs.compactMap(\.link)
        #expect(links == [WeatherAttribution.siteURL, WeatherAttribution.licenseURL])
    }

    @Test("Marquage IA : ligne finale ajoutée une seule fois, texte vide inchangé")
    func aiMarking() {
        let marked = AIGeneratedMarking.marked("Paris est la capitale de la France.  \n")
        #expect(marked == "Paris est la capitale de la France.\n\n— Réponse générée par IA avec Triva")
        #expect(AIGeneratedMarking.marked(marked) == marked)
        #expect(AIGeneratedMarking.marked("") == "")
    }
}

@Suite("PDFCopyPolicy — PDF à copie interdite (décision de Ben, 2026-11-17)")
struct PDFCopyPolicyTests {
    @Test("Lu si la copie est permise, ou si seule l'accessibilité l'est ; refusé sinon")
    func decisionTable() {
        #expect(PDFCopyPolicy.allowsReading(allowsCopying: true, allowsContentAccessibility: true))
        #expect(PDFCopyPolicy.allowsReading(allowsCopying: true, allowsContentAccessibility: false))
        #expect(PDFCopyPolicy.allowsReading(allowsCopying: false, allowsContentAccessibility: true))
        #expect(!PDFCopyPolicy.allowsReading(allowsCopying: false, allowsContentAccessibility: false))
    }

    @Test("Message de refus : clair, affiché tel quel à l'utilisateur")
    func refusalMessage() {
        #expect(AttachmentExtractionError.copyProtectedPDF.userFacingMessage
            == "Ce PDF interdit la copie de son texte : Triva ne peut pas le lire.")
        #expect(FileAttachmentPresentation.failureMessage(for: AttachmentExtractionError.copyProtectedPDF) == PDFCopyPolicy.refusalMessage)
    }
}
