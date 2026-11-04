//
//  WebSearchChainWiringTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 03/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Injection de la chaîne de repli (RI1b), de la session jusqu'aux artefacts : orchestrateur
// (source retenue, catégorie, échec total, médias), `ChatViewModel` de bout en bout (avec son
// `makeOrchestrator` PAR DÉFAUT) et `SearchSession` (composition relue à chaque envoi).
// Aucun réseau, aucun modèle système.

private typealias Provider = ScriptedWebSearchProvider

private enum WiringFixtures {
    static let found = [ChainFixtures.result("Trouvé", url: "https://trouve.example/page")]

    /// JSON valide pour `QueryClassifier.parse` : drapeaux à `false` sauf ceux passés à `true`.
    static func classification(
        skipSearch: Bool = false,
        personalSearch: Bool = false,
        academic: Bool = false,
        discussion: Bool = false,
        followUp: String
    ) -> String {
        """
        {"classification":{"skipSearch":\(skipSearch),"personalSearch":\(personalSearch),"academicSearch":\(academic),\
        "discussionSearch":\(discussion),"showWeatherWidget":false,"showStockWidget":false,\
        "showCalculationWidget":false},"standaloneFollowUp":"\(followUp)"}
        """
    }

    static func classification(for category: WebSearchCategory, followUp: String) -> String {
        classification(academic: category == .academic, discussion: category == .discussion, followUp: followUp)
    }

    /// Chaîne réduite à une seule source (peu importe laquelle : `kind` est rendu tel quel).
    static func chain(_ source: Provider) -> WebSearchChain {
        WebSearchChain(keyedProviders: [source], searxng: nil, openSourceProviders: { _ in [] })
    }

    /// Vrai `FailoverManager` sur un client factice.
    static func manager(_ client: ChainSearXNGClient = ChainSearXNGClient(shouldFail: true)) -> FailoverManager {
        FailoverManager(client: client, instances: [ChainFixtures.instance])
    }
}

/// Similarité identique partout : le classement garde l'ordre d'arrivée, sans embeddings système.
private struct ConstantSimilarityScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

/// Rien n'est un quasi-doublon : des extraits de test courts se ressemblent trop.
private struct NeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Aucune langue reconnue : un seul groupe, aucune fusion FR/EN.
private struct UnknownLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Aucun scrape réel (le mode Rapide n'a pas de planner, mais une doublure vaut mieux qu'un réseau).
private struct NoScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

// MARK: - Orchestrateur

/// La chaîne reçue par l'orchestrateur remplace SearXNG dans le tour seedé, et sa source remonte
/// jusqu'aux artefacts. Classement et scrape neutralisés, widgets vides.
@MainActor
@Suite("WebSearchChain — orchestrateur et artefacts")
struct WebSearchChainOrchestratorTests {
    private typealias F = WiringFixtures

    private func makeOrchestrator(
        failoverManager: FailoverManager = WiringFixtures.manager(),
        aiProvider: ChainAIProvider = ChainAIProvider(),
        chain: WebSearchChain?
    ) -> SearchOrchestrator {
        SearchOrchestrator(
            failoverManager: failoverManager,
            aiProvider: aiProvider,
            responseMode: .quick,
            configuration: .cloud,
            scrapeService: NoScrapeService(),
            sourceRanker: SourceRanker(
                relevanceScorer: ConstantSimilarityScorer(),
                duplicateScorer: NeverDuplicateScorer(),
                languageIdentifier: UnknownLanguageIdentifier()
            ),
            widgets: [],
            webSearchChain: chain
        )
    }

    // MARK: Source retenue

    @Test("Sans chaîne : SearXNG seul, source .searxng, y compris pour une réponse vide (une recherche a eu lieu)")
    func withoutChainTheSourceIsSearXNG() async throws {
        let answered = try await makeOrchestrator(failoverManager: F.manager(ChainSearXNGClient(results: F.found)), chain: nil)
            .answer(query: "q")
        let empty = try await makeOrchestrator(failoverManager: F.manager(ChainSearXNGClient()), chain: nil)
            .answer(query: "q")

        #expect(answered.artifacts.webSourceKind == .searxng)
        #expect(answered.sources == F.found)
        #expect(empty.artifacts.webSourceKind == .searxng)
        #expect(empty.sources.isEmpty)
    }

    @Test("Avec chaîne : la source retenue remonte jusqu'aux artefacts (answer et streamAnswer), plus d'appel SearXNG direct", arguments: WebSearchSourceKind.allCases)
    func theRetainedSourceReachesTheArtifacts(kind: WebSearchSourceKind) async throws {
        let source = Provider(kind: kind, outcome: .results(F.found))
        let client = ChainSearXNGClient(results: [ChainFixtures.result("SearXNG direct", url: "https://direct.example/r")])
        let orchestrator = makeOrchestrator(failoverManager: F.manager(client), chain: F.chain(source))

        let answered = try await orchestrator.answer(query: "q")
        let streamed = try await orchestrator.streamAnswer(query: "q")

        #expect(answered.artifacts.webSourceKind == kind)
        #expect(answered.sources == F.found)
        #expect(streamed.artifacts.webSourceKind == kind)
        #expect(streamed.sources == F.found)
        #expect(await source.callCount == 2)
        #expect(await client.callCount == 0)
    }

    @Test("Repli complet : SearXNG réel en panne, la source ouverte fournit les sources du prompt")
    func sourcesComeFromTheFallbackWhenSearXNGIsDown() async throws {
        let client = ChainSearXNGClient(shouldFail: true)
        let manager = F.manager(client)
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(F.found))
        let chain = WebSearchChain(searxng: SearXNGWebSearchProvider(failover: manager), openSourceProviders: { _ in [wikipedia] })
        let aiProvider = ChainAIProvider()

        let result = try await makeOrchestrator(failoverManager: manager, aiProvider: aiProvider, chain: chain)
            .answer(query: "Tour Eiffel")

        #expect(result.artifacts.webSourceKind == .wikipedia)
        #expect(result.sources == F.found)
        #expect(await client.receivedQueries.contains("Tour Eiffel"))
        #expect(await client.receivedOptions.allSatisfy { $0.language == nil })
        #expect(aiProvider.receivedPrompts.last?.contains("Trouvé") == true)
    }

    @Test("Route sans recherche : webSourceKind nil, aucune source interrogée")
    func noSearchRouteHasNoWebSource() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results(F.found))
        let aiProvider = ChainAIProvider(classification: F.classification(skipSearch: true, followUp: "bonjour"))

        let result = try await makeOrchestrator(aiProvider: aiProvider, chain: F.chain(brave)).answer(query: "bonjour")

        #expect(result.artifacts.webSourceKind == nil)
        #expect(!result.artifacts.searchPerformed)
        #expect(await brave.callCount == 0)
    }

    @Test("Route fichiers joints seuls : une recherche a eu lieu, mais aucune source web (webSourceKind nil)")
    func attachmentsRouteHasNoWebSource() async throws {
        let attachment = IndexedAttachment(
            id: UUID(),
            fileName: "notes.txt",
            kind: .plainText,
            pageCount: nil,
            characterCount: 29,
            isTruncated: false,
            isCopyRestricted: false,
            chunks: [AttachmentChunk(index: 0, text: "Le préavis est de trois mois.", pageRange: nil)]
        )
        let brave = Provider(kind: .braveSearch, outcome: .results(F.found))
        let aiProvider = ChainAIProvider(classification: F.classification(personalSearch: true, followUp: "préavis"))

        let result = try await makeOrchestrator(aiProvider: aiProvider, chain: F.chain(brave)).answer(
            query: "Quel préavis ?",
            attachments: AttachmentSearchIndex(attachments: [attachment], scorer: ConstantSimilarityScorer())
        )

        #expect(result.artifacts.searchPerformed)
        #expect(result.artifacts.webSourceKind == nil)
        #expect(await brave.callCount == 0)
    }

    // MARK: Catégorie

    /// La détection ne reconnaît QUE la reformulation : `"fr"` prouve qu'elle porte sur le texte
    /// envoyé aux sources, jamais sur la question d'origine (« et ça ? »).
    @Test("La route donne sa catégorie à la chaîne, avec la reformulation (texte envoyé et langue détectée) et le plafond par source", arguments: [
        WebSearchCategory.general, .academic, .discussion,
    ])
    func theRouteSetsTheCategoryOfTheChain(category: WebSearchCategory) async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results(F.found))
        let chain = WebSearchChain(
            keyedProviders: [brave],
            searxng: nil,
            openSourceProviders: { _ in [] },
            languageIdentifier: StubLanguageIdentifier(languages: ["sujet reformulé": "fr"])
        )
        let aiProvider = ChainAIProvider(classification: F.classification(for: category, followUp: "sujet reformulé"))

        _ = try await makeOrchestrator(aiProvider: aiProvider, chain: chain).answer(query: "et ça ?")

        #expect(await brave.calls == [
            WebSearchOptions(language: "fr", category: category, maxResults: WebSearchChain.maxResultsPerSource),
        ])
        #expect(await brave.receivedQueries == ["sujet reformulé"])
    }

    @Test("Moteurs forcés vides avec la chaîne : son étape SearXNG suffit, l'orchestrateur ne relance pas toute la chaîne (bug 5)", arguments: [
        WebSearchCategory.academic, .discussion,
    ])
    func theChainReplacesTheSecondPassOfBug5(category: WebSearchCategory) async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results([]))
        let searxng = Provider(kind: .searxng, outcome: .results([]))
        let open = Provider(kind: .wikipedia, outcome: .results([]))
        let chain = WebSearchChain(keyedProviders: [brave], searxng: searxng, openSourceProviders: { _ in [open] })
        let aiProvider = ChainAIProvider(classification: F.classification(for: category, followUp: "sujet"))

        let result = try await makeOrchestrator(aiProvider: aiProvider, chain: chain).answer(query: "q")

        #expect(await searxng.categories == [category, .general])
        #expect(await brave.categories == [category])
        #expect(await open.categories == [category])
        #expect(result.sources.isEmpty)
        #expect(result.artifacts.searchPerformed)
        #expect(result.artifacts.webSourceKind == .wikipedia)
    }

    // MARK: Échec total

    @Test("Toutes les sources en échec : allSourcesFailed traverse l'orchestrateur tel quel (answer et streamAnswer)")
    func allSourcesFailedCrossesTheOrchestrator() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .failure(WebSearchError.unauthorized))
        let orchestrator = makeOrchestrator(chain: F.chain(brave))
        let expected = WebSearchChainError.allSourcesFailed([
            WebSearchSourceFailure(source: .braveSearch, reason: .searchFailed(.unauthorized)),
        ])

        await #expect(throws: expected) { _ = try await orchestrator.answer(query: "q") }
        await #expect(throws: expected) { _ = try await orchestrator.streamAnswer(query: "q") }
    }

    // MARK: Médias

    @Test("Médias : toujours sur SearXNG (FailoverManager de la session), jamais sur la chaîne")
    func mediaStayOnSearXNG() async throws {
        let client = ChainSearXNGClient()
        let brave = Provider(kind: .braveSearch, outcome: .results(F.found))
        let orchestrator = makeOrchestrator(failoverManager: F.manager(client), chain: F.chain(brave))

        _ = try await orchestrator.answer(query: "q", media: [.images, .videos])

        #expect(await brave.categories == [.general])
        let mediaOptions = await client.receivedOptions
        #expect(mediaOptions.count == 2)
        #expect(mediaOptions.contains(SearXNGMediaSearcher.imageSearchOptions))
        #expect(mediaOptions.contains(SearXNGMediaSearcher.videoSearchOptions))
    }
}

// MARK: - ChatViewModel

/// `resolveWebSearchChain` -> `OrchestratorInputs` -> `makeOrchestrator` PAR DÉFAUT -> orchestrateur
/// -> action : c'est le chemin de l'app, donc aucune couture sur `makeOrchestrator` ici. Mode Rapide :
/// pas de planner, donc aucun scrape réel ; classifieur factice vide : recherche générale sans widget.
@MainActor
@Suite("WebSearchChain — injection dans ChatViewModel")
struct WebSearchChainViewModelTests {
    private typealias F = WiringFixtures

    /// Journal des résolutions de chaîne, et chaînes à rendre, une par envoi.
    @MainActor
    private final class ChainResolver {
        private(set) var receivedManagers: [FailoverManager] = []
        private var chains: [WebSearchChain]

        init(_ chains: [WebSearchChain]) {
            self.chains = chains
        }

        func resolve(_ manager: FailoverManager) -> WebSearchChain {
            receivedManagers.append(manager)
            return chains.removeFirst()
        }
    }

    private func makeViewModel(
        client: ChainSearXNGClient = ChainSearXNGClient(shouldFail: true),
        aiProvider: ChainAIProvider = ChainAIProvider(),
        resolveChain: @escaping @MainActor (FailoverManager) throws -> WebSearchChain?
    ) -> ChatViewModel {
        let manager = F.manager(client)
        return ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            resolveWebSearchChain: resolveChain,
            readResponseMode: { .quick },
            generateSuggestions: { _, _ in [] }
        )
    }

    @Test("De bout en bout : la chaîne de l'envoi fournit les sources et le prompt, sur le FailoverManager résolu")
    func theInjectedChainAnswersEndToEnd() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .results(F.found))
        let client = ChainSearXNGClient(shouldFail: true)
        let aiProvider = ChainAIProvider()
        let resolver = ChainResolver([F.chain(brave)])
        let manager = F.manager(client)
        let viewModel = ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            resolveWebSearchChain: { resolver.resolve($0) },
            readResponseMode: { .quick },
            generateSuggestions: { _, _ in [] }
        )

        await viewModel.send(query: "Tour Eiffel")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.sources == F.found)
        #expect(viewModel.errorDescription == nil)
        #expect(await brave.receivedQueries == ["Tour Eiffel"])
        #expect(await client.callCount == 0)
        #expect(aiProvider.receivedPrompts.last?.contains("Trouvé") == true)
        #expect(resolver.receivedManagers.count == 1)
        #expect(resolver.receivedManagers.first === manager)
    }

    @Test("Sans chaîne injectée (défaut de l'init) : SearXNG seul, comportement d'avant")
    func withoutInjectedChainSearXNGAnswersAlone() async throws {
        let client = ChainSearXNGClient(results: F.found)
        let manager = F.manager(client)
        let aiProvider = ChainAIProvider()
        let viewModel = ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            readResponseMode: { .quick },
            generateSuggestions: { _, _ in [] }
        )

        await viewModel.send(query: "Tour Eiffel")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.sources == F.found)
        #expect(await client.receivedQueries == ["Tour Eiffel"])
    }

    @Test("Chaîne résolue à CHAQUE envoi : une clé ajoutée entre deux questions vaut dès la suivante")
    func theChainIsResolvedForEverySend() async throws {
        let first = Provider(kind: .searxng, outcome: .results(F.found))
        let second = Provider(kind: .braveSearch, outcome: .results(F.found))
        let resolver = ChainResolver([F.chain(first), F.chain(second)])
        let viewModel = makeViewModel(resolveChain: { resolver.resolve($0) })

        await viewModel.send(query: "première")
        await viewModel.send(query: "seconde")

        #expect(resolver.receivedManagers.count == 2)
        #expect(await first.receivedQueries == ["première"])
        #expect(await second.receivedQueries == ["seconde"])
    }

    @Test("Toutes les sources en échec : réponse .failed et bandeau lisible, jamais le nom technique de l'erreur")
    func allSourcesFailedReachesTheErrorBanner() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .failure(WebSearchError.rateLimited))
        let viewModel = makeViewModel(resolveChain: { _ in F.chain(brave) })

        await viewModel.send(query: "q")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .failed)
        let message = try #require(viewModel.errorDescription)
        #expect(!message.isEmpty)
        #expect(!message.contains("allSourcesFailed"))
        #expect(!message.contains("WebSearch"))
    }

    @Test("La résolution de la chaîne échoue : erreur au bandeau, aucune recherche lancée")
    func aThrowingChainResolutionFailsTheExchange() async throws {
        let client = ChainSearXNGClient(results: F.found)
        let aiProvider = ChainAIProvider()
        let viewModel = makeViewModel(client: client, aiProvider: aiProvider, resolveChain: { _ in
            throw SearchSessionError.sessionEnded
        })

        await viewModel.send(query: "q")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .failed)
        #expect(viewModel.errorDescription != nil)
        #expect(await client.callCount == 0)
        #expect(aiProvider.receivedPrompts.isEmpty)
    }

    @Test("Stop pendant une source : réponse interrompue, pas d'erreur, la source payante suivante n'est jamais appelée")
    func cancellingDuringASourceInterruptsTheAnswer() async throws {
        let brave = Provider(kind: .braveSearch, outcome: .waitForCancellation)
        let cloud = Provider(kind: .cloudProviderWebSearch, outcome: .results(F.found))
        let viewModel = makeViewModel(resolveChain: { _ in
            WebSearchChain(keyedProviders: [brave], searxng: nil, cloudProvider: cloud, openSourceProviders: { _ in [] })
        })

        let task = Task { await viewModel.send(query: "q") }
        await ChainFixtures.waitUntil("Brave interrogé") { await brave.callCount == 1 }
        task.cancel()
        await task.value

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .interrupted)
        #expect(viewModel.errorDescription == nil)
        #expect(await cloud.callCount == 0)
    }
}

// MARK: - SearchSession

/// Composition de la chaîne par la session : moteur FIGÉ, sélection cloud et clés relues à chaque
/// envoi. `kinds(for:)` ne fait aucune requête ; le seul test qui cherche s'arrête à SearXNG factice.
@MainActor
@Suite("WebSearchChain — composition par SearchSession")
struct SearchSessionWebSearchChainTests {
    private typealias F = WiringFixtures

    private func makeStores(cloudKeys: ChainKeyStore = ChainKeyStore()) throws -> TrivaSharedStores {
        let userDefaults = try #require(UserDefaults(suiteName: "test.webSearchChain.\(UUID().uuidString)"))
        return TrivaSharedStores(
            userDefaults: userDefaults,
            container: try TrivaModelContainer.makeInMemory(),
            isHistoryStorageVolatile: false,
            searchInstances: CustomInstanceStore(defaultInstances: [ChainFixtures.instance], userDefaults: userDefaults),
            keyStore: cloudKeys
        )
    }

    private var claudeKey: ChainKeyStore {
        ChainKeyStore(items: [CloudProviderSelectionResolver.claudeProviderID: "sk-test"])
    }

    @Test("Session cloud avec clé : clés de recherche, SearXNG, recherche cloud, puis sources ouvertes")
    func cloudSessionComposesTheFullChain() throws {
        let stores = try makeStores(cloudKeys: claudeKey)
        stores.cloudSelection.selection = ChainFixtures.claudeSelection
        let session = SearchSession(engine: .cloudBYOK, stores: stores, searchKeyStore: ChainFixtures.searchKeys(brave: "b"))

        let chain = session.resolveWebSearchChain(failoverManager: F.manager())

        #expect(chain.kinds(for: .general) == [.braveSearch, .searxng, .cloudProviderWebSearch, .wikipedia, .marginalia])
    }

    @Test("Session sur l'appareil : JAMAIS de recherche cloud, même si une autre fenêtre a enregistré une sélection et sa clé", arguments: [
        AIEngineOption.appleIntelligence, .mlxLocal,
    ])
    func onDeviceSessionNeverUsesTheCloudSearch(engine: AIEngineOption) throws {
        let stores = try makeStores(cloudKeys: claudeKey)
        stores.cloudSelection.selection = ChainFixtures.claudeSelection
        let session = SearchSession(engine: engine, stores: stores, searchKeyStore: ChainFixtures.searchKeys())

        let chain = session.resolveWebSearchChain(failoverManager: F.manager())

        #expect(chain.kinds(for: .general) == [.searxng, .wikipedia, .marginalia])
    }

    @Test("Sélection cloud et clés de recherche relues à chaque envoi, jamais mises en cache")
    func selectionAndSearchKeysAreReadAtEverySend() throws {
        let stores = try makeStores(cloudKeys: claudeKey)
        let searchKeychain = ChainKeyStore()
        let session = SearchSession(
            engine: .cloudBYOK,
            stores: stores,
            searchKeyStore: SearchKeyStore(keyStore: searchKeychain, requester: ChainOfflineRequester())
        )
        let manager = F.manager()
        #expect(session.resolveWebSearchChain(failoverManager: manager).kinds(for: .general) == [.searxng, .wikipedia, .marginalia])

        stores.cloudSelection.selection = ChainFixtures.claudeSelection
        searchKeychain.items[BYOKSearchSource.tavily.keyAccount] = "t"

        #expect(session.resolveWebSearchChain(failoverManager: manager).kinds(for: .general) == [
            .tavily, .searxng, .cloudProviderWebSearch, .wikipedia, .marginalia,
        ])
    }

    @Test("Langue de repli : première langue préférée de l'appareil, règle FR/EN de Découvrir")
    func fallbackLanguageFollowsPreferredLanguages() {
        #expect(SearchSession.fallbackSearchLanguage(preferredLanguages: ["fr-FR", "en-US"]) == "fr")
        #expect(SearchSession.fallbackSearchLanguage(preferredLanguages: ["en-FR", "fr-FR"]) == "en")
        #expect(SearchSession.fallbackSearchLanguage(preferredLanguages: ["de-DE"]) == "en")
        #expect(SearchSession.fallbackSearchLanguage(preferredLanguages: []) == "en")
    }

    @Test("Étape SearXNG de la session : sur le FailoverManager reçu de ChatViewModel")
    func theSearXNGStepUsesTheGivenManager() async throws {
        let client = ChainSearXNGClient(results: F.found)
        let session = SearchSession(engine: .appleIntelligence, stores: try makeStores(), searchKeyStore: ChainFixtures.searchKeys())

        let result = try await session.resolveWebSearchChain(failoverManager: F.manager(client))
            .search(query: "Tour Eiffel", options: WebSearchOptions())

        #expect(result.source == .searxng)
        #expect(result.response.results == F.found)
        #expect(await client.receivedQueries == ["Tour Eiffel"])
    }
}
