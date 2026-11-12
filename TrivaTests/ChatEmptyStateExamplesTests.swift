//
//  ChatEmptyStateExamplesTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Exemples de l'écran vide du chat : la liste dépend de la présence d'une clé de recherche
// (décision de Ben, 2026-11-11). Faux trousseau en mémoire, jamais le vrai.

private final class FakeKeychain: APIKeyStoring, @unchecked Sendable {
    var items: [String: String] = [:]
    var failOnRead = false
    private(set) var readCount = 0

    func apiKey(account: String) throws -> String? {
        readCount += 1
        if failOnRead { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        return items[account]
    }

    func save(apiKey: String, account: String) throws { items[account] = apiKey }
    func deleteAPIKey(account: String) throws { items[account] = nil }
}

@MainActor
@Suite("Exemples de l'écran vide")
struct ChatEmptyStateExamplesTests {
    @Test("Avec une clé : les quatre exemples du web du jour")
    func withKey() {
        #expect(ChatEmptyStateView.examples(hasSearchKey: true) == [
            "Qu'est-ce qui fait l'actualité aujourd'hui ?",
            "Quels films sortent au cinéma cette semaine ?",
            "Quelles sont les nouveautés d'iOS 27 ?",
            "Compare les voitures électriques les plus vendues en France",
        ])
    }

    @Test("Sans clé : les deux exemples que Wikipédia suffit à sourcer")
    func withoutKey() {
        #expect(ChatEmptyStateView.examples(hasSearchKey: false) == [
            "Pourquoi la tour Eiffel a-t-elle été construite ?",
            "Comment se forme un trou noir ?",
        ])
    }

    @Test("Disponibilité : lecture unique du trousseau, puis valeur gardée")
    func availabilityReadsOnce() {
        let keychain = FakeKeychain()
        let availability = SearchKeyAvailability(store: SearchKeyStore(keyStore: keychain))
        #expect(keychain.readCount == 0)
        #expect(availability.hasKey == false)
        let reads = keychain.readCount
        _ = availability.hasKey
        #expect(keychain.readCount == reads)
    }

    @Test("Disponibilité : une clé ajoutée puis retirée change la réponse après invalidation")
    func availabilityFollowsKeyChanges() throws {
        let keychain = FakeKeychain()
        let store = SearchKeyStore(keyStore: keychain)
        let availability = SearchKeyAvailability(store: store)
        #expect(availability.hasKey == false)

        try store.save(SearchKeyCredentials(source: .brave, apiKey: "clé-factice"))
        availability.invalidate()
        #expect(availability.hasKey == true)

        try store.delete(.brave)
        availability.invalidate()
        #expect(availability.hasKey == false)
    }

    @Test("Enregistrer ou supprimer une clé poste la notification de changement")
    func storePostsNotification() async throws {
        let store = SearchKeyStore(keyStore: FakeKeychain())
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: SearchKeyStore.didChangeNotification, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        try store.save(SearchKeyCredentials(source: .tavily, apiKey: "clé-factice"))
        try store.delete(.tavily)
        #expect(count >= 2)
    }

    @Test("Panne du trousseau : on se comporte comme sans clé")
    func keychainFailureMeansNoKey() {
        let keychain = FakeKeychain()
        keychain.failOnRead = true
        #expect(SearchKeyStore(keyStore: keychain).hasConfiguredKey == false)
    }
}
