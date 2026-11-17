//
//  CloudAIConsentTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 14/11/2026.
//

import Testing
import Foundation
@testable import Triva

private struct KeyStore: APIKeyStoring {
    var key: String? = "sk-test"
    func apiKey(account: String) throws -> String? { key }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

/// Compte tous les appels réseau simulés.
private final class CountingClient: PerplexityAgentRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func generate(baseURL: URL, apiKey: String, model: String, prompt: String) async throws -> String {
        lock.withLock { count += 1 }
        return "réponse"
    }

    func stream(baseURL: URL, apiKey: String, model: String, prompt: String) -> AsyncThrowingStream<PerplexityStreamEvent, Error> {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class CountingRequester: HTTPDataRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { count += 1 }
        throw URLError(.notConnectedToInternet)
    }
}

private func freshDefaults() -> UserDefaults {
    TestDefaults.suite(named: "test.cloudConsent.\(UUID().uuidString)")!
}

@Suite("CloudAIConsent — stockage")
struct CloudAIConsentStorageTests {
    @Test("Sans accord, rien n'est autorisé ; un accord vaut pour son fournisseur seulement")
    func perProvider() {
        let storage = CloudAIConsentStorage(userDefaults: freshDefaults())
        #expect(!storage.isGranted(providerID: "openai"))
        storage.grant(providerID: "openai")
        #expect(storage.isGranted(providerID: "openai"))
        #expect(!storage.isGranted(providerID: "claude"))
        #expect(!storage.isGranted(providerID: "custom:abc"))
    }

    @Test("Retirer l'accord le fait redemander")
    func revoke() {
        let storage = CloudAIConsentStorage(userDefaults: freshDefaults())
        storage.grant(providerID: "openai")
        storage.revoke(providerID: "openai")
        #expect(!storage.isGranted(providerID: "openai"))
    }

    @Test("Une nouvelle version du texte invalide les accords précédents")
    func versionChangeInvalidates() {
        let defaults = freshDefaults()
        CloudAIConsentStorage(userDefaults: defaults, textVersion: 1).grant(providerID: "openai")
        let v2 = CloudAIConsentStorage(userDefaults: defaults, textVersion: 2)
        #expect(!v2.isGranted(providerID: "openai"))
        v2.grant(providerID: "openai")
        #expect(v2.isGranted(providerID: "openai"))
    }

    @Test("L'accord garde sa date et survit à une nouvelle instance")
    func persistence() {
        let defaults = freshDefaults()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        CloudAIConsentStorage(userDefaults: defaults).grant(providerID: "groq", at: date)
        let record = CloudAIConsentStorage(userDefaults: defaults).record(providerID: "groq")
        #expect(record?.grantedAt == date)
        #expect(record?.textVersion == CloudAIConsentStorage.currentTextVersion)
    }

    @MainActor
    @Test("Le store observable suit le stockage et la porte lit en direct")
    func storeAndLiveGate() {
        let defaults = freshDefaults()
        let store = CloudAIConsentStore(userDefaults: defaults)
        let gate = CloudAIConsentGate(providerID: "openai", checker: store.storage)
        #expect(throws: CloudAIConsentError.notGranted(providerID: "openai")) { try gate.require() }
        store.grant(providerID: "openai")
        #expect(store.isGranted(providerID: "openai"))
        #expect(throws: Never.self) { try gate.require() }
        store.revoke(providerID: "openai")
        #expect(!store.isGranted(providerID: "openai"))
        #expect(throws: CloudAIConsentError.notGranted(providerID: "openai")) { try gate.require() }
    }
}

@MainActor
@Suite("CloudAIConsent — demandes")
struct CloudAIConsentRequestTests {
    @Test("Chaque fournisseur du catalogue a un nom exact et un lien de politique")
    func catalogPresetsHaveLinks() throws {
        for preset in CloudProviderCatalog.presets {
            let request = try #require(CloudAIConsentCatalog.request(providerID: preset.id, customPresets: []))
            #expect(request.displayName == preset.displayName)
            #expect(request.privacyURL?.scheme == "https")
        }
    }

    @Test("Claude : nom « Claude », recherche web et reformulation annoncées")
    func claude() throws {
        let request = try #require(CloudAIConsentCatalog.request(providerID: "claude", customPresets: []))
        #expect(request.displayName == "Claude")
        #expect(request.extras.contains(.webSearch))
        #expect(request.extras.contains(.media))
    }

    @Test("Lignes propres à Gemini, OpenRouter et DeepSeek")
    func specificExtras() throws {
        #expect(try #require(CloudAIConsentCatalog.request(providerID: "gemini", customPresets: [])).extras.contains(.gemini))
        #expect(try #require(CloudAIConsentCatalog.request(providerID: "openrouter", customPresets: [])).extras.contains(.openRouter))
        #expect(try #require(CloudAIConsentCatalog.request(providerID: "deepseek", customPresets: [])).extras.contains(.deepSeek))
        #expect(try #require(CloudAIConsentCatalog.request(providerID: "groq", customPresets: [])).extras == [.media])
    }

    @Test("Fournisseur personnalisé : hôte dans le titre, pas de lien, ligne dédiée")
    func custom() throws {
        let preset = CloudProviderPreset(
            id: "custom:1", displayName: "Mon LLM",
            baseURL: URL(string: "https://api.exemple.com/v1")!, defaultModel: "m"
        )
        let request = try #require(CloudAIConsentCatalog.request(providerID: "custom:1", customPresets: [preset]))
        #expect(request.privacyURL == nil)
        #expect(request.host == "api.exemple.com")
        #expect(CloudAIConsentText.title(request).contains("Mon LLM (api.exemple.com)"))
        #expect(request.extras.contains(.custom))
        #expect(CloudAIConsentCatalog.request(providerID: "custom:1", customPresets: []) == nil)
    }
}

@Suite("CloudAIConsent — aucune requête sans accord")
struct CloudAIConsentGateTests {
    private func gate(_ id: String, granted: Bool) -> CloudAIConsentGate {
        let storage = CloudAIConsentStorage(userDefaults: freshDefaults())
        if granted { storage.grant(providerID: id) }
        return CloudAIConsentGate(providerID: id, checker: storage)
    }

    @MainActor
    @Test("OpenAI-compatible : refusé sans accord, zéro appel réseau, y compris en streaming")
    func openAICompatible() async throws {
        let client = CountingClient()
        let provider = OpenAICompatibleProvider(
            account: "groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!, model: "m",
            keyStore: KeyStore(), client: client, consentGate: gate("groq", granted: false)
        )
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "groq")) {
            _ = try await provider.generate(prompt: "ma question privée")
        }
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "groq")) {
            for try await _ in provider.streamGenerate(prompt: "ma question privée") {}
        }
        #expect(client.calls == 0)
    }

    @MainActor
    @Test("OpenAI-compatible : avec accord, l'appel part")
    func openAICompatibleGranted() async throws {
        let client = CountingClient()
        let provider = OpenAICompatibleProvider(
            account: "groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!, model: "m",
            keyStore: KeyStore(), client: client, consentGate: gate("groq", granted: true)
        )
        #expect(try await provider.generate(prompt: "q") == "réponse")
        #expect(client.calls == 1)
    }

    @MainActor
    @Test("Perplexity : refusé sans accord, zéro appel, y compris en streaming")
    func perplexity() async throws {
        let client = CountingClient()
        let provider = PerplexityAgentProvider(
            baseURL: URL(string: "https://api.perplexity.ai")!, model: "fast",
            keyStore: KeyStore(), client: client, consentGate: gate("perplexity", granted: false)
        )
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "perplexity")) {
            _ = try await provider.generate(prompt: "q")
        }
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "perplexity")) {
            for try await _ in provider.streamGenerate(prompt: "q") {}
        }
        #expect(client.calls == 0)
    }

    @MainActor
    @Test("Claude : refusé sans accord avant toute lecture de clé")
    func claude() async throws {
        let provider = CloudBYOKProvider(keyStore: KeyStore(), consentGate: gate("claude", granted: false))
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "claude")) {
            _ = try await provider.generate(prompt: "q")
        }
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "claude")) {
            for try await _ in provider.streamGenerate(prompt: "q") {}
        }
    }

    @Test("Recherche web du fournisseur : aucune requête sans accord")
    func webSearch() async throws {
        let requester = CountingRequester()
        let provider = CloudWebSearchProvider(
            service: .openAI, apiKey: "sk-test", requester: requester,
            consentGate: gate("openai", granted: false)
        )
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "openai")) {
            _ = try await provider.search(query: "météo", options: WebSearchOptions())
        }
        #expect(requester.calls == 0)
    }

    @MainActor
    @Test("Chemin de production : la session cloud résout un provider verrouillé, déverrouillé par l'accord")
    func sessionPath() async throws {
        let defaults = freshDefaults()
        let stores = TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: KeyStore()
        )
        stores.cloudSelection.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        let session = SearchSession(engine: .cloudBYOK, stores: stores)

        // Demande à montrer tant que l'accord manque, et la porte tient.
        let request = try #require(session.cloudConsentRequestForSending())
        #expect(request.providerID == "claude")
        let provider = try await session.resolveProviderForSending()
        await #expect(throws: CloudAIConsentError.notGranted(providerID: "claude")) {
            _ = try await provider.generate(prompt: "q")
        }

        stores.cloudConsent.grant(providerID: "claude")
        #expect(session.cloudConsentRequestForSending() == nil)

        // Retrait : la question suivante redemande.
        stores.cloudConsent.revoke(providerID: "claude")
        #expect(session.cloudConsentRequestForSending() != nil)
    }

    @MainActor
    @Test("Moteurs sur l'appareil : aucune demande de consentement")
    func onDeviceNeverAsks() throws {
        let defaults = freshDefaults()
        let stores = TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: KeyStore()
        )
        stores.cloudSelection.selection = CloudProviderSelection(providerID: "claude", model: "m")
        #expect(SearchSession(engine: .appleIntelligence, stores: stores).cloudConsentRequestForSending() == nil)
        #expect(SearchSession(engine: .mlxLocal, stores: stores).cloudConsentRequestForSending() == nil)
    }

    @MainActor
    @Test("Annuler : message clair, rien d'envoyé ; Autoriser : accord transmis")
    func chatViewModelFlow() {
        let request = CloudAIConsentCatalog.request(providerID: "openai", customPresets: [])!
        final class Box { var ids: [String] = [] }
        let box = Box()
        let viewModel = ChatViewModel(
            resolveProvider: { throw ChatViewModelError.emptyResponse },
            resolveFailoverManager: { throw ChatViewModelError.emptyResponse },
            resolveConsentRequest: { request },
            grantConsent: { box.ids.append($0.providerID) }
        )
        #expect(viewModel.consentRequestBeforeSending() == request)
        viewModel.declineCloudConsent()
        #expect(viewModel.errorDescription == CloudAIConsentText.cancelled)
        viewModel.allowCloudConsent(request)
        #expect(box.ids == ["openai"])
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.messages.isEmpty)
    }
}
