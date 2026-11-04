//
//  WebSearchChainTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 03/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Réseau coupé qui note l'hôte de chaque requête : prouve vers quel Wikipédia part une question.
/// `private actor` : voir `ScriptedWebSearchProvider` pour le piège des acteurs internes.
private actor HostRecordingRequester: HTTPDataRequesting {
    private(set) var hosts: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        hosts.append(request.url?.host() ?? "")
        throw URLError(.notConnectedToInternet)
    }
}

/// Chaîne de repli de la recherche web (RI1b) : ordre, repli sur erreur ET sur zéro résultat,
/// échec total typé, annulation, étape SearXNG à repli web, langue. Aucun réseau : sources scénarisées.
@MainActor
@Suite("WebSearchChain — ordre et repli")
struct WebSearchChainTests {
    private typealias Provider = ScriptedWebSearchProvider

    private static let found = [ChainFixtures.result("Trouvé", url: "https://trouve.example/page")]

    private func chain(
        keyed: [Provider] = [],
        searxng: Provider? = nil,
        cloud: Provider? = nil,
        open: [Provider] = [],
        unreadable: [WebSearchSourceKind] = []
    ) -> WebSearchChain {
        WebSearchChain(
            keyedProviders: keyed,
            searxng: searxng,
            cloudProvider: cloud,
            openSourceProviders: { _ in open },
            unreadableKeySources: unreadable
        )
    }

    // MARK: - Ordre

    @Test("Ordre d'essai : clés (Brave puis Tavily), SearXNG, cloud, puis sources ouvertes")
    func orderIsKeysThenSearXNGThenCloudThenOpenSources() {
        let chain = WebSearchChain(
            keyedProviders: [Provider(kind: .braveSearch, outcome: .results([])), Provider(kind: .tavily, outcome: .results([]))],
            searxng: Provider(kind: .searxng, outcome: .results([])),
            cloudProvider: Provider(kind: .cloudProviderWebSearch, outcome: .results([])),
            openSources: ChainFixtures.offlineOpenSources()
        )
        #expect(chain.kinds(for: .general) == [.braveSearch, .tavily, .searxng, .cloudProviderWebSearch, .wikipedia, .marginalia])
        #expect(chain.kinds(for: .academic) == [.braveSearch, .tavily, .searxng, .cloudProviderWebSearch, .openAlex, .arXiv, .wikipedia])
        #expect(chain.kinds(for: .discussion) == [.braveSearch, .tavily, .searxng, .cloudProviderWebSearch, .marginalia, .wikipedia])
    }

    @Test("La première réponse non vide gagne : les sources suivantes ne sont jamais interrogées")
    func firstNonEmptyAnswerWins() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results(Self.found))
        let searxng = Provider(kind: .searxng, outcome: .results(Self.found))
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(Self.found))

        let result = try await chain(keyed: [brave], searxng: searxng, cloud: cloud).search(query: "q", options: WebSearchOptions())

        #expect(result.source == .braveSearch)
        #expect(result.response.results == Self.found)
        #expect(await searxng.callCount == 0)
        #expect(await cloud.callCount == 0)
    }

    // MARK: - Repli

    @Test("Repli sur ERREUR puis sur ZÉRO résultat : la première source qui trouve fournit la réponse")
    func fallsBackOnErrorAndOnEmptyResults() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .failure(WebSearchError.rateLimited))
        let tavily = Provider(kind: .tavily, outcome: .results([]))
        let searxng = Provider(kind: .searxng, outcome: .results(Self.found))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.found))

        let result = try await chain(keyed: [brave, tavily], searxng: searxng, open: [wikipedia])
            .search(query: "q", options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(await brave.callCount == 1)
        #expect(await tavily.callCount == 1)
        #expect(await searxng.callCount == 1)
        #expect(await wikipedia.callCount == 0)
    }

    @Test("Chaque source reçoit la même question et les mêmes options")
    func everySourceReceivesTheSameQueryAndOptions() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results([]))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.found))
        let options = WebSearchOptions(language: "fr", category: .general, maxResults: 50)

        _ = try await chain(keyed: [brave], open: [wikipedia]).search(query: "Tour Eiffel", options: options)

        #expect(await brave.calls == [options])
        #expect(await wikipedia.calls == [options])
        #expect(await wikipedia.receivedQueries == ["Tour Eiffel"])
    }

    @Test("Toutes ont répondu à vide : réponse vide (pas une erreur), source = la dernière qui a répondu")
    func allEmptyAnswersYieldAnEmptyResponseFromTheLastSource() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results([]))
        let marginalia = Provider(kind: .marginalia, outcome: .results([]))

        let result = try await chain(keyed: [brave], open: [marginalia]).search(query: "q", options: WebSearchOptions())

        #expect(result.response.results.isEmpty)
        #expect(result.source == .marginalia)
    }

    @Test("Échecs et réponses vides mêlés : réponse vide, pas d'erreur (au moins une source a répondu)")
    func mixedFailuresAndEmptyAnswersAreNotAFailure() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results([]))
        let wikipedia = Provider(kind: .wikipedia, outcome: .failure(WebSearchError.unavailable))

        let result = try await chain(keyed: [brave], open: [wikipedia]).search(query: "q", options: WebSearchOptions())

        #expect(result.response.results.isEmpty)
        #expect(result.source == .braveSearch)
    }

    // MARK: - Échec total

    @Test("Toutes en échec : allSourcesFailed, un motif par source dans l'ordre, erreur inconnue -> .unavailable")
    func allFailuresThrowATypedErrorWithOrderedReasons() async {
        struct OpaqueError: Error, Sendable {}
        let brave = Provider(kind: .braveSearch, outcome: .failure(WebSearchError.unauthorized))
        let searxng = Provider(kind: .searxng, outcome: .failure(WebSearchError.timeout))
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .failure(OpaqueError()))

        let expected = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .braveSearch, reason: .searchFailed(.unauthorized)),
            WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.timeout)),
            WebSearchSourceFailure(source: .cloudProviderWebSearch, reason: .searchFailed(.unavailable)),
        ])
        await #expect(throws: expected) {
            try await chain(keyed: [brave], searxng: searxng, cloud: cloud).search(query: "q", options: WebSearchOptions())
        }
    }

    @Test("Clé illisible : source jamais interrogée, motif .keychainUnreadable en tête des échecs")
    func unreadableKeysAreReportedFirstAndNeverQueried() async {
        let searxng = Provider(kind: .searxng, outcome: .failure(WebSearchError.unavailable))

        let expected = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .braveSearch, reason: .keychainUnreadable),
            WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable)),
        ])
        await #expect(throws: expected) {
            try await chain(searxng: searxng, unreadable: [.braveSearch]).search(query: "q", options: WebSearchOptions())
        }
    }

    @Test("Le texte de l'erreur est un message français fixe, aussi via String(describing:)")
    func errorDescriptionIsAFixedFrenchMessage() {
        let error = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .braveSearch, reason: .searchFailed(.unauthorized)),
        ])
        #expect(error.userFacingMessage == "Aucune source de recherche n'a répondu. Vérifie ta connexion, puis réessaie.")
        #expect(String(describing: error) == error.userFacingMessage)
    }

    // MARK: - Annulation

    @Test("Annulation pendant une source : CancellationError, la source suivante (cloud payant) n'est jamais appelée")
    func cancellationStopsTheChainBeforeThePaidCloudSearch() async {
        let brave = Provider(kind: .braveSearch, outcome: .waitForCancellation)
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(Self.found))
        let chain = chain(keyed: [brave], cloud: cloud)

        let task = Task { try await chain.search(query: "q", options: WebSearchOptions()) }
        await ChainFixtures.waitUntil("Brave interrogé") { await brave.callCount == 1 }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cloud.callCount == 0)
    }

    @Test("Une source qui lève URLError(.cancelled) arrête la chaîne : jamais compté comme un échec de source")
    func urlCancellationIsNeverASourceFailure() async {
        let brave = Provider(kind: .braveSearch, outcome: .failure(URLError(.cancelled)))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.found))

        await #expect(throws: CancellationError.self) {
            try await chain(keyed: [brave], open: [wikipedia]).search(query: "q", options: WebSearchOptions())
        }
        #expect(await wikipedia.callCount == 0)
    }

    @Test("Tâche déjà annulée : aucune source n'est interrogée")
    func alreadyCancelledTaskQueriesNothing() async {
        let brave = Provider(kind: .braveSearch, outcome: .results(Self.found))
        let chain = chain(keyed: [brave])

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await chain.search(query: "q", options: WebSearchOptions())
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await brave.callCount == 0)
    }

    // MARK: - Langue

    @Test("Langue détectée : clés et sources ouvertes la reçoivent ; SearXNG et le cloud gardent les options de l'appelant")
    func detectedLanguageGoesToKeysAndOpenSourcesOnly() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results([]))
        let searxng = Provider(kind: .searxng, outcome: .results([]))
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results([]))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results([]))
        let chain = WebSearchChain(
            keyedProviders: [brave],
            searxng: searxng,
            cloudProvider: cloud,
            openSourceProviders: { _ in [wikipedia] },
            languageIdentifier: StubLanguageIdentifier(otherwise: "fr"),
            fallbackLanguage: "en"
        )
        let options = WebSearchOptions(category: .general, maxResults: 50)

        _ = try await chain.search(query: "q", options: options)

        let localized = WebSearchOptions(language: "fr", category: .general, maxResults: 50)
        #expect(await brave.calls == [localized])
        #expect(await wikipedia.calls == [localized])
        #expect(await searxng.calls == [options])
        #expect(await cloud.calls == [options])
    }

    @Test("SearXNG : aucune langue sur ses DEUX appels (moteurs forcés, puis repli général)")
    func searxngNeverReceivesTheDetectedLanguage() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results([]))
        let chain = WebSearchChain(
            searxng: searxng,
            openSourceProviders: { _ in [] },
            languageIdentifier: StubLanguageIdentifier(otherwise: "fr")
        )

        _ = try await chain.search(query: "q", options: WebSearchOptions(category: .academic))

        #expect(await searxng.calls.map(\.category) == [.academic, .general])
        #expect(await searxng.calls.map(\.language) == [nil, nil])
    }

    @Test("Question non reconnue : la langue de repli s'applique ; sans repli, aucune langue")
    func unrecognizedQueryUsesTheFallbackLanguage() async throws {
        let withFallback = Provider(kind: .wikipedia, outcome: .results(Self.found))
        let withoutFallback = Provider(kind: .wikipedia, outcome: .results(Self.found))
        let unsure = StubLanguageIdentifier()

        _ = try await WebSearchChain(searxng: nil, openSourceProviders: { _ in [withFallback] }, languageIdentifier: unsure, fallbackLanguage: "fr")
            .search(query: "Marie Curie", options: WebSearchOptions())
        _ = try await WebSearchChain(searxng: nil, openSourceProviders: { _ in [withoutFallback] }, languageIdentifier: unsure)
            .search(query: "Marie Curie", options: WebSearchOptions())

        #expect(await withFallback.calls.map(\.language) == ["fr"])
        #expect(await withoutFallback.calls.map(\.language) == [nil])
    }

    @Test("La langue de la question prime sur celle de l'appareil")
    func detectedLanguageWinsOverTheFallback() async throws {
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.found))
        let chain = WebSearchChain(
            searxng: nil,
            openSourceProviders: { _ in [wikipedia] },
            languageIdentifier: StubLanguageIdentifier(languages: ["capital of Japan": "en"]),
            fallbackLanguage: "fr"
        )

        _ = try await chain.search(query: "capital of Japan", options: WebSearchOptions())

        #expect(await wikipedia.calls.map(\.language) == ["en"])
    }

    @Test("Langue imposée par l'appelant : conservée partout, la détection ne l'écrase pas")
    func explicitLanguageIsKeptEverywhere() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results([]))
        let searxng = Provider(kind: .searxng, outcome: .results(Self.found))
        let chain = WebSearchChain(
            keyedProviders: [brave],
            searxng: searxng,
            openSourceProviders: { _ in [] },
            languageIdentifier: StubLanguageIdentifier(otherwise: "fr"),
            fallbackLanguage: "fr"
        )

        _ = try await chain.search(query: "q", options: WebSearchOptions(language: "de"))

        #expect(await brave.calls.map(\.language) == ["de"])
        #expect(await searxng.calls.map(\.language) == ["de"])
    }

    // MARK: - Étape SearXNG (repli du bug 5 dans la chaîne)

    @Test("Académique : moteurs forcés VIDES -> recherche générale SearXNG, avant le cloud payant", arguments: [
        WebSearchCategory.academic, .discussion,
    ])
    func forcedEnginesEmptyRetriesGeneralSearXNGBeforeTheCloud(category: WebSearchCategory) async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(Self.found), outcomesByCategory: [category: .results([])])
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(Self.found))

        let result = try await chain(searxng: searxng, cloud: cloud)
            .search(query: "q", options: WebSearchOptions(category: category, maxResults: 50))

        #expect(result.source == .searxng)
        #expect(await searxng.categories == [category, .general])
        #expect(await searxng.calls.last?.maxResults == 50)
        #expect(await cloud.callCount == 0)
    }

    @Test("Académique : moteurs forcés en ERREUR -> pas de second appel SearXNG, source suivante")
    func forcedEnginesErrorSkipsTheGeneralRetry() async throws {
        let searxng = Provider(kind: .searxng, outcome: .failure(WebSearchError.unavailable))
        let openAlex = Provider(kind: .openAlex, outcome: .results(Self.found))

        let result = try await chain(searxng: searxng, open: [openAlex])
            .search(query: "q", options: WebSearchOptions(category: .academic))

        #expect(result.source == .openAlex)
        #expect(await searxng.categories == [.academic])
        #expect(await openAlex.categories == [.academic])
    }

    @Test("Générale vide : pas de second appel SearXNG (aucun moteur forcé à contourner)")
    func generalEmptyDoesNotRetrySearXNG() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results([]))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(Self.found))

        let result = try await chain(searxng: searxng, open: [wikipedia]).search(query: "q", options: WebSearchOptions())

        #expect(result.source == .wikipedia)
        #expect(await searxng.callCount == 1)
    }
}

/// Assemblage d'une chaîne pour un envoi : recherche cloud seulement pour un moteur cloud avec clé,
/// clés de recherche lues source par source, trousseau illisible enregistré sans bloquer.
@MainActor
@Suite("WebSearchChain.assemble — composition")
struct WebSearchChainAssemblyTests {
    private func assemble(
        engine: AIEngineOption,
        cloudSelection: CloudProviderSelection? = nil,
        cloudKeys: ChainKeyStore = ChainKeyStore(),
        searchKeys: SearchKeyStore = ChainFixtures.searchKeys(),
        client: ChainSearXNGClient = ChainSearXNGClient(shouldFail: true),
        fallbackLanguage: String? = "fr",
        openSources: OpenSourceSearchChain = ChainFixtures.offlineOpenSources()
    ) -> WebSearchChain {
        WebSearchChain.assemble(
            engine: engine,
            cloudSelection: cloudSelection,
            cloudKeyStore: cloudKeys,
            searchKeys: searchKeys,
            failoverManager: FailoverManager(client: client, instances: [ChainFixtures.instance]),
            fallbackLanguage: fallbackLanguage,
            openSources: openSources
        )
    }

    private var claudeKey: ChainKeyStore {
        ChainKeyStore(items: [CloudProviderSelectionResolver.claudeProviderID: "sk-test"])
    }

    @Test("Moteur cloud + fournisseur qui cherche + clé : recherche cloud juste après SearXNG")
    func cloudEngineWithKeyAddsTheCloudStep() {
        let chain = assemble(engine: .cloudBYOK, cloudSelection: ChainFixtures.claudeSelection, cloudKeys: claudeKey)
        #expect(chain.kinds(for: .general) == [.searxng, .cloudProviderWebSearch, .wikipedia, .marginalia])
    }

    @Test("Moteur sur l'appareil : JAMAIS de recherche cloud, même avec une sélection cloud et sa clé", arguments: [
        AIEngineOption.appleIntelligence, .mlxLocal,
    ])
    func onDeviceEnginesNeverUseTheCloudSearch(engine: AIEngineOption) {
        let chain = assemble(engine: engine, cloudSelection: ChainFixtures.claudeSelection, cloudKeys: claudeKey)
        #expect(!chain.kinds(for: .general).contains(.cloudProviderWebSearch))
    }

    @Test("Moteur cloud sans clé, ou fournisseur sans recherche web : pas d'étape cloud")
    func cloudEngineWithoutKeyOrSupportSkipsTheCloudStep() {
        let withoutKey = assemble(engine: .cloudBYOK, cloudSelection: ChainFixtures.claudeSelection)
        let unsupported = assemble(
            engine: .cloudBYOK,
            cloudSelection: CloudProviderSelection(providerID: "mistral", model: "mistral-small"),
            cloudKeys: ChainKeyStore(items: ["mistral": "sk-test"])
        )
        #expect(!withoutKey.kinds(for: .general).contains(.cloudProviderWebSearch))
        #expect(!unsupported.kinds(for: .general).contains(.cloudProviderWebSearch))
    }

    @Test("Clés de recherche : Brave puis Tavily en tête ; une seule clé, une seule source")
    func searchKeysComeFirstInPreferenceOrder() {
        let both = assemble(engine: .appleIntelligence, searchKeys: ChainFixtures.searchKeys(brave: "b", tavily: "t"))
        let tavilyOnly = assemble(engine: .appleIntelligence, searchKeys: ChainFixtures.searchKeys(tavily: "t"))
        #expect(both.kinds(for: .general) == [.braveSearch, .tavily, .searxng, .wikipedia, .marginalia])
        #expect(tavilyOnly.kinds(for: .general) == [.tavily, .searxng, .wikipedia, .marginalia])
    }

    @Test("Étape SearXNG branchée sur le FailoverManager fourni (son client reçoit la question)")
    func searxngStepUsesTheGivenFailoverManager() async throws {
        let client = ChainSearXNGClient(results: [ChainFixtures.result("SearXNG", url: "https://searx.example/r")])
        let chain = assemble(engine: .appleIntelligence, client: client)

        let result = try await chain.search(query: "Tour Eiffel", options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(await client.receivedQueries == ["Tour Eiffel"])
    }

    // Le défaut que la langue corrige : avec `language: nil`, le vrai provider part sur
    // en.wikipedia.org, qui répond à une question française par du hors-sujet NON VIDE.
    @Test("Vrai provider Wikipédia : question française et nom propre (repli de l'appareil) partent sur fr.wikipedia.org", arguments: [
        "Quelle est la hauteur de la tour Eiffel ?", "Marie Curie",
    ])
    func frenchQuestionsReachTheFrenchWikipedia(query: String) async throws {
        let requester = HostRecordingRequester()
        let chain = assemble(
            engine: .appleIntelligence,
            fallbackLanguage: "fr",
            openSources: OpenSourceSearchChain(requester: requester, arXivSpacer: ArXivRequestSpacer(interval: .zero))
        )

        _ = try? await chain.search(query: query, options: WebSearchOptions())

        #expect(await requester.hosts.first == "fr.wikipedia.org")
    }

    @Test("Vrai provider Wikipédia : une question anglaise sur un appareil français part sur en.wikipedia.org")
    func englishQuestionsReachTheEnglishWikipedia() async throws {
        let requester = HostRecordingRequester()
        let chain = assemble(
            engine: .appleIntelligence,
            fallbackLanguage: "fr",
            openSources: OpenSourceSearchChain(requester: requester, arXivSpacer: ArXivRequestSpacer(interval: .zero))
        )

        _ = try? await chain.search(query: "what is the capital of Japan", options: WebSearchOptions())

        #expect(await requester.hosts.first == "en.wikipedia.org")
    }

    @Test("Trousseau des clés de recherche illisible : envoi non bloqué, clés rapportées dans l'échec total")
    func unreadableSearchKeychainIsRecordedNotFatal() async {
        let chain = assemble(engine: .appleIntelligence, searchKeys: ChainFixtures.searchKeys(brave: "b", failOnRead: true))
        #expect(chain.kinds(for: .general) == [.searxng, .wikipedia, .marginalia])

        let error = await #expect(throws: WebSearchChainError.self) {
            try await chain.search(query: "q", options: WebSearchOptions())
        }
        guard case .allSourcesFailed(let failures)? = error else { return }
        #expect(Array(failures.prefix(2)) == [
            WebSearchSourceFailure(source: .braveSearch, reason: .keychainUnreadable),
            WebSearchSourceFailure(source: .tavily, reason: .keychainUnreadable),
        ])
        #expect(failures.dropFirst(2).map(\.source) == [.searxng, .wikipedia, .marginalia])
    }

    @Test("Trousseau des clés IA illisible (moteur cloud) : recherche cloud sautée et rapportée")
    func unreadableCloudKeychainIsRecordedNotFatal() async {
        let brokenKeys = ChainKeyStore()
        brokenKeys.failOnRead = true
        let chain = assemble(engine: .cloudBYOK, cloudSelection: ChainFixtures.claudeSelection, cloudKeys: brokenKeys)
        #expect(!chain.kinds(for: .general).contains(.cloudProviderWebSearch))

        let error = await #expect(throws: WebSearchChainError.self) {
            try await chain.search(query: "q", options: WebSearchOptions())
        }
        guard case .allSourcesFailed(let failures)? = error else { return }
        #expect(failures.first == WebSearchSourceFailure(source: .cloudProviderWebSearch, reason: .keychainUnreadable))
    }
}
