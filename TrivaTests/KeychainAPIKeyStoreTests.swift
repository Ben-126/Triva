//
//  KeychainAPIKeyStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 31/08/2026.
//

import Testing
import Foundation
import Security
@testable import Triva

/// Un `service` Keychain unique par test évite toute interférence entre
/// tests exécutés en parallèle ou d'une exécution à l'autre.
@MainActor
@Suite("KeychainAPIKeyStore")
struct KeychainAPIKeyStoreTests {
    @Test("Round-trip : save() puis apiKey() renvoie la même valeur")
    func saveThenRead() throws {
        let store = makeStore(service: uniqueService())
        defer { try? store.deleteAPIKey(account: "claude") }

        try store.save(apiKey: "sk-test-123", account: "claude")

        #expect(try store.apiKey(account: "claude") == "sk-test-123")
    }

    @Test("apiKey() renvoie nil quand rien n'est stocké")
    func readWithoutStoredKeyReturnsNil() throws {
        let store = makeStore(service: uniqueService())

        #expect(try store.apiKey(account: "claude") == nil)
    }

    @Test("readAPIKey() (lecture hors main actor) renvoie la même valeur que apiKey()")
    func offMainReadMatchesSyncRead() async throws {
        let store = makeStore(service: uniqueService())
        defer { try? store.deleteAPIKey(account: "claude") }

        #expect(try await store.readAPIKey(account: "claude") == nil)
        try store.save(apiKey: "sk-test-456", account: "claude")

        #expect(try await store.readAPIKey(account: "claude") == "sk-test-456")
    }

    @Test("save() écrase une clé existante pour le même compte")
    func saveOverwritesExistingKey() throws {
        let store = makeStore(service: uniqueService())
        defer { try? store.deleteAPIKey(account: "claude") }

        try store.save(apiKey: "sk-old", account: "claude")
        try store.save(apiKey: "sk-new", account: "claude")

        #expect(try store.apiKey(account: "claude") == "sk-new")
    }

    @Test("deleteAPIKey() supprime la clé stockée")
    func deleteRemovesKey() throws {
        let store = makeStore(service: uniqueService())

        try store.save(apiKey: "sk-test", account: "claude")
        try store.deleteAPIKey(account: "claude")

        #expect(try store.apiKey(account: "claude") == nil)
    }

    @Test("deleteAPIKey() ne lève pas d'erreur si rien n'est stocké")
    func deleteWithoutStoredKeyDoesNotThrow() throws {
        let store = makeStore(service: uniqueService())

        try store.deleteAPIKey(account: "claude")
    }

    @Test("Une requête du trousseau protégé porte kSecUseDataProtectionKeychain à vrai")
    func primaryQueryTargetsTheProtectedKeychain() {
        let target = KeychainAPIKeyStore.Target(service: "s", flags: nil, accessible: KeychainAccessibility.whenUnlocked.attribute)
        let query = KeychainAPIKeyStore.query(target, account: "a", scope: .primary)

        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

#if os(macOS)
    @Test("Mac : une requête de l'ancien trousseau exclut EXPLICITEMENT le trousseau protégé (sans cela, lecture et suppression atteignent aussi le protégé)")
    func legacyQueryExcludesTheProtectedKeychain() {
        let target = KeychainAPIKeyStore.Target(service: "s", flags: nil, accessible: KeychainAccessibility.whenUnlocked.attribute)
        let query = KeychainAPIKeyStore.query(target, account: "a", scope: .legacy)

        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
    }
#endif

    @Test("Les vraies clés restent lisibles seulement trousseau déverrouillé : l'accessibilité par défaut est « whenUnlocked »")
    func productionDefaultIsWhenUnlocked() {
        #expect(KeychainAPIKeyStore().accessibility == .whenUnlocked)
        #expect(KeychainAccessibility.whenUnlocked.attribute == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test("Le sondage classe les statuts : succès et doublon = disponible, -25308 = verrouillé (jamais indisponible), le reste = indisponible")
    func probeStatusClassification() {
        #expect(ProtectedKeychainState.classify(errSecSuccess) == .available)
        #expect(ProtectedKeychainState.classify(errSecDuplicateItem) == .available)
        #expect(ProtectedKeychainState.classify(errSecInteractionNotAllowed) == .locked)
        #expect(ProtectedKeychainState.classify(errSecMissingEntitlement) == .unavailable)
        #expect(ProtectedKeychainState.classify(errSecNotAvailable) == .unavailable)
    }

#if os(macOS)
    // MARK: - Migration de l'ancien trousseau Mac vers le trousseau protégé (mission C2)

    @Test("Mac : une clé de l'ancien trousseau est copiée dans le trousseau protégé, puis l'ancienne est supprimée (C6)", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainUsableNow))
    func legacyKeyIsCopiedThenRemoved() throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer { removeLegacy(service: service, account: "claude") }
        try addLegacy("sk-legacy", service: service, account: "claude")
        let store = makeStore(service: service, flags: flags)
        defer { try? store.deleteAPIKey(account: "claude") }

        #expect(try store.apiKey(account: "claude") == "sk-legacy")
        // Copiée dans le trousseau protégé (relue), puis l'ancienne entrée est supprimée.
        #expect(try readProtected(service: service, account: "claude") == "sk-legacy")
        #expect(try readLegacy(service: service, account: "claude") == nil)
        // La clé reste lisible après la suppression de l'ancienne copie.
        #expect(try store.apiKey(account: "claude") == "sk-legacy")
    }

    @Test("Mac : une clé supprimée dans Triva ne renaît pas depuis l'ancien trousseau, ET la copie héritée est supprimée aussi (R2-1)", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainUsableNow))
    func deletedKeyDoesNotComeBack() throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer { removeLegacy(service: service, account: "claude") }
        try addLegacy("sk-legacy", service: service, account: "claude")
        let store = makeStore(service: service, flags: flags)

        #expect(try store.apiKey(account: "claude") == "sk-legacy")
        try store.deleteAPIKey(account: "claude")

        #expect(try store.apiKey(account: "claude") == nil)
        #expect(try readProtected(service: service, account: "claude") == nil)
        #expect(try readLegacy(service: service, account: "claude") == nil)
    }

    @Test("Mac : remplacer une clé supprime aussi l'ancienne copie héritée (R2-1)", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainUsableNow))
    func replacingAKeyRemovesTheLegacyCopy() throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer { removeLegacy(service: service, account: "claude") }
        try addLegacy("sk-legacy", service: service, account: "claude")
        let store = makeStore(service: service, flags: flags)
        defer { try? store.deleteAPIKey(account: "claude") }

        try store.save(apiKey: "sk-new", account: "claude")

        #expect(try store.apiKey(account: "claude") == "sk-new")
        #expect(try readLegacy(service: service, account: "claude") == nil)
    }

    @Test("Mac : migrateLegacyKeys() copie tous les comptes du service, hors du fil principal", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainUsableNow))
    func migrateLegacyKeysCopiesEveryAccount() async throws {
        let service = uniqueService()
        let flags = freshFlags()
        defer {
            removeLegacy(service: service, account: "openai")
            removeLegacy(service: service, account: "groq")
        }
        try addLegacy("sk-openai", service: service, account: "openai")
        try addLegacy("sk-groq", service: service, account: "groq")
        let store = makeStore(service: service, flags: flags)
        defer {
            try? store.deleteAPIKey(account: "openai")
            try? store.deleteAPIKey(account: "groq")
        }

        let failed = await store.migrateLegacyKeys()

        #expect(failed.isEmpty)
        #expect(try readProtected(service: service, account: "openai") == "sk-openai")
        #expect(try readProtected(service: service, account: "groq") == "sk-groq")
        #expect(try readLegacy(service: service, account: "openai") == nil)
        #expect(try readLegacy(service: service, account: "groq") == nil)
    }

    @Test("Mac : sans ancienne clé, la lecture renvoie nil et ne crée rien", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainUsableNow))
    func nothingToMigrateReturnsNil() throws {
        let service = uniqueService()
        let store = makeStore(service: service)

        #expect(try store.apiKey(account: "claude") == nil)
        #expect(try readProtected(service: service, account: "claude") == nil)
    }

    @Test("Mac : save() laisse la clé lisible dans le trousseau protégé (la suppression de l'ancienne copie ne l'atteint pas)", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainUsableNow))
    func saveKeepsTheProtectedEntry() throws {
        let service = uniqueService()
        let store = makeStore(service: service)
        defer { try? store.deleteAPIKey(account: "claude") }

        try store.save(apiKey: "sk-protected", account: "claude")

        #expect(try readProtected(service: service, account: "claude") == "sk-protected")
    }

    @Test("Mac : migrer une clé ne supprime que l'ancienne copie, pas celle du trousseau protégé", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainUsableNow))
    func migrationKeepsTheProtectedCopy() throws {
        let service = uniqueService()
        defer { removeLegacy(service: service, account: "claude") }
        try addLegacy("sk-legacy", service: service, account: "claude")
        let store = makeStore(service: service)
        defer { try? store.deleteAPIKey(account: "claude") }

        _ = try store.apiKey(account: "claude")

        #expect(try readProtected(service: service, account: "claude") == "sk-legacy")
    }

    @Test("Mac : trousseau verrouillé, une écriture échoue en -25308 ; déverrouillé, elle réussit et se relit (jamais de repli silencieux)", .enabled(if: KeychainAPIKeyStore.isProtectedKeychainAvailable))
    func lockedKeychainFailsLoudly() throws {
        let store = KeychainAPIKeyStore(service: uniqueService(), migrationFlagsSuite: freshFlags())
        defer { try? store.deleteAPIKey(account: "claude") }

        do {
            try store.save(apiKey: "sk-locked", account: "claude")
            #expect(try store.apiKey(account: "claude") == "sk-locked")
        } catch let error as KeychainAPIKeyStoreError {
            #expect(error == .unexpectedStatus(errSecInteractionNotAllowed))
        }
    }

    @Test("Mac : diagnostic — signale (sans échouer) quand le trousseau protégé est inutilisable et que les tests Mac sont donc ignorés")
    func reportsWhenProtectedTestsAreSkipped() {
        let state = KeychainAPIKeyStore.protectedKeychainState
        guard state != .available else { return }
        let status = KeychainAPIKeyStore.lastProbeStatus.map(String.init) ?? "inconnu"
        Issue.record(
            "Tests du trousseau protégé IGNORÉS : état \(state), dernier OSStatus du sondage \(status).",
            severity: .warning
        )
    }

    // MARK: Aides : accès direct aux deux trousseaux, hors du code testé

    private func legacyQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Sans cette clé, lecture et suppression atteignent AUSSI le trousseau protégé (voir
            // `KeychainAPIKeyStore.query`) : le test « l'ancienne copie a disparu » lirait la copie protégée.
            kSecUseDataProtectionKeychain as String: false
        ]
    }

    private func addLegacy(_ key: String, service: String, account: String) throws {
        var query = legacyQuery(service: service, account: account)
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainAPIKeyStoreError.unexpectedStatus(status) }
    }

    private func removeLegacy(service: String, account: String) {
        SecItemDelete(legacyQuery(service: service, account: account) as CFDictionary)
    }

    private func readLegacy(service: String, account: String) throws -> String? {
        try read(legacyQuery(service: service, account: account))
    }

    private func readProtected(service: String, account: String) throws -> String? {
        var query = legacyQuery(service: service, account: account)
        query[kSecUseDataProtectionKeychain as String] = true
        return try read(query)
    }

    private func read(_ base: [String: Any]) throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }
#endif

    /// Suite `UserDefaults` neuve par test pour les drapeaux de migration (jamais la standard : sur
    /// Mac, `save` et `deleteAPIKey` y posent un drapeau par compte, dans les préférences réelles
    /// de l'app). Retenue pour être supprimée en fin de run (`TestDefaults`).
    private func freshFlags() -> String {
        let name = "triva.tests.keychainFlags.\(UUID().uuidString)"
        TestDefaults.track(suiteName: name)
        return name
    }

    /// Les tests écrivent en `.afterFirstUnlock` : le trousseau protégé refuse toute écriture
    /// `.whenUnlocked` écran verrouillé (-25308), et les tests Mac seraient alors ignorés sans bruit.
    /// Seul l'attribut d'accessibilité change ; le code de lecture, d'écriture, de migration et de
    /// suppression est celui de production.
    private func makeStore(service: String, flags: String? = nil) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(
            service: service,
            migrationFlagsSuite: flags ?? freshFlags(),
            accessibility: .afterFirstUnlock
        )
    }

    private func uniqueService() -> String {
        "com.benpodrojsky.Triva.tests.\(UUID().uuidString)"
    }
}
