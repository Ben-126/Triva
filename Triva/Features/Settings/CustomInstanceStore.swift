//
//  CustomInstanceStore.swift
//  Triva
//
//  Created by ben podrojsky on 04/10/2026.
//

import Foundation

// MARK: - Erreurs

/// Erreurs de l'édition de la liste d'instances SearXNG (1.15, section
/// « Avancé » des Réglages).
///
/// `nonisolated` : levées par la validation pure (`SearXNGInstanceAddress`),
/// appelable depuis n'importe quel contexte, et comparées avec `==` par des
/// tests non isolés. Sous `-default-isolation=MainActor` avec conformances
/// isolées (`SWIFT_APPROACHABLE_CONCURRENCY`), un `Equatable` hérité du main
/// actor y serait inutilisable — même raison que pour `SearXNGModels.swift`.
nonisolated enum CustomInstanceError: Error, Sendable, Equatable {
    /// Champ vide, ou seulement des espaces.
    case emptyInput
    /// Le texte ne forme pas une adresse exploitable : espace au milieu, hôte
    /// absent, port non numérique, schéma mal écrit (`https:/hôte`)…
    case invalidAddress
    /// Schéma autre que `https` (`http://`, `ftp://`…). Imposé : la requête
    /// part en clair sinon, et ATS la bloquerait de toute façon.
    case httpsRequired
    /// `https://utilisateur:motdepasse@hôte`. Refusé plutôt que toléré : la
    /// liste vit dans `UserDefaults`, en clair — un secret n'a sa place que
    /// dans le Keychain (règle BYOK du projet), et l'authentification d'une
    /// instance n'est de toute façon pas prise en charge.
    case credentialsNotAllowed
    /// Paramètres (`?…`) ou ancre (`#…`) : `SearXNGClient` ajoute `/search`
    /// au CHEMIN de l'adresse, une requête collée depuis le navigateur
    /// (`…/search?q=test`) donnerait une URL cassée.
    case parametersNotAllowed
    /// Même instance déjà présente, éventuellement écrite autrement
    /// (majuscules, barre finale, port 443 explicite : voir
    /// `SearXNGInstanceAddress.comparisonKey(for:)`).
    case alreadyInList
    /// La liste effective ne peut pas devenir vide : `FailoverManager` lève
    /// `noInstancesConfigured` sur une liste vide, toute recherche échouerait.
    case cannotRemoveLastInstance
    /// L'instance à retirer n'est plus dans la liste (déjà retirée ailleurs).
    case notInList

    /// Message court en français (tutoiement, DESIGN.md). Toujours un texte
    /// FIXE : jamais construit à partir de la saisie de l'utilisateur.
    var userFacingMessage: String {
        switch self {
        case .emptyInput:
            "Saisis l'adresse d'une instance."
        case .invalidAddress:
            "Adresse invalide. Exemple : https://searx.exemple.org"
        case .httpsRequired:
            "Seules les adresses https:// sont acceptées."
        case .credentialsNotAllowed:
            "Retire l'identifiant de l'adresse : il serait enregistré en clair sur l'appareil."
        case .parametersNotAllowed:
            "Indique l'adresse de base de l'instance, sans «\u{00A0}?\u{00A0}» ni «\u{00A0}#\u{00A0}»."
        case .alreadyInList:
            "Cette instance est déjà dans la liste."
        case .cannotRemoveLastInstance:
            "Garde au moins une instance : la recherche en a besoin."
        case .notInList:
            "Cette instance n'est plus dans la liste."
        }
    }
}

// MARK: - Validation d'adresse (logique pure)

/// Adresse d'instance validée et normalisée, pas encore ajoutée.
nonisolated struct SearXNGInstanceCandidate: Sendable, Equatable {
    let url: URL
    /// Hôte local ou privé (voir `SearXNGInstanceAddress.isLocalOrPrivate`) :
    /// l'ajout reste permis — c'est le cas d'usage d'une instance auto-hébergée
    /// — mais l'écran demande une confirmation explicite avant.
    let isLocalOrPrivate: Bool
}

/// Validation, normalisation et comparaison des adresses d'instances.
///
/// Logique pure et déterministe, sans aucun appel réseau : une adresse dont le
/// nom public pointe vers une IP privée n'est donc PAS détectée comme locale
/// (il faudrait une résolution DNS) — limite assumée, l'avertissement porte
/// sur ce qui se voit dans l'adresse elle-même.
nonisolated enum SearXNGInstanceAddress {
    /// Suffixes réservés aux réseaux privés : `.local` (Bonjour/mDNS),
    /// `.home.arpa` (RFC 8375), `.internal` (réservé par l'ICANN en 2024),
    /// `.localhost` (RFC 6761), et `.lan`/`.home`, défauts courants des box
    /// et routeurs domestiques. Liste volontairement courte : un faux positif
    /// ne coûte qu'une confirmation, un suffixe exotique en plus n'apporterait
    /// rien de mesurable.
    static let privateSuffixes = [".localhost", ".local", ".home.arpa", ".internal", ".lan", ".home"]

    /// Valide une saisie libre et la normalise. `https://` est ajouté quand
    /// aucun schéma n'est écrit (« searx.exemple.org ») : c'est la façon la
    /// plus courante de taper une adresse, et le résultat reste en https.
    static func validate(_ rawInput: String) throws -> SearXNGInstanceCandidate {
        let components = try parsedComponents(from: rawInput)
        guard let host = components.host, !host.isEmpty else {
            throw CustomInstanceError.invalidAddress
        }
        guard let url = normalized(components).url else {
            throw CustomInstanceError.invalidAddress
        }
        return SearXNGInstanceCandidate(url: url, isLocalOrPrivate: isLocalOrPrivate(host: host))
    }

    /// Clé de comparaison de deux adresses : hôte en minuscules (le DNS ne
    /// distingue pas la casse), port explicite (443 par défaut en https),
    /// chemin sans barre finale. Le chemin garde sa casse — il est sensible à
    /// la casse côté serveur, deux sous-chemins différents peuvent être deux
    /// instances. `nil` pour une adresse sans hôte.
    ///
    /// Nécessaire parce que `FailoverManager` et `URL` comparent les adresses
    /// au caractère près : sans cette clé, « https://Searx.be/ » et
    /// « https://searx.be » seraient deux instances distinctes.
    static func comparisonKey(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let scheme = components.scheme?.lowercased() ?? "https"
        let defaultPort = scheme == "https" ? "443" : ""
        let port = components.port.map { String($0) } ?? defaultPort
        return "\(scheme)://\(host):\(port)\(trimmingTrailingSlashes(components.percentEncodedPath))"
    }

    /// Adresse affichée dans la liste : hôte, port s'il n'est pas implicite,
    /// sous-chemin éventuel — sans `https://`, toujours le même puisque seul
    /// https est accepté.
    static func displayAddress(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            return url.absoluteString
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return host + port + trimmingTrailingSlashes(components.path)
    }

    /// Variante de `isLocalOrPrivate(host:)` pour une adresse déjà stockée.
    static func isLocalOrPrivate(url: URL) -> Bool {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host else { return false }
        return isLocalOrPrivate(host: host)
    }

    /// Vrai pour un hôte qui ne répondra que depuis le réseau local (ou un
    /// VPN) : `localhost`, nom court sans point (« nas »), suffixes de
    /// `privateSuffixes`, IPv4 privées/réservées, IPv6 de bouclage, locales
    /// uniques (fc00::/7) ou de lien local (fe80::/10).
    static func isLocalOrPrivate(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !host.isEmpty else { return false }
        if host.contains(":") {
            return isPrivateIPv6(host)
        }
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        if !host.contains(".") {
            return true
        }
        return privateSuffixes.contains { suffix in host.hasSuffix(suffix) || host == suffix.dropFirst() }
    }

    // MARK: Détails

    /// Découpe et contrôle la saisie, sans la normaliser.
    ///
    /// La présence d'un schéma se juge sur « :// » et non sur un « : » : sinon
    /// « localhost:8080 » serait lu comme le schéma « localhost ». Un
    /// « https:/hôte » (une seule barre) est refusé plutôt que complété : le
    /// compléter donnerait l'hôte « https ».
    private static func parsedComponents(from rawInput: String) throws -> URLComponents {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomInstanceError.emptyInput }
        guard !trimmed.contains(where: \.isWhitespace) else { throw CustomInstanceError.invalidAddress }

        let lowercased = trimmed.lowercased()
        let hasScheme = trimmed.contains("://")
        if !hasScheme, lowercased.hasPrefix("http:") || lowercased.hasPrefix("https:") {
            throw CustomInstanceError.invalidAddress
        }
        guard let components = URLComponents(string: hasScheme ? trimmed : "https://" + trimmed),
              let scheme = components.scheme else {
            throw CustomInstanceError.invalidAddress
        }
        guard scheme.lowercased() == "https" else { throw CustomInstanceError.httpsRequired }
        guard components.user == nil, components.password == nil else {
            throw CustomInstanceError.credentialsNotAllowed
        }
        guard components.query?.isEmpty ?? true, components.fragment?.isEmpty ?? true else {
            throw CustomInstanceError.parametersNotAllowed
        }
        return components
    }

    /// Forme canonique stockée : schéma en minuscules, port 443 implicite,
    /// sans « ? » ni « # » vides, sans barre finale. L'hôte garde la casse
    /// saisie : la comparaison passe par `comparisonKey`, et réécrire l'hôte
    /// (IDN, IPv6 entre crochets) via `URLComponents` est plus risqué
    /// qu'utile. Le chemin réaffecté vient d'un `URLComponents` déjà analysé,
    /// donc correctement encodé : son setter ne peut pas échouer.
    private static func normalized(_ components: URLComponents) -> URLComponents {
        var normalized = components
        normalized.scheme = "https"
        normalized.query = nil
        normalized.fragment = nil
        if normalized.port == 443 {
            normalized.port = nil
        }
        normalized.percentEncodedPath = trimmingTrailingSlashes(components.percentEncodedPath)
        return normalized
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Les quatre octets d'une IPv4 écrite en décimal pointé, `nil` sinon.
    /// Chiffres ASCII uniquement : `Int("+1")` accepterait un signe, et
    /// `Character.isNumber` des chiffres non latins.
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    /// Plages privées ou non routables : 10/8, 172.16/12, 192.168/16
    /// (RFC 1918), 127/8 (bouclage), 169.254/16 (lien local), 0/8, et
    /// 100.64/10 (RFC 6598, NAT des opérateurs — c'est aussi la plage de
    /// Tailscale : joignable depuis le VPN, jamais depuis Internet).
    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (0, _):
            true
        case (172, 16...31), (192, 168), (169, 254), (100, 64...127):
            true
        default:
            false
        }
    }

    /// `::1`/`::`, IPv4 mappée (`::ffff:a.b.c.d`), fc00::/7 et fe80::/10. Ne
    /// s'applique qu'à un littéral IPv6 (hôte contenant « : ») : un nom comme
    /// « fd.exemple.org » n'est jamais lu comme une adresse fd00::.
    private static func isPrivateIPv6(_ host: String) -> Bool {
        if host == "::1" || host == "::" {
            return true
        }
        let mappedPrefix = "::ffff:"
        if host.hasPrefix(mappedPrefix), let octets = ipv4Octets(String(host.dropFirst(mappedPrefix.count))) {
            return isPrivateIPv4(octets)
        }
        guard let firstGroup = host.split(separator: ":", omittingEmptySubsequences: false).first,
              let value = UInt16(firstGroup, radix: 16) else {
            return false
        }
        return (value & 0xFE00) == 0xFC00 || (value & 0xFFC0) == 0xFE80
    }
}

// MARK: - Surcouche persistée (logique pure)

/// Ce que l'utilisateur a changé par rapport à la liste du bundle
/// (`Resources/searxng-instances.json`, chargée par `PublicInstanceList`).
///
/// Une DIFFÉRENCE plutôt qu'une copie de la liste : une mise à jour de l'app
/// qui ajoute une instance par défaut la fait apparaître chez tout le monde,
/// y compris chez qui a personnalisé sa liste, et une instance masquée reste
/// masquée. Une copie figerait au contraire la liste du jour de la première
/// modification. Les instances ajoutées passent AVANT celles par défaut : on
/// ajoute sa propre instance justement pour qu'elle soit essayée en premier
/// (`FailoverManager` essaie dans l'ordre).
///
/// Adresses stockées en `String` (`absoluteString`) plutôt qu'en `URL` : le
/// format JSON obtenu ne dépend d'aucun détail d'encodage de `URL`.
nonisolated struct SearXNGInstanceOverrides: Codable, Sendable, Equatable {
    static let storageKey = "searxng.instanceOverrides"
    static let empty = SearXNGInstanceOverrides(addedInstances: [], hiddenDefaultInstances: [])

    /// Instances ajoutées, déjà normalisées, dans l'ordre d'essai.
    let addedInstances: [String]
    /// Instances par défaut masquées, écrites comme dans le bundle au moment
    /// du masquage (comparées ensuite par `comparisonKey`).
    let hiddenDefaultInstances: [String]

    var isEmpty: Bool {
        addedInstances.isEmpty && hiddenDefaultInstances.isEmpty
    }

    /// Une entrée illisible (donnée corrompue) est ignorée plutôt que de
    /// faire échouer toute la liste.
    var addedURLs: [URL] {
        addedInstances.compactMap { URL(string: $0) }
    }

    /// Liste réellement essayée : ajouts puis défauts visibles, doublons
    /// retirés (le premier gagne). Sans personnalisation, c'est EXACTEMENT
    /// `defaults`, même ordre, mêmes valeurs — aucun changement de
    /// comportement pour qui ne touche à rien.
    func effectiveInstances(defaults: [URL]) -> [URL] {
        Self.deduplicated(addedURLs + visibleDefaults(defaults))
    }

    /// Instances par défaut non masquées, dans l'ordre du bundle.
    func visibleDefaults(_ defaults: [URL]) -> [URL] {
        let hiddenKeys = Set(hiddenDefaultInstances.compactMap { stored in
            URL(string: stored).flatMap(SearXNGInstanceAddress.comparisonKey(for:))
        })
        return defaults.filter { url in
            guard let key = SearXNGInstanceAddress.comparisonKey(for: url) else { return true }
            return !hiddenKeys.contains(key)
        }
    }

    func adding(_ url: URL) -> SearXNGInstanceOverrides {
        SearXNGInstanceOverrides(
            addedInstances: addedInstances + [url.absoluteString],
            hiddenDefaultInstances: hiddenDefaultInstances
        )
    }

    /// Retire `url` de la liste effective : supprimée des ajouts si c'en est
    /// un, ET masquée si une instance par défaut porte la même adresse — sans
    /// ça, retirer un ajout identique à une instance par défaut ferait
    /// « réapparaître » aussitôt cette dernière.
    func removing(_ url: URL, defaults: [URL]) -> SearXNGInstanceOverrides {
        guard let key = SearXNGInstanceAddress.comparisonKey(for: url) else { return self }
        let hasSameKey: (String) -> Bool = { stored in
            URL(string: stored).flatMap(SearXNGInstanceAddress.comparisonKey(for:)) == key
        }
        let matchingDefaults = defaults.map(\.absoluteString).filter(hasSameKey)
        let isAlreadyHidden = hiddenDefaultInstances.contains(where: hasSameKey)
        return SearXNGInstanceOverrides(
            addedInstances: addedInstances.filter { !hasSameKey($0) },
            hiddenDefaultInstances: hiddenDefaultInstances + (isAlreadyHidden ? [] : matchingDefaults)
        )
    }

    /// Donnée absente ou illisible : repli documenté sur « aucune
    /// personnalisation », c'est-à-dire la liste du bundle — jamais de crash
    /// ni de liste vide pour une préférence corrompue. Même choix que
    /// `CustomProviderStore.load()`.
    static func load(from userDefaults: UserDefaults) -> SearXNGInstanceOverrides {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SearXNGInstanceOverrides.self, from: data) else {
            return .empty
        }
        return decoded
    }

    /// Aucune personnalisation : la clé est supprimée, pas écrite vide — une
    /// remise à zéro ne laisse rien derrière elle. L'encodage de deux tableaux
    /// de `String` ne peut pas échouer en pratique ; le `try?` suit
    /// `CustomProviderStore.persist()`.
    func save(to userDefaults: UserDefaults) {
        guard !isEmpty else {
            userDefaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seenKeys = Set<String>()
        return urls.filter { url in
            guard let key = SearXNGInstanceAddress.comparisonKey(for: url) else { return true }
            return seenKeys.insert(key).inserted
        }
    }
}

// MARK: - Test de connectivité

/// Pourquoi une instance n'a pas répondu, en motifs FIXES : aucun texte
/// renvoyé par le serveur n'est jamais affiché (même prudence que
/// `ChatViewModel.userFacingMessage(for:)` — une instance publique est un
/// tiers non maîtrisé). Seul le code HTTP, un entier, est repris.
nonisolated enum SearXNGInstanceFailure: Sendable, Equatable {
    case timeout
    case httpStatus(Int)
    /// Statut 200 mais corps non JSON : le cas typique d'une instance qui
    /// protège `format=json` derrière un challenge anti-robot (Anubis) — voir
    /// le commentaire de `searxng-instances.json`.
    case notJSON
    case network
    case invalidAddress

    var userFacingMessage: String {
        switch self {
        case .timeout:
            "Délai dépassé"
        case .httpStatus(429):
            "Trop de requêtes (429)"
        case .httpStatus(403):
            "Accès refusé (403)"
        case .httpStatus(let statusCode):
            "Erreur HTTP \(statusCode)"
        case .notJSON:
            "Pas de réponse JSON (protection anti-robot ?)"
        case .network:
            "Injoignable"
        case .invalidAddress:
            "Adresse invalide"
        }
    }
}

/// État du dernier test d'une instance.
nonisolated enum SearXNGInstanceConnectivity: Sendable, Equatable {
    case testing
    /// L'instance a répondu en JSON. `resultCount` distingue une instance
    /// saine d'une instance qui répond mais dont les moteurs ne renvoient plus
    /// rien (bloqués ou suspendus) : joignable, mais inutile en pratique.
    case reachable(resultCount: Int, latency: Duration)
    case unreachable(SearXNGInstanceFailure)

    /// Résumé d'une ligne pour la liste, `nil` pendant un test (l'écran
    /// montre alors un indicateur de progression).
    var summary: String? {
        switch self {
        case .testing:
            return nil
        case .reachable(let resultCount, let latency):
            let milliseconds = Int((latency / Duration.milliseconds(1)).rounded())
            return resultCount > 0
                ? "Répond · \(milliseconds) ms"
                : "Répond, sans résultat · \(milliseconds) ms"
        case .unreachable(let failure):
            return failure.userFacingMessage
        }
    }
}

/// Résultat brut d'une sonde, avant traduction en `SearXNGInstanceConnectivity`
/// par le store (sur le main actor, où `SearXNGClientError` — isolé au main
/// actor par défaut — se décompose sans aucune question d'isolation).
nonisolated struct SearXNGProbeOutcome: Sendable {
    let result: Result<Int, any Error>
    let latency: Duration
}

/// Sonde une instance avec une VRAIE recherche (`format=json`) via
/// `SearXNGSearching`, et non un simple GET de la page d'accueil : la plupart
/// des instances publiques répondent 200 à un navigateur mais renvoient une
/// page de challenge anti-robot à une requête JSON. Un test HTTP nu dirait
/// « OK » pour exactement les instances qui ne marchent pas dans l'app.
///
/// Requête volontairement neutre (« test ») : rien de personnel ne part vers
/// une instance tierce. `@concurrent` : avec `NonisolatedNonsendingByDefault`,
/// une fonction `nonisolated async` tournerait sur l'acteur de l'appelant — le
/// main actor ici — et y ferait le décodage JSON de la réponse.
nonisolated enum SearXNGInstanceProbe {
    static let query = "test"

    @concurrent
    static func run(instance: URL, client: any SearXNGSearching) async -> SearXNGProbeOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        let result: Result<Int, any Error>
        do {
            let response = try await client.search(query: query, options: SearXNGSearchOptions(), instance: instance)
            result = .success(response.results.count)
        } catch {
            result = .failure(error)
        }
        return SearXNGProbeOutcome(result: result, latency: start.duration(to: clock.now))
    }
}

// MARK: - Store

/// Liste d'instances SearXNG personnalisable (1.15) : la liste statique du
/// bundle plus une surcouche persistée (`SearXNGInstanceOverrides`, dans
/// `UserDefaults` — sur le modèle de `CustomProviderStore` : uniquement des
/// métadonnées non sensibles), avec ajout, suppression, remise à zéro et test
/// de connectivité par instance.
///
/// Pas de `@MainActor` EXPLICITE, volontairement : l'isolation implicite
/// (`-default-isolation=MainActor`) permet d'écrire `CustomInstanceStore()`
/// comme valeur par défaut d'un paramètre de vue (même forme que
/// `CustomProviderStore()` dans `TrivaRootView`), ce qu'un `@MainActor` écrit
/// en toutes lettres empêche (voir le commentaire de `EngineStatusView` sur
/// `SearchSession`).
///
/// INTÉGRATION (hors de ce fichier) : `SearchSession.resolveFailoverManager()`
/// et `DiscoverViewModel.standalone` construisent encore leur
/// `FailoverManager` avec `PublicInstanceList.load()`. Ils doivent passer par
/// `effectiveInstances` (store partagé) ou `resolvedInstances(defaults:)`, et
/// la session doit invalider son `FailoverManager` en cache quand
/// `effectiveInstances` change — sinon une modification n'agit qu'au prochain
/// lancement.
@Observable
final class CustomInstanceStore {
    /// Liste du bundle, dans l'ordre du fichier.
    let defaultInstances: [URL]
    /// La liste du bundle n'a pas pu être lue (ressource absente ou
    /// illisible : un défaut d'empaquetage). Exposé pour être affiché, jamais
    /// avalé en silence.
    let defaultListLoadFailed: Bool
    private(set) var overrides: SearXNGInstanceOverrides
    /// État transitoire des tests, non persisté. Indexé par l'URL exacte telle
    /// qu'elle figure dans `effectiveInstances` (c'est elle que l'écran
    /// passe), pas par la clé de comparaison.
    private(set) var connectivityByInstance: [URL: SearXNGInstanceConnectivity] = [:]

    private let userDefaults: UserDefaults
    private let client: any SearXNGSearching

    /// Constructeur de l'app : liste du bundle via `PublicInstanceList`. Nom
    /// du type écrit en toutes lettres (pas `Self.`) : rien ne doit ressembler
    /// à un usage de `self` avant la délégation à `self.init`.
    convenience init(userDefaults: UserDefaults = .standard, client: any SearXNGSearching = SearXNGClient()) {
        let bundled = CustomInstanceStore.loadBundledDefaults()
        self.init(
            defaultInstances: bundled.instances,
            defaultListLoadFailed: bundled.failed,
            userDefaults: userDefaults,
            client: client
        )
    }

    /// Constructeur d'injection : les tests passent leur propre liste par
    /// défaut, JAMAIS celle de `Bundle.main` — le `searxng-instances.json`
    /// d'une machine de développement peut différer volontairement de celui
    /// qui est committé (instance personnelle en tête), un test qui le lirait
    /// ne serait pas reproductible.
    init(
        defaultInstances: [URL],
        defaultListLoadFailed: Bool = false,
        userDefaults: UserDefaults,
        client: any SearXNGSearching = SearXNGClient()
    ) {
        self.defaultInstances = defaultInstances
        self.defaultListLoadFailed = defaultListLoadFailed
        self.userDefaults = userDefaults
        self.client = client
        self.overrides = SearXNGInstanceOverrides.load(from: userDefaults)
    }

    // MARK: Lecture

    /// Liste réellement utilisée par la recherche, dans l'ordre d'essai.
    var effectiveInstances: [URL] {
        overrides.effectiveInstances(defaults: defaultInstances)
    }

    /// Instances ajoutées par l'utilisateur, dans l'ordre d'essai.
    var customInstances: [URL] {
        overrides.effectiveInstances(defaults: [])
    }

    /// Instances par défaut encore utilisées (ni masquées, ni doublons d'un
    /// ajout).
    var defaultSectionInstances: [URL] {
        effectiveInstances.filter { !isCustom($0) }
    }

    var hiddenDefaultCount: Int {
        defaultInstances.count - overrides.visibleDefaults(defaultInstances).count
    }

    var isCustomized: Bool {
        !overrides.isEmpty
    }

    /// Faux quand il ne reste qu'une instance (voir `cannotRemoveLastInstance`).
    var canRemoveInstance: Bool {
        effectiveInstances.count > 1
    }

    func isCustom(_ url: URL) -> Bool {
        guard let key = SearXNGInstanceAddress.comparisonKey(for: url) else { return false }
        return overrides.addedURLs.contains { SearXNGInstanceAddress.comparisonKey(for: $0) == key }
    }

    func connectivity(for url: URL) -> SearXNGInstanceConnectivity? {
        connectivityByInstance[url]
    }

    /// Même liste que `effectiveInstances`, lue directement dans
    /// `UserDefaults`, sans instance du store : pour un appelant qui construit
    /// un `FailoverManager` sans avoir le store sous la main (intégration en
    /// une ligne : `resolvedInstances(defaults: try PublicInstanceList.load())`).
    /// `nonisolated` : utilisable depuis n'importe quel contexte.
    nonisolated static func resolvedInstances(defaults: [URL], userDefaults: UserDefaults = .standard) -> [URL] {
        SearXNGInstanceOverrides.load(from: userDefaults).effectiveInstances(defaults: defaults)
    }

    // MARK: Édition

    /// Valide une saisie sans l'ajouter : l'écran a besoin de savoir si
    /// l'adresse est locale AVANT l'ajout, pour demander confirmation.
    func candidate(from rawInput: String) throws -> SearXNGInstanceCandidate {
        let candidate = try SearXNGInstanceAddress.validate(rawInput)
        guard !contains(candidate.url) else { throw CustomInstanceError.alreadyInList }
        return candidate
    }

    /// Ajoute une instance en tête de liste, après les ajouts précédents.
    /// L'adresse est REVALIDÉE : un `SearXNGInstanceCandidate` peut être
    /// construit à la main ailleurs dans l'app, et le store garantit que tout
    /// ce qu'il persiste est passé par la validation.
    @discardableResult
    func add(_ candidate: SearXNGInstanceCandidate) throws -> URL {
        let validated = try SearXNGInstanceAddress.validate(candidate.url.absoluteString)
        guard !contains(validated.url) else { throw CustomInstanceError.alreadyInList }
        apply(overrides.adding(validated.url))
        return validated.url
    }

    /// Retire une instance : supprimée si elle a été ajoutée, masquée si elle
    /// vient du bundle (réversible par `resetToDefaults()`).
    func remove(_ url: URL) throws {
        guard contains(url) else { throw CustomInstanceError.notInList }
        guard canRemoveInstance else { throw CustomInstanceError.cannotRemoveLastInstance }
        apply(overrides.removing(url, defaults: defaultInstances))
    }

    /// Retour à la liste du bundle : ajouts supprimés, masquages annulés.
    func resetToDefaults() {
        apply(.empty)
    }

    // MARK: Connectivité

    /// Teste une instance. Un second appel pendant qu'un test est en cours
    /// pour la même instance est ignoré (pas de requêtes en double).
    func testConnectivity(of url: URL) async {
        guard effectiveInstances.contains(url), connectivityByInstance[url] != .testing else { return }
        connectivityByInstance[url] = .testing
        let outcome = await SearXNGInstanceProbe.run(instance: url, client: client)
        record(outcome, for: url)
    }

    /// Teste toutes les instances EN PARALLÈLE (une sonde par instance, au
    /// plus le délai d'une seule sonde au total). Les tâches enfants du
    /// `TaskGroup` tournent hors du main actor ; seul l'enregistrement des
    /// résultats y revient, au fil de l'eau.
    func testAllConnectivity() async {
        let pending = effectiveInstances.filter { connectivityByInstance[$0] != .testing }
        guard !pending.isEmpty else { return }
        for url in pending {
            connectivityByInstance[url] = .testing
        }
        let client = self.client
        await withTaskGroup(of: (URL, SearXNGProbeOutcome).self) { group in
            for url in pending {
                group.addTask { (url, await SearXNGInstanceProbe.run(instance: url, client: client)) }
            }
            for await (url, outcome) in group {
                record(outcome, for: url)
            }
        }
    }

    // MARK: Détails

    private static func loadBundledDefaults() -> (instances: [URL], failed: Bool) {
        do {
            return (try PublicInstanceList.load(), false)
        } catch {
            return ([], true)
        }
    }

    private func contains(_ url: URL) -> Bool {
        guard let key = SearXNGInstanceAddress.comparisonKey(for: url) else { return false }
        return effectiveInstances.contains { SearXNGInstanceAddress.comparisonKey(for: $0) == key }
    }

    /// Point unique de mutation : état observé, persistance, puis purge des
    /// résultats de test d'instances qui ne sont plus dans la liste.
    private func apply(_ updated: SearXNGInstanceOverrides) {
        overrides = updated
        updated.save(to: userDefaults)
        let remaining = Set(effectiveInstances)
        connectivityByInstance = connectivityByInstance.filter { remaining.contains($0.key) }
    }

    /// Deux cas où un résultat arrivé est oublié plutôt qu'affiché : la tâche
    /// a été annulée (`URLSession` remonte alors une erreur de transport, qui
    /// s'afficherait à tort comme « Injoignable » — même prudence que
    /// `FailoverManager` face à l'annulation), ou l'instance a été retirée
    /// pendant le test.
    private func record(_ outcome: SearXNGProbeOutcome, for url: URL) {
        guard !Task.isCancelled, effectiveInstances.contains(url) else {
            connectivityByInstance[url] = nil
            return
        }
        connectivityByInstance[url] = Self.connectivity(from: outcome)
    }

    private static func connectivity(from outcome: SearXNGProbeOutcome) -> SearXNGInstanceConnectivity {
        switch outcome.result {
        case .success(let resultCount):
            return .reachable(resultCount: resultCount, latency: outcome.latency)
        case .failure(let error as SearXNGClientError):
            return .unreachable(failure(for: error))
        case .failure:
            return .unreachable(.network)
        }
    }

    private static func failure(for error: SearXNGClientError) -> SearXNGInstanceFailure {
        switch error {
        case .invalidURL:
            .invalidAddress
        case .requestFailed(let statusCode):
            .httpStatus(statusCode)
        case .timeout:
            .timeout
        case .decodingFailed:
            .notJSON
        case .transportError:
            .network
        }
    }
}
