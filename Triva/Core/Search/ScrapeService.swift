//
//  ScrapeService.swift
//  Triva
//
//  Created by ben podrojsky on 14/09/2026.
//

import Foundation

/// Une page scrapée : titre + contenu principal extrait, borné en taille
/// (voir `ScrapeService.maxContentCharactersPerPage`, protection NIVEAU 1
/// anti-overflow). `succeeded = false` signale un échec (réseau, statut HTTP,
/// contenu non-HTML, timeout...) — jamais un `throw`, voir
/// `ScrapeServing.scrape(url:)`.
struct ScrapedPage: Sendable, Equatable {
    let url: String
    let title: String
    let content: String
    let succeeded: Bool
}

/// Abstraction pour permettre le mock dans `SearchOrchestrator` et les tests,
/// sans réseau réel — même principe que `SearXNGSearching`.
protocol ScrapeServing: Sendable {
    func scrape(url: String) async -> ScrapedPage
}

/// Point d'abstraction réseau minimal, injecté par défaut avec une
/// implémentation `URLSession` — permet de mocker statut HTTP/Content-Type/
/// timeout dans les tests sans dépendre d'un vrai réseau ni d'un
/// `URLProtocol` personnalisé plus lourd à maintenir (cohérent avec le style
/// DI déjà établi du projet, voir `SearXNGSearching`).
protocol URLFetching: Sendable {
    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse)
}

/// Implémentation `URLSession` réelle. Envoie un User-Agent desktop custom,
/// même intention que le spoofing de `scraper.ts` (web) — sans reproduire le
/// masquage de `navigator.webdriver`, qui n'a pas de sens hors d'un vrai
/// navigateur.
struct URLSessionFetcher: URLFetching {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetch(url: URL, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        return try await urlSession.data(for: request)
    }
}

/// Port de `scrapeURL.ts` (web) en Foundation pur — zéro dépendance externe
/// (voir CLAUDE.md), pas de `NSAttributedString(html:)` (dépréciée, contrainte
/// au thread principal, mal adaptée à du scraping en arrière-plan).
///
/// DIVERGENCE MAJEURE assumée vis-à-vis de la référence : `scraper.ts` pilote
/// un vrai Chromium headless (Playwright) qui exécute le JS avant
/// d'extraire le HTML rendu. `URLSession` ne récupère que le HTML initial
/// servi par le serveur — les sites fortement SPA (rendu React/Vue côté
/// client) donneront un contenu pauvre ou vide. Limitation V0/V1 assumée ;
/// un rendu via `WKWebView` hors-écran resterait une idée V2 (framework
/// système, donc toujours "zéro dépendance"), pas ici.
///
/// L'extraction du contenu principal est une approximation de
/// `@mozilla/readability` (utilisée telle quelle côté web) : sans arbre DOM
/// réel, la propagation de score aux ancêtres n'est pas transposable telle
/// quelle — voir `scoreAndSelectMainBlock` pour la simplification retenue
/// (scoring par segment de texte plutôt que par nœud DOM).
struct ScrapeService: ScrapeServing {
    private let fetcher: any URLFetching
    private let timeoutInterval: TimeInterval
    private let maxDownloadBytes: Int
    private let maxContentCharactersPerPage: Int

    /// Constructeur de production : construit un `URLSessionFetcher` à
    /// partir d'une `URLSession` plutôt que d'exposer `URLFetching` (détail
    /// d'implémentation réservé aux tests) sur le point d'entrée principal.
    /// `timeoutInterval` à 8s (raccourci vs les 20s de `scraper.ts`, qui doit
    /// aussi attendre le rendu JS d'un vrai navigateur) : `SearchOrchestrator`
    /// scrape plusieurs URLs en parallèle dans une boucle bornée par un
    /// nombre d'itérations fixe, un timeout long par page dégraderait vite le
    /// temps de réponse perçu.
    init(
        urlSession: URLSession = .shared,
        timeoutInterval: TimeInterval = 8,
        maxDownloadBytes: Int = 2_000_000,
        maxContentCharactersPerPage: Int = 4000
    ) {
        self.fetcher = URLSessionFetcher(urlSession: urlSession)
        self.timeoutInterval = timeoutInterval
        self.maxDownloadBytes = maxDownloadBytes
        self.maxContentCharactersPerPage = maxContentCharactersPerPage
    }

    /// Constructeur d'injection de test : `URLFetching` mocké, sans réseau
    /// réel ni `URLProtocol` custom.
    init(
        fetcher: any URLFetching,
        timeoutInterval: TimeInterval = 8,
        maxDownloadBytes: Int = 2_000_000,
        maxContentCharactersPerPage: Int = 4000
    ) {
        self.fetcher = fetcher
        self.timeoutInterval = timeoutInterval
        self.maxDownloadBytes = maxDownloadBytes
        self.maxContentCharactersPerPage = maxContentCharactersPerPage
    }

    /// Ne throw JAMAIS (`do`/`catch` interne complet) : fidèle à
    /// `scrapeURL.ts`, qui retourne toujours un objet de repli plutôt que de
    /// propager une erreur — un scrape raté sur UNE URL ne doit jamais faire
    /// échouer tout un tour de la boucle d'orchestration (`SearchOrchestrator`
    /// n'a alors pas besoin de `try` dans son `TaskGroup`).
    func scrape(url: String) async -> ScrapedPage {
        guard let parsedURL = URL(string: url) else {
            return ScrapedPage(url: url, title: url, content: "", succeeded: false)
        }

        do {
            let (data, response) = try await fetcher.fetch(url: parsedURL, timeout: timeoutInterval)

            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                return ScrapedPage(url: url, title: url, content: "", succeeded: false)
            }

            // AJOUT vs `scrapeURL.ts` (absent côté web : masqué par la
            // couche navigateur, qui tente de tout rendre) : sans ce check,
            // une réponse PDF/JSON/image produirait un texte n'importe quoi
            // après un stripping regex agressif.
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.lowercased().contains("text/html") else {
                return ScrapedPage(url: url, title: url, content: "", succeeded: false)
            }

            // AJOUT vs `scrapeURL.ts` : tronque AVANT tout traitement regex,
            // pour éviter un passage regex catastrophique sur une page
            // énorme (le TS n'a pas ce problème, Playwright borne déjà le
            // rendu par sa propre gestion mémoire).
            let isTruncated = data.count > maxDownloadBytes
            let boundedData = isTruncated ? data.prefix(maxDownloadBytes) : data
            guard let html = Self.decodeBoundedHTML(boundedData, isTruncated: isTruncated) else {
                return ScrapedPage(url: url, title: url, content: "", succeeded: false)
            }

            let (title, content) = Self.extractMainContent(fromHTML: html)
            let chunk = Self.splitIntoChunks(content, maxCharacters: maxContentCharactersPerPage, overlapCharacters: 0).first ?? ""
            let resolvedTitle = title.isEmpty ? url : title

            return ScrapedPage(url: url, title: resolvedTitle, content: chunk, succeeded: true)
        } catch {
            return ScrapedPage(url: url, title: url, content: "", succeeded: false)
        }
    }

    /// Décode `boundedData` en `String`, sans jamais corrompre un caractère
    /// multi-octets coupé en deux par la troncature par octets appliquée
    /// juste avant (`maxDownloadBytes`). BUG corrigé : un simple
    /// `String(data:encoding:.utf8) ?? String(data:encoding:.isoLatin1)`
    /// retombait sur Latin-1 dès que l'UTF-8 échouait — y compris quand la
    /// SEULE raison de l'échec était une séquence UTF-8 tronquée en fin de
    /// buffer (page réellement UTF-8, juste coupée au mauvais endroit) ; ce
    /// repli interprétait alors chaque octet orphelin de la séquence comme un
    /// caractère Latin-1 indépendant, produisant du texte corrompu (mojibake)
    /// au lieu d'une troncature propre.
    ///
    /// Si `isTruncated`, on recule d'au plus 3 octets (longueur max d'une
    /// séquence UTF-8) pour retrouver la dernière frontière de caractère
    /// valide avant de retomber sur Latin-1 — seule une page qui n'est
    /// authentiquement PAS de l'UTF-8 (tronquée ou non) doit atterrir sur ce
    /// repli.
    static func decodeBoundedHTML(_ boundedData: Data, isTruncated: Bool) -> String? {
        if let utf8String = String(data: boundedData, encoding: .utf8) {
            return utf8String
        }
        if isTruncated, let repaired = Self.utf8StringByTrimmingIncompleteSequence(boundedData) {
            return repaired
        }
        return String(data: boundedData, encoding: .isoLatin1)
    }

    private static func utf8StringByTrimmingIncompleteSequence(_ data: Data) -> String? {
        let maxBacktrack = min(3, data.count)
        guard maxBacktrack > 0 else { return nil }
        for backtrack in 1...maxBacktrack {
            let candidate = data.prefix(data.count - backtrack)
            if let string = String(data: candidate, encoding: .utf8) {
                return string
            }
        }
        return nil
    }

    // MARK: - Extraction, fonctions pures statiques testables sans réseau

    static func extractMainContent(fromHTML html: String) -> (title: String, content: String) {
        let title = Self.extractTitle(from: html)
        let cleaned = Self.stripNonContentTags(html)
        let mainBlock = Self.scoreAndSelectMainBlock(fromCleanedHTML: cleaned)
        let withoutTags = Self.removeAllTags(mainBlock)
        let decoded = Self.decodeHTMLEntities(withoutTags)
        let normalized = Self.collapseWhitespace(decoded)
        return (title, normalized)
    }

    private static func extractTitle(from html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            return ""
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), let titleRange = Range(match.range(at: 1), in: html) else {
            return ""
        }
        let raw = String(html[titleRange])
        return Self.collapseWhitespace(Self.decodeHTMLEntities(Self.removeAllTags(raw)))
    }

    /// Retire les blocs sans valeur de contenu : script/style/noscript,
    /// commentaires, et conteneurs structurels (nav/header/footer/aside/form)
    /// — étape "unlikely candidates" de Readability, portée fidèlement
    /// puisqu'elle ne dépend pas d'un arbre DOM réel (une simple suppression
    /// de paires de balises nommées).
    static func stripNonContentTags(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "noscript", "nav", "header", "footer", "aside", "form"] {
            result = Self.removeTagPairs(named: tag, from: result)
        }
        result = Self.replace(pattern: "<!--.*?-->", in: result, with: "", options: [.dotMatchesLineSeparators])
        return result
    }

    private static func removeTagPairs(named tag: String, from html: String) -> String {
        // Non-greedy correct ICI (contrairement à `scoreAndSelectMainBlock`
        // plus bas) : ces balises (script/style/nav/header/footer/aside/form)
        // ne s'imbriquent normalement jamais les unes dans les autres dans du
        // HTML réel, donc s'arrêter à la première fermeture correspondante ne
        // tronque rien — le risque de troncature sur imbrication ne concerne
        // que les conteneurs génériques (`<div>`), traités séparément.
        let pattern = "<\(tag)\\b[^>]*>.*?</\(tag)>"
        return Self.replace(pattern: pattern, in: html, with: "", options: [.dotMatchesLineSeparators, .caseInsensitive])
    }

    /// Sélectionne le contenu principal SANS arbre DOM réel — simplification
    /// assumée de la propagation de score aux ancêtres de Readability (voir
    /// commentaire de tête du fichier).
    ///
    /// Un appariement de paires de balises génériques (`<div>...</div>` non-
    /// greedy) s'arrêterait à la PREMIÈRE balise fermante rencontrée, pas la
    /// correspondante — cassé sur la quasi-totalité du HTML réel, où
    /// `<div class="content"><div class="para">...</div>...</div>` est la
    /// norme. À la place : on découpe le HTML nettoyé en SEGMENTS sur les
    /// frontières de bloc (`</p>`, `</div>`, `</section>`, `</article>`,
    /// `</td>`, `</li>`, `<br>`) — chaque segment est un candidat
    /// INDÉPENDANT, noté par densité de texte utile, ponctuation forte,
    /// densité de liens (calculée AVANT de retirer les `<a>`, sinon toujours
    /// nulle) et mots-clés class=/id=. Tous les segments au score net
    /// POSITIF sont concaténés dans l'ordre du document — préserve un article
    /// multi-paragraphes réparti sur plusieurs `<div>` imbriqués (la
    /// découpe par frontière ne dépend d'aucun appariement de balises, donc
    /// insensible à l'imbrication) tout en excluant les fragments dominés par
    /// les liens ou les mots-clés négatifs (nav résiduelle, encart
    /// commentaires...).
    static func scoreAndSelectMainBlock(fromCleanedHTML html: String) -> String {
        let segments = Self.splitIntoBlockSegments(html)
        guard !segments.isEmpty else { return html }

        let scored = segments.map { ($0, Self.score(segment: $0)) }
        let positive = scored.filter { $0.1 > 0 }.map(\.0)

        // Si aucun segment n'a un score net positif (page entièrement
        // navigation/liens résiduelle après nettoyage) : retombe sur le
        // meilleur segment quand même plutôt qu'une chaîne vide — un scrape
        // au contenu pauvre reste préférable à un scrape qui échoue
        // silencieusement.
        guard !positive.isEmpty else {
            return scored.max(by: { $0.1 < $1.1 })?.0 ?? html
        }
        return positive.joined(separator: " ")
    }

    private static func splitIntoBlockSegments(_ html: String) -> [String] {
        let boundaryPattern = "</(?:p|div|section|article|td|li)>|<br\\s*/?>"
        guard let regex = try? NSRegularExpression(pattern: boundaryPattern, options: [.caseInsensitive]) else {
            return [html]
        }
        let nsHTML = html as NSString
        var segments: [String] = []
        var lastEnd = 0
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: nsHTML.length)) { match, _, _ in
            guard let match else { return }
            let end = match.range.location + match.range.length
            segments.append(nsHTML.substring(with: NSRange(location: lastEnd, length: end - lastEnd)))
            lastEnd = end
        }
        if lastEnd < nsHTML.length {
            segments.append(nsHTML.substring(from: lastEnd))
        }
        // Segments minuscules (balise seule, séparateur) sans valeur de
        // contenu réel : ignorés plutôt que de fausser le classement.
        return segments.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 }
    }

    private static let positiveKeywords = ["article", "body", "content", "main", "post", "entry"]
    private static let negativeKeywords = ["comment", "sidebar", "nav", "footer", "widget", "sponsor"]

    private static func score(segment: String) -> Double {
        let textOnly = Self.collapseWhitespace(Self.decodeHTMLEntities(Self.removeAllTags(segment)))
        let textLength = Double(textOnly.count)
        let linkDensity = Self.linkDensity(of: segment, textLength: textLength)
        let strongPunctuationCount = Double(textOnly.filter { $0 == "," || $0 == "." }.count)

        var keywordBonus = 0.0
        let lowerSegment = segment.lowercased()
        for keyword in Self.positiveKeywords where lowerSegment.contains(keyword) {
            keywordBonus += 30
        }
        // Pénalité large et volontairement disproportionnée (vs le bonus
        // positif) : un simple malus additif modeste laisserait un segment
        // "comments"/"sidebar" dense en texte rester net positif malgré le
        // mot-clé négatif — l'intention de ces classes (contenu secondaire,
        // pas l'article) doit dominer sa longueur de texte.
        for keyword in Self.negativeKeywords where lowerSegment.contains(keyword) {
            keywordBonus -= 500
        }

        return textLength + strongPunctuationCount * 2 - linkDensity * textLength * 2 + keywordBonus
    }

    /// BUG corrigé : divisait par la longueur du segment BRUT (balises HTML
    /// incluses), pas par la longueur du texte réel. Un bloc de liens courts
    /// (`<a href="...">Lien N</a>`) a un ratio balisage/texte élevé — le
    /// marquage (`href="..."`, balises fermantes) gonflait artificiellement
    /// le dénominateur et diluait la densité mesurée (~23% au lieu de ~88%
    /// pour un bloc composé presque uniquement de liens), laissant passer un
    /// bloc 100% liens comme "positif" dans `score`. Diviser par `textLength`
    /// (le texte APRÈS suppression des balises, déjà calculé par l'appelant)
    /// mesure la vraie proportion de texte qui est du texte de lien.
    private static func linkDensity(of segment: String, textLength: Double) -> Double {
        guard textLength > 0 else { return 0 }
        let linkTextLength = Self.matches(pattern: "<a\\b[^>]*>(.*?)</a>", in: segment, options: [.dotMatchesLineSeparators, .caseInsensitive])
            .reduce(0.0) { $0 + Double($1.count) }
        return min(1.0, linkTextLength / textLength)
    }

    private static func removeAllTags(_ html: String) -> String {
        Self.replace(pattern: "<[^>]+>", in: html, with: " ", options: [])
    }

    private static func collapseWhitespace(_ text: String) -> String {
        Self.replace(pattern: "\\s+", in: text, with: " ", options: []).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Décodage d'entités HTML fait à la main — Foundation n'a pas de
    /// decoder simple hors `NSAttributedString(html:)` (explicitement écarté,
    /// voir CLAUDE.md) : table pour les entités nommées courantes, puis regex
    /// pour les formes numériques `&#(\d+);` et hexadécimales
    /// `&#x([0-9a-fA-F]+);`, converties via `Unicode.Scalar`.
    static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in Self.namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        result = Self.decodeNumericEntities(result, pattern: "&#([0-9]+);", radix: 10)
        result = Self.decodeNumericEntities(result, pattern: "&#x([0-9a-fA-F]+);", radix: 16)
        return result
    }

    private static let namedEntities: [(String, String)] = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"),
        ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
        ("&rdquo;", "\""), ("&ldquo;", "\""),
    ]

    private static func decodeNumericEntities(_ text: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        // En ordre inverse : remplacer un match modifie les indices de tous
        // les matches suivants dans la chaîne d'origine si on itère dans
        // l'ordre normal — remonter du dernier au premier évite ce décalage.
        for match in matches.reversed() {
            guard
                let codeRange = Range(match.range(at: 1), in: text),
                let code = UInt32(text[codeRange], radix: radix),
                let scalar = Unicode.Scalar(code),
                let fullRange = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }

    private static func matches(pattern: String, in text: String, options: NSRegularExpression.Options) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }

    private static func replace(pattern: String, in text: String, with replacement: String, options: NSRegularExpression.Options) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let nsText = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsText.length), withTemplate: replacement)
    }

    // MARK: - Chunking générique (réutilisable par 1.4)

    /// Segmentation par phrases avec fenêtre glissante à chevauchement —
    /// proxy direct de `splitText.ts` (web), sans tokenizer BPE réel :
    /// `maxCharacters`/`overlapCharacters` jouent le rôle des tokens (le TS
    /// lui-même retombe sur caractères/4 en cas d'échec d'encodage cl100k —
    /// même ordre de grandeur assumé ici directement en caractères, sans
    /// passer par une division par 4 arbitraire côté Swift).
    ///
    /// GARDE-FOU ANTI-BLOCAGE : "ne jamais couper au milieu d'un mot" plus
    /// "couper sur une frontière de phrase" n'a pas de solution si AUCUNE
    /// frontière n'existe dans toute la fenêtre `maxCharacters` (texte sans
    /// ponctuation ni retour à la ligne sur des milliers de caractères) — une
    /// boucle naïve ne progresserait alors jamais. Ici, la progression est
    /// GARANTIE à chaque itération (au moins un caractère) : si aucune
    /// frontière n'est trouvée dans la fenêtre, on coupe net à
    /// `maxCharacters` ; si le chevauchement demandé ramènerait le prochain
    /// départ en arrière ou sur place, il est forcé à avancer d'au moins un
    /// caractère. Cette boucle termine donc toujours, en au plus
    /// `text.count` itérations.
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
        let pattern = "(?<=[.!?;:])\\s+|\\n+|(?<=- )|(?<=\\* )"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            Range(match.range, in: text)?.upperBound
        }
    }
}
