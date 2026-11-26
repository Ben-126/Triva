//
//  SearchKeyLockedDeviceTests.swift
//  TrivaTests
//
//  Mission F2 (26/11), point 2 : une clé Brave/Tavily illisible PARCE QUE l'appareil est verrouillé (Siri, Raccourcis sur
//  un écran verrouillé) n'est ni une clé absente ni une clé refusée. Le chat ne dit pas « ajoute une clé » ni « ta clé n'a
//  pas fonctionné » : il dit de déverrouiller (même règle que la mission NC, `DeviceLock`). Faux trousseau en mémoire.
//

import Foundation
import Testing
@testable import Triva

private func unreadable(_ source: WebSearchSourceKind) -> WebSearchSourceFailure {
    WebSearchSourceFailure(source: source, reason: .keychainUnreadable)
}

private func failed(_ source: WebSearchSourceKind, _ error: WebSearchError = .unavailable) -> WebSearchSourceFailure {
    WebSearchSourceFailure(source: source, reason: .searchFailed(error))
}

@Suite("Clé de recherche illisible, appareil verrouillé — invitation")
struct SearchKeyInvitationLockedTests {
    @Test("Toutes les sources en échec dont une clé illisible, verrouillé : aucune invitation")
    func lockedAfterTotalFailure() {
        let error = WebSearchChainError.allSourcesFailed([unreadable(.braveSearch), failed(.searxng), failed(.wikipedia)])

        #expect(SearchKeyInvitation(for: error, isDeviceLocked: true) == nil)
    }

    @Test("Même échec, déverrouillé : la forme « vérifier » d'avant ne change pas")
    func unlockedKeepsTheCheckInvitation() throws {
        let error = WebSearchChainError.allSourcesFailed([unreadable(.braveSearch), failed(.searxng)])

        let invitation = try #require(SearchKeyInvitation(for: error, isDeviceLocked: false))

        #expect(invitation.actionTitle == SearchKeyInvitation.checkKeysTitle)
    }

    @Test("Verrouillé SANS clé illisible : l'invitation d'avant (aucune clé -> en ajouter une)")
    func lockedWithoutUnreadableKeyStillInvites() throws {
        let error = WebSearchChainError.allSourcesFailed([failed(.searxng), failed(.wikipedia)])

        let invitation = try #require(SearchKeyInvitation(for: error, isDeviceLocked: true))

        #expect(invitation.actionTitle == SearchKeyInvitation.addKeyTitle)
    }

    @Test("Clé du fournisseur IA illisible (recherche cloud sautée), verrouillé : aucune invitation à « ajouter »")
    func lockedCloudKeyDoesNotInvite() {
        let error = WebSearchChainError.allSourcesFailed([unreadable(.cloudProviderWebSearch), failed(.searxng)])

        #expect(SearchKeyInvitation(for: error, isDeviceLocked: true) == nil)
    }

    @Test("Après une réponse de secours, clé illisible, verrouillé : aucune invitation ; déverrouillé : « vérifier »")
    func afterFallbackWhileLocked() throws {
        let report = WebSearchChainReport(passedOver: [unreadable(.braveSearch), failed(.searxng)])

        #expect(SearchKeyInvitation(afterFallback: report, retainedSource: .wikipedia, webSourceCount: 3, isDeviceLocked: true) == nil)
        let unlocked = try #require(
            SearchKeyInvitation(afterFallback: report, retainedSource: .wikipedia, webSourceCount: 3, isDeviceLocked: false)
        )
        #expect(unlocked.actionTitle == SearchKeyInvitation.checkKeysTitle)
    }

    @Test("Après une réponse de secours, aucune clé tentée, verrouillé : l'invitation d'avant")
    func afterFallbackLockedWithoutKeys() {
        let report = WebSearchChainReport(passedOver: [failed(.searxng)])

        let invitation = SearchKeyInvitation(afterFallback: report, retainedSource: .wikipedia, webSourceCount: 3, isDeviceLocked: true)

        #expect(invitation?.actionTitle == SearchKeyInvitation.addKeyTitle)
    }
}

@MainActor
@Suite("Clé de recherche illisible, appareil verrouillé — message du bandeau")
struct SearchKeyLockedMessageTests {
    @Test("Toutes les sources en échec dont une clé illisible, verrouillé : « Déverrouille… », pas « Aucune source n'a répondu »")
    func lockedBannerSaysUnlock() {
        let error = WebSearchChainError.allSourcesFailed([unreadable(.tavily), failed(.searxng)])

        #expect(ChatViewModel.userFacingMessage(for: error, isDeviceLocked: true) == DeviceLock.invitation)
    }

    @Test("Déverrouillé, ou verrouillé sans clé illisible : le message d'avant")
    func otherwiseTheUsualBanner() {
        let withKey = WebSearchChainError.allSourcesFailed([unreadable(.tavily), failed(.searxng)])
        let withoutKey = WebSearchChainError.allSourcesFailed([failed(.searxng), failed(.wikipedia)])

        #expect(ChatViewModel.userFacingMessage(for: withKey, isDeviceLocked: false) == withKey.userFacingMessage)
        #expect(ChatViewModel.userFacingMessage(for: withoutKey, isDeviceLocked: true) == withoutKey.userFacingMessage)
    }

    @Test("Hors ligne : le message de connexion reste prioritaire, même verrouillé")
    func offlineWins() {
        let error = WebSearchChainError.allSourcesFailed([unreadable(.braveSearch), failed(.searxng, .noConnection)])

        #expect(ChatViewModel.userFacingMessage(for: error, isDeviceLocked: true)
                == "Pas de connexion à internet. Reconnecte-toi, puis réessaie.")
    }

    @Test("Seule la présence d'une clé illisible est lue dans les échecs")
    func hasUnreadableKey() {
        #expect(WebSearchChainError.allSourcesFailed([unreadable(.braveSearch)]).hasUnreadableKey)
        #expect(WebSearchChainError.allSourcesFailed([failed(.searxng), unreadable(.cloudProviderWebSearch)]).hasUnreadableKey)
        #expect(!WebSearchChainError.allSourcesFailed([failed(.searxng, .unauthorized)]).hasUnreadableKey)
    }
}

private final class LockableKeychain: APIKeyStoring, @unchecked Sendable {
    var items: [String: String] = [:]
    var locked = false

    func apiKey(account: String) throws -> String? {
        if locked { throw KeychainAPIKeyStoreError.unexpectedStatus(-25308) }
        return items[account]
    }

    func save(apiKey: String, account: String) throws { items[account] = apiKey }
    func deleteAPIKey(account: String) throws { items[account] = nil }
}

@MainActor
@Suite("Clé de recherche illisible, appareil verrouillé — exemples de l'écran vide")
struct SearchKeyAvailabilityLockedTests {
    @Test("Lecture refusée (verrouillé) : « pas de clé » pour l'instant, mais RIEN n'est gardé en mémoire")
    func failedReadIsNotCached() throws {
        let keychain = LockableKeychain()
        let store = SearchKeyStore(keyStore: keychain)
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "clé-factice"))
        let availability = SearchKeyAvailability(store: store)

        keychain.locked = true
        #expect(availability.hasKey == false)

        keychain.locked = false
        #expect(availability.hasKey == true)
    }

    @Test("Lecture réussie : toujours gardée, une seule lecture")
    func successfulReadIsStillCached() throws {
        let keychain = LockableKeychain()
        let store = SearchKeyStore(keyStore: keychain)
        try store.save(SearchKeyCredentials(source: .brave, apiKey: "clé-factice"))
        let availability = SearchKeyAvailability(store: store)
        #expect(availability.hasKey == true)

        keychain.locked = true
        #expect(availability.hasKey == true)
    }
}
