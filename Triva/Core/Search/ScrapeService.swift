//
//  ScrapeService.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Une page scrapée : titre + contenu principal borné (protection NIVEAU 1
/// anti-overflow, `maxContentCharactersPerPage`). `succeeded = false` signale
/// un échec (URL refusée, réseau, statut, non-HTML, page vide...), jamais un
/// `throw`. `nonisolated` (donnée pure) : construite hors du main actor, et sa
/// conformance `Equatable` cesse d'être isolée au main actor.
nonisolated struct ScrapedPage: Sendable, Equatable {
    let url: String
    let title: String
    let content: String
    let succeeded: Bool
}

/// Abstraction pour permettre le mock dans `SearchOrchestrator` et les tests,
/// sans réseau réel — même principe que `SearXNGSearching`. `nonisolated` :
/// sans lui, `-default-isolation=MainActor` isolait l'exigence au main actor
/// (vérifié en Swift 6.4) — chaque scrape, même lancé depuis le `TaskGroup`
/// de `SearchOrchestrator`, revenait sur le thread principal, et les scrapes
/// « parallèles » s'y exécutaient l'un après l'autre. Nécessaire mais pas
/// suffisant : voir le `@concurrent` de `ScrapeService.scrape(url:)`.
nonisolated protocol ScrapeServing: Sendable {
    func scrape(url: String) async -> ScrapedPage
}

/// Réponse dont seuls les en-têtes sont arrivés, plus le flux de son corps :
/// permet de refuser une réponse (statut, type MIME) AVANT d'en télécharger
/// le premier octet, puis d'arrêter la lecture à un plafond — impossible avec
/// `URLSession.data(for:)`, qui charge tout le corps en mémoire avant de
/// rendre la main (un PDF de 150 Mo compris).
nonisolated struct URLByteStream: Sendable {
    let response: URLResponse
    let bytes: any AsyncSequence<UInt8, any Error> & Sendable
    /// Annule la requête (sans effet si elle est terminée, rappelable) :
    /// sinon le téléchargement continue après qu'on a cessé de lire.
    let cancel: @Sendable () -> Void
}

/// Point d'abstraction réseau minimal (implémentation `URLSession` par
/// défaut) : mock du statut HTTP, du Content-Type ou d'un timeout sans vrai
/// réseau ni `URLProtocol` (style DI du projet, voir `SearXNGSearching`).
/// `nonisolated`, protocole ET implémentation réelle : sinon le motif
/// `fetcher: any URLFetching = URLSessionFetcher()` est rejeté en Swift 6
/// (« main actor-isolated default value in a nonisolated context »).
nonisolated protocol URLFetching: Sendable {
    /// Corps complet en mémoire : pour les petites réponses JSON (météo).
    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse)

    /// Corps lu à la demande, pour les pages web de taille inconnue. Exigence
    /// DU PROTOCOLE, pas simple méthode d'extension : sinon un appel via
    /// `any URLFetching` serait résolu statiquement vers le repli ci-dessous,
    /// et la vraie lecture en flux de `URLSessionFetcher` jamais exécutée.
    func streamBytes(url: URL, timeout: TimeInterval) async throws -> URLByteStream
}

/// `nonisolated` explicite : dans la cible app, une extension reste isolée au
/// main actor par défaut MÊME quand le protocole étendu est `nonisolated`
/// (vérifié en Swift 6.4) — le repli renverrait son flux à travers une
/// frontière d'isolation.
nonisolated extension URLFetching {
    /// Repli pour les conformances qui n'implémentent que `fetch` (mocks
    /// existants, ex. `WeatherWidgetServiceTests`) : télécharge tout, PUIS
    /// rejoue les octets — aucune borne réelle, réservé aux mocks.
    func streamBytes(url: URL, timeout: TimeInterval) async throws -> URLByteStream {
        let (data, response) = try await fetch(url: url, timeout: timeout)
        let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
            data.forEach { continuation.yield($0) }
            continuation.finish()
        }
        return URLByteStream(response: response, bytes: bytes, cancel: {})
    }
}

/// Implémentation `URLSession` réelle. User-Agent desktop custom, même
/// intention que le spoofing de la version web d'origine — sans le masquage de
/// `navigator.webdriver`, sans objet hors d'un vrai navigateur. Session
/// sans cache par défaut (widget météo : la ville et les coordonnées sont des
/// données personnelles qui n'ont pas à rester dans `Cache.db`) ; le scraping
/// injecte la sienne, voir `ScrapeService.scrapingSession`.
nonisolated struct URLSessionFetcher: URLFetching {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    let urlSession: URLSession

    init(urlSession: URLSession = URLSessionDataRequester.uncachedSession) {
        self.urlSession = urlSession
    }

    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        try await urlSession.data(for: Self.request(url: url, timeout: timeout))
    }

    /// `bytes(for:)` rend la main dès les en-têtes reçus ; le corps arrive
    /// au fil de la lecture, et `cancel` coupe la tâche de données.
    func streamBytes(url: URL, timeout: TimeInterval) async throws -> URLByteStream {
        let (bytes, response) = try await urlSession.bytes(for: Self.request(url: url, timeout: timeout))
        let task = bytes.task
        return URLByteStream(response: response, bytes: bytes, cancel: { task.cancel() })
    }

    /// `timeoutInterval` d'une `URLRequest` = délai d'INACTIVITÉ (aucun octet
    /// reçu pendant ce délai), pas une durée totale de téléchargement.
    private static func request(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// Port de la lecture de pages de la version web d'origine en Foundation pur — zéro dépendance, pas de
/// `NSAttributedString(html:)` (dépréciée, contrainte au thread principal).
///
/// DIVERGENCE MAJEURE assumée : la version web d'origine pilote un vrai Chromium headless
/// (Playwright) qui exécute le JS ; `URLSession` ne récupère que le HTML
/// initial — une SPA (rendu React/Vue côté client) donne un contenu vide,
/// signalé en échec (`minimumContentCharacters`). Un rendu `WKWebView` hors
/// écran reste une idée V2. L'extraction approxime `@mozilla/readability`
/// sans arbre DOM, voir `scoreAndSelectMainBlock`.
///
/// CONCURRENCE : `nonisolated` + `@concurrent` sur `scrape(url:)`. Sous
/// `NonisolatedNonsendingByDefault` (réglage `SWIFT_APPROACHABLE_CONCURRENCY`),
/// une méthode `nonisolated async` s'exécute sur l'acteur de SON APPELANT :
/// sans `@concurrent`, un appel depuis le main actor y ferait tourner la
/// lecture octet par octet puis toute l'extraction regex d'un document de
/// 2 Mo — défilement, saisie et bouton Stop figés.
nonisolated struct ScrapeService: ScrapeServing {
    // MARK: - Réglages

    /// Délai d'INACTIVITÉ par requête, pas une durée totale (bornée par
    /// `maxPageLoadDuration`). Raccourci vs les 20 s de la version web d'origine, qui
    /// attend aussi le rendu JS d'un vrai navigateur.
    static let defaultIdleTimeout: TimeInterval = 8

    /// Durée TOTALE maximale d'une page (`timeoutIntervalForResource`, 7 jours
    /// par défaut) : un serveur au compte-gouttes relançait indéfiniment le
    /// délai d'inactivité, et `SearchOrchestrator`, qui attend tous les
    /// scrapes d'un tour, attendait avec lui. Le corps déjà reçu à
    /// l'expiration reste exploité (voir `readBoundedBody`).
    static let maxPageLoadDuration: TimeInterval = 12

    /// Plafond d'octets LUS, plus seulement traités : la lecture s'arrête là
    /// et la requête est annulée ; le début d'une page trop longue sert.
    static let defaultMaxDownloadBytes = 2_000_000
    static let defaultMaxContentCharactersPerPage = 4000

    /// Créée UNE fois (une `URLSession` configurée non invalidée n'est jamais
    /// libérée). `.ephemeral` : cookies et cache jamais écrits sur disque, un
    /// site ne suit pas l'utilisateur d'un lancement à l'autre ; `urlCache`
    /// nul, une page n'est lue qu'une fois. Cellulaire : coût borné par le plafond.
    static let scrapingSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ScrapeService.defaultIdleTimeout
        configuration.timeoutIntervalForResource = ScrapeService.maxPageLoadDuration
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5"]
        return URLSession(configuration: configuration)
    }()

    /// Contenu extrait plus court : échec (voir `page`). Seuil de Readability
    /// pour qu'un paragraphe compte — en dessous, rien d'exploitable.
    static let minimumContentCharacters = 25

    private let fetcher: any URLFetching
    private let timeoutInterval: TimeInterval
    private let maxDownloadBytes: Int
    private let maxContentCharactersPerPage: Int

    /// Constructeur de production : construit un `URLSessionFetcher` plutôt
    /// que d'exposer `URLFetching` (détail réservé aux tests).
    init(
        urlSession: URLSession = ScrapeService.scrapingSession,
        timeoutInterval: TimeInterval = ScrapeService.defaultIdleTimeout,
        maxDownloadBytes: Int = ScrapeService.defaultMaxDownloadBytes,
        maxContentCharactersPerPage: Int = ScrapeService.defaultMaxContentCharactersPerPage
    ) {
        self.init(
            fetcher: URLSessionFetcher(urlSession: urlSession),
            timeoutInterval: timeoutInterval,
            maxDownloadBytes: maxDownloadBytes,
            maxContentCharactersPerPage: maxContentCharactersPerPage
        )
    }

    /// Constructeur d'injection de test : `URLFetching` mocké.
    init(
        fetcher: any URLFetching,
        timeoutInterval: TimeInterval = ScrapeService.defaultIdleTimeout,
        maxDownloadBytes: Int = ScrapeService.defaultMaxDownloadBytes,
        maxContentCharactersPerPage: Int = ScrapeService.defaultMaxContentCharactersPerPage
    ) {
        self.fetcher = fetcher
        self.timeoutInterval = timeoutInterval
        self.maxDownloadBytes = maxDownloadBytes
        self.maxContentCharactersPerPage = maxContentCharactersPerPage
    }

    // MARK: - Scrape

    /// Ne throw JAMAIS, fidèle à la version web d'origine : un scrape raté sur UNE URL
    /// ne doit pas faire échouer tout un tour d'orchestration
    /// (`SearchOrchestrator` n'a pas besoin de `try`). Refus du moins cher au
    /// plus cher : URL (aucune requête), en-têtes (aucun octet de corps lu),
    /// corps plafonné, contenu vide (aucune part du budget de contexte). Le
    /// `defer` annule la requête sur TOUTES les sorties.
    @concurrent
    func scrape(url: String) async -> ScrapedPage {
        guard let parsedURL = URL(string: url), Self.isScrapable(parsedURL) else {
            return Self.failedPage(url)
        }
        let stream: URLByteStream
        do {
            stream = try await fetcher.streamBytes(url: parsedURL, timeout: timeoutInterval)
        } catch {
            return Self.failedPage(url)
        }
        defer { stream.cancel() }

        guard
            let httpResponse = stream.response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            Self.isHTML(httpResponse)
        else {
            return Self.failedPage(url)
        }

        let body = await Self.readBoundedBody(
            stream.bytes,
            maxBytes: maxDownloadBytes,
            expectedLength: httpResponse.expectedContentLength
        )
        // Scrape annulé (bouton Stop) : inutile de payer l'extraction.
        guard !Task.isCancelled else { return Self.failedPage(url) }

        let html = Self.decodeHTML(body.bytes, isTruncated: body.isTruncated, declaredCharset: httpResponse.textEncodingName)
        return Self.page(url: url, html: html, maxCharacters: maxContentCharactersPerPage)
    }

    /// Refus AVANT toute requête. Schéma non http(s) : un planner LLM qui
    /// renverrait `file:///…` ferait lire un fichier local, ensuite envoyé
    /// dans le prompt (parfois à un fournisseur cloud). Extension binaire : un
    /// PDF Scholar/arXiv pèse souvent 30 à 150 Mo ; sans extension
    /// (`arxiv.org/pdf/2401.00001`), refus dès les en-têtes (`isHTML`).
    static func isScrapable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !binaryFileExtensions.contains(url.pathExtension.lowercased())
    }

    private static let binaryFileExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "epub", "rtf", "zip", "gz", "tgz", "bz2",
        "xz", "rar", "7z", "tar", "dmg", "iso", "exe", "msi", "apk", "ipa", "pkg", "jpg", "jpeg", "png", "gif", "webp",
        "heic", "avif", "bmp", "tif", "tiff", "ico", "mp3", "mp4", "m4a", "m4v", "mov", "avi", "mkv", "webm", "wav", "flac", "ogg",
    ]

    /// AJOUT vs la version web d'origine (masqué là-bas par le navigateur, qui tente de
    /// tout rendre) : une réponse PDF/JSON/image donnerait un texte absurde
    /// après le stripping regex. Décidé sur les en-têtes, sans lire le corps.
    static func isHTML(_ response: HTTPURLResponse) -> Bool {
        let mimeType = (response.mimeType ?? response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return mimeType.contains("text/html") || mimeType.contains("application/xhtml+xml")
    }

    /// Au plus `maxBytes` octets. `isTruncated` = plafond atteint OU erreur en
    /// cours de lecture (typiquement `maxPageLoadDuration`) : le début d'une
    /// page, où est l'article, reste exploitable. `Content-Length` ne fait que
    /// dimensionner le tampon (une page annoncée trop grosse n'est pas
    /// refusée). `Task.isCancelled` vérifié tous les 64 Kio.
    static func readBoundedBody(
        _ bytes: some AsyncSequence<UInt8, any Error>,
        maxBytes: Int,
        expectedLength: Int64
    ) async -> (bytes: [UInt8], isTruncated: Bool) {
        guard maxBytes > 0 else { return ([], true) }
        var buffer: [UInt8] = []
        buffer.reserveCapacity(Int(min(max(expectedLength, 0), Int64(maxBytes))))
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= maxBytes { return (buffer, true) }
                if buffer.count.isMultiple(of: 65_536), Task.isCancelled { return (buffer, true) }
            }
            return (buffer, false)
        } catch {
            return (buffer, true)
        }
    }

    /// Page vide ou quasi vide (squelette d'app JS, mur de consentement…) :
    /// échec plutôt que succès vide. BUG corrigé : `formatScrapedPages`
    /// répartit le budget de contexte entre les pages RÉUSSIES, un succès sans
    /// contenu en consommait une part pour rien.
    private static func page(url: String, html: String, maxCharacters: Int) -> ScrapedPage {
        let (title, content) = extractMainContent(fromHTML: html)
        guard content.count >= minimumContentCharacters else { return failedPage(url) }
        // Mission A5 : une page « Je m'assure que vous n'êtes pas un robot »
        // (HTTP 200, texte assez long) n'est pas une source : échec, non citable.
        guard !BotChallengeDetector.isChallenge(html: html, title: title, content: content) else { return failedPage(url) }
        let chunk = firstChunk(of: content, maxCharacters: maxCharacters)
        return ScrapedPage(url: url, title: title.isEmpty ? url : title, content: chunk, succeeded: true)
    }

    private static func failedPage(_ url: String) -> ScrapedPage {
        ScrapedPage(url: url, title: url, content: "", succeeded: false)
    }

    // MARK: - Décodage du charset

    nonisolated enum TextEncoding: Equatable, Sendable {
        case utf8
        /// Aussi `iso-8859-1` et `us-ascii` déclarés : le standard WHATWG (celui
        /// des navigateurs) les lit en windows-1252, dont les octets 0x80–0x9F
        /// portent ’ œ € … au lieu de caractères de contrôle.
        case windows1252
        case other(String.Encoding)
    }

    /// Priorité des navigateurs (WHATWG) : BOM UTF-8, charset HTTP, `<meta
    /// charset>`, détection. BUG corrigé : le charset déclaré était ignoré et
    /// TOUTE la page basculait en Latin-1 au premier octet UTF-8 invalide (un
    /// octet parasite → « Ã‰lÃ¨ve … lâ€™Ã©cole » ; windows-1252 → ’ œ € en
    /// caractères de contrôle).
    static func decodeHTML(_ bytes: [UInt8], isTruncated: Bool, declaredCharset: String?) -> String {
        switch resolveEncoding(declaredCharset: declaredCharset, head: bytes.prefix(charsetSniffingByteCount)) {
        case .utf8:
            // Tolérant : un octet invalide devient « � », le reste est intact.
            return String(decoding: utf8Payload(bytes, isTruncated: isTruncated), as: UTF8.self)
        case .windows1252:
            return decodeWindows1252(bytes)
        case .other(let encoding):
            return decode(bytes, as: encoding, isTruncated: isTruncated) ?? detectAndDecode(bytes, isTruncated: isTruncated)
        case nil:
            return detectAndDecode(bytes, isTruncated: isTruncated)
        }
    }

    /// Le standard n'examine que 1 024 octets ; un `<head>` chargé repousse
    /// parfois le `<meta>` plus loin, la marge ne coûte rien.
    private static let charsetSniffingByteCount = 2048
    private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func resolveEncoding(declaredCharset: String?, head: ArraySlice<UInt8>) -> TextEncoding? {
        if head.starts(with: utf8ByteOrderMark) { return .utf8 }
        if let declaredCharset, let encoding = encoding(forCharsetLabel: declaredCharset) { return encoding }
        return metaCharsetLabel(in: head).flatMap(encoding(forCharsetLabel:))
    }

    /// Nom de charset → encodage, via la table IANA de CoreFoundation
    /// (`iso-8859-15`, `shift_jis`, `windows-1251`…) plus l'alias `x-cp1252`
    /// qu'elle ignore (vérifié). `nil` = charset inconnu.
    static func encoding(forCharsetLabel label: String) -> TextEncoding? {
        let name = label.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))).lowercased()
        if name == "x-cp1252" { return .windows1252 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        switch encoding {
        case .utf8: return .utf8
        case .windowsCP1252, .isoLatin1, .ascii: return .windows1252
        default: return .other(encoding)
        }
    }

    /// `<meta charset>` ou `<meta http-equiv="Content-Type" content="…;
    /// charset=…">`, lu en Latin-1 : accepte tout octet, ASCII intact.
    private static func metaCharsetLabel(in head: ArraySlice<UInt8>) -> String? {
        let text = String(bytes: head, encoding: .isoLatin1) ?? ""
        let nsText = text as NSString
        guard let match = metaCharsetRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    /// Octets à lire en UTF-8 : sans BOM et, lecture coupée, sans la séquence
    /// multi-octets incomplète de la fin — sinon un « � » final (ou, avec
    /// l'ancien repli Latin-1, un caractère corrompu).
    private static func utf8Payload(_ bytes: [UInt8], isTruncated: Bool) -> ArraySlice<UInt8> {
        let withoutMark = bytes.starts(with: utf8ByteOrderMark) ? bytes.dropFirst(utf8ByteOrderMark.count) : bytes[...]
        return isTruncated ? droppingIncompleteTrailingSequence(withoutMark) : withoutMark
    }

    /// Recule jusqu'à l'octet de tête de la dernière séquence (au plus 3
    /// octets de continuation `10xxxxxx`) et la retire si elle annonce plus
    /// d'octets qu'il n'en reste.
    private static func droppingIncompleteTrailingSequence(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard let leadIndex = bytes.indices.reversed().prefix(4).first(where: { bytes[$0] & 0xC0 != 0x80 }) else {
            return bytes
        }
        let lead = bytes[leadIndex]
        let expectedLength = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.endIndex - leadIndex < expectedLength ? bytes[..<leadIndex] : bytes
    }

    /// Charset non déclaré : UTF-8 s'il est valide (l'immense majorité). Sinon
    /// détection, que le standard WHATWG autorise (défaut windows-1252 en
    /// locale française) — un UTF-8 tolérant d'office mettrait « � » à chaque
    /// accent d'une vieille page Latin-1 : UTF-8 abîmé si les caractères non
    /// ASCII bien décodés l'emportent sur les octets invalides, windows-1252
    /// sinon (« é » = 0xE9 + lettre ASCII n'est jamais de l'UTF-8 valide).
    private static func detectAndDecode(_ bytes: [UInt8], isTruncated: Bool) -> String {
        let payload = utf8Payload(bytes, isTruncated: isTruncated)
        if let valid = String(validating: payload, as: UTF8.self) { return valid }
        let lenient = String(decoding: payload, as: UTF8.self)
        var decodedNonASCIICount = 0
        var replacementCount = 0
        for scalar in lenient.unicodeScalars where !scalar.isASCII {
            if scalar == "\u{FFFD}" { replacementCount += 1 } else { decodedNonASCIICount += 1 }
        }
        return decodedNonASCIICount > replacementCount ? lenient : decodeWindows1252(bytes)
    }

    /// Repli ISO Latin-1 (accepte tout octet) si la page contient l'un des 5
    /// octets que windows-1252 laisse indéfinis (0x81, 0x8D, 0x8F, 0x90, 0x9D),
    /// car Foundation refuse alors la page entière (vérifié). Dernier repli
    /// UTF-8 tolérant, jamais atteint en pratique : rien n'est forcé.
    private static func decodeWindows1252(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .windowsCP1252)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Autre charset déclaré (`iso-8859-15`, `shift_jis`…) : lecture coupée au
    /// milieu d'un caractère multi-octets, recul d'au plus 3 octets ; échec
    /// persistant (charset mensonger), `nil` → détection.
    private static func decode(_ bytes: [UInt8], as encoding: String.Encoding, isTruncated: Bool) -> String? {
        let maxBacktrack = isTruncated ? min(3, bytes.count) : 0
        for backtrack in 0...maxBacktrack {
            if let text = String(bytes: bytes.dropLast(backtrack), encoding: encoding) { return text }
        }
        return nil
    }

    // MARK: - Extraction, fonctions pures statiques testables sans réseau

    static func extractMainContent(fromHTML html: String) -> (title: String, content: String) {
        let title = extractTitle(from: html)
        let content = scoreAndSelectMainBlock(fromCleanedHTML: stripNonContentTags(html))
        return (title, content)
    }

    private static func extractTitle(from html: String) -> String {
        let nsHTML = html as NSString
        guard let match = titleRegex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else {
            return ""
        }
        return visibleText(of: nsHTML.substring(with: match.range(at: 1)))
    }

    /// Retire le non-contenu AVANT la sélection (« unlikely candidates » de
    /// Readability, portable sans DOM) : 0. valeurs `data-*` contenant `<` ou
    /// `>` — BUG corrigé (mesuré le 2026-11-05 sur Wikipédia) : `data-mw` y
    /// porte le wikicode des modèles, balises comprises ; `<[^>]+>` s'arrêtait
    /// au premier `>` de la valeur et la suite passait pour du texte, si bien
    /// que les 4 000 caractères retenus n'étaient que du wikicode, sans
    /// l'introduction. Une valeur sans balise reste : `data-role="menu"`, cité
    /// dans une documentation, est du contenu ;
    /// 1. commentaires d'abord (un `<nav>`
    /// commenté ne s'apparie pas avec le `</nav>` réel suivant) ; 2. éléments
    /// à texte brut (script/style/noscript/template) ; 3. `<head>` (seul son
    /// `<title>` compte, extrait à part ; Readability ne lit que `<body>`),
    /// svg, nav, footer, aside, `<select>`, `<textarea>` ; 4. `<form>` DÉBALLÉ
    /// (balises et `<input>` retirés, contenu gardé) — BUG corrigé : une page
    /// ASP.NET WebForms / SharePoint met tout son `<body>` dans un
    /// `<form id="aspnetForm">`, que la suppression en bloc vidait ;
    /// `<button>` gardé, souvent la question d'une FAQ en accordéon ;
    /// 5. `<header>` seulement HORS `<article>`/`<main>` — BUG corrigé : le
    /// chapô d'un `<article><header>` était perdu. Non-greedy correct ICI :
    /// ces éléments ne s'imbriquent pas en eux-mêmes (contrairement aux
    /// `<div>`). Nom suivi d'un blanc, `/` ou `>` : `<style-guide>` n'est pas
    /// un `<style>`.
    static func stripNonContentTags(_ html: String) -> String {
        var result = replacing(markupInDataAttributeRegex, in: html, with: "")
        result = replacing(commentRegex, in: result, with: "")
        result = replacing(rawTextElementRegex, in: result, with: "")
        result = replacing(nonContentElementRegex, in: result, with: "")
        result = replacing(formWrapperRegex, in: result, with: "")
        return removingHeadersOutsideContentContainers(result)
    }

    /// Sans DOM, suit la profondeur `<article>`/`<main>` au fil des balises
    /// qui précèdent chaque `<header>` : en-tête du site ou de l'article ?
    private static func removingHeadersOutsideContentContainers(_ html: String) -> String {
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)
        let headers = headerElementRegex.matches(in: html, range: fullRange)
        guard !headers.isEmpty else { return html }
        let containerTags = contentContainerTagRegex.matches(in: html, range: fullRange)

        var result = ""
        var cursor = 0
        var tagIndex = 0
        var depth = 0
        for header in headers {
            while tagIndex < containerTags.count, containerTags[tagIndex].range.location < header.range.location {
                let isClosingTag = containerTags[tagIndex].range(at: 1).length > 0
                depth = max(0, depth + (isClosingTag ? -1 : 1))
                tagIndex += 1
            }
            guard depth == 0 else { continue }
            result += nsHTML.substring(with: NSRange(location: cursor, length: header.range.location - cursor))
            cursor = header.range.location + header.range.length
        }
        return result + nsHTML.substring(from: cursor)
    }

    /// Contenu principal SANS arbre DOM (simplification assumée de la
    /// propagation de score de Readability), renvoyé en TEXTE VISIBLE. Un
    /// appariement `<div>...</div>` non-greedy s'arrêterait à la PREMIÈRE
    /// fermante, cassé sur du HTML imbriqué : on découpe plutôt en SEGMENTS
    /// sur les frontières de bloc (`</p>`, `</div>`, `</section>`,
    /// `</article>`, `</td>`, `</li>`, `<br>`), candidats INDÉPENDANTS dont
    /// ceux au score POSITIF sont concaténés dans l'ordre du document. Texte
    /// visible calculé UNE fois par segment et réutilisé (longueur,
    /// ponctuation, densité de liens, assemblage), plus refait à chaque étape.
    static func scoreAndSelectMainBlock(fromCleanedHTML html: String) -> String {
        let candidates = splitIntoBlockSegments(html).compactMap(candidate(fromSegment:))
        // Aucun segment assez long (vers courts, page minuscule) : tout le texte
        // visible plutôt que rien ; `page` tranche ensuite sur la page vide.
        guard !candidates.isEmpty else { return visibleText(of: html) }
        let positive = candidates.filter { $0.score > 0 }
        // Aucun score positif (page entièrement liens) : le meilleur segment
        // quand même, un contenu pauvre vaut mieux qu'un échec silencieux.
        guard !positive.isEmpty else {
            return candidates.max(by: { $0.score < $1.score })?.text ?? ""
        }
        return positive.map(\.text).joined(separator: " ")
    }

    private nonisolated struct SegmentCandidate {
        let text: String
        let score: Double
    }

    private static func splitIntoBlockSegments(_ html: String) -> [String] {
        let nsHTML = html as NSString
        var segments: [String] = []
        var lastEnd = 0
        for match in blockBoundaryRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let end = match.range.location + match.range.length
            segments.append(nsHTML.substring(with: NSRange(location: lastEnd, length: end - lastEnd)))
            lastEnd = end
        }
        if lastEnd < nsHTML.length {
            segments.append(nsHTML.substring(from: lastEnd))
        }
        return segments
    }

    /// Filtre sur le TEXTE VISIBLE. BUG corrigé : la longueur HTML BRUTE
    /// comparée à 40 supprimait `<li>4 œufs</li>` ou `<td>1,20 €</td>`. Seuil
    /// de Readability (25) pour un paragraphe ; texte non vide pour un item de
    /// liste ou une cellule (une liste de liens reste écartée par sa densité).
    private static func candidate(fromSegment segment: String) -> SegmentCandidate? {
        let text = visibleText(of: segment)
        let closingTag = segment.suffix(5).lowercased()
        let isListOrTableItem = closingTag == "</li>" || closingTag == "</td>"
        guard text.count >= (isListOrTableItem ? 1 : 25) else { return nil }
        return SegmentCandidate(text: text, score: score(segment: segment, visibleText: text))
    }

    private static let positiveKeywords = ["article", "body", "content", "main", "post", "entry"]
    private static let negativeKeywords = ["comment", "sidebar", "nav", "footer", "widget", "sponsor"]

    /// Longueur + ponctuation − densité de liens ± mots-clés, ces derniers
    /// cherchés UNIQUEMENT dans les `class`/`id` (`_getClassWeight` de
    /// Readability), par PRÉFIXE de token. BUG corrigé : `contains` sur TOUT le
    /// segment brut — « Voici comment vider le cache de votre navigateur »
    /// contenait « comment » et « nav » (-1000, exclu). Préfixe : `comments`,
    /// `commentaires`, `navbar` reconnus ; token : `unavailable` ne contient
    /// plus « nav ». Pénalité disproportionnée vs le bonus : un segment
    /// "comments" dense en texte reste exclu malgré sa longueur.
    private static func score(segment: String, visibleText: String) -> Double {
        let textLength = Double(visibleText.count)
        guard textLength > 0 else { return 0 }
        let linkDensity = min(1, weightedLinkTextLength(in: segment) / textLength)
        let strongPunctuationCount = Double(visibleText.filter { $0 == "," || $0 == "." }.count)

        let tokens = classAndIDTokens(in: segment)
        var keywordBonus = 0.0
        for keyword in positiveKeywords where tokens.contains(where: { $0.hasPrefix(keyword) }) {
            keywordBonus += 30
        }
        for keyword in negativeKeywords where tokens.contains(where: { $0.hasPrefix(keyword) }) {
            keywordBonus -= 500
        }
        return textLength + strongPunctuationCount * 2 - linkDensity * textLength * 2 + keywordBonus
    }

    /// Tokens (lettres, chiffres) des `class`/`id` des balises OUVRANTES
    /// réelles, jamais du texte : un exemple de code échappé
    /// (`&lt;div class="comment"&gt;`) n'est pas une balise.
    private static func classAndIDTokens(in segment: String) -> [String] {
        let nsSegment = segment as NSString
        var tokens: [String] = []
        for tagMatch in openingTagRegex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length)) {
            let tag = nsSegment.substring(with: tagMatch.range)
            let nsTag = tag as NSString
            for attribute in classOrIDAttributeRegex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
                // Trois groupes exclusifs : "valeur", 'valeur', valeur nue.
                guard let valueRange = (1...3).map(attribute.range(at:)).first(where: { $0.location != NSNotFound }) else {
                    continue
                }
                let value = nsTag.substring(with: valueRange).lowercased()
                tokens += value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            }
        }
        return tokens
    }

    /// Longueur du texte VISIBLE des liens ; lien interne (`href="#…"`, renvoi
    /// de note) pondéré 0,3 comme dans `_getLinkDensity` de Readability. BUG
    /// corrigé : on additionnait le HTML BRUT des `<a>` — une intro Wikipédia
    /// de 455 caractères truffée de renvois `<a href="#cite_note-3"><span
    /// class="cite-bracket">&#91;</span>3…</a>` (~72 caractères bruts chacun)
    /// mesurait 0,86 au lieu de ~0,2 et disparaissait (idem d'un lien `<svg>`).
    private static func weightedLinkTextLength(in segment: String) -> Double {
        let nsSegment = segment as NSString
        let links = linkRegex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))
        return links.reduce(0) { total, link in
            let attributes = nsSegment.substring(with: link.range(at: 1))
            let attributesRange = NSRange(location: 0, length: (attributes as NSString).length)
            let isInPageAnchor = hashHrefRegex.firstMatch(in: attributes, range: attributesRange) != nil
            let linkTextLength = Double(visibleText(of: nsSegment.substring(with: link.range(at: 2))).count)
            return total + linkTextLength * (isInPageAnchor ? 0.3 : 1)
        }
    }

    /// Texte tel qu'affiché : balises remplacées par une espace (deux mots
    /// séparés par une balise ne se collent pas), entités décodées, blancs
    /// normalisés.
    static func visibleText(of html: String) -> String {
        let decoded = decodeHTMLEntities(replacing(tagRegex, in: html, with: " "))
        return replacing(whitespaceRegex, in: decoded, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chunking générique

    /// Premier chunk de `splitIntoChunks(text, maxCharacters:, overlapCharacters: 0)`
    /// sans découper tout le contenu d'une page de 2 Mo pour n'en garder que le
    /// début. Résultat identique (test d'équivalence dédié) : seules comptent
    /// les frontières finissant AU PLUS à `maxCharacters`, et le motif ne lit
    /// jamais au-delà du caractère qui suit une suite de blancs — une fenêtre
    /// de `maxCharacters + 1` suffirait ; la marge de 32 absorbe une évolution
    /// future du motif.
    static func firstChunk(of text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return text }
        let lookahead = 32
        let windowLength = maxCharacters > Int.max - lookahead ? Int.max : maxCharacters + lookahead
        return splitIntoChunks(String(text.prefix(windowLength)), maxCharacters: maxCharacters, overlapCharacters: 0).first ?? ""
    }

    /// Segmentation par phrases avec fenêtre glissante à chevauchement —
    /// proxy direct du découpage de la version web d'origine, sans tokenizer BPE réel :
    /// `maxCharacters`/`overlapCharacters` jouent le rôle des tokens (la version web d'origine
    /// retombe lui-même sur caractères/4 en cas d'échec d'encodage cl100k).
    ///
    /// GARDE-FOU ANTI-BLOCAGE : sans AUCUNE frontière dans la fenêtre, une
    /// boucle naïve ne progresserait jamais. Ici la progression est GARANTIE
    /// (au moins un caractère par itération) : coupe nette à `maxCharacters`
    /// faute de frontière, chevauchement forcé à avancer s'il ramènerait le
    /// départ en arrière — au plus `text.count` itérations.
    static func splitIntoChunks(_ text: String, maxCharacters: Int, overlapCharacters: Int) -> [String] {
        guard maxCharacters > 0 else { return text.isEmpty ? [] : [text] }
        guard !text.isEmpty else { return [] }

        let boundaries = Self.sentenceBoundaryIndices(in: text)
        let clampedOverlap = max(0, min(overlapCharacters, maxCharacters - 1))

        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            guard let hardLimit = text.index(start, offsetBy: maxCharacters, limitedBy: text.endIndex) else {
                // Le reste du texte tient dans une fenêtre : dernier chunk.
                chunks.append(String(text[start...]))
                break
            }
            if hardLimit == text.endIndex {
                chunks.append(String(text[start...]))
                break
            }

            // Meilleure frontière de phrase strictement après `start` et au
            // plus à `hardLimit` ; à défaut, coupe net à `hardLimit`.
            let end = boundaries.last(where: { $0 > start && $0 <= hardLimit }) ?? hardLimit
            chunks.append(String(text[start..<end]))

            let overlapBoundary = text.index(end, offsetBy: -clampedOverlap, limitedBy: start) ?? start
            start = overlapBoundary > start ? overlapBoundary : text.index(after: start)
        }
        return chunks
    }

    private static func sentenceBoundaryIndices(in text: String) -> [String.Index] {
        let nsText = text as NSString
        return sentenceBoundaryRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            Range(match.range, in: text)?.upperBound
        }
    }

    // MARK: - Regex précompilées

    /// Motifs CONSTANTS compilés une fois (`static let` paresseux, thread-safe ;
    /// `NSRegularExpression` est immuable) — l'ancien code en recompilait ~5
    /// par segment. `try!` assumé : aucun motif ne vient de l'extérieur, et
    /// chaque regex est exercée par les tests `ScrapeService*` — une faute de
    /// frappe casse les tests, jamais l'app d'un utilisateur.
    private static func compile(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let markup: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    private static let titleRegex = compile("<title(?=[\\s>])[^>]*>(.*?)</title\\s*>", markup)
    private static let markupInDataAttributeRegex = compile("\\sdata-[\\w.:-]+\\s*=\\s*(?:\"[^\"]*[<>][^\"]*\"|'[^']*[<>][^']*')", [.caseInsensitive])
    private static let commentRegex = compile("<!--.*?-->", [.dotMatchesLineSeparators])
    private static let rawTextElementRegex = compile("<(script|style|noscript|template)(?=[\\s/>])[^>]*>.*?</\\1\\s*>", markup)
    private static let nonContentElementRegex = compile("<(head|svg|nav|footer|aside|select|textarea)(?=[\\s/>])[^>]*>.*?</\\1\\s*>", markup)
    private static let formWrapperRegex = compile("</?form(?=[\\s/>])[^>]*>|<input(?=[\\s/>])[^>]*>", [.caseInsensitive])
    private static let headerElementRegex = compile("<header(?=[\\s/>])[^>]*>.*?</header\\s*>", markup)
    private static let contentContainerTagRegex = compile("<(/?)(?:article|main)(?=[\\s/>])[^>]*>", [.caseInsensitive])
    private static let blockBoundaryRegex = compile("</(?:p|div|section|article|td|li)>|<br\\s*/?>", [.caseInsensitive])
    private static let tagRegex = compile("<[^>]+>")
    private static let whitespaceRegex = compile("\\s+")
    private static let openingTagRegex = compile("<[A-Za-z][^>]*>")
    private static let classOrIDAttributeRegex = compile("\\s(?:class|id)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))", [.caseInsensitive])
    private static let linkRegex = compile("<a(?=[\\s>])([^>]*)>(.*?)</a\\s*>", markup)
    private static let hashHrefRegex = compile("\\shref\\s*=\\s*[\"']?#[^\"'\\s>]", [.caseInsensitive])
    private static let metaCharsetRegex = compile("<meta[^>]+charset\\s*=\\s*[\"']?\\s*([A-Za-z0-9._:-]+)", [.caseInsensitive])
    private static let sentenceBoundaryRegex = compile("(?<=[.!?;:])\\s+|\\n+|(?<=- )|(?<=\\* )")

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}
