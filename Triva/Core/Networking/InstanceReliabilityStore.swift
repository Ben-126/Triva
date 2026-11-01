//
//  InstanceReliabilityStore.swift
//  Triva
//
//  Created by ben podrojsky on 27/10/2026.
//

import Foundation
import Synchronization

// MARK: - Motifs d'échec

/// Pourquoi une instance SearXNG n'a pas donné de résultats exploitables.
///
/// Motifs FIXES, jamais de texte venu du serveur : une instance publique est un tiers non
/// maîtrisé, et ce qui est persisté dans `UserDefaults` (donc en clair, dans les sauvegardes de
/// l'appareil) ne doit contenir ni extrait de réponse ni URL de requête. Seul un code de motif
/// est conservé, avec la date.
///
/// Cas à ne pas confondre, car ils ne se traitent pas pareil (voir `baseBackoff`) :
/// - `accessDenied` : HTTP 403. La doc SearXNG précise que demander un format non activé dans
///   `settings.yml > search > formats` renvoie 403 et que « beaucoup d'instances publiques ont
///   ces formats désactivés » : c'est le cas le plus courant, et il est PERMANENT jusqu'à ce que
///   l'administrateur change sa configuration.
/// - `notJSON` : statut 200 mais corps non JSON, le signe d'une page de défi anti-robot (Anubis,
///   Cloudflare) servie à la place de la réponse. Également durable.
/// - `rateLimited` : HTTP 429, le limiteur de l'instance a vu trop de requêtes de notre IP.
///   Transitoire, mais retenter vite n'arrange rien.
///
/// Source : https://docs.searxng.org/dev/search_api.html (consultée le 2026-10-27).
nonisolated enum InstanceFailureReason: String, Codable, Sendable, Equatable, CaseIterable {
    case timeout
    /// Aucune réponse HTTP : DNS, connexion refusée, TLS, appareil hors ligne. `SearXNGClient`
    /// ne distingue pas ces cas (tout `URLError` hors délai devient `transportError`).
    case network
    case rateLimited
    case accessDenied
    case notJSON
    case serverError
    /// Autre statut HTTP d'erreur (404, 400…) : l'adresse n'est vraisemblablement pas une
    /// instance SearXNG, ou elle a déménagé.
    case httpError
    /// JSON valide mais zéro résultat à une requête banale : moteurs bloqués ou suspendus chez
    /// l'instance. Joignable, mais inutile. Ne sort QUE de la sonde (une recherche réelle vide
    /// n'est pas une panne : la requête de l'utilisateur peut être pointue).
    case emptyResults
    case invalidAddress
    case unknown

    /// Délai de base de mise de côté après le seuil d'échecs (voir
    /// `InstanceReliabilityPolicy.backoff`).
    ///
    /// Un blocage de configuration (403, anti-robot) ne se lève pas en dix minutes : une heure
    /// avant de retenter. Une limite de débit se résorbe en quelques minutes mais pas en
    /// secondes. Une panne transitoire (délai, 5xx, réseau) se retente vite.
    var baseBackoff: TimeInterval {
        switch self {
        case .accessDenied, .notJSON, .emptyResults, .httpError, .invalidAddress: 3_600
        case .rateLimited: 900
        case .timeout, .network, .serverError, .unknown: 600
        }
    }

    /// Libellé court en français, pour les Réglages.
    var userFacingMessage: String {
        switch self {
        case .timeout: "Délai dépassé"
        case .network: "Injoignable"
        case .rateLimited: "Trop de requêtes (429)"
        case .accessDenied: "Format JSON refusé (403)"
        case .notJSON: "Pas de réponse JSON (protection anti-robot ?)"
        case .serverError: "Erreur du serveur"
        case .httpError: "Réponse inattendue"
        case .emptyResults: "Répond, sans résultat"
        case .invalidAddress: "Adresse invalide"
        case .unknown: "Échec inconnu"
        }
    }

    /// Range une erreur levée par un `SearXNGSearching` dans un motif. L'appelant traite
    /// l'annulation AVANT (une annulation n'est pas une panne d'instance, voir
    /// `FailoverManager`).
    static func classify(_ error: any Error) -> InstanceFailureReason {
        if let clientError = error as? SearXNGClientError {
            switch clientError {
            case .invalidURL: return .invalidAddress
            case .timeout: return .timeout
            case .decodingFailed: return .notJSON
            case .transportError: return .network
            case .requestFailed(let statusCode): return reason(forStatus: statusCode)
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network
        }
        return .unknown
    }

    private static func reason(forStatus statusCode: Int) -> InstanceFailureReason {
        switch statusCode {
        case 403: .accessDenied
        case 429: .rateLimited
        case 500...599: .serverError
        default: .httpError
        }
    }
}

// MARK: - Fiche d'une instance

/// Niveau de confiance d'une instance, de la meilleure à la pire. C'est lui (et non un score
/// continu) qui ordonne la liste, pour que l'ORDRE DE LA LISTE reste le critère de départage.
nonisolated enum InstanceReliabilityTier: Sendable, Equatable {
    /// A répondu correctement à son dernier essai, taux de réussite élevé, pas lente.
    case good
    /// Aucune donnée, ou signal trop faible pour juger (un seul échec, mélange de réussites et
    /// d'échecs, instance lente).
    case neutral
    /// Échecs répétés ou taux de réussite bas, mais plus mise de côté : elle ne sera essayée
    /// qu'après toutes les autres.
    case poor
    /// Mise de côté jusqu'à une date (voir `InstanceReliabilityRecord.benchedUntil`).
    case benched
}

/// Réglages de la mesure de fiabilité. Valeurs choisies à la main, pas calibrées sur des
/// mesures : elles sont regroupées ici (et injectables dans les tests) pour être ajustées en
/// un seul endroit quand on aura du recul sur le terrain.
nonisolated struct InstanceReliabilityPolicy: Sendable, Equatable {
    /// Échecs consécutifs à partir desquels l'instance est mise de côté. 2 et non 1 : un
    /// échec isolé (paquet perdu, redémarrage de l'instance) ne doit pas bannir un bon
    /// serveur ; deux de suite sont déjà un signal.
    var benchThreshold = 2
    /// Plafond de la mise de côté : une instance retentée toutes les 24 h au pire, jamais
    /// bannie à vie (les administrateurs corrigent leur configuration).
    var maxBackoff: TimeInterval = 86_400
    /// Au-delà de ce nombre d'essais cumulés, les compteurs sont divisés par deux : « récent »
    /// veut dire environ les 20 dernières tentatives, pas l'historique complet.
    var window = 20
    /// Taux lissé minimal pour être « bonne ». 0,6 et non 0,7 : après UN seul succès le taux
    /// lissé vaut 2/3 (0,667), et une instance qui vient de répondre doit passer devant les
    /// inconnues dès la première recherche, sinon la mesure n'apprend rien d'utile avant la
    /// deuxième. Les échecs, eux, sont déjà pris en compte par `consecutiveFailures == 0`.
    var goodMinimumRate = 0.6
    var poorMaximumRate = 0.4
    /// Nombre d'essais minimal avant de juger un taux bas : 1 échec sur 1 essai donne 0 %
    /// sans rien prouver.
    var poorMinimumSamples = 4
    /// Au-delà de cette latence moyenne, une instance fiable n'est plus « bonne » mais
    /// « neutre » : une réponse en plus de 4 s se paie à chaque recherche. Sert de rétrogradation,
    /// pas de tri : voir `InstanceReliabilityStore.ordered`.
    var slowLatencyMilliseconds = 4_000.0
    /// Poids de la dernière mesure dans la moyenne mobile exponentielle des latences.
    var latencySmoothing = 0.3

    static let standard = InstanceReliabilityPolicy()

    /// Durée de mise de côté : `baseBackoff` du motif, doublée à chaque échec au-delà du
    /// seuil, plafonnée à `maxBackoff`.
    func backoff(for reason: InstanceFailureReason, consecutiveFailures: Int) -> TimeInterval {
        let extra = max(0, consecutiveFailures - benchThreshold)
        // Exposant borné : 2^40 déborderait sans rien changer, le plafond tranche bien avant.
        return min(maxBackoff, reason.baseBackoff * pow(2, Double(min(extra, 40))))
    }
}

/// Ce que l'app retient d'UNE instance. Valeur immuable : chaque enregistrement en produit une
/// nouvelle copie. Données non sensibles (comptes, dates, un code de motif) : `UserDefaults`
/// suffit, pas le Keychain.
nonisolated struct InstanceReliabilityRecord: Codable, Sendable, Equatable {
    var successes = 0
    var failures = 0
    var consecutiveFailures = 0
    /// Moyenne mobile exponentielle des latences des réponses réussies, en ms.
    var averageLatencyMilliseconds: Double?
    var lastFailureReason: InstanceFailureReason?
    var lastFailureAt: Date?
    var lastSuccessAt: Date?

    /// Taux de réussite lissé (règle de succession de Laplace) : une instance sans historique
    /// vaut 0,5, pas 0 ni 1 — ni coupable ni innocente.
    var successRate: Double {
        Double(successes + 1) / Double(successes + failures + 2)
    }

    var lastActivityAt: Date {
        max(lastSuccessAt ?? .distantPast, lastFailureAt ?? .distantPast)
    }

    func recordingSuccess(
        latencyMilliseconds: Double?,
        at date: Date,
        policy: InstanceReliabilityPolicy
    ) -> InstanceReliabilityRecord {
        var copy = self
        copy.successes += 1
        copy.consecutiveFailures = 0
        copy.lastSuccessAt = date
        if let latencyMilliseconds {
            copy.averageLatencyMilliseconds = averageLatencyMilliseconds.map {
                $0 + policy.latencySmoothing * (latencyMilliseconds - $0)
            } ?? latencyMilliseconds
        }
        return copy.foldedIntoWindow(policy.window)
    }

    func recordingFailure(
        reason: InstanceFailureReason,
        at date: Date,
        policy: InstanceReliabilityPolicy
    ) -> InstanceReliabilityRecord {
        var copy = self
        copy.failures += 1
        copy.consecutiveFailures += 1
        copy.lastFailureReason = reason
        copy.lastFailureAt = date
        return copy.foldedIntoWindow(policy.window)
    }

    /// Date de fin de la mise de côté, `nil` si l'instance n'est pas (ou plus) concernée par
    /// le seuil d'échecs. Passée, elle signifie « retentable » : voir `tier(at:policy:)`.
    func benchedUntil(policy: InstanceReliabilityPolicy) -> Date? {
        guard consecutiveFailures >= policy.benchThreshold,
              let lastFailureAt, let lastFailureReason else {
            return nil
        }
        let delay = policy.backoff(for: lastFailureReason, consecutiveFailures: consecutiveFailures)
        return lastFailureAt.addingTimeInterval(delay)
    }

    func tier(at date: Date, policy: InstanceReliabilityPolicy) -> InstanceReliabilityTier {
        if let until = benchedUntil(policy: policy) {
            // Délai écoulé : retentable, mais rien ne prouve encore qu'elle va mieux. Elle
            // passe après toutes les autres plutôt que de retarder une recherche réelle.
            return date < until ? .benched : .poor
        }
        let samples = successes + failures
        if samples >= policy.poorMinimumSamples, successRate < policy.poorMaximumRate {
            return .poor
        }
        let isFast = averageLatencyMilliseconds.map { $0 <= policy.slowLatencyMilliseconds } ?? true
        if consecutiveFailures == 0, successes >= 1, successRate >= policy.goodMinimumRate, isFast {
            return .good
        }
        return .neutral
    }

    /// Divise les compteurs par deux quand leur somme dépasse la fenêtre. L'arrondi des
    /// échecs est vers le HAUT : un échec ne doit jamais disparaître par arrondi.
    private func foldedIntoWindow(_ window: Int) -> InstanceReliabilityRecord {
        guard successes + failures > window else { return self }
        var copy = self
        copy.successes = successes / 2
        copy.failures = (failures + 1) / 2
        return copy
    }
}

// MARK: - Classement

/// Résultat de `InstanceReliabilityStore.ordered`.
nonisolated struct InstanceOrdering: Sendable, Equatable {
    /// À essayer, dans l'ordre : bonnes, puis neutres, puis médiocres.
    let active: [URL]
    /// Mises de côté en ce moment, la plus proche de sa retentative en premier.
    let benched: [URL]
}

// MARK: - Store

/// Mémoire de fiabilité des instances SearXNG, persistée dans `UserDefaults`.
///
/// POURQUOI : sur ~20 instances publiques testées, une seule répondait en JSON (voir le plan,
/// section Risques). Sans mémoire, chaque lancement de l'app, chaque recherche, retombe sur
/// les mêmes instances mortes en tête de liste et paie 10 s de délai à chacune. Avec elle, la
/// première recherche réussie apprend quoi essayer en premier, et ce savoir survit au
/// redémarrage.
///
/// ORDRE : par niveau (`InstanceReliabilityTier`), puis par position dans la liste d'origine.
/// La latence ne trie PAS directement : elle ne fait que rétrograder une instance lente (voir
/// `InstanceReliabilityPolicy.slowLatencyMilliseconds`). Raison : la liste est ordonnée par
/// priorité (une instance personnelle auto-hébergée y est placée en tête exprès, par choix de
/// confidentialité). Un tri à la milliseconde enverrait les requêtes vers une instance
/// publique de 300 ms plutôt que vers la sienne à 600 ms. L'écart assumé avec « les plus
/// rapides d'abord » est documenté dans le rapport de la tâche R3.
///
/// CONCURRENCE : `nonisolated` + `Mutex` (framework `Synchronization`) plutôt qu'un `actor`.
/// Le classement est consulté depuis `FailoverManager` (un acteur), mais aussi depuis les
/// Réglages (main actor) et la sonde (tâches enfants) ; un `actor` obligerait chacun à
/// `await` pour une lecture en mémoire de quelques microsecondes. Les sections critiques sont
/// courtes et sans `await`.
///
/// VIE PRIVÉE : uniquement des hôtes d'instances publiques, des compteurs et des dates. Aucune
/// requête de l'utilisateur, aucune clé. Les instances personnelles de l'utilisateur y figurent
/// aussi (clé = adresse) : ces données restent dans `UserDefaults`, sur l'appareil.
nonisolated final class InstanceReliabilityStore: Sendable {
    static let defaultsKey = "searxng.instanceReliability.v1"

    /// Store partagé de l'app, persisté. Le constructeur sans argument, lui, est en mémoire :
    /// c'est le défaut de `FailoverManager`, pour que les tests et les aperçus ne polluent
    /// pas les vraies données.
    static let shared = InstanceReliabilityStore(userDefaults: .standard)

    private let records: Mutex<[String: InstanceReliabilityRecord]>
    // `UserDefaults` est documenté thread-safe par Apple mais n'est pas déclaré `Sendable` par
    // le SDK : `nonisolated(unsafe)` est exact ici (lecture/écriture de clés, jamais de mutation
    // de l'objet lui-même).
    nonisolated(unsafe) private let userDefaults: UserDefaults?
    private let policy: InstanceReliabilityPolicy
    private let maxRecords: Int

    /// - Parameters:
    ///   - userDefaults: `nil` = mémoire seule, rien n'est écrit ni lu.
    ///   - maxRecords: plafond d'entrées conservées (les plus anciennes sont oubliées) : une
    ///     liste rafraîchie chaque jour depuis l'annuaire ne doit pas faire grossir indéfiniment
    ///     la préférence.
    init(
        userDefaults: UserDefaults? = nil,
        policy: InstanceReliabilityPolicy = .standard,
        maxRecords: Int = 200
    ) {
        self.userDefaults = userDefaults
        self.policy = policy
        self.maxRecords = maxRecords
        self.records = Mutex(Self.load(from: userDefaults))
    }

    // MARK: Lecture

    func record(for instance: URL) -> InstanceReliabilityRecord? {
        records.withLock { $0[Self.key(for: instance)] }
    }

    func tier(for instance: URL, at date: Date = Date()) -> InstanceReliabilityTier {
        guard let record = record(for: instance) else { return .neutral }
        return record.tier(at: date, policy: policy)
    }

    /// Fin de la mise de côté si l'instance est actuellement écartée, sinon `nil`.
    func benchedUntil(for instance: URL, at date: Date = Date()) -> Date? {
        guard let record = record(for: instance),
              record.tier(at: date, policy: policy) == .benched else {
            return nil
        }
        return record.benchedUntil(policy: policy)
    }

    /// Classe `instances` : doublons retirés (adresses équivalentes, voir `key(for:)`),
    /// niveaux `good` > `neutral` > `poor`, ordre d'origine à égalité, instances mises de côté
    /// à part.
    func ordered(_ instances: [URL], at date: Date = Date()) -> InstanceOrdering {
        let snapshot = records.withLock { $0 }
        var seen = Set<String>()
        var good: [URL] = [], neutral: [URL] = [], poor: [URL] = []
        var benched: [(url: URL, until: Date)] = []
        for instance in instances {
            let key = Self.key(for: instance)
            guard seen.insert(key).inserted else { continue }
            let record = snapshot[key]
            switch record?.tier(at: date, policy: policy) ?? .neutral {
            case .good: good.append(instance)
            case .neutral: neutral.append(instance)
            case .poor: poor.append(instance)
            case .benched: benched.append((instance, record?.benchedUntil(policy: policy) ?? date))
            }
        }
        // `sorted` n'est pas garanti stable : l'index d'origine départage les égalités.
        let benchedOrdered = benched.enumerated()
            .sorted { ($0.element.until, $0.offset) < ($1.element.until, $1.offset) }
            .map(\.element.url)
        return InstanceOrdering(active: good + neutral + poor, benched: benchedOrdered)
    }

    // MARK: Écriture

    func recordSuccess(for instance: URL, latency: Duration, at date: Date = Date()) {
        update(instance) {
            $0.recordingSuccess(latencyMilliseconds: Self.milliseconds(latency), at: date, policy: policy)
        }
    }

    func recordFailure(for instance: URL, reason: InstanceFailureReason, at date: Date = Date()) {
        update(instance) { $0.recordingFailure(reason: reason, at: date, policy: policy) }
    }

    /// Enregistre le verdict d'une sonde (voir `SearXNGInstanceHealthProbe`).
    func record(_ result: InstanceProbeResult, for instance: URL, at date: Date = Date()) {
        switch result.verdict {
        case .healthy:
            recordSuccess(for: instance, latency: result.latency, at: date)
        case .failed(let reason):
            recordFailure(for: instance, reason: reason, at: date)
        }
    }

    /// Oublie une instance (retirée de la liste par l'utilisateur, ou bouton « réessayer »).
    func forget(_ instance: URL) {
        mutate { $0[Self.key(for: instance)] = nil }
    }

    func resetAll() {
        mutate { $0 = [:] }
    }

    // MARK: Détails

    /// Clé de stockage : la même que celle qui sert à comparer les adresses dans les Réglages
    /// (`https://Searx.be/` et `https://searx.be` sont la même instance). Repli sur l'adresse
    /// en minuscules pour une URL sans hôte, qui ne peut pas être une instance mais ne doit pas
    /// faire planter le store.
    static func key(for instance: URL) -> String {
        SearXNGInstanceAddress.comparisonKey(for: instance) ?? instance.absoluteString.lowercased()
    }

    private func update(_ instance: URL, _ transform: (InstanceReliabilityRecord) -> InstanceReliabilityRecord) {
        let key = Self.key(for: instance)
        mutate { $0[key] = transform($0[key] ?? InstanceReliabilityRecord()) }
    }

    /// Point unique de mutation : modification, purge, puis écriture, sous le même verrou.
    private func mutate(_ change: (inout [String: InstanceReliabilityRecord]) -> Void) {
        records.withLock { current in
            change(&current)
            Self.prune(&current, keeping: maxRecords)
            persist(current)
        }
    }

    private func persist(_ current: [String: InstanceReliabilityRecord]) {
        guard let userDefaults else { return }
        // Un `Dictionary<String, Codable>` s'encode toujours : l'échec n'est pas atteignable,
        // et perdre une écriture de statistiques ne vaut pas un crash.
        guard let data = try? JSONEncoder().encode(current) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }

    /// Données illisibles (version future de l'app, corruption) : on repart de zéro. La mesure
    /// se reconstruit en quelques recherches, rien de précieux n'est perdu.
    private static func load(from userDefaults: UserDefaults?) -> [String: InstanceReliabilityRecord] {
        guard let data = userDefaults?.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: InstanceReliabilityRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func prune(_ current: inout [String: InstanceReliabilityRecord], keeping limit: Int) {
        guard current.count > limit else { return }
        let oldestFirst = current.sorted { $0.value.lastActivityAt < $1.value.lastActivityAt }
        for (key, _) in oldestFirst.prefix(current.count - limit) {
            current[key] = nil
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

// MARK: - Sonde

/// Verdict d'une sonde.
nonisolated struct InstanceProbeResult: Sendable, Equatable {
    enum Verdict: Sendable, Equatable {
        /// Vraie réponse JSON avec au moins un résultat.
        case healthy(resultCount: Int)
        case failed(InstanceFailureReason)
    }

    let verdict: Verdict
    /// Durée de la requête, réponse ou échec compris.
    let latency: Duration

    var isHealthy: Bool {
        if case .healthy = verdict { return true }
        return false
    }
}

/// Test rapide d'une instance. Abstraction pour injecter une fausse sonde dans les tests de
/// `FailoverManager` et du rafraîchissement de l'annuaire. Ne lève que `CancellationError` :
/// une instance qui échoue est un RÉSULTAT (`.failed`), pas une erreur.
nonisolated protocol InstanceProbing: Sendable {
    func probe(_ instance: URL) async throws -> InstanceProbeResult
}

/// Sonde réelle : une VRAIE recherche `format=json` via `SearXNGSearching`, et non un GET de la
/// page d'accueil. La plupart des instances publiques répondent 200 à un navigateur mais
/// servent une page de défi anti-robot à une requête JSON : un test HTTP nu dirait « OK »
/// pour exactement les instances qui ne marchent pas dans l'app. En passant par le même client
/// que les recherches réelles, on teste aussi le même chemin de décodage.
///
/// Verdict `.healthy` seulement si le JSON est exploitable ET non vide : une instance qui
/// répond `{"results": []}` à « test » a ses moteurs bloqués, elle est inutile.
///
/// Requête volontairement neutre (« test ») : rien de personnel ne part vers un tiers.
/// Réutilisable par les Réglages (c'est la même sonde que `SearXNGInstanceProbe` de
/// `CustomInstanceStore.swift`, avec un verdict typé en plus).
///
/// `@concurrent` : avec `NonisolatedNonsendingByDefault`, une fonction `nonisolated async`
/// tourne sur l'acteur de l'APPELANT ; lancée depuis le main actor, elle y ferait le décodage
/// JSON de la réponse.
nonisolated struct SearXNGInstanceHealthProbe: InstanceProbing {
    static let query = "test"

    private let client: any SearXNGSearching

    init(client: any SearXNGSearching = SearXNGClient()) {
        self.client = client
    }

    @concurrent
    func probe(_ instance: URL) async throws -> InstanceProbeResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await client.search(
                query: Self.query,
                options: SearXNGSearchOptions(),
                instance: instance
            )
            let latency = start.duration(to: clock.now)
            return response.results.isEmpty
                ? InstanceProbeResult(verdict: .failed(.emptyResults), latency: latency)
                : InstanceProbeResult(verdict: .healthy(resultCount: response.results.count), latency: latency)
        } catch {
            // Annulation : `URLSession` la remonte en erreur de transport, qui se lirait à tort
            // comme « Injoignable ». Même prudence que `FailoverManager`.
            if Task.isCancelled { throw CancellationError() }
            return InstanceProbeResult(
                verdict: .failed(InstanceFailureReason.classify(error)),
                latency: start.duration(to: clock.now)
            )
        }
    }
}

/// Sonde plusieurs instances avec une concurrence bornée, et nourrit le store.
///
/// Borne à 4 par défaut : sonder 15 instances d'un coup ouvrirait 15 connexions TLS en même
/// temps sur un téléphone, pour un résultat qui n'est pas urgent.
nonisolated enum InstanceProbeBatch {
    static let defaultConcurrency = 4

    /// Renvoie le verdict de chaque instance sondée. Une sonde annulée n'a pas de verdict (et
    /// n'est pas enregistrée). `store` : si fourni, chaque verdict y est enregistré au fil de
    /// l'eau.
    @concurrent
    static func run(
        _ instances: [URL],
        using prober: any InstanceProbing,
        store: InstanceReliabilityStore? = nil,
        concurrency: Int = defaultConcurrency
    ) async -> [URL: InstanceProbeResult] {
        var results: [URL: InstanceProbeResult] = [:]
        var pending = instances[...]
        await withTaskGroup(of: (URL, InstanceProbeResult?).self) { group in
            func launchNext() {
                guard let instance = pending.popFirst() else { return }
                group.addTask { (instance, try? await prober.probe(instance)) }
            }
            for _ in 0..<max(1, concurrency) { launchNext() }
            for await (instance, result) in group {
                if let result {
                    results[instance] = result
                    store?.record(result, for: instance)
                }
                if !Task.isCancelled { launchNext() }
            }
        }
        return results
    }
}
