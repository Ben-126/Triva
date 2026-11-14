//
//  CustomInstanceStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/10/2026.
//

import Testing
import Foundation
@testable import Triva

// Logique de l'écran Réglages (1.15) : la liste d'instances SearXNG
// personnalisable (`CustomInstanceStore.swift`) puis, en fin de fichier, la
// gestion des modèles MLX téléchargés (`MLXStorageView.swift`). Les suites
// MLX n'ont aucune dépendance commune avec le reste du fichier : elles
// peuvent être déplacées telles quelles dans un `MLXModelStorageTests.swift`.

// MARK: - Clients SearXNG factices

/// Client scripté : chaque instance renvoie la réponse ou l'erreur prévue
/// (réponse vide par défaut), et chaque appel est journalisé (instance,
/// requête, options). Un `actor`, comme `MockSearXNGClient` dans
/// `FailoverManagerTests.swift` (requis par `SearXNGSearching: Sendable`) —
/// dupliqué ici car `private` est scopé au fichier.
private actor ScriptedSearXNGClient: SearXNGSearching {
    private let outcomes: [URL: Result<SearXNGSearchResponse, any Error>]
    private(set) var calledInstances: [URL] = []
    private(set) var receivedQueries: [String] = []
    private(set) var receivedOptions: [SearXNGSearchOptions] = []

    init(outcomes: [URL: Result<SearXNGSearchResponse, any Error>] = [:]) {
        self.outcomes = outcomes
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        calledInstances.append(instance)
        receivedQueries.append(query)
        receivedOptions.append(options)
        return try (outcomes[instance] ?? .success(SearXNGSearchResponse(results: [], suggestions: []))).get()
    }
}

/// Client qui reste suspendu jusqu'à `release()` : permet de vérifier ce qui
/// se passe PENDANT une sonde (retrait de l'instance, second test lancé).
private actor GatedSearXNGClient: SearXNGSearching {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    var hasPendingCall: Bool {
        continuation != nil
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return SearXNGSearchResponse(results: [], suggestions: [])
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Validation d'adresse (logique pure, suite non isolée)

/// Non isolée exprès : `SearXNGInstanceAddress` et les types qu'elle manipule
/// sont `nonisolated`, cette suite le vérifie à la compilation.
@Suite("SearXNGInstanceAddress")
struct SearXNGInstanceAddressTests {
    @Test("Accepte une adresse https, retire espaces et barre finale")
    func acceptsHTTPSAndTrimsTrailingSlash() throws {
        let candidate = try SearXNGInstanceAddress.validate("  https://searx.example.org/  ")

        #expect(candidate.url == URL(string: "https://searx.example.org"))
        #expect(!candidate.isLocalOrPrivate)
    }

    @Test("Ajoute https:// quand aucun schéma n'est écrit")
    func addsHTTPSWhenSchemeMissing() throws {
        let candidate = try SearXNGInstanceAddress.validate("searx.example.org")

        #expect(candidate.url == URL(string: "https://searx.example.org"))
    }

    @Test("Garde un port non standard et un sous-chemin, retire le port 443 implicite")
    func keepsPortAndPathDropsDefaultPort() throws {
        #expect(try SearXNGInstanceAddress.validate("https://example.org:8443/searx/").url
            == URL(string: "https://example.org:8443/searx"))
        #expect(try SearXNGInstanceAddress.validate("https://example.org:443").url
            == URL(string: "https://example.org"))
    }

    @Test(
        "Refuse tout schéma autre que https",
        arguments: ["http://searx.example.org", "HTTP://searx.example.org", "ftp://searx.example.org"]
    )
    func rejectsNonHTTPSSchemes(input: String) {
        #expect(throws: CustomInstanceError.httpsRequired) {
            try SearXNGInstanceAddress.validate(input)
        }
    }

    @Test("Refuse une saisie vide ou blanche")
    func rejectsEmptyInput() {
        #expect(throws: CustomInstanceError.emptyInput) {
            try SearXNGInstanceAddress.validate("   \n")
        }
    }

    @Test(
        "Refuse une adresse sans hôte, avec une espace ou au schéma mal écrit",
        arguments: ["https://", "https://exa mple.org", "https:/searx.example.org"]
    )
    func rejectsMalformedAddresses(input: String) {
        #expect(throws: CustomInstanceError.invalidAddress) {
            try SearXNGInstanceAddress.validate(input)
        }
    }

    @Test("Refuse un identifiant dans l'adresse : il serait stocké en clair")
    func rejectsCredentials() {
        #expect(throws: CustomInstanceError.credentialsNotAllowed) {
            try SearXNGInstanceAddress.validate("https://ben:secret@searx.example.org")
        }
    }

    @Test(
        "Refuse paramètres et ancre",
        arguments: ["https://searx.example.org/search?q=test", "https://searx.example.org/#haut"]
    )
    func rejectsQueryAndFragment(input: String) {
        #expect(throws: CustomInstanceError.parametersNotAllowed) {
            try SearXNGInstanceAddress.validate(input)
        }
    }

    @Test("Une IPv4 privée saisie sans schéma est acceptée et signalée comme locale")
    func validatedPrivateIPv4IsFlagged() throws {
        let candidate = try SearXNGInstanceAddress.validate("192.168.1.10:8443")

        #expect(candidate.isLocalOrPrivate)
        #expect(candidate.url == URL(string: "https://192.168.1.10:8443"))
    }

    /// `URLComponents.host` garde les crochets d'une IPv6 : l'adresse affichée
    /// reste lisible avec son port (« [fd00::1]:8443 », pas « fd00::1:8443 »).
    @Test("IPv6 entre crochets : acceptée, signalée comme locale, affichée sans ambiguïté")
    func bracketedIPv6IsHandled() throws {
        let candidate = try SearXNGInstanceAddress.validate("https://[fd00::1]:8443/")

        #expect(candidate.url == URL(string: "https://[fd00::1]:8443"))
        #expect(candidate.isLocalOrPrivate)
        #expect(SearXNGInstanceAddress.displayAddress(for: candidate.url) == "[fd00::1]:8443")
    }

    @Test(
        "Hôtes locaux ou privés signalés",
        arguments: [
            "localhost", "nas", "box.lan", "nas.local", "maison.home.arpa", "service.internal",
            "10.0.0.5", "127.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.10", "169.254.10.1",
            "100.64.0.1", "::1", "[::1]", "fd12:3456::1", "fe80::1", "::ffff:192.168.0.1",
        ]
    )
    func flagsLocalOrPrivateHosts(host: String) {
        #expect(SearXNGInstanceAddress.isLocalOrPrivate(host: host))
    }

    @Test(
        "Hôtes publics non signalés, y compris aux bornes des plages privées",
        arguments: [
            "searx.be", "search.example.org", "local.example.org", "fd.example.org",
            "172.15.255.255", "172.32.0.1", "192.169.0.1", "8.8.8.8",
            "100.63.255.255", "100.128.0.1", "2001:db8::1",
        ]
    )
    func doesNotFlagPublicHosts(host: String) {
        #expect(!SearXNGInstanceAddress.isLocalOrPrivate(host: host))
    }

    @Test("La clé de comparaison ignore la casse de l'hôte, la barre finale et le port 443")
    func comparisonKeyNormalizesEquivalentAddresses() throws {
        let reference = try #require(URL(string: "https://searx.example.org"))
        let otherCase = try #require(URL(string: "https://Searx.Example.org/"))
        let explicitPort = try #require(URL(string: "https://searx.example.org:443"))
        let otherPath = try #require(URL(string: "https://searx.example.org/autre"))
        let referenceKey = SearXNGInstanceAddress.comparisonKey(for: reference)

        #expect(referenceKey != nil)
        #expect(SearXNGInstanceAddress.comparisonKey(for: otherCase) == referenceKey)
        #expect(SearXNGInstanceAddress.comparisonKey(for: explicitPort) == referenceKey)
        #expect(SearXNGInstanceAddress.comparisonKey(for: otherPath) != referenceKey)
    }

    @Test("Adresse affichée sans schéma, avec port et sous-chemin")
    func displayAddressOmitsScheme() throws {
        let plain = try #require(URL(string: "https://searx.be"))
        let withPortAndPath = try #require(URL(string: "https://example.org:8443/searx"))

        #expect(SearXNGInstanceAddress.displayAddress(for: plain) == "searx.be")
        #expect(SearXNGInstanceAddress.displayAddress(for: withPortAndPath) == "example.org:8443/searx")
    }

    @Test("Les résumés de test sont des textes fixes, seul le code HTTP est repris")
    func connectivitySummariesAreFixedTexts() {
        #expect(SearXNGInstanceConnectivity.reachable(resultCount: 3, latency: .milliseconds(420)).summary
            == "Répond · 420 ms")
        #expect(SearXNGInstanceConnectivity.reachable(resultCount: 0, latency: .milliseconds(80)).summary
            == "Répond, sans résultat · 80 ms")
        #expect(SearXNGInstanceConnectivity.unreachable(.httpStatus(429)).summary == "Trop de requêtes (429)")
        #expect(SearXNGInstanceConnectivity.unreachable(.httpStatus(502)).summary == "Erreur HTTP 502")
        #expect(SearXNGInstanceConnectivity.testing.summary == nil)
    }
}

// MARK: - Store

@MainActor
@Suite("CustomInstanceStore")
struct CustomInstanceStoreTests {
    private static let instanceA = URL(string: "https://a.example")!
    private static let instanceB = URL(string: "https://b.example")!
    private static let instanceC = URL(string: "https://c.example")!
    private static let defaults = [instanceA, instanceB, instanceC]
    private static let mine = URL(string: "https://mine.example")!

    /// Suite `UserDefaults` propre à chaque test (Swift Testing crée une
    /// instance de la suite par test) — jamais `.standard`, pour ne pas
    /// toucher la vraie liste personnalisée de la machine qui exécute les
    /// tests (même principe que `CustomProviderStoreTests.uniqueDefaults()`).
    /// Tous les stores d'un même test la partagent : c'est ce qui permet de
    /// vérifier la persistance d'un store à l'autre.
    ///
    /// Pas de suppression en fin de test : `removePersistentDomain` laisse un
    /// .plist vide derrière lui (et en crée même un pour une suite jamais
    /// écrite), ce qui ne nettoie rien — vérifié sur macOS le 2026-10-04.
    private let userDefaults: UserDefaults

    init() throws {
        userDefaults = try #require(TestDefaults.suite(named: "test.customInstanceStore.\(UUID().uuidString)"))
    }

    /// Liste par défaut TOUJOURS injectée : jamais celle de `Bundle.main`.
    private func makeStore(defaults: [URL]? = nil, client: (any SearXNGSearching)? = nil) -> CustomInstanceStore {
        CustomInstanceStore(
            defaultInstances: defaults ?? Self.defaults,
            userDefaults: userDefaults,
            client: client ?? ScriptedSearXNGClient()
        )
    }

    private static func response(resultCount: Int) -> SearXNGSearchResponse {
        let results = (0..<resultCount).map { index in
            SearXNGSearchResult(
                title: "Résultat \(index)",
                url: "https://resultat\(index).example",
                content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
            )
        }
        return SearXNGSearchResponse(results: results, suggestions: [])
    }

    private func isReachable(_ connectivity: SearXNGInstanceConnectivity?) -> Bool {
        if case .reachable? = connectivity {
            return true
        }
        return false
    }

    /// Poll coopératif avec `Task.sleep`, JAMAIS `Task.yield()` : sous
    /// l'isolation main actor, `yield()` ne garantit pas que l'autre tâche
    /// progresse (piège documenté, voir `ChatViewModelTests`).
    private func waitUntil(_ description: String, maxAttempts: Int = 500, _ condition: () async -> Bool) async {
        for _ in 0..<maxAttempts {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Délai dépassé en attendant : \(description)")
    }

    // MARK: Liste effective

    @Test("Sans personnalisation, la liste effective est exactement la liste par défaut")
    func effectiveListEqualsDefaultsWithoutOverrides() {
        let store = makeStore()

        #expect(store.effectiveInstances == Self.defaults)
        #expect(store.customInstances.isEmpty)
        #expect(store.defaultSectionInstances == Self.defaults)
        #expect(store.hiddenDefaultCount == 0)
        #expect(!store.isCustomized)
    }

    @Test("Une instance ajoutée passe en tête, avant la liste par défaut")
    func addedInstanceIsTriedFirst() throws {
        let store = makeStore()

        let added = try store.add(store.candidate(from: "mine.example"))

        #expect(added == Self.mine)
        #expect(store.effectiveInstances == [Self.mine] + Self.defaults)
        #expect(store.customInstances == [Self.mine])
        #expect(store.defaultSectionInstances == Self.defaults)
        #expect(store.isCustom(Self.mine))
        #expect(store.isCustomized)
    }

    @Test("Les instances ajoutées gardent leur ordre d'ajout")
    func addedInstancesKeepInsertionOrder() throws {
        let store = makeStore()

        try store.add(store.candidate(from: "https://premiere.example"))
        try store.add(store.candidate(from: "https://seconde.example"))

        #expect(store.customInstances.map(\.absoluteString) == ["https://premiere.example", "https://seconde.example"])
    }

    @Test("Ajouts et suppressions persistent d'une instance du store à l'autre")
    func overridesPersistAcrossStores() throws {
        let store = makeStore()
        try store.add(store.candidate(from: "mine.example"))
        try store.remove(Self.instanceB)

        let reloaded = makeStore()

        #expect(reloaded.effectiveInstances == [Self.mine, Self.instanceA, Self.instanceC])
        #expect(reloaded.hiddenDefaultCount == 1)
    }

    @Test("Refuse un doublon, même écrit autrement")
    func rejectsDuplicatesWrittenDifferently() throws {
        let store = makeStore()

        #expect(throws: CustomInstanceError.alreadyInList) {
            try store.candidate(from: "https://A.example/")
        }
        try store.add(store.candidate(from: "mine.example"))
        #expect(throws: CustomInstanceError.alreadyInList) {
            try store.candidate(from: "https://mine.example:443")
        }
    }

    @Test("add revalide une adresse construite à la main")
    func addRevalidatesHandmadeCandidates() throws {
        let store = makeStore()
        let insecure = SearXNGInstanceCandidate(
            url: try #require(URL(string: "http://non-securisee.example")),
            isLocalOrPrivate: false
        )

        #expect(throws: CustomInstanceError.httpsRequired) {
            try store.add(insecure)
        }
        #expect(store.effectiveInstances == Self.defaults)
    }

    @Test("Liste par défaut illisible : sa propre instance suffit à rétablir la recherche")
    func customInstanceWorksWhenDefaultListFailed() throws {
        let store = CustomInstanceStore(
            defaultInstances: [],
            defaultListLoadFailed: true,
            userDefaults: userDefaults,
            client: ScriptedSearXNGClient()
        )
        #expect(store.effectiveInstances.isEmpty)

        let added = try store.add(store.candidate(from: "mine.example"))

        #expect(store.effectiveInstances == [added])
        #expect(!store.canRemoveInstance)
        #expect(store.defaultListLoadFailed)
    }

    // MARK: Suppression et remise à zéro

    @Test("Retirer une instance par défaut la masque sans toucher aux autres")
    func removingDefaultHidesIt() throws {
        let store = makeStore()

        try store.remove(Self.instanceB)

        #expect(store.effectiveInstances == [Self.instanceA, Self.instanceC])
        #expect(store.defaultSectionInstances == [Self.instanceA, Self.instanceC])
        #expect(store.hiddenDefaultCount == 1)
        #expect(store.isCustomized)
    }

    @Test("Retirer une instance ajoutée la supprime et annule la personnalisation")
    func removingAddedInstanceDeletesIt() throws {
        let store = makeStore()
        try store.add(store.candidate(from: "mine.example"))

        try store.remove(Self.mine)

        #expect(store.effectiveInstances == Self.defaults)
        #expect(!store.isCustomized)
    }

    @Test("Impossible de retirer la dernière instance : la recherche n'aurait plus rien à essayer")
    func cannotRemoveLastInstance() {
        let store = makeStore(defaults: [Self.instanceA])

        #expect(!store.canRemoveInstance)
        #expect(throws: CustomInstanceError.cannotRemoveLastInstance) {
            try store.remove(Self.instanceA)
        }
        #expect(store.effectiveInstances == [Self.instanceA])
    }

    @Test("Retirer une instance absente lève notInList")
    func removingUnknownInstanceThrows() throws {
        let store = makeStore()
        let unknown = try #require(URL(string: "https://inconnue.example"))

        #expect(throws: CustomInstanceError.notInList) {
            try store.remove(unknown)
        }
    }

    @Test("La remise à zéro rétablit la liste par défaut et efface la persistance")
    func resetRestoresDefaultsAndClearsStorage() throws {
        let store = makeStore()
        try store.add(store.candidate(from: "mine.example"))
        try store.remove(Self.instanceA)

        store.resetToDefaults()

        #expect(store.effectiveInstances == Self.defaults)
        #expect(!store.isCustomized)
        #expect(userDefaults.data(forKey: SearXNGInstanceOverrides.storageKey) == nil)
        #expect(makeStore().effectiveInstances == Self.defaults)
    }

    // MARK: Surcouche et mises à jour du bundle

    @Test("Une instance livrée par défaut après personnalisation apparaît quand même")
    func newBundledDefaultsStillAppear() throws {
        let before = makeStore(defaults: [Self.instanceA, Self.instanceB])
        try before.remove(Self.instanceB)
        let shipped = try #require(URL(string: "https://nouvelle.example"))

        let after = makeStore(defaults: [Self.instanceA, Self.instanceB, shipped])

        #expect(after.effectiveInstances == [Self.instanceA, shipped])
    }

    @Test("Une instance par défaut masquée peut être rajoutée, et passe alors en tête")
    func hiddenDefaultCanBeAddedBack() throws {
        let store = makeStore()
        try store.remove(Self.instanceB)

        try store.add(store.candidate(from: "https://b.example"))

        #expect(store.effectiveInstances == [Self.instanceB, Self.instanceA, Self.instanceC])
    }

    @Test("Retirer un ajout devenu identique à une instance par défaut ne la fait pas réapparaître")
    func removingAddedDuplicateOfDefaultKeepsItGone() throws {
        let early = makeStore(defaults: [Self.instanceA])
        try early.add(early.candidate(from: "https://b.example"))
        let updated = makeStore(defaults: [Self.instanceA, Self.instanceB])
        #expect(updated.effectiveInstances == [Self.instanceB, Self.instanceA])

        try updated.remove(Self.instanceB)

        #expect(updated.effectiveInstances == [Self.instanceA])
    }

    @Test("Donnée persistée illisible : repli sur la liste par défaut")
    func corruptedStorageFallsBackToDefaults() {
        userDefaults.set(Data("pas du JSON".utf8), forKey: SearXNGInstanceOverrides.storageKey)

        #expect(makeStore().effectiveInstances == Self.defaults)
    }

    @Test("Le chargeur statique applique la même surcouche que le store")
    func staticResolverMatchesStore() throws {
        let store = makeStore()
        try store.add(store.candidate(from: "mine.example"))
        try store.remove(Self.instanceC)

        let resolved = CustomInstanceStore.resolvedInstances(defaults: Self.defaults, userDefaults: userDefaults)

        #expect(resolved == store.effectiveInstances)
    }

    // MARK: Connectivité

    @Test("Instance qui répond en JSON : joignable, avec son nombre de résultats")
    func reachableInstanceRecordsResultCount() async {
        let client = ScriptedSearXNGClient(outcomes: [Self.instanceA: .success(Self.response(resultCount: 2))])
        let store = makeStore(client: client)

        await store.testConnectivity(of: Self.instanceA)

        guard case .reachable(let resultCount, _)? = store.connectivity(for: Self.instanceA) else {
            Issue.record("Attendu : instance joignable")
            return
        }
        #expect(resultCount == 2)
        #expect(await client.calledInstances == [Self.instanceA])
    }

    /// Une instance publique est un tiers : la sonde ne doit rien lui
    /// apprendre de l'utilisateur (ni recherche réelle, ni langue, ni filtre).
    @Test("La sonde n'envoie qu'une requête neutre, sans aucune option")
    func probeSendsOnlyANeutralQuery() async {
        let client = ScriptedSearXNGClient()
        let store = makeStore(client: client)

        await store.testConnectivity(of: Self.instanceA)

        #expect(await client.receivedQueries == [SearXNGInstanceProbe.query])
        #expect(await client.receivedOptions == [SearXNGSearchOptions()])
    }

    @Test("Chaque échec du client devient un motif fixe")
    func clientErrorsMapToFixedFailures() async {
        let cases: [(any Error, SearXNGInstanceFailure)] = [
            (SearXNGClientError.timeout, .timeout),
            (SearXNGClientError.requestFailed(statusCode: 429), .httpStatus(429)),
            (SearXNGClientError.decodingFailed, .notJSON),
            (SearXNGClientError.transportError, .network),
            (SearXNGClientError.invalidURL, .invalidAddress),
            (URLError(.notConnectedToInternet), .network),
        ]

        for (error, expected) in cases {
            let store = makeStore(client: ScriptedSearXNGClient(outcomes: [Self.instanceA: .failure(error)]))

            await store.testConnectivity(of: Self.instanceA)

            #expect(store.connectivity(for: Self.instanceA) == .unreachable(expected), "\(error)")
        }
    }

    @Test("Tester une adresse absente de la liste ne lance aucune requête")
    func testingUnknownInstanceSendsNothing() async throws {
        let client = ScriptedSearXNGClient()
        let store = makeStore(client: client)
        let unknown = try #require(URL(string: "https://inconnue.example"))

        await store.testConnectivity(of: unknown)

        #expect(await client.calledInstances.isEmpty)
        #expect(store.connectivity(for: unknown) == nil)
    }

    @Test("Tout tester interroge chaque instance une fois et range chaque résultat")
    func testAllProbesEveryInstanceOnce() async {
        let client = ScriptedSearXNGClient(outcomes: [
            Self.instanceA: .success(Self.response(resultCount: 3)),
            Self.instanceB: .failure(SearXNGClientError.timeout),
            Self.instanceC: .success(Self.response(resultCount: 0)),
        ])
        let store = makeStore(client: client)

        await store.testAllConnectivity()

        let called = await client.calledInstances
        #expect(called.count == Self.defaults.count)
        #expect(Set(called) == Set(Self.defaults))
        #expect(store.connectivity(for: Self.instanceB) == .unreachable(.timeout))
        guard case .reachable(let countA, _)? = store.connectivity(for: Self.instanceA),
              case .reachable(let countC, _)? = store.connectivity(for: Self.instanceC) else {
            Issue.record("Attendu : A et C joignables")
            return
        }
        #expect(countA == 3)
        #expect(countC == 0)
    }

    @Test("Un résultat arrivé après le retrait de l'instance n'est pas affiché")
    func resultForRemovedInstanceIsDiscarded() async throws {
        let client = GatedSearXNGClient()
        let store = makeStore(client: client)
        let probe = Task { await store.testConnectivity(of: Self.instanceB) }
        await waitUntil("sonde en cours") { await client.hasPendingCall }
        #expect(store.connectivity(for: Self.instanceB) == .testing)

        try store.remove(Self.instanceB)
        await client.release()
        await probe.value

        #expect(store.connectivity(for: Self.instanceB) == nil)
    }

    @Test("Un second test de la même instance pendant le premier est ignoré")
    func concurrentTestOfSameInstanceIsIgnored() async {
        let client = GatedSearXNGClient()
        let store = makeStore(client: client)
        let first = Task { await store.testConnectivity(of: Self.instanceA) }
        await waitUntil("première sonde en cours") { await client.hasPendingCall }

        await store.testConnectivity(of: Self.instanceA)

        #expect(await client.callCount == 1)
        await client.release()
        await first.value
        #expect(isReachable(store.connectivity(for: Self.instanceA)))
    }

    @Test("Les résultats de test d'une instance retirée sont purgés")
    func removingInstancePurgesItsConnectivity() async throws {
        let client = ScriptedSearXNGClient(outcomes: [Self.instanceA: .failure(SearXNGClientError.timeout)])
        let store = makeStore(client: client)
        await store.testConnectivity(of: Self.instanceA)
        #expect(store.connectivity(for: Self.instanceA) == .unreachable(.timeout))

        try store.remove(Self.instanceA)

        #expect(store.connectivity(for: Self.instanceA) == nil)
    }
}

// MARK: - Modèles MLX téléchargés (MLXStorageView.swift)

/// Chaque test travaille dans son propre bac à sable temporaire, supprimé à
/// la fin du test — jamais dans la vraie racine `Application Support/MLXModels` :
/// ces tests SUPPRIMENT des dossiers. La racine passée au code est un
/// sous-dossier du bac à sable (`…/models`) : un identifiant « .. » qui
/// passerait la garde par régression n'atteindrait que le bac à sable, jamais
/// le dossier temporaire du système. Une classe plutôt qu'une struct pour son
/// `deinit`, qui supprime le bac à sable (Swift Testing crée une instance par
/// test, y compris pour chaque argument d'un test paramétré).
@Suite("MLXModelStorage")
final class MLXModelStorageTests {
    private let sandbox: URL
    private let root: URL

    init() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXModelStorageTests-\(UUID().uuidString)", isDirectory: true)
        let root = sandbox.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.sandbox = sandbox
        self.root = root
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Octets NON nuls : un fichier de zéros pourrait être stocké de façon
    /// creuse, et sa taille allouée ne refléterait plus son contenu.
    @discardableResult
    private func writeFile(_ relativePath: String, byteCount: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<byteCount).map { UInt8($0 % 251 + 1) }).write(to: url)
        return url
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path(percentEncoded: false))
    }

    @Test("Racine absente : aucun modèle téléchargé, sans erreur")
    func missingRootMeansNoModels() throws {
        let missing = root.appendingPathComponent("absente", isDirectory: true)

        #expect(try MLXModelStorage.scanSynchronously(rootDirectory: missing).isEmpty)
    }

    @Test("Un modèle par sous-dossier, taille récursive, du plus lourd au plus léger")
    func scanListsModelsBySizeIncludingNestedFiles() throws {
        try writeFile("petit/config.json", byteCount: 10_000)
        try writeFile("gros/poids.safetensors", byteCount: 50_000)
        try writeFile("gros/sous/dossier/poids-2.safetensors", byteCount: 300_000)

        let models = try MLXModelStorage.scanSynchronously(rootDirectory: root)

        try #require(models.count == 2)
        #expect(models.map(\.id) == ["gros", "petit"])
        #expect(models[0].allocatedBytes >= 350_000)
        #expect(models[1].allocatedBytes >= 10_000)
        #expect(models[1].allocatedBytes < 350_000)
    }

    @Test("À taille égale, l'ordre suit l'identifiant : stable d'un affichage à l'autre")
    func equalSizesAreOrderedByID() throws {
        try writeFile("modele-b/poids", byteCount: 20_000)
        try writeFile("modele-a/poids", byteCount: 20_000)

        #expect(try MLXModelStorage.scanSynchronously(rootDirectory: root).map(\.id) == ["modele-a", "modele-b"])
    }

    @Test("Fichiers isolés, dossiers cachés et liens symboliques de la racine ne sont pas des modèles")
    func scanIgnoresNonModelEntries() throws {
        try writeFile("modele/poids", byteCount: 4_096)
        try writeFile("note.txt", byteCount: 100)
        try writeFile(".cache/temp", byteCount: 100)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("raccourci"),
            withDestinationURL: root.appendingPathComponent("modele", isDirectory: true)
        )

        #expect(try MLXModelStorage.scanSynchronously(rootDirectory: root).map(\.id) == ["modele"])
    }

    /// Le cache Hugging Face relie `snapshots/` à `blobs/` par des liens
    /// symboliques : les suivre compterait chaque poids deux fois.
    @Test("Les liens symboliques internes ne sont ni suivis ni comptés deux fois")
    func symbolicLinksAreNotDoubleCounted() throws {
        let blob = try writeFile("avec-liens/blobs/poids", byteCount: 200_000)
        let snapshot = root.appendingPathComponent("avec-liens/snapshots/main", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("poids"), withDestinationURL: blob)
        try writeFile("sans-liens/poids", byteCount: 200_000)

        let models = try MLXModelStorage.scanSynchronously(rootDirectory: root)
        let sizes = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.allocatedBytes) })

        #expect(sizes["avec-liens"] == sizes["sans-liens"])
        #expect((sizes["sans-liens"] ?? 0) >= 200_000)
    }

    @Test("Supprimer un modèle efface exactement son dossier, et rien d'autre")
    func deleteRemovesOnlyThatModel() throws {
        try writeFile("a/poids", byteCount: 4_096)
        try writeFile("b/poids", byteCount: 4_096)

        try MLXModelStorage.deleteSynchronously(modelID: "a", rootDirectory: root)

        #expect(!exists("a"))
        #expect(exists("b/poids"))
        #expect(try MLXModelStorage.scanSynchronously(rootDirectory: root).map(\.id) == ["b"])
    }

    @Test(
        "Un identifiant qui sortirait du dossier des modèles est refusé, rien n'est supprimé",
        arguments: ["", ".", "..", "../models", "a/poids"]
    )
    func unsafeIDsAreRejected(modelID: String) throws {
        try writeFile("a/poids", byteCount: 4_096)

        #expect(!MLXModelStorage.isSafeModelID(modelID))
        #expect(throws: MLXModelStorageError.invalidModelID) {
            try MLXModelStorage.deleteSynchronously(modelID: modelID, rootDirectory: root)
        }
        #expect(exists("a/poids"))
    }

    @Test("Supprimer un modèle déjà absent échoue proprement")
    func deletingMissingModelFails() {
        #expect(throws: MLXModelStorageError.deletionFailed) {
            try MLXModelStorage.deleteSynchronously(modelID: "absent", rootDirectory: root)
        }
    }

    @Test("Les points d'entrée asynchrones lisent et suppriment comme les synchrones")
    func asyncEntryPointsMatchSynchronousOnes() async throws {
        try writeFile("modele/poids", byteCount: 4_096)

        #expect(try await MLXModelStorage.scan(rootDirectory: root).map(\.id) == ["modele"])
        try await MLXModelStorage.delete(modelID: "modele", rootDirectory: root)
        #expect(try await MLXModelStorage.scan(rootDirectory: root).isEmpty)
    }

    /// Garde-fou : l'écran doit lire et supprimer exactement là où
    /// `MLXProvider` télécharge, sinon il montrerait un dossier vide pendant
    /// que les vrais modèles occupent le disque.
    @Test("La racine est le dossier parent de celui où MLXProvider range chaque modèle")
    func rootMatchesMLXProviderStorage() {
        let modelID = "qwen3-4b-4bit"

        #expect(MLXModelStorage.rootDirectory.lastPathComponent == "MLXModels")
        #expect(
            MLXModelStorage.rootDirectory.appendingPathComponent(modelID, isDirectory: true).standardizedFileURL
                == MLXProvider.modelStorageDirectory(for: modelID).standardizedFileURL
        )
    }
}

/// `MLXStorageView` est une vue (isolée au main actor) : suite `@MainActor`.
@MainActor
@Suite("MLXStorageView — modèle en service")
struct MLXStorageInUseRuleTests {
    @Test("Le modèle sélectionné est protégé tant que MLX est, ou peut être, le moteur actif")
    func selectedModelIsProtectedWhileMLXMayBeActive() {
        #expect(MLXStorageView.isInUse(modelID: "a", selectedModelID: "a", activeEngine: .mlxLocal))
        #expect(MLXStorageView.isInUse(modelID: "a", selectedModelID: "a", activeEngine: nil))
    }

    @Test("Avec un autre moteur actif, même le modèle sélectionné est supprimable")
    func selectedModelIsDeletableUnderAnotherEngine() {
        #expect(!MLXStorageView.isInUse(modelID: "a", selectedModelID: "a", activeEngine: .appleIntelligence))
        #expect(!MLXStorageView.isInUse(modelID: "a", selectedModelID: "a", activeEngine: .cloudBYOK))
    }

    @Test("Un modèle non sélectionné n'est jamais en service")
    func unselectedModelIsNeverInUse() {
        #expect(!MLXStorageView.isInUse(modelID: "b", selectedModelID: "a", activeEngine: .mlxLocal))
        #expect(!MLXStorageView.isInUse(modelID: "a", selectedModelID: nil, activeEngine: .mlxLocal))
        #expect(!MLXStorageView.isInUse(modelID: "a", selectedModelID: nil, activeEngine: nil))
    }
}
