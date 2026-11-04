//
//  SearXNGDirectory.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation
import Synchronization

// MARK: - Échecs

/// Pourquoi un rafraîchissement de l'annuaire n'a rien changé. Dans tous les cas, la liste
/// précédente (ou, à défaut, la liste embarquée) reste en service : un échec ici n'est jamais
/// visible de l'utilisateur.
nonisolated enum SearXNGDirectoryFailure: Error, Sendable, Equatable {
    /// Aucune réponse de searx.space (hors ligne, DNS, délai).
    case network
    case httpStatus(Int)
    /// Réponse qui n'est pas le JSON attendu, ou trop volumineuse.
    case invalidFormat
    /// Annuaire non mis à jour depuis plus de `SearXNGDirectoryCriteria.maxDataAge` : les
    /// mesures ne décrivent plus l'état actuel des instances.
    case staleData
    /// Données valides, mais aucune instance ne remplit les critères.
    case noCandidates
    /// Des candidats existent, mais aucun n'a répondu en JSON exploitable à la sonde.
    case noneVerified
}

// MARK: - Critères et candidats

/// Critères de sélection d'une instance dans l'annuaire. Chaque seuil est un choix de Ben à
/// réviser avec du recul, pas une valeur issue d'une mesure ; ils sont regroupés ici pour être
/// ajustés en un seul endroit.
nonisolated struct SearXNGDirectoryCriteria: Sendable, Equatable {
    /// Disponibilité sur 30 jours (`uptime.uptimeMonth`, en %). 90 % = au plus ~3 jours d'arrêt
    /// par mois : en dessous, une instance fait perdre du temps à chaque panne.
    var minimumMonthlyUptime = 90.0
    /// Taux de réussite des recherches de test de searx.space (`timing.search.success_percentage`,
    /// en %). Chaque instance reçoit 5 recherches : 80 % = 4 sur 5. Ce chiffre mesure les
    /// MOTEURS de l'instance, pas le format JSON (voir `SearXNGDirectory` : l'annuaire ne
    /// teste pas `format=json`, d'où la sonde ensuite).
    var minimumSearchSuccess = 80.0
    /// Ancienneté maximale des mesures (`metadata.timestamp`). L'annuaire est régénéré toutes les
    /// quelques heures ; plus de 7 jours signifie que sa génération est en panne.
    var maxDataAge: TimeInterval = 7 * 86_400

    static let standard = SearXNGDirectoryCriteria()
}

/// Une instance retenue dans l'annuaire, avec les mesures qui ont servi à la classer.
nonisolated struct SearXNGDirectoryCandidate: Sendable, Equatable {
    let url: URL
    let searchSuccessPercentage: Double
    let monthlyUptime: Double
    /// Temps médian d'une recherche, en secondes, quand l'annuaire le donne (souvent absent).
    let searchMedianSeconds: Double?
}

// MARK: - Lecture de l'annuaire

/// Lecture de l'annuaire public searx.space.
///
/// Source (consultée le 2026-10-27) : `https://searx.space/data/instances.json`, publié par le
/// projet searxng/searx-space (https://github.com/searxng/searx-space). Le fichier fait ~350 Ko,
/// est servi avec `Cache-Control: public, max-age=3600` et CORS ouvert. Un en-tête `x-searx`
/// prévient que « le format de ce fichier peut changer » : d'où un décodage tolérant, champ par
/// champ (voir `Lenient`), pour qu'un champ qui change de type fasse écarter UNE instance, pas
/// tout l'annuaire.
///
/// Forme utilisée : `{"metadata": {"timestamp": <epoch>}, "instances": {"https://hôte/": {
/// "network_type": "normal"|"tor", "version": "…"|null, "error": null|"…", "analytics": bool,
/// "http": {"status_code": 200}, "uptime": {"uptimeMonth": 99.5},
/// "timing": {"search": {"success_percentage": 100.0, "error": null|"HTTP status code 403",
/// "all": {"value": 0.4}|null}}}}}`.
///
/// LIMITE IMPORTANTE, mesurée le 2026-10-27 : l'annuaire ne dit PAS si `format=json` est
/// activé ni si l'instance sert un défi anti-robot à un client sans JavaScript. Son contrôle de
/// recherche passe par le HTML, et certaines instances à 100 % de réussite refusent pourtant le
/// JSON (403 si le format est désactivé, voir `InstanceFailureReason`). La seule indication
/// disponible de blocage est `timing.search.error` = « HTTP status code 403/429 », que l'on
/// exclut ; le reste se vérifie par la sonde (`SearXNGInstanceHealthProbe`).
nonisolated enum SearXNGDirectory {
    /// Filtre l'annuaire et classe le résultat : meilleur taux de réussite, puis meilleure
    /// disponibilité, puis temps médian le plus court, puis adresse (ordre déterministe).
    ///
    /// Retenues : https uniquement, réseau « normal » (ni Tor ni I2P), instance SearXNG
    /// (champ `version` renseigné), sans erreur de collecte, HTTP 200, sans analytique tierce
    /// (`analytics` : un tracker de plus entre l'utilisateur et sa recherche), disponibilité et
    /// taux de réussite au-dessus des seuils, sans blocage 403/429 signalé, hôte public (pas
    /// d'adresse locale ou privée).
    ///
    /// - Throws: `SearXNGDirectoryFailure.invalidFormat` ou `.staleData`. Une liste de
    ///   candidats vide n'est PAS une erreur ici (c'est à l'appelant d'en décider).
    static func candidates(
        from data: Data,
        now: Date = Date(),
        criteria: SearXNGDirectoryCriteria = .standard
    ) throws(SearXNGDirectoryFailure) -> [SearXNGDirectoryCandidate] {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw .invalidFormat
        }
        guard let entries = document.instances, !entries.isEmpty else { throw .invalidFormat }

        // Horodatage absent : on ne peut pas juger la fraîcheur, on accepte. Le rejeter
        // couperait le rafraîchissement dès que le projet renommerait ce champ.
        if let timestamp = document.metadata?.value?.timestamp?.value,
           now.timeIntervalSince1970 - timestamp > criteria.maxDataAge {
            throw .staleData
        }

        var seen = Set<String>()
        return entries
            .compactMap { candidate(address: $0.key, entry: $0.value.value, criteria: criteria) }
            .filter { seen.insert(InstanceReliabilityStore.key(for: $0.url)).inserted }
            .sorted(by: ranksBefore)
    }

    // MARK: Détails

    private static func candidate(
        address: String,
        entry: Entry?,
        criteria: SearXNGDirectoryCriteria
    ) -> SearXNGDirectoryCandidate? {
        guard let entry,
              entry.networkType?.value == "normal",
              entry.version?.value != nil,
              entry.error?.value == nil,
              entry.http?.value?.statusCode?.value == 200,
              entry.analytics?.value != true,
              let uptime = entry.uptime?.value?.monthly?.value, uptime >= criteria.minimumMonthlyUptime,
              let search = entry.timing?.value?.search?.value,
              let success = search.successPercentage?.value, success >= criteria.minimumSearchSuccess,
              !isBlockingError(search.error?.value),
              let validated = try? SearXNGInstanceAddress.validate(address),
              !validated.isLocalOrPrivate else {
            return nil
        }
        return SearXNGDirectoryCandidate(
            url: validated.url,
            searchSuccessPercentage: success,
            monthlyUptime: uptime,
            searchMedianSeconds: search.all?.value?.value?.value
        )
    }

    /// « HTTP status code 403 » / « … 429 » dans l'erreur du test de recherche : l'instance a
    /// refusé ou limité le contrôle de searx.space. Les autres textes (« No result »…) disent
    /// que des moteurs n'ont rien renvoyé, pas qu'on est bloqué.
    private static func isBlockingError(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.hasSuffix("403") || text.hasSuffix("429")
    }

    private static func ranksBefore(_ lhs: SearXNGDirectoryCandidate, _ rhs: SearXNGDirectoryCandidate) -> Bool {
        if lhs.searchSuccessPercentage != rhs.searchSuccessPercentage {
            return lhs.searchSuccessPercentage > rhs.searchSuccessPercentage
        }
        if lhs.monthlyUptime != rhs.monthlyUptime {
            return lhs.monthlyUptime > rhs.monthlyUptime
        }
        if lhs.searchMedianSeconds != rhs.searchMedianSeconds {
            // Une valeur absente passe après une valeur connue.
            return (lhs.searchMedianSeconds ?? .infinity) < (rhs.searchMedianSeconds ?? .infinity)
        }
        return lhs.url.absoluteString < rhs.url.absoluteString
    }

    // MARK: Décodage tolérant

    /// Décode une valeur sans jamais échouer : un champ du mauvais type devient `nil`.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) {
            value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }

    private struct Document: Decodable {
        let metadata: Lenient<Metadata>?
        let instances: [String: Lenient<Entry>]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try? container.decode(Lenient<Metadata>.self, forKey: .metadata)
            instances = try container.decode([String: Lenient<Entry>].self, forKey: .instances)
        }

        enum CodingKeys: String, CodingKey { case metadata, instances }
    }

    private struct Metadata: Decodable {
        let timestamp: Lenient<Double>?
    }

    private struct Entry: Decodable {
        let networkType: Lenient<String>?
        let version: Lenient<String>?
        let error: Lenient<String>?
        let analytics: Lenient<Bool>?
        let http: Lenient<HTTPStatus>?
        let uptime: Lenient<Uptime>?
        let timing: Lenient<Timing>?

        enum CodingKeys: String, CodingKey {
            case networkType = "network_type"
            case version, error, analytics, http, uptime, timing
        }
    }

    private struct HTTPStatus: Decodable {
        let statusCode: Lenient<Int>?

        enum CodingKeys: String, CodingKey { case statusCode = "status_code" }
    }

    private struct Uptime: Decodable {
        let monthly: Lenient<Double>?

        enum CodingKeys: String, CodingKey { case monthly = "uptimeMonth" }
    }

    private struct Timing: Decodable {
        let search: Lenient<SearchTiming>?
    }

    private struct SearchTiming: Decodable {
        let successPercentage: Lenient<Double>?
        let error: Lenient<String>?
        let all: Lenient<Measure>?

        enum CodingKeys: String, CodingKey {
            case successPercentage = "success_percentage"
            case error, all
        }
    }

    private struct Measure: Decodable {
        let value: Lenient<Double>?
    }
}

// MARK: - Liste rafraîchie (persistée)

/// Ce qui est conservé du dernier rafraîchissement réussi.
nonisolated struct SearXNGDirectorySnapshot: Codable, Sendable, Equatable {
    /// Adresses retenues (et vérifiées par la sonde), meilleure en premier.
    var instances: [String] = []
    var updatedAt: Date?
    /// Pas de nouvelle tentative avant cette date (voir `SearXNGDirectoryRefresher`).
    var nextAttemptAt: Date?
}

/// Liste d'instances issue de l'annuaire, persistée dans `UserDefaults` (adresses publiques et
/// dates : rien de sensible). Constructeur sans argument = mémoire seule, pour les tests.
nonisolated final class SearXNGDirectoryStore: Sendable {
    static let defaultsKey = "searxng.directorySnapshot.v1"
    static let shared = SearXNGDirectoryStore(userDefaults: .standard)

    private let snapshot: Mutex<SearXNGDirectorySnapshot>
    // `UserDefaults` est documenté thread-safe par Apple mais n'est pas déclaré `Sendable` par
    // le SDK : `nonisolated(unsafe)` est exact ici (lecture/écriture de clés, jamais de mutation
    // de l'objet lui-même).
    nonisolated(unsafe) private let userDefaults: UserDefaults?

    init(userDefaults: UserDefaults? = nil) {
        self.userDefaults = userDefaults
        self.snapshot = Mutex(Self.load(from: userDefaults))
    }

    func load() -> SearXNGDirectorySnapshot {
        snapshot.withLock { $0 }
    }

    func save(_ newValue: SearXNGDirectorySnapshot) {
        snapshot.withLock { $0 = newValue }
        guard let userDefaults, let data = try? JSONEncoder().encode(newValue) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }

    /// Instances rafraîchies utilisables : adresses revalidées (https, hôte public), car la
    /// préférence est modifiable hors de l'app (sauvegarde restaurée, outil de débogage) et
    /// ne doit pas pouvoir injecter une adresse locale ou en clair.
    var refreshedInstances: [URL] {
        load().instances.compactMap { address in
            guard let candidate = try? SearXNGInstanceAddress.validate(address),
                  !candidate.isLocalOrPrivate else {
                return nil
            }
            return candidate.url
        }
    }

    private static func load(from userDefaults: UserDefaults?) -> SearXNGDirectorySnapshot {
        guard let data = userDefaults?.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SearXNGDirectorySnapshot.self, from: data) else {
            return SearXNGDirectorySnapshot()
        }
        return decoded
    }
}

// MARK: - Rafraîchissement

/// Issue d'un appel à `SearXNGDirectoryRefresher.refreshIfNeeded`.
nonisolated enum SearXNGDirectoryRefreshOutcome: Sendable, Equatable {
    /// Trop tôt pour une nouvelle tentative.
    case skipped(until: Date)
    case updated(count: Int)
    /// Échec ; liste précédente conservée.
    case failed(SearXNGDirectoryFailure)
    /// `Task` annulée : rien n'est enregistré, la prochaine occasion réessaiera.
    case cancelled
}

/// Rafraîchissement de l'annuaire tel que le voit l'entretien de fond (`SearXNGMaintenance`) :
/// abstrait pour qu'un test vérifie l'enchaînement d'un passage, et son verrou, avec un faux,
/// sans réseau. Comme `SearXNGDirectoryRefresher`, ne lève jamais : un échec est une issue
/// (`.failed`), pas une erreur.
nonisolated protocol SearXNGDirectoryRefreshing: Sendable {
    func refreshIfNeeded(now: Date, force: Bool) async -> SearXNGDirectoryRefreshOutcome
}

/// Rafraîchit en tâche de fond la liste d'instances depuis l'annuaire searx.space.
///
/// - Fréquence : au plus UNE tentative par jour (24 h), succès ou non. Exception : un échec
///   « aucune réponse réseau » (hors ligne) n'a rien coûté à searx.space, la prochaine tentative
///   n'attend que 1 h. Le moindre autre échec (HTTP, format) attend 24 h : insister sur un
///   service en difficulté serait discourtois.
/// - Jamais bloquant : la fonction ne lève rien, et le résultat n'est consommé qu'au prochain
///   `FailoverManager` construit. À lancer dans une `Task` de priorité `.background` : c'est ce
///   que fait `SearXNGMaintenance`, à chaque passage de l'app au premier plan (la limite d'une
///   tentative par jour ci-dessus rend ces appels répétés gratuits).
/// - Vérification : les `maxProbed` meilleurs candidats passent par la sonde (une requête neutre
///   « test » chacun), seuls ceux qui répondent en JSON exploitable sont gardés (au plus
///   `maxKept`). Puisque l'annuaire ne teste pas le JSON, sans cette étape la liste
///   contiendrait surtout des instances qui refusent le format. Les verdicts alimentent aussi le
///   store de fiabilité si fourni. `prober: nil` désactive la vérification (liste non testée).
/// - Si rien ne passe (aucune instance vérifiée), l'ancienne liste n'est PAS effacée.
///
/// Vie privée : chaque rafraîchissement expose l'adresse IP de l'appareil à searx.space (un GET) et
/// aux instances sondées (une requête « test » chacune), sans action de l'utilisateur. Le même
/// niveau d'exposition qu'une recherche normale, mais à signaler dans les mentions légales.
nonisolated struct SearXNGDirectoryRefresher: Sendable, SearXNGDirectoryRefreshing {
    static let directoryURL = URL(string: "https://searx.space/data/instances.json")!
    static let refreshInterval: TimeInterval = 86_400
    static let transportRetryInterval: TimeInterval = 3_600
    static let requestTimeout: TimeInterval = 20
    /// Garde-fou : le fichier réel fait ~350 Ko ; 10 Mo ne peut être qu'une erreur ou un abus.
    static let maxPayloadBytes = 10_000_000

    private let requester: any HTTPDataRequesting
    private let prober: (any InstanceProbing)?
    private let store: SearXNGDirectoryStore
    private let reliability: InstanceReliabilityStore?
    private let criteria: SearXNGDirectoryCriteria
    private let maxProbed: Int
    private let maxKept: Int

    init(
        requester: any HTTPDataRequesting = URLSessionDataRequester(),
        prober: (any InstanceProbing)? = SearXNGInstanceHealthProbe(),
        store: SearXNGDirectoryStore = .shared,
        reliability: InstanceReliabilityStore? = nil,
        criteria: SearXNGDirectoryCriteria = .standard,
        maxProbed: Int = 15,
        maxKept: Int = 12
    ) {
        self.requester = requester
        self.prober = prober
        self.store = store
        self.reliability = reliability
        self.criteria = criteria
        self.maxProbed = maxProbed
        self.maxKept = maxKept
    }

    @concurrent
    func refreshIfNeeded(now: Date = Date(), force: Bool = false) async -> SearXNGDirectoryRefreshOutcome {
        let previous = store.load()
        if !force, let next = previous.nextAttemptAt, now < next {
            return .skipped(until: next)
        }
        do {
            let kept = try await fetchVerifiedInstances(now: now)
            store.save(SearXNGDirectorySnapshot(
                instances: kept.map(\.absoluteString),
                updatedAt: now,
                nextAttemptAt: now.addingTimeInterval(Self.refreshInterval)
            ))
            return .updated(count: kept.count)
        } catch is CancellationError {
            return .cancelled
        } catch {
            let failure = (error as? SearXNGDirectoryFailure) ?? .invalidFormat
            var updated = previous
            let delay = failure == .network ? Self.transportRetryInterval : Self.refreshInterval
            updated.nextAttemptAt = now.addingTimeInterval(delay)
            store.save(updated)
            return .failed(failure)
        }
    }

    // MARK: Détails

    private func fetchVerifiedInstances(now: Date) async throws -> [URL] {
        let data = try await fetchDirectory()
        let candidates = try SearXNGDirectory.candidates(from: data, now: now, criteria: criteria)
        guard !candidates.isEmpty else { throw SearXNGDirectoryFailure.noCandidates }
        return try await verified(Array(candidates.prefix(maxProbed)).map(\.url))
    }

    private func fetchDirectory() async throws -> Data {
        var request = URLRequest(url: Self.directoryURL, timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requester.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SearXNGDirectoryFailure.network
        }
        guard let http = response as? HTTPURLResponse else { throw SearXNGDirectoryFailure.network }
        guard http.statusCode == 200 else { throw SearXNGDirectoryFailure.httpStatus(http.statusCode) }
        guard data.count <= Self.maxPayloadBytes else { throw SearXNGDirectoryFailure.invalidFormat }
        return data
    }

    private func verified(_ candidates: [URL]) async throws -> [URL] {
        guard let prober else { return Array(candidates.prefix(maxKept)) }
        let results = await InstanceProbeBatch.run(candidates, using: prober, store: reliability)
        try Task.checkCancellation()
        let healthy = candidates.filter { results[$0]?.isHealthy == true }
        guard !healthy.isEmpty else { throw SearXNGDirectoryFailure.noneVerified }
        return Array(healthy.prefix(maxKept))
    }
}
