//
//  SearchKeyStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 08/10/2026.
//

import Testing
import Foundation
@testable import Triva

/// Faux Keychain en mémoire : jamais le vrai Keychain de l'appareil depuis un test.
private final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    var items: [String: String] = [:]
    var failOnSave = false
    var failOnSaveForAccount: String?
    var failOnRead = false
    var failOnDelete = false

    func apiKey(account: String) throws -> String? {
        if failOnRead { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        return items[account]
    }

    func save(apiKey: String, account: String) throws {
        if failOnSave || failOnSaveForAccount == account {
            throw KeychainAPIKeyStoreError.unexpectedStatus(-25308)
        }
        items[account] = apiKey
    }

    func deleteAPIKey(account: String) throws {
        if failOnDelete { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        items[account] = nil
    }
}

@MainActor
@Suite("SearchKeyStore")
struct SearchKeyStoreTests {
    private func makeStore(_ keychain: InMemoryAPIKeyStore = InMemoryAPIKeyStore()) -> (SearchKeyStore, InMemoryAPIKeyStore) {
        (SearchKeyStore(keyStore: keychain, requester: BYOKTestRequester(body: "{}")), keychain)
    }

    private func google(key: String = "g-key", engine: String? = "cx-1") -> SearchKeyCredentials {
        SearchKeyCredentials(source: .google, apiKey: key, engineID: engine)
    }

    // MARK: Aucune clé

    @Test("sans aucune clé : rien de configuré, aucun provider")
    func nothingConfigured() throws {
        let (store, _) = makeStore()
        #expect(try store.configuredSources().isEmpty)
        #expect(try store.preferredProvider() == nil)
        #expect(try store.providersInPreferenceOrder().isEmpty)
        for source in BYOKSearchSource.allCases {
            #expect(try store.isConfigured(source) == false)
        }
    }

    // MARK: Enregistrement

    @Test("round-trip Brave et Tavily : une clé, un compte dédié")
    func saveSingleKeySources() throws {
        let (store, keychain) = makeStore()
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "brave-key"))
        try store.save(SearchKeyCredentials(source: .tavily, apiKey: "tvly-key"))

        #expect(keychain.items["search.brave.apiKey"] == "brave-key")
        #expect(keychain.items["search.tavily.apiKey"] == "tvly-key")
        #expect(try store.credentials(for: .brave)?.apiKey.value == "brave-key")
        #expect(try store.isConfigured(.tavily))
    }

    @Test("Google : deux valeurs, configuré seulement avec la clé ET le cx")
    func googleNeedsBothValues() throws {
        let (store, keychain) = makeStore()
        try store.save(google())

        #expect(keychain.items["search.google.apiKey"] == "g-key")
        #expect(keychain.items["search.google.engineID"] == "cx-1")
        #expect(try store.isConfigured(.google))

        // Clé seule (cx effacé à la main) : pas configuré.
        keychain.items["search.google.engineID"] = nil
        #expect(try store.isConfigured(.google) == false)
        #expect(try store.credentials(for: .google) == nil)

        // cx seul : pas configuré non plus.
        keychain.items["search.google.engineID"] = "cx-1"
        keychain.items["search.google.apiKey"] = nil
        #expect(try store.isConfigured(.google) == false)
    }

    @Test("les espaces autour de la saisie sont retirés")
    func trimsInput() throws {
        let (store, keychain) = makeStore()
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "  brave-key \n"))
        try store.save(google(key: " g-key ", engine: " cx-1\n"))

        #expect(keychain.items["search.brave.apiKey"] == "brave-key")
        #expect(keychain.items["search.google.apiKey"] == "g-key")
        #expect(keychain.items["search.google.engineID"] == "cx-1")
    }

    @Test("saisie incomplète : erreur explicite, rien d'écrit")
    func rejectsIncomplete() {
        let (store, keychain) = makeStore()
        #expect(throws: SearchKeyStoreError.incompleteCredentials) {
            try store.save(SearchKeyCredentials(source: .brave, apiKey: "   "))
        }
        #expect(throws: SearchKeyStoreError.incompleteCredentials) {
            try store.save(google(engine: nil))
        }
        #expect(throws: SearchKeyStoreError.incompleteCredentials) {
            try store.save(google(engine: "  "))
        }
        #expect(keychain.items.isEmpty)
    }

    @Test("enregistrer à nouveau remplace la valeur")
    func overwrite() throws {
        let (store, _) = makeStore()
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "old"))
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "new"))
        #expect(try store.credentials(for: .brave)?.apiKey.value == "new")
    }

    // MARK: Erreurs Keychain

    @Test("une erreur Keychain n'est jamais avalée")
    func keychainErrorsSurface() throws {
        let (store, keychain) = makeStore()
        keychain.failOnSave = true
        #expect(throws: SearchKeyStoreError.keychainFailure) {
            try store.save(SearchKeyCredentials(source: .brave, apiKey: "k"))
        }
        keychain.failOnSave = false
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "k"))

        keychain.failOnRead = true
        #expect(throws: SearchKeyStoreError.keychainFailure) { try store.credentials(for: .brave) }
        #expect(throws: SearchKeyStoreError.keychainFailure) { try store.configuredSources() }
        #expect(throws: SearchKeyStoreError.keychainFailure) { try store.preferredProvider() }

        keychain.failOnRead = false
        keychain.failOnDelete = true
        #expect(throws: SearchKeyStoreError.keychainFailure) { try store.delete(.brave) }
    }

    @Test("Google : si le cx échoue à s'écrire, la clé déjà écrite est retirée (pas de demi-configuration)")
    func googleRollback() {
        let (store, keychain) = makeStore()
        keychain.failOnSaveForAccount = "search.google.engineID"
        #expect(throws: SearchKeyStoreError.keychainFailure) { try store.save(google()) }
        #expect(keychain.items["search.google.apiKey"] == nil)
    }

    // MARK: Suppression

    @Test("delete retire la clé (et le cx pour Google) sans toucher aux autres sources")
    func deleteRemovesOnlyThatSource() throws {
        let (store, _) = makeStore()
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "b"))
        try store.save(google())

        try store.delete(.google)
        #expect(try store.isConfigured(.google) == false)
        #expect(try store.isConfigured(.brave))
        // Supprimer ce qui n'existe pas n'est pas une erreur.
        try store.delete(.tavily)
    }

    // MARK: Ordre de préférence

    @Test("ordre de préférence : Brave, puis Tavily, puis Google, quel que soit l'ordre d'enregistrement")
    func preferenceOrder() throws {
        let (store, _) = makeStore()
        try store.save(google())
        try store.save(SearchKeyCredentials(source: .tavily, apiKey: "t"))
        #expect(try store.configuredSources() == [.tavily, .google])
        #expect(try store.preferredProvider()?.kind == .tavily)

        try store.save(SearchKeyCredentials(source: .brave, apiKey: "b"))
        #expect(try store.configuredSources() == [.brave, .tavily, .google])
        #expect(try store.preferredProvider()?.kind == .braveSearch)
        #expect(try store.providersInPreferenceOrder().map(\.kind) == [.braveSearch, .tavily, .googleProgrammableSearch])

        try store.delete(.brave)
        #expect(try store.preferredProvider()?.kind == .tavily)
    }

    @Test("chaque source correspond au bon WebSearchSourceKind")
    func kinds() {
        #expect(BYOKSearchSource.brave.kind == .braveSearch)
        #expect(BYOKSearchSource.tavily.kind == .tavily)
        #expect(BYOKSearchSource.google.kind == .googleProgrammableSearch)
        #expect(BYOKSearchSource.preferenceOrder == [.brave, .tavily, .google])
        #expect(Set(BYOKSearchSource.preferenceOrder) == Set(BYOKSearchSource.allCases))
    }

    // MARK: Isolation vis-à-vis des clés IA

    @Test("aucun compte de recherche ne peut entrer en collision avec un compte de clé IA")
    func noCollisionWithAIAccounts() {
        let searchAccounts = BYOKSearchSource.allCases.flatMap { [$0.keyAccount, $0.engineIDAccount] }
        #expect(Set(searchAccounts).count == searchAccounts.count)
        #expect(searchAccounts.allSatisfy { $0.hasPrefix("search.") })
        for kind in CloudBYOKProviderKind.allCases {
            #expect(!searchAccounts.contains(kind.rawValue))
        }
        // Service Keychain distinct de celui des clés IA.
        #expect(SearchKeyStore.keychainService != "com.benpodrojsky.Triva.cloudBYOK")
    }

    // MARK: Providers et test de clé

    @Test("le provider construit porte la clé enregistrée et sait la tester")
    func providerUsesStoredKey() async throws {
        let requester = BYOKTestRequester(body: #"{ "web": { "results": [] } }"#)
        let keychain = InMemoryAPIKeyStore()
        let store = SearchKeyStore(keyStore: keychain, requester: requester)
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "stored-brave-key"))

        let outcome = try await store.validateStoredKey(for: .brave)
        #expect(outcome == .valid)
        #expect(requester.requests.count == 1)
        #expect(requester.requests[0].value(forHTTPHeaderField: "X-Subscription-Token") == "stored-brave-key")
    }

    @Test("tester une source sans clé : missingKey, aucune requête")
    func validateWithoutKey() async {
        let requester = BYOKTestRequester(body: "{}")
        let store = SearchKeyStore(keyStore: InMemoryAPIKeyStore(), requester: requester)
        let error = await byokThrownError { _ = try await store.validateStoredKey(for: .tavily) }
        #expect(error as? WebSearchError == .missingKey)
        #expect(requester.requests.isEmpty)
    }

    @Test("des identifiants saisis peuvent être testés AVANT d'être enregistrés")
    func validateBeforeSaving() async throws {
        let requester = BYOKTestRequester(status: 401, body: "{}")
        let credentials = SearchKeyCredentials(source: .tavily, apiKey: "typed-key")
        let provider = credentials.makeProvider(requester: requester)

        let error = await byokThrownError { _ = try await provider.validateKey() }
        #expect(error as? WebSearchError == .unauthorized)
        #expect(provider.kind == .tavily)
    }

    @Test("makeProvider : une saisie Google sans cx donne un provider qui lève missingKey")
    func incompleteGoogleProvider() async {
        let requester = BYOKTestRequester(body: "{}")
        let provider = SearchKeyCredentials(source: .google, apiKey: "k", engineID: nil).makeProvider(requester: requester)
        let error = await byokThrownError { _ = try await provider.search(query: "x", options: WebSearchOptions()) }
        #expect(error as? WebSearchError == .missingKey)
        #expect(requester.requests.isEmpty)
    }

    // MARK: Masquage

    @Test("SearchSecret et SearchKeyCredentials ne montrent jamais la clé")
    func secretsAreMasked() {
        let credentials = SearchKeyCredentials(source: .brave, apiKey: "super-secret-value")
        let secret = SearchSecret("super-secret-value")

        for text in [String(describing: secret), String(reflecting: secret),
                     String(describing: credentials), "\(credentials)"] {
            #expect(!text.contains("super-secret-value"))
        }
    }

    @Test("dump (Mirror) d'un provider et d'identifiants ne montre jamais la clé")
    func dumpDoesNotLeak() {
        let brave = BraveSearchProvider(apiKey: "super-secret-value", requester: BYOKTestRequester(body: "{}"))
        let tavily = TavilySearchProvider(apiKey: "super-secret-value", requester: BYOKTestRequester(body: "{}"))
        let google = GoogleProgrammableSearchProvider(
            apiKey: "super-secret-value", engineID: "cx-1", requester: BYOKTestRequester(body: "{}")
        )
        let credentials = SearchKeyCredentials(source: .google, apiKey: "super-secret-value", engineID: "cx-1")

        var output = ""
        dump(brave, to: &output)
        dump(tavily, to: &output)
        dump(google, to: &output)
        dump(credentials, to: &output)
        #expect(!output.contains("super-secret-value"))
    }
}

// MARK: - Aides de texte

@Suite("BYOKSearchHTTP — nettoyage de texte")
struct BYOKSearchTextTests {
    @Test("stripHTML : balises, entités nommées et numériques", arguments: [
        ("<strong>Swift</strong> 6", "Swift 6"),
        ("l&#x27;app &amp; le web", "l'app & le web"),
        ("&#39;ok&#39; &quot;ok&quot;", "'ok' \"ok\""),
        ("a&nbsp;b", "a b"),
        ("&amp;lt;b&amp;gt;", "&lt;b&gt;"),
        ("ligne 1\n\n   ligne 2", "ligne 1 ligne 2"),
        ("pas d'entité ici", "pas d'entité ici"),
        ("&#xZZ; &#99999999999;", "&#xZZ; &#99999999999;"),
    ])
    func stripsHTML(input: String, expected: String) {
        #expect(BYOKSearchHTTP.stripHTML(input) == expected)
    }

    @Test("baseLanguage")
    func baseLanguage() {
        #expect(BYOKSearchHTTP.baseLanguage(from: "fr-FR") == "fr")
        #expect(BYOKSearchHTTP.baseLanguage(from: "EN_us") == "en")
        #expect(BYOKSearchHTTP.baseLanguage(from: "") == nil)
        #expect(BYOKSearchHTTP.baseLanguage(from: "123") == nil)
        #expect(BYOKSearchHTTP.baseLanguage(from: "français") == nil)
        #expect(BYOKSearchHTTP.baseLanguage(from: nil) == nil)
    }

    @Test("makeResult ignore les liens non http(s) et accepte http")
    func makeResultFiltersLinks() {
        #expect(BYOKSearchHTTP.makeResult(title: "t", url: "javascript:alert(1)", content: nil) == nil)
        #expect(BYOKSearchHTTP.makeResult(title: "t", url: "", content: nil) == nil)
        #expect(BYOKSearchHTTP.makeResult(title: "t", url: nil, content: nil) == nil)
        #expect(BYOKSearchHTTP.makeResult(title: "t", url: "http://exemple.fr/a", content: "c")?.url == "http://exemple.fr/a")
    }
}
