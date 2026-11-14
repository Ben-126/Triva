//
//  KeychainAPIKeyStore.swift
//  Triva
//
//  Created by ben podrojsky on 31/08/2026.
//

import Foundation
import Security

/// Accès à une clé API BYOK (0.6), pour pouvoir injecter un faux magasin
/// dans les tests sans toucher au vrai Keychain de l'appareil.
protocol APIKeyStoring: Sendable {
    func apiKey(account: String) throws -> String?
    func save(apiKey: String, account: String) throws
    func deleteAPIKey(account: String) throws

    /// Lecture qui ne doit PAS tenir le fil principal. `apiKey(account:)` est isolée au
    /// main actor (comme tout ce protocole) : sur Mac, une invite d'autorisation du
    /// trousseau la bloque tant qu'elle est ouverte, et l'écran gèle avec elle.
    /// Les écrans qui lisent beaucoup de clés d'un coup (`CloudProviderModelPickerViewModel`)
    /// passent par celle-ci. Défaut : saute sur le main actor et appelle `apiKey(account:)`,
    /// ce qui garde le comportement des faux magasins de test ; `KeychainAPIKeyStore`
    /// la surcharge avec une vraie lecture hors main actor.
    nonisolated func readAPIKey(account: String) async throws -> String?
}

extension APIKeyStoring {
    nonisolated func readAPIKey(account: String) async throws -> String? {
        try await MainActor.run { try apiKey(account: account) }
    }
}

enum KeychainAPIKeyStoreError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Trousseau visé par une opération. Sur iOS/iPadOS il n'y en a qu'un (le trousseau protégé, seul
/// existant) ; sur Mac `.legacy` est l'ancien trousseau « fichier » que l'app utilisait jusqu'ici.
nonisolated private enum KeychainScope: Sendable {
    case primary
    case legacy
}

/// Stocke les clés API BYOK (Claude, puis d'autres fournisseurs cloud le cas
/// échéant) exclusivement en Keychain local — jamais en UserDefaults ni en
/// clair sur disque, conformément à la règle BYOK du projet (zéro serveur
/// intermédiaire, la clé ne doit jamais quitter l'appareil).
///
/// TROUSSEAU PROTÉGÉ SUR MAC (mission C2, décision de Ben du 2026-11-11) : sans
/// `kSecUseDataProtectionKeychain`, macOS range ces clés dans l'ancien trousseau « fichier »
/// (`login.keychain`), lié à la signature du binaire : chaque nouvelle version signée autrement fait
/// apparaître une invite d'autorisation qui, lue sur le fil principal, gèle l'écran. Le trousseau
/// protégé (le même que sur iOS) est rattaché à l'identifiant d'app et à l'équipe, sans invite.
///
/// MIGRATION, sans rien supprimer de l'ancien trousseau : au premier accès à un compte, si le
/// trousseau protégé ne l'a pas, la clé est COPIÉE depuis l'ancien. La migration elle-même laisse
/// l'ancienne entrée en place (règle de Ben : jamais de suppression de clé de son propre chef), donc
/// un retour à une version antérieure retrouve la sienne. Un drapeau par compte (`UserDefaults`)
/// retient que le compte est traité : sans lui, une clé supprimée dans Triva renaîtrait au prochain
/// accès depuis l'ancien trousseau. Le drapeau est posé par une copie réussie, par une recherche qui
/// ne trouve rien, par `save` et par `deleteAPIKey`. `migrateLegacyKeys()` copie toutes les clés d'un
/// coup au lancement, hors du fil principal.
///
/// SUPPRESSION DEMANDÉE PAR L'UTILISATEUR (revue R2-1) : quand il supprime ou remplace une clé, c'est
/// une demande explicite, et la copie héritée est supprimée AUSSI. Sinon une clé qu'il croit effacée
/// (peut-être compromise, révoquée chez le fournisseur) resterait dans `login.keychain`. Seul le
/// retour à une version antérieure est perdu pour ce compte, ce qui est voulu. Sans trousseau protégé
/// (cas actuel : aucun droit d'équipe), la clé n'a qu'une entrée, supprimée par le chemin normal.
///
/// DISPONIBILITÉ : le trousseau protégé exige un identifiant d'équipe dans les droits du binaire
/// (`application-identifier` ou `keychain-access-groups`), que seul un profil de provisionnement
/// apporte sur Mac. Sans lui, `SecItemAdd` répond `errSecMissingEntitlement` (-34018) — mais
/// `SecItemCopyMatching` répond « introuvable », ce qui ressemble à une clé absente. On sonde donc UNE
/// fois par processus (`isProtectedKeychainAvailable`) en écrivant puis retirant un élément de test,
/// et on choisit le trousseau en conséquence. Indisponible : tout reste dans l'ancien trousseau,
/// exactement comme avant ce changement, sans migration ni perte.
struct KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    /// Nom de la suite `UserDefaults` qui porte les drapeaux de migration, `nil` pour la suite
    /// standard. Un nom plutôt que l'objet : `UserDefaults` n'est pas `Sendable`, alors que ce
    /// magasin doit l'être et lire depuis n'importe quel contexte (`@concurrent`).
    private let migrationFlagsSuite: String?

    init(
        service: String = "com.benpodrojsky.Triva.cloudBYOK",
        migrationFlagsSuite: String? = nil
    ) {
        self.service = service
        self.migrationFlagsSuite = migrationFlagsSuite
    }

    func apiKey(account: String) throws -> String? {
        try Self.read(service: service, account: account, flags: migrationFlagsSuite)
    }

    /// Lecture réelle hors du main actor : `@concurrent` est indispensable, une
    /// fonction `nonisolated async` s'exécuterait sinon sur l'acteur de l'appelant
    /// (voir CLAUDE.md, section concurrence). Sert à `CloudProviderModelPickerViewModel`.
    @concurrent
    func readAPIKey(account: String) async throws -> String? {
        try Self.read(service: service, account: account, flags: migrationFlagsSuite)
    }

    /// Copie, hors du fil principal, toutes les clés de l'ancien trousseau Mac vers le trousseau
    /// protégé, au lancement. Sans effet sur iOS/iPadOS. Ne supprime rien. Renvoie les comptes dont
    /// la copie a échoué (vide si tout va bien) : une erreur sur un compte ne bloque pas les autres.
    @concurrent
    func migrateLegacyKeys() async -> [String] {
        #if os(macOS)
        guard Self.isProtectedKeychainAvailable else { return [] }
        var failed: [String] = []
        for account in Self.legacyAccounts(service: service) {
            do {
                _ = try Self.read(service: service, account: account, flags: migrationFlagsSuite)
            } catch {
                failed.append(account)
            }
        }
        return failed
        #else
        return []
        #endif
    }

    func save(apiKey: String, account: String) throws {
        let data = Data(apiKey.utf8)
        try Self.write(data, service: service, account: account, scope: Self.activeScope)
        // La clé remplacée ne doit pas survivre dans l'ancien trousseau. Au mieux : la nouvelle clé est
        // enregistrée, un échec ici ne doit pas faire croire à l'inverse (elle ne serait de toute façon
        // jamais relue, le drapeau ci-dessous l'écarte).
        // MAC SEULEMENT (VE2c) : sur iOS/iPadOS, la requête `.legacy` (sans
        // `kSecUseDataProtectionKeychain`) désigne LE MÊME trousseau que `.primary` : cette ligne y
        // effaçait la clé qu'on venait d'enregistrer (mesuré : round-trip rouge sur simulateur iOS).
        #if os(macOS)
        if Self.activeScope == .primary {
            try? Self.remove(service: service, account: account, scope: .legacy)
        }
        #endif
        Self.markHandled(service: service, account: account, flags: migrationFlagsSuite)
    }

    /// Supprime la clé des deux trousseaux (le protégé et, sur Mac, l'ancien). Une erreur est levée
    /// sans poser le drapeau : la clé encore présente quelque part reste lisible, et l'écran le dit.
    func deleteAPIKey(account: String) throws {
        try Self.remove(service: service, account: account, scope: Self.activeScope)
        // Mac seulement : sur iOS, `.legacy` est le même trousseau (voir `save`).
        #if os(macOS)
        if Self.activeScope == .primary {
            try Self.remove(service: service, account: account, scope: .legacy)
        }
        #endif
        Self.markHandled(service: service, account: account, flags: migrationFlagsSuite)
    }

    // MARK: - Lecture et migration

    /// Lit dans le trousseau protégé ; sinon, tant que le compte n'est pas traité, copie depuis
    /// l'ancien trousseau (Mac).
    nonisolated private static func read(service: String, account: String, flags: String?) throws -> String? {
        guard isProtectedKeychainAvailable else {
            return try copyAPIKey(service: service, account: account, scope: .legacy)
        }
        if let key = try copyAPIKey(service: service, account: account, scope: .primary) {
            return key
        }
        return try migrateFromLegacy(service: service, account: account, flags: flags)
    }

    nonisolated private static func migrateFromLegacy(
        service: String,
        account: String,
        flags: String?
    ) throws -> String? {
        #if os(macOS)
        guard !isHandled(service: service, account: account, flags: flags) else { return nil }
        let legacyKey = try copyAPIKey(service: service, account: account, scope: .legacy)
        if let legacyKey {
            // Copie au mieux : si elle échoue, la clé reste lisible dans l'ancien trousseau et la
            // prochaine lecture réessaiera (le drapeau n'est posé qu'après une copie réussie).
            guard (try? write(Data(legacyKey.utf8), service: service, account: account, scope: .primary)) != nil else {
                return legacyKey
            }
        }
        markHandled(service: service, account: account, flags: flags)
        return legacyKey
        #else
        return nil
        #endif
    }

    /// `SecItemCopyMatching` seul, sans état : appelable de n'importe quel contexte.
    nonisolated private static func copyAPIKey(
        service: String,
        account: String,
        scope: KeychainScope
    ) throws -> String? {
        var query = query(service: service, account: account, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    /// Comptes présents dans l'ancien trousseau pour ce service (attributs seulement : aucune
    /// invite, les secrets ne sont pas lus ici).
    nonisolated private static func legacyAccounts(service: String) -> [String] {
        var query = query(service: service, account: nil, scope: .legacy)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - Écriture

    nonisolated private static func write(
        _ data: Data,
        service: String,
        account: String,
        scope: KeychainScope
    ) throws {
        let query = query(service: service, account: account, scope: scope)

        let addStatus = SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(addStatus)
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(updateStatus)
        }
    }

    nonisolated private static func remove(service: String, account: String, scope: KeychainScope) throws {
        let status = SecItemDelete(query(service: service, account: account, scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    // MARK: - Requête et drapeaux

    nonisolated private static func query(
        service: String,
        account: String?,
        scope: KeychainScope
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        // Sur Mac, l'absence de cette clé désigne l'ancien trousseau ; sur iOS elle est le défaut.
        if scope == .primary {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Trousseau où se font lectures et écritures : le protégé s'il est disponible, sinon l'ancien.
    nonisolated private static var activeScope: KeychainScope {
        isProtectedKeychainAvailable ? .primary : .legacy
    }

    /// Vrai si le binaire peut utiliser le trousseau protégé (toujours vrai sur iOS/iPadOS). Sondé
    /// une seule fois par processus : voir « DISPONIBILITÉ » en tête de type.
    nonisolated static let isProtectedKeychainAvailable: Bool = {
        #if os(macOS)
        let probe = query(service: "com.benpodrojsky.Triva.keychainProbe", account: "probe", scope: .primary)
        let status = SecItemAdd(probe.merging([kSecValueData as String: Data("probe".utf8)]) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return false }
        SecItemDelete(probe as CFDictionary)
        return true
        #else
        return true
        #endif
    }()

    nonisolated private static func flagKey(service: String, account: String) -> String {
        "triva.keychainMigrated.\(service).\(account)"
    }

    nonisolated private static func defaults(_ suite: String?) -> UserDefaults {
        suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    nonisolated private static func isHandled(service: String, account: String, flags: String?) -> Bool {
        defaults(flags).bool(forKey: flagKey(service: service, account: account))
    }

    nonisolated private static func markHandled(service: String, account: String, flags: String?) {
        defaults(flags).set(true, forKey: flagKey(service: service, account: account))
    }
}
