//
//  LegalComplianceTests.swift
//  TrivaTests
//
//  Mission légale C1 (2026-11-14) : manifeste de confidentialité, safesearch toujours actif,
//  extraits Brave non conservés, mention Tavily.
//

import Foundation
import SwiftData
import Testing
@testable import Triva

// MARK: - Manifeste de confidentialité (audit n° 3 et 31)

@MainActor
@Suite("Manifeste de confidentialité")
struct PrivacyManifestTests {
    private func manifest() throws -> [String: Any] {
        let url = try #require(
            Bundle(for: BundleToken.self).url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
                ?? Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("Le manifeste est dans le bundle de l'app et déclare UserDefaults avec la raison CA92.1")
    func declaresUserDefaultsReason() throws {
        let manifest = try manifest()
        let apis = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let userDefaults = try #require(
            apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" }
        )
        let reasons = try #require(userDefaults["NSPrivacyAccessedAPITypeReasons"] as? [String])
        #expect(reasons.contains("CA92.1"))
    }

    @Test("Aucun suivi, aucun domaine de suivi, aucune donnée collectée")
    func declaresNoTrackingNoCollection() throws {
        let manifest = try manifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    @Test("Le chiffrement non exempté est déclaré absent dans l'Info.plist")
    func declaresExemptEncryptionOnly() throws {
        let value = Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool
        #expect(value == false)
    }
}

private final class BundleToken {}

// MARK: - Safesearch (audit n° 15, décision Q5 révisée : modéré par défaut, désactivable)

@MainActor
@Suite("Safesearch modéré par défaut, désactivable")
struct SafeSearchTests {
    private let instance = URL(string: "https://searx.example")!

    private func searXNGItems(_ enabled: Bool, category: String? = nil) throws -> [URLQueryItem] {
        let options = SearXNGSearchOptions(categories: category.map { [$0] } ?? [], language: "fr", pageNumber: 2)
        let url = try #require(SearXNGClient.buildURL(instance: instance, query: "chat", options: options, safeSearchEnabled: enabled))
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    @Test("Réglage : activé par défaut, lu et écrit dans les UserDefaults fournis")
    func settingDefaultsToEnabled() throws {
        let suite = "SafeSearchTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SafeSearchPolicy.isEnabled(in: defaults))
        defaults.set(false, forKey: SafeSearchPolicy.defaultsKey)
        #expect(SafeSearchPolicy.isEnabled(in: defaults) == false)
        defaults.set(true, forKey: SafeSearchPolicy.defaultsKey)
        #expect(SafeSearchPolicy.isEnabled(in: defaults))
    }

    @Test("SearXNG : 1 si activé (web, images, vidéos), 0 si désactivé")
    func searXNG() throws {
        for category in [nil, "images", "videos", "general"] {
            #expect(try searXNGItems(true, category: category).filter { $0.name == "safesearch" }.map(\.value) == ["1"])
            #expect(try searXNGItems(false, category: category).filter { $0.name == "safesearch" }.map(\.value) == ["0"])
        }
    }

    @Test("Brave : moderate si activé, off sinon")
    func brave() throws {
        let on = try BraveSearchProvider(apiKey: "k").buildRequest(query: "chat", options: WebSearchOptions(), safeSearchEnabled: true)
        let off = try BraveSearchProvider(apiKey: "k").buildRequest(query: "chat", options: WebSearchOptions(), safeSearchEnabled: false)
        #expect(byokQueryValue("safesearch", in: on) == "moderate")
        #expect(byokQueryValue("safesearch", in: off) == "off")
    }

    @Test("Tavily : safe_search=true si activé, paramètre omis sinon")
    func tavily() throws {
        for depth in [TavilySearchProvider.Depth.basic, .advanced] {
            let provider = TavilySearchProvider(apiKey: "k", depth: depth)
            let on = try provider.buildRequest(query: "chat", options: WebSearchOptions(), safeSearchEnabled: true)
            let off = try provider.buildRequest(query: "chat", options: WebSearchOptions(), safeSearchEnabled: false)
            let onBody = try #require(on.httpBody)
            let offBody = try #require(off.httpBody)
            let onJSON = try #require(JSONSerialization.jsonObject(with: onBody) as? [String: Any])
            let offJSON = try #require(JSONSerialization.jsonObject(with: offBody) as? [String: Any])
            #expect(onJSON["safe_search"] as? Bool == true)
            #expect(offJSON["safe_search"] == nil)
        }
    }

    @Test("Marginalia : nsfw=1 si activé, nsfw=0 sinon")
    func marginalia() throws {
        let on = try MarginaliaSearchProvider().buildRequest(query: "chat", options: WebSearchOptions(), safeSearchEnabled: true)
        let off = try MarginaliaSearchProvider().buildRequest(query: "chat", options: WebSearchOptions(), safeSearchEnabled: false)
        #expect(ossQueryValue("nsfw", in: on) == "1")
        #expect(ossQueryValue("nsfw", in: off) == "0")
    }
}

// MARK: - Extraits Brave (audit n° 22, décision Q6)

@MainActor
@Suite("Extraits Brave non conservés")
struct BraveExcerptRetentionTests {
    private static let braveJSON = """
    {"web":{"results":[{"title":"Titre Brave","url":"https://brave.example/a","description":"Extrait Brave"}]}}
    """

    private func braveResults() throws -> [SearXNGSearchResult] {
        try BraveSearchProvider.parse(Data(Self.braveJSON.utf8), maxResults: 5).results
    }

    @Test("Un résultat Brave garde son extrait pour la réponse mais le marque transitoire")
    func braveResultIsTransient() throws {
        let result = try #require(braveResults().first)
        #expect(result.content == "Extrait Brave")
        #expect(result.excerptIsTransient)
        #expect(result.persistedExcerpt == nil)
    }

    @Test("Tavily et SearXNG ne sont pas concernés")
    func otherSourcesKeepExcerpt() throws {
        let plain = historyMakeSource(1, content: "Extrait libre")
        #expect(plain.excerptIsTransient == false)
        #expect(plain.persistedExcerpt == "Extrait libre")
        let tavily = try TavilySearchProvider.parse(
            Data(#"{"results":[{"title":"T","url":"https://t.example","content":"C"}]}"#.utf8), maxResults: 3
        )
        #expect(tavily.results.first?.excerptIsTransient == false)
    }

    @Test("Historique : titre + lien gardés, extrait Brave jamais écrit ; extrait des autres sources écrit")
    func historyDropsBraveExcerpt() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Test", now: historyDate(0))
        let brave = try #require(braveResults().first)
        let other = historyMakeSource(2, content: "Extrait libre")
        _ = try store.appendAssistantMessage(to: conversation, text: "Réponse [1][2]", sources: [brave, other], now: historyDate(1))

        let context = historyFreshContext(store)
        let stored = try context.fetch(FetchDescriptor<StoredSource>()).sorted { $0.order < $1.order }
        #expect(stored.count == 2)
        #expect(stored[0].title == "Titre Brave")
        #expect(stored[0].url == "https://brave.example/a")
        #expect(stored[0].snippet == nil)
        #expect(stored[1].snippet == "Extrait libre")
    }

    @Test("Favoris : même règle, directe depuis le chat ou recopiée depuis l'historique")
    func favoritesDropBraveExcerpt() throws {
        let container = try TrivaModelContainer.makeInMemory()
        let favorites = FavoritesStore(container: container, locale: Locale(identifier: "fr_FR"))
        let brave = try #require(braveResults().first)
        _ = try favorites.mark(messageID: UUID(), conversationID: nil, question: "Q", answer: "R", sources: [brave], now: historyDate(0))

        let stored = try ModelContext(container).fetch(FetchDescriptor<StoredFavoriteSource>())
        #expect(stored.count == 1)
        #expect(stored.first?.title == "Titre Brave")
        #expect(stored.first?.snippet == nil)
    }
}

// MARK: - Mention Tavily (audit n° 23)

@Suite("Mention Tavily")
struct TavilyLegalNoteTests {
    @Test("Tavily affiche la réserve 18 ans et la réutilisation des requêtes ; Brave n'a pas de mention")
    func tavilyNote() {
        let note = BYOKSearchSource.tavily.legalNote ?? ""
        #expect(note.contains("18 ans"))
        #expect(note.contains("réutiliser"))
        #expect(BYOKSearchSource.brave.legalNote == nil)
    }
}
