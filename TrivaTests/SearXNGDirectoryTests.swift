//
//  SearXNGDirectoryTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 28/10/2026.
//

import Testing
import Foundation
import Synchronization
@testable import Triva

// MARK: - Fixtures

/// Instance de l'annuaire searx.space, telle que `instances.json` la décrit (forme relevée le
/// 2026-10-28). Chaque champ filtré par `SearXNGDirectory` est réglable ; les défauts décrivent
/// une instance qui passe tous les critères.
private struct DirectoryFixtureEntry {
    var networkType: Any = "normal"
    var version: Any = "2026.10.27+b5ed73fcb"
    var error: Any = NSNull()
    var analytics: Any = false
    var statusCode: Any = 200
    var uptimeMonth: Any = 99.5
    var successPercentage: Any = 100.0
    var searchError: Any = NSNull()
    var median: Double?

    var json: [String: Any] {
        var all: Any = NSNull()
        if let median { all = ["value": median] }
        return [
            "network_type": networkType,
            "version": version,
            "error": error,
            "analytics": analytics,
            "http": ["status_code": statusCode],
            "uptime": ["uptimeDay": 100.0, "uptimeMonth": uptimeMonth],
            "timing": ["search": ["success_percentage": successPercentage, "error": searchError, "all": all]]
        ]
    }
}

private let fixtureNow = Date(timeIntervalSince1970: 1_793_200_000)

private func directoryData(
    _ instances: [String: DirectoryFixtureEntry],
    timestamp: Double? = fixtureNow.timeIntervalSince1970 - 3_600
) throws -> Data {
    var document: [String: Any] = ["instances": instances.mapValues(\.json)]
    if let timestamp { document["metadata"] = ["timestamp": timestamp] }
    return try JSONSerialization.data(withJSONObject: document)
}

private func candidateURLs(_ instances: [String: DirectoryFixtureEntry]) throws -> [String] {
    try SearXNGDirectory.candidates(from: directoryData(instances), now: fixtureNow).map(\.url.absoluteString)
}

// MARK: - Filtrage

@Suite("SearXNGDirectory — filtrage de l'annuaire")
struct SearXNGDirectoryFilteringTests {
    @Test("Une instance qui remplit tous les critères est retenue")
    func keepsAGoodInstance() throws {
        #expect(try candidateURLs(["https://bonne.example.org/": DirectoryFixtureEntry()]) == ["https://bonne.example.org"])
    }

    @Test("Chaque critère écarte son instance, les bonnes restent")
    func eachCriterionDropsItsInstance() throws {
        var tor = DirectoryFixtureEntry(); tor.networkType = "tor"
        var noVersion = DirectoryFixtureEntry(); noVersion.version = NSNull()
        var withError = DirectoryFixtureEntry(); withError.error = "Connection refused"
        var tracked = DirectoryFixtureEntry(); tracked.analytics = true
        var down = DirectoryFixtureEntry(); down.statusCode = 503
        var unreliable = DirectoryFixtureEntry(); unreliable.uptimeMonth = 60.0
        var failing = DirectoryFixtureEntry(); failing.successPercentage = 40.0
        var forbidden = DirectoryFixtureEntry(); forbidden.searchError = "HTTP status code 403"
        var limited = DirectoryFixtureEntry(); limited.searchError = "HTTP status code 429"

        let kept = try candidateURLs([
            "https://bonne.example.org/": DirectoryFixtureEntry(),
            "http://clair.example.org/": DirectoryFixtureEntry(),
            "https://tor.example.org/": tor,
            "https://sans-version.example.org/": noVersion,
            "https://erreur.example.org/": withError,
            "https://analytique.example.org/": tracked,
            "https://hors-service.example.org/": down,
            "https://instable.example.org/": unreliable,
            "https://echoue.example.org/": failing,
            "https://refuse.example.org/": forbidden,
            "https://limite.example.org/": limited,
            "https://localhost/": DirectoryFixtureEntry(),
            "https://192.168.1.10/": DirectoryFixtureEntry(),
            "https://box.local/": DirectoryFixtureEntry()
        ])

        #expect(kept == ["https://bonne.example.org"])
    }

    @Test("Une erreur de recherche sans rapport avec un blocage (« No result ») n'écarte pas l'instance")
    func nonBlockingSearchErrorIsTolerated() throws {
        var noResult = DirectoryFixtureEntry(); noResult.searchError = "No result"

        #expect(try candidateURLs(["https://a.example.org/": noResult]) == ["https://a.example.org"])
    }

    @Test("Les seuils sont inclusifs : 90 % de disponibilité et 80 % de réussite passent")
    func thresholdsAreInclusive() throws {
        var edge = DirectoryFixtureEntry(); edge.uptimeMonth = 90.0; edge.successPercentage = 80.0

        #expect(try candidateURLs(["https://limite.example.org/": edge]) == ["https://limite.example.org"])
    }

    @Test("Des critères plus stricts, injectés, écartent davantage")
    func customCriteriaApply() throws {
        let data = try directoryData(["https://a.example.org/": DirectoryFixtureEntry()])
        var strict = SearXNGDirectoryCriteria()
        strict.minimumMonthlyUptime = 99.9

        let kept = try SearXNGDirectory.candidates(from: data, now: fixtureNow, criteria: strict)

        #expect(kept.isEmpty)
    }

    @Test("Le même hôte écrit deux fois (casse, barre finale) ne donne qu'un candidat")
    func deduplicatesEquivalentAddresses() throws {
        let kept = try candidateURLs([
            "https://Dup.example.org/": DirectoryFixtureEntry(),
            "https://dup.example.org": DirectoryFixtureEntry()
        ])

        #expect(kept.count == 1)
    }
}

// MARK: - Classement et robustesse

@Suite("SearXNGDirectory — classement et robustesse du décodage")
struct SearXNGDirectoryRankingTests {
    @Test("Classement : meilleur taux de réussite, puis disponibilité, puis temps médian, puis adresse")
    func ranking() throws {
        var bestSuccess = DirectoryFixtureEntry(); bestSuccess.successPercentage = 100.0; bestSuccess.uptimeMonth = 91.0
        var bestUptime = DirectoryFixtureEntry(); bestUptime.successPercentage = 100.0; bestUptime.uptimeMonth = 99.0
        var fastest = DirectoryFixtureEntry(); fastest.successPercentage = 100.0; fastest.uptimeMonth = 99.0; fastest.median = 0.4
        var slower = DirectoryFixtureEntry(); slower.successPercentage = 100.0; slower.uptimeMonth = 99.0; slower.median = 1.2
        var weaker = DirectoryFixtureEntry(); weaker.successPercentage = 80.0; weaker.uptimeMonth = 100.0

        let kept = try candidateURLs([
            "https://faible.example.org/": weaker,
            "https://lent.example.org/": slower,
            "https://disponible.example.org/": bestSuccess,
            "https://rapide.example.org/": fastest,
            "https://sans-mesure.example.org/": bestUptime
        ])

        // Même réussite (100) : disponibilité 99 avant 91 ; à 99, médian connu avant absent,
        // le plus court d'abord ; puis la plus faible réussite (80) en dernier.
        #expect(kept == [
            "https://rapide.example.org",
            "https://lent.example.org",
            "https://sans-mesure.example.org",
            "https://disponible.example.org",
            "https://faible.example.org"
        ])
    }

    @Test("Un champ qui change de type fait écarter UNE instance, pas tout l'annuaire")
    func lenientDecoding() throws {
        var brokenUptime = DirectoryFixtureEntry(); brokenUptime.uptimeMonth = "beaucoup"
        var brokenStatus = DirectoryFixtureEntry(); brokenStatus.statusCode = ["inattendu": true]

        let kept = try candidateURLs([
            "https://bonne.example.org/": DirectoryFixtureEntry(),
            "https://uptime-texte.example.org/": brokenUptime,
            "https://statut-objet.example.org/": brokenStatus
        ])

        #expect(kept == ["https://bonne.example.org"])
    }

    @Test("Un JSON qui n'est pas l'annuaire lève invalidFormat")
    func garbageIsInvalidFormat() {
        #expect(throws: SearXNGDirectoryFailure.invalidFormat) {
            try SearXNGDirectory.candidates(from: Data("<html>Just a moment...</html>".utf8), now: fixtureNow)
        }
        #expect(throws: SearXNGDirectoryFailure.invalidFormat) {
            try SearXNGDirectory.candidates(from: Data(#"{"instances": {}}"#.utf8), now: fixtureNow)
        }
        #expect(throws: SearXNGDirectoryFailure.invalidFormat) {
            try SearXNGDirectory.candidates(from: Data(#"{"instances": [1, 2]}"#.utf8), now: fixtureNow)
        }
    }

    @Test("Des mesures vieilles de plus de 7 jours lèvent staleData")
    func staleDataIsRejected() throws {
        let data = try directoryData(
            ["https://a.example.org/": DirectoryFixtureEntry()],
            timestamp: fixtureNow.timeIntervalSince1970 - 8 * 86_400
        )

        #expect(throws: SearXNGDirectoryFailure.staleData) {
            try SearXNGDirectory.candidates(from: data, now: fixtureNow)
        }
    }

    @Test("Sans horodatage, les données sont acceptées plutôt que rejetées")
    func missingTimestampIsAccepted() throws {
        let data = try directoryData(["https://a.example.org/": DirectoryFixtureEntry()], timestamp: nil)

        let kept = try SearXNGDirectory.candidates(from: data, now: fixtureNow)

        #expect(kept.count == 1)
    }
}

// MARK: - Store persistant

@Suite("SearXNGDirectoryStore")
struct SearXNGDirectoryStoreTests {
    @Test("Le dernier rafraîchissement survit au redémarrage")
    func persistsAcrossInstances() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        SearXNGDirectoryStore(userDefaults: defaults).save(SearXNGDirectorySnapshot(
            instances: ["https://a.example.org"],
            updatedAt: date,
            nextAttemptAt: date.addingTimeInterval(86_400)
        ))

        let reloaded = SearXNGDirectoryStore(userDefaults: defaults).load()

        #expect(reloaded.instances == ["https://a.example.org"])
        #expect(reloaded.updatedAt == date)
        #expect(reloaded.nextAttemptAt == date.addingTimeInterval(86_400))
    }

    @Test("Un store en mémoire n'écrit rien dans les préférences")
    func inMemoryStoreWritesNothing() {
        let before = UserDefaults.standard.data(forKey: SearXNGDirectoryStore.defaultsKey)

        SearXNGDirectoryStore().save(SearXNGDirectorySnapshot(instances: ["https://a.example.org"]))

        #expect(UserDefaults.standard.data(forKey: SearXNGDirectoryStore.defaultsKey) == before)
    }

    @Test("Des données illisibles donnent un instantané vide au lieu de planter")
    func corruptedDataIsIgnored() {
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }
        defaults.set(Data("pas du json".utf8), forKey: SearXNGDirectoryStore.defaultsKey)

        #expect(SearXNGDirectoryStore(userDefaults: defaults).load() == SearXNGDirectorySnapshot())
    }

    @Test("refreshedInstances revalide les adresses : ni http, ni hôte local ou privé")
    func refreshedInstancesAreRevalidated() {
        let store = SearXNGDirectoryStore()
        store.save(SearXNGDirectorySnapshot(instances: [
            "https://bonne.example.org",
            "http://clair.example.org",
            "https://localhost",
            "https://192.168.0.5",
            "pas une adresse"
        ]))

        #expect(store.refreshedInstances == [URL(string: "https://bonne.example.org")!])
    }
}

// MARK: - Rafraîchissement

/// Requêteur HTTP factice : renvoie un corps et un statut fixes, ou lève une erreur, et compte
/// les appels.
private final class FakeDirectoryRequester: HTTPDataRequesting, Sendable {
    enum Behavior: Sendable {
        case respond(status: Int, body: Data)
        case fail(any Error)
    }

    private let behavior: Behavior
    private let requests = Mutex<[URLRequest]>([])

    init(_ behavior: Behavior) { self.behavior = behavior }

    var callCount: Int { requests.withLock { $0.count } }
    var lastRequest: URLRequest? { requests.withLock { $0.last } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request) }
        switch behavior {
        case .respond(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        case .fail(let error):
            throw error
        }
    }
}

@Suite("SearXNGDirectoryRefresher")
struct SearXNGDirectoryRefresherTests {
    private let a = URL(string: "https://a.example.org")!
    private let b = URL(string: "https://b.example.org")!
    private let c = URL(string: "https://c.example.org")!

    private func goodDirectory() throws -> Data {
        var best = DirectoryFixtureEntry(); best.successPercentage = 100.0
        var second = DirectoryFixtureEntry(); second.successPercentage = 90.0
        var third = DirectoryFixtureEntry(); third.successPercentage = 80.0
        return try directoryData([
            "https://a.example.org/": best,
            "https://b.example.org/": second,
            "https://c.example.org/": third
        ])
    }

    private func refresher(
        _ requester: FakeDirectoryRequester,
        prober: (any InstanceProbing)? = nil,
        store: SearXNGDirectoryStore,
        reliability: InstanceReliabilityStore? = nil,
        maxProbed: Int = 15,
        maxKept: Int = 12
    ) -> SearXNGDirectoryRefresher {
        SearXNGDirectoryRefresher(
            requester: requester,
            prober: prober,
            store: store,
            reliability: reliability,
            maxProbed: maxProbed,
            maxKept: maxKept
        )
    }

    @Test("Succès : seules les instances qui répondent en JSON sont gardées, meilleures d'abord")
    func keepsOnlyVerifiedInstances() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))
        let store = SearXNGDirectoryStore()
        let prober = ScriptedProber(healthy: [a, c])

        let outcome = await refresher(requester, prober: prober, store: store).refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .updated(count: 2))
        #expect(store.load().instances == ["https://a.example.org", "https://c.example.org"])
        #expect(store.load().updatedAt == fixtureNow)
        #expect(store.load().nextAttemptAt == fixtureNow.addingTimeInterval(86_400))
    }

    @Test("La requête vise searx.space en https, accepte du JSON et ne porte aucune donnée personnelle")
    func requestShape() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))

        _ = await refresher(requester, store: SearXNGDirectoryStore()).refreshIfNeeded(now: fixtureNow)

        let request = try #require(requester.lastRequest)
        #expect(request.url == URL(string: "https://searx.space/data/instances.json"))
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == SearXNGDirectoryRefresher.requestTimeout)
    }

    @Test("Au plus une tentative par jour : un second appel dans les 24 h ne touche pas le réseau")
    func atMostOnceADay() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))
        let store = SearXNGDirectoryStore()
        let instance = refresher(requester, store: store)

        _ = await instance.refreshIfNeeded(now: fixtureNow)
        let second = await instance.refreshIfNeeded(now: fixtureNow.addingTimeInterval(3_600))

        #expect(requester.callCount == 1)
        #expect(second == .skipped(until: fixtureNow.addingTimeInterval(86_400)))
    }

    @Test("Passé 24 h, le rafraîchissement reprend")
    func resumesAfterADay() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))
        let instance = refresher(requester, store: SearXNGDirectoryStore())

        _ = await instance.refreshIfNeeded(now: fixtureNow)
        _ = await instance.refreshIfNeeded(now: fixtureNow.addingTimeInterval(86_401))

        #expect(requester.callCount == 2)
    }

    @Test("force ignore le délai d'un jour")
    func forceBypassesTheDelay() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))
        let instance = refresher(requester, store: SearXNGDirectoryStore())

        _ = await instance.refreshIfNeeded(now: fixtureNow)
        _ = await instance.refreshIfNeeded(now: fixtureNow.addingTimeInterval(60), force: true)

        #expect(requester.callCount == 2)
    }

    @Test("Hors ligne : échec silencieux, nouvelle tentative dans 1 h, ancienne liste conservée")
    func offlineKeepsTheOldListAndRetriesSoon() async {
        let store = SearXNGDirectoryStore()
        store.save(SearXNGDirectorySnapshot(instances: ["https://ancienne.example.org"], updatedAt: fixtureNow.addingTimeInterval(-90_000)))
        let requester = FakeDirectoryRequester(.fail(URLError(.notConnectedToInternet)))

        let outcome = await refresher(requester, store: store).refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .failed(.network))
        #expect(store.load().instances == ["https://ancienne.example.org"])
        #expect(store.load().nextAttemptAt == fixtureNow.addingTimeInterval(3_600))
    }

    @Test("Statut HTTP d'erreur : échec, ancienne liste conservée, prochaine tentative dans 24 h")
    func httpErrorWaitsADay() async {
        let store = SearXNGDirectoryStore()
        store.save(SearXNGDirectorySnapshot(instances: ["https://ancienne.example.org"]))
        let requester = FakeDirectoryRequester(.respond(status: 503, body: Data()))

        let outcome = await refresher(requester, store: store).refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .failed(.httpStatus(503)))
        #expect(store.load().instances == ["https://ancienne.example.org"])
        #expect(store.load().nextAttemptAt == fixtureNow.addingTimeInterval(86_400))
    }

    @Test("Une réponse qui n'est pas l'annuaire est un échec de format")
    func garbageResponse() async {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: Data("<html></html>".utf8)))

        let outcome = await refresher(requester, store: SearXNGDirectoryStore()).refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .failed(.invalidFormat))
    }

    @Test("Une réponse démesurée (> 10 Mo) est refusée sans être décodée")
    func oversizedResponseIsRejected() async {
        let huge = Data(count: SearXNGDirectoryRefresher.maxPayloadBytes + 1)
        let requester = FakeDirectoryRequester(.respond(status: 200, body: huge))

        let outcome = await refresher(requester, store: SearXNGDirectoryStore()).refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .failed(.invalidFormat))
    }

    @Test("Aucune instance ne remplit les critères : noCandidates, ancienne liste conservée")
    func noCandidates() async throws {
        var weak = DirectoryFixtureEntry(); weak.uptimeMonth = 10.0
        let body = try directoryData(["https://a.example.org/": weak])
        let store = SearXNGDirectoryStore()
        store.save(SearXNGDirectorySnapshot(instances: ["https://ancienne.example.org"]))

        let outcome = await refresher(FakeDirectoryRequester(.respond(status: 200, body: body)), store: store)
            .refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .failed(.noCandidates))
        #expect(store.load().instances == ["https://ancienne.example.org"])
    }

    @Test("Aucun candidat ne répond en JSON : noneVerified, l'ancienne liste n'est PAS effacée")
    func noneVerifiedKeepsTheOldList() async throws {
        let store = SearXNGDirectoryStore()
        store.save(SearXNGDirectorySnapshot(instances: ["https://ancienne.example.org"]))
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))

        let outcome = await refresher(requester, prober: ScriptedProber(healthy: []), store: store)
            .refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .failed(.noneVerified))
        #expect(store.load().instances == ["https://ancienne.example.org"])
    }

    @Test("Seuls les maxProbed meilleurs candidats sont sondés, et au plus maxKept sont gardés")
    func probesAndKeepsAreBounded() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))
        let store = SearXNGDirectoryStore()
        let prober = ScriptedProber(healthy: [a, b, c])

        let outcome = await refresher(requester, prober: prober, store: store, maxProbed: 2, maxKept: 1)
            .refreshIfNeeded(now: fixtureNow)

        #expect(await Set(prober.probed) == [a, b])
        #expect(outcome == .updated(count: 1))
        #expect(store.load().instances == ["https://a.example.org"])
    }

    @Test("Sans sonde (prober nil), la liste filtrée est gardée telle quelle")
    func withoutProberTheFilteredListIsKept() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))
        let store = SearXNGDirectoryStore()

        let outcome = await refresher(requester, prober: nil, store: store).refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .updated(count: 3))
    }

    @Test("Les verdicts de la sonde alimentent le store de fiabilité")
    func probeVerdictsFeedTheReliabilityStore() async throws {
        let requester = FakeDirectoryRequester(.respond(status: 200, body: try goodDirectory()))
        let reliability = InstanceReliabilityStore()

        _ = await refresher(
            requester,
            prober: ScriptedProber(healthy: [a]),
            store: SearXNGDirectoryStore(),
            reliability: reliability
        ).refreshIfNeeded(now: fixtureNow)

        #expect(reliability.record(for: a)?.successes == 1)
        #expect(reliability.record(for: b)?.lastFailureReason == .notJSON)
    }

    @Test("Une Task annulée ne laisse rien d'enregistré")
    func cancellationRecordsNothing() async throws {
        let store = SearXNGDirectoryStore()
        let requester = FakeDirectoryRequester(.fail(URLError(.cancelled)))

        let outcome = await refresher(requester, store: store).refreshIfNeeded(now: fixtureNow)

        #expect(outcome == .cancelled)
        #expect(store.load() == SearXNGDirectorySnapshot())
    }
}
