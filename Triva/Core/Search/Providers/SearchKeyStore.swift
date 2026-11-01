//
//  SearchKeyStore.swift
//  Triva
//
//  Created by ben podrojsky on 08/10/2026.
//

import Foundation

// MARK: - Sources à clé personnelle

/// Les trois sources de recherche qui exigent une clé de l'utilisateur (BYOK recherche).
///
/// `nonisolated` : donnée pure, utilisée aussi bien par les vues que par les providers.
nonisolated enum BYOKSearchSource: String, Sendable, Equatable, CaseIterable {
    case brave
    case tavily
    case google

    /// ORDRE DE PRÉFÉRENCE quand plusieurs clés existent : Brave, puis Tavily, puis Google.
    ///
    /// Pourquoi cet ordre :
    /// - Brave : index web indépendant, un seul champ à saisir, quota gratuit mensuel ;
    /// - Tavily : conçu pour alimenter un LLM (extraits déjà nettoyés), mais l'offre gratuite
    ///   est plus restreinte et un résultat y est un « extrait recomposé », pas un snippet brut ;
    /// - Google : dernier, car il demande DEUX valeurs (clé + moteur « cx »), l'API n'est plus
    ///   ouverte aux nouveaux clients et sa fermeture est annoncée pour le 2027-01-01.
    ///   Voir `GoogleProgrammableSearchProvider`.
    static let preferenceOrder: [BYOKSearchSource] = [.brave, .tavily, .google]

    /// Le `WebSearchSourceKind` correspondant, pour dire honnêtement d'où viennent les résultats.
    var kind: WebSearchSourceKind {
        switch self {
        case .brave: .braveSearch
        case .tavily: .tavily
        case .google: .googleProgrammableSearch
        }
    }

    /// Libellé court pour les Réglages.
    var displayName: String { kind.displayName }

    /// Vrai si la source exige un second identifiant en plus de la clé (le « cx » de Google).
    var requiresEngineID: Bool { self == .google }

    /// Identifiants de compte Keychain. Préfixe `search.` : aucune collision possible avec les
    /// comptes des clés IA (`claude`, `openai`… ou les identifiants de fournisseurs personnalisés),
    /// qui vivent de toute façon dans un AUTRE service Keychain (voir `SearchKeyStore.keychainService`).
    var keyAccount: String { "search.\(rawValue).apiKey" }
    var engineIDAccount: String { "search.\(rawValue).engineID" }
}

// MARK: - Identifiants

/// Valeur secrète dont l'affichage est masqué.
///
/// Pourquoi un type dédié : un provider contient forcément la clé en mémoire pour signer ses
/// requêtes. Sans ce masque, un `print(provider)`, un `dump`, un `String(reflecting:)` ou le
/// message d'un `#expect` en échec afficherait la clé en clair. Ici `description` renvoie
/// toujours « ••••• », quel que soit le chemin d'affichage.
nonisolated struct SearchSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    init(_ value: String) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { value.isEmpty }
    var description: String { "•••••" }
    var debugDescription: String { "•••••" }
    /// `dump` et les affichages fondés sur `Mirror` parcourent les propriétés stockées : sans
    /// ceci, `value` s'afficherait en clair. Un miroir sans enfant les en empêche.
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// Résultat d'un test de clé.
nonisolated enum SearchKeyValidationOutcome: Sendable, Equatable {
    /// La source a répondu normalement.
    case valid
    /// La source a refusé la requête pour cause de quota ou de débit (429, 432…) : la clé a bien
    /// été RECONNUE (une clé inconnue n'a pas de quota), elle est simplement épuisée pour le moment.
    /// Les Réglages doivent l'afficher comme « clé valide, quota atteint », pas comme un refus.
    case validQuotaReached
}

/// Test d'une clé par une requête minimale.
///
/// Chaque test CONSOMME une requête du quota de l'utilisateur (un crédit Tavily, une requête
/// Brave ou Google) : les Réglages doivent le déclencher à la demande, jamais en boucle ni à
/// chaque frappe.
nonisolated protocol SearchKeyValidating: Sendable {
    /// Lève uniquement des `WebSearchError` (et `CancellationError` si la tâche est annulée).
    func validateKey() async throws -> SearchKeyValidationOutcome
}

/// Un provider de recherche qui sait aussi tester sa propre clé.
typealias KeyedWebSearchProvider = WebSearchProviding & SearchKeyValidating

/// Les valeurs saisies pour une source. Séparé du stockage : les Réglages peuvent TESTER une clé
/// avant de l'enregistrer (`makeProvider(...).validateKey()`), sans toucher au Keychain.
nonisolated struct SearchKeyCredentials: Sendable, Equatable, CustomStringConvertible {
    let source: BYOKSearchSource
    let apiKey: SearchSecret
    /// Identifiant du moteur Programmable Search (« cx »), Google uniquement. Public par nature
    /// (il figure dans le code d'intégration d'une page web), mais rangé avec la clé.
    let engineID: String?

    init(source: BYOKSearchSource, apiKey: String, engineID: String? = nil) {
        self.source = source
        self.apiKey = SearchSecret(apiKey)
        let trimmedEngine = engineID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.engineID = (trimmedEngine?.isEmpty ?? true) ? nil : trimmedEngine
    }

    /// Utilisable : une clé non vide, et un « cx » non vide pour Google.
    var isComplete: Bool {
        guard !apiKey.isEmpty else { return false }
        return source.requiresEngineID ? engineID != nil : true
    }

    var description: String { "SearchKeyCredentials(\(source.rawValue), clé masquée)" }

    /// Construit le provider de la source. Un « cx » manquant pour Google donne un provider qui
    /// lèvera `.missingKey` à la recherche : pas de crash sur une saisie incomplète.
    func makeProvider(requester: any HTTPDataRequesting = URLSessionDataRequester()) -> any KeyedWebSearchProvider {
        switch source {
        case .brave:
            BraveSearchProvider(apiKey: apiKey.value, requester: requester)
        case .tavily:
            TavilySearchProvider(apiKey: apiKey.value, requester: requester)
        case .google:
            GoogleProgrammableSearchProvider(apiKey: apiKey.value, engineID: engineID ?? "", requester: requester)
        }
    }
}

// MARK: - Stockage Keychain

/// Erreurs de stockage. Aucune valeur secrète dans ces cas.
enum SearchKeyStoreError: Error, Sendable, Equatable {
    /// Clé vide (ou « cx » manquant pour Google) : rien n'est enregistré.
    case incompleteCredentials
    /// Le Keychain a refusé l'opération. Jamais avalée : l'appelant l'affiche.
    case keychainFailure

    var userFacingMessage: String {
        switch self {
        case .incompleteCredentials: "Il manque une valeur : renseigne la clé (et l'identifiant du moteur pour Google)."
        case .keychainFailure: "Impossible d'accéder au trousseau de l'appareil."
        }
    }
}

/// Stockage des clés de recherche BYOK et fabrique des providers correspondants.
///
/// CONCURRENCE : volontairement NON `nonisolated`, donc isolé au main actor (défaut du projet).
/// `APIKeyStoring` et `KeychainAPIKeyStore` sont eux-mêmes isolés au main actor (ils servent les
/// vues de Réglages) : un type `nonisolated` ne pourrait pas les appeler. Ce n'est pas un coût :
/// lire/écrire une clé est instantané. Le travail réseau, lui, vit dans les providers, qui sont
/// `nonisolated` : on lit la clé ICI (main actor), puis on passe un provider autonome — valeur
/// `Sendable` qui contient sa clé — à l'orchestrateur, sans aucun accès au Keychain en arrière-plan.
///
/// SERVICE KEYCHAIN SÉPARÉ de celui des clés IA (`com.benpodrojsky.Triva.cloudBYOK`) EN PLUS du
/// préfixe `search.` des comptes : supprimer une clé de recherche ne peut jamais toucher une clé
/// IA, et inversement (par exemple un futur « tout effacer » côté IA).
///
/// Google compte comme CONFIGURÉ seulement si la clé ET le « cx » sont présents.
struct SearchKeyStore {
    static let keychainService = "com.benpodrojsky.Triva.searchBYOK"

    private let keyStore: any APIKeyStoring
    private let requester: any HTTPDataRequesting

    init(
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(service: SearchKeyStore.keychainService),
        requester: any HTTPDataRequesting = URLSessionDataRequester()
    ) {
        self.keyStore = keyStore
        self.requester = requester
    }

    // MARK: Écriture

    /// Enregistre (ou remplace) les identifiants d'une source. Les espaces autour de la saisie
    /// sont retirés (un collage depuis un tableau de bord en apporte souvent).
    func save(_ credentials: SearchKeyCredentials) throws {
        guard credentials.isComplete else { throw SearchKeyStoreError.incompleteCredentials }
        let source = credentials.source
        do {
            try keyStore.save(apiKey: credentials.apiKey.value, account: source.keyAccount)
        } catch {
            throw SearchKeyStoreError.keychainFailure
        }
        guard source.requiresEngineID, let engineID = credentials.engineID else { return }
        do {
            try keyStore.save(apiKey: engineID, account: source.engineIDAccount)
        } catch {
            // Pas de demi-configuration : on retire la clé qu'on vient d'écrire (au mieux).
            try? keyStore.deleteAPIKey(account: source.keyAccount)
            throw SearchKeyStoreError.keychainFailure
        }
    }

    /// Supprime tout ce qui concerne une source (clé et, pour Google, « cx »).
    func delete(_ source: BYOKSearchSource) throws {
        var failed = false
        for account in [source.keyAccount, source.engineIDAccount] {
            do { try keyStore.deleteAPIKey(account: account) } catch { failed = true }
        }
        if failed { throw SearchKeyStoreError.keychainFailure }
    }

    // MARK: Lecture

    /// Les identifiants d'une source, ou `nil` si elle n'est pas (entièrement) configurée.
    func credentials(for source: BYOKSearchSource) throws -> SearchKeyCredentials? {
        let apiKey: String?
        var engineID: String?
        do {
            apiKey = try keyStore.apiKey(account: source.keyAccount)
            if source.requiresEngineID {
                engineID = try keyStore.apiKey(account: source.engineIDAccount)
            }
        } catch {
            throw SearchKeyStoreError.keychainFailure
        }
        let credentials = SearchKeyCredentials(source: source, apiKey: apiKey ?? "", engineID: engineID)
        return credentials.isComplete ? credentials : nil
    }

    func isConfigured(_ source: BYOKSearchSource) throws -> Bool {
        try credentials(for: source) != nil
    }

    /// Sources configurées, dans l'ordre de préférence (`BYOKSearchSource.preferenceOrder`).
    func configuredSources() throws -> [BYOKSearchSource] {
        try BYOKSearchSource.preferenceOrder.filter { try isConfigured($0) }
    }

    // MARK: Providers

    /// Provider d'une source précise, ou `nil` si elle n'est pas configurée.
    func provider(for source: BYOKSearchSource) throws -> (any KeyedWebSearchProvider)? {
        try credentials(for: source)?.makeProvider(requester: requester)
    }

    /// Le provider PRÉFÉRÉ parmi les sources configurées, ou `nil` s'il n'y en a aucune.
    func preferredProvider() throws -> (any KeyedWebSearchProvider)? {
        try providersInPreferenceOrder().first
    }

    /// Tous les providers configurés, du préféré au dernier : l'orchestrateur peut passer au
    /// suivant si le premier est épuisé (`.rateLimited`) ou refusé (`.unauthorized`).
    func providersInPreferenceOrder() throws -> [any KeyedWebSearchProvider] {
        try BYOKSearchSource.preferenceOrder.compactMap { try provider(for: $0) }
    }

    /// Teste la clé DÉJÀ enregistrée d'une source. `.missingKey` si rien n'est enregistré.
    func validateStoredKey(for source: BYOKSearchSource) async throws -> SearchKeyValidationOutcome {
        guard let provider = try provider(for: source) else { throw WebSearchError.missingKey }
        return try await provider.validateKey()
    }
}

// MARK: - Socle HTTP commun aux trois providers

/// Fonctions partagées par Brave, Tavily et Google. Réunies ici (et non dans un fichier à part)
/// parce que la mission R1 est bornée à quatre fichiers sources ; rien n'empêche de les
/// déplacer dans leur propre fichier à l'intégration.
///
/// Réutilise `HTTPDataRequesting` (déjà utilisé par `CloudModelListService`) : `URLFetching` ne
/// sait ni envoyer d'en-têtes ni poster un corps, or les trois API veulent une clé en en-tête.
nonisolated enum BYOKSearchHTTP {
    /// Délai d'inactivité d'une requête, aligné sur `SearXNGClient` (10 s).
    static let timeout: TimeInterval = 10

    // MARK: Requête / réponse

    /// Exécute la requête et renvoie le corps d'une réponse 2xx.
    ///
    /// CLÉ JAMAIS DIVULGUÉE : l'erreur `URLError` d'origine n'est JAMAIS relayée ni encapsulée. Elle
    /// embarque `failingURL` (et `NSURLErrorFailingURLStringErrorKey`), c'est-à-dire l'URL complète
    /// avec ses paramètres. Même si aucun des trois providers ne met la clé dans l'URL (en-têtes),
    /// on garde la règle : seul un `WebSearchError` à message fixe sort d'ici.
    ///
    /// ANNULATION : une annulation (`CancellationError` ou `URLError.cancelled`) ressort en
    /// `CancellationError`, comme `CloudModelListService` et `SearchOrchestrator.isCancellation`.
    /// La convertir en `.unavailable` ferait passer l'orchestrateur à la source suivante (parfois
    /// payante) alors que l'utilisateur vient d'appuyer sur Stop.
    static func send(
        _ request: URLRequest,
        via requester: any HTTPDataRequesting,
        classify: (_ status: Int, _ body: Data) -> WebSearchError
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requester.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            switch urlError.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw WebSearchError.timeout
            default: throw WebSearchError.unavailable
            }
        } catch {
            throw WebSearchError.unavailable
        }

        guard let http = response as? HTTPURLResponse else { throw WebSearchError.unavailable }
        guard (200..<300).contains(http.statusCode) else {
            throw classify(http.statusCode, data)
        }
        return data
    }

    /// Correspondance statut HTTP -> erreur, valable pour les trois sources. Chaque provider
    /// l'affine avec ses codes propres (422 Brave, 432/433 Tavily, motifs Google).
    static func defaultError(forStatus status: Int) -> WebSearchError {
        switch status {
        case 401, 403: .unauthorized
        case 408: .timeout
        case 429: .rateLimited
        case 500...599: .unavailable
        // 400, 404, 422… : c'est NOTRE requête qui est refusée, pas un problème de clé ni de
        // service. `.invalidResponse` est le moins mauvais choix du contrat commun.
        default: .invalidResponse
        }
    }

    /// Décode le JSON d'une réponse ; tout échec devient `.invalidResponse` (jamais le détail
    /// du décodeur : il peut citer un extrait du corps).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WebSearchError.invalidResponse
        }
    }

    // MARK: URL

    /// Construit `https://{host}{path}?…` avec le `+` littéral encodé en `%2B`.
    ///
    /// Même piège que dans `SearXNGClient.buildURL` (bug 12 de la revue V1) : `URLComponents`
    /// laisse `+` tel quel dans une query (RFC 3986), alors que les serveurs qui décodent en
    /// `application/x-www-form-urlencoded` le lisent comme une espace — « C++ » deviendrait
    /// « C » et « Canal+ » « Canal ». Le remplacement se fait APRÈS le setter `queryItems`, sur
    /// `percentEncodedQuery` : à ce stade un `+` restant est forcément un `+` littéral.
    static func makeURL(host: String, path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw WebSearchError.invalidResponse }
        return url
    }

    // MARK: Paramètres

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Code langue de base en minuscules (« fr-FR » -> « fr »), `nil` si vide ou illisible.
    static func baseLanguage(from language: String?) -> String? {
        guard let language else { return nil }
        let lowered = language.lowercased()
        let base = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let isLetters = !base.isEmpty && base.count <= 3 && base.allSatisfy { $0.isASCII && $0.isLetter }
        return isLetters ? base : nil
    }

    /// Requête nettoyée, ou `nil` si elle est vide (on évite alors tout appel réseau payant).
    static func trimmedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Résultats

    /// Réponse vide valide : zéro résultat n'est pas une erreur.
    static let emptyResponse = SearXNGSearchResponse(results: [], suggestions: [])

    /// Convertit un résultat brut au format du pipeline. `nil` (résultat ignoré) si l'URL n'est
    /// pas un lien http(s) exploitable : un résultat sans lien ne peut être ni cité ni ouvert.
    /// Titre vide -> nom d'hôte. `content` vide -> `nil`.
    static func makeResult(title: String?, url: String?, content: String?) -> SearXNGSearchResult? {
        guard let rawURL = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = URL(string: rawURL),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty
        else { return nil }

        let cleanTitle = collapseWhitespace(title ?? "")
        let cleanContent = collapseWhitespace(content ?? "")
        return SearXNGSearchResult(
            title: cleanTitle.isEmpty ? host : cleanTitle,
            url: rawURL,
            content: cleanContent.isEmpty ? nil : cleanContent,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    // MARK: Texte

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Retire les balises HTML (`<strong>` de surbrillance chez Brave) et décode les entités.
    ///
    /// Appliqué uniquement aux champs qui peuvent contenir du HTML (Brave) : sur un titre en
    /// texte brut, « templates <T> » perdrait « <T> ».
    static func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return collapseWhitespace(decodeEntities(withoutTags))
    }

    private static let namedEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        // `&amp;` EN DERNIER : décoder « &amp;lt; » en « &lt; » (et non « < »).
        ("&amp;", "&"),
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var decoded = decodeNumericEntities(text)
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }

    /// `&#39;`, `&#x27;`… Parcours à l'envers pour que les remplacements ne décalent pas les
    /// positions des correspondances restantes.
    private static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#([xX][0-9A-Fa-f]+|[0-9]+);") else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let digits = Range(match.range(at: 1), in: result),
                  let scalar = scalar(fromEntityDigits: String(result[digits]))
            else { continue }
            result.replaceSubrange(whole, with: String(scalar))
        }
        return result
    }

    private static func scalar(fromEntityDigits digits: String) -> Unicode.Scalar? {
        let isHex = digits.hasPrefix("x") || digits.hasPrefix("X")
        let value = isHex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
        return value.flatMap(Unicode.Scalar.init)
    }

    // MARK: Test de clé

    /// Implémentation commune de `validateKey()` : une recherche minimale (1 résultat).
    /// Un quota atteint prouve que la clé est reconnue ; toute autre erreur est relayée.
    static func validate(_ provider: some WebSearchProviding) async throws -> SearchKeyValidationOutcome {
        do {
            _ = try await provider.search(query: "triva", options: WebSearchOptions(maxResults: 1))
            return .valid
        } catch WebSearchError.rateLimited {
            return .validQuotaReached
        }
    }
}
