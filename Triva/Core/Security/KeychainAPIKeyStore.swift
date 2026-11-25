//
//  KeychainAPIKeyStore.swift
//  Triva
//
//  Created by ben podrojsky on 31/08/2026.
//

import Foundation
import os
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
nonisolated enum KeychainScope: Sendable {
    case primary
    case legacy
}

/// Quand une entrée du trousseau protégé se lit. Les vraies clés restent `.whenUnlocked` ; les tests
/// passent en `.afterFirstUnlock` pour pouvoir tourner aussi écran verrouillé (le trousseau
/// protégé refuse alors toute écriture `.whenUnlocked`, voir `ProtectedKeychainState`).
nonisolated enum KeychainAccessibility: Sendable {
    case whenUnlocked
    case afterFirstUnlock

    var attribute: String {
        switch self {
        case .whenUnlocked: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        }
    }
}

/// Résultat du sondage du trousseau protégé (Mac). `locked` n'est JAMAIS retenu : l'écran
/// verrouillé est un état passager, pas une propriété du binaire.
nonisolated enum ProtectedKeychainState: Sendable, Equatable {
    /// Le binaire peut écrire dans le trousseau protégé.
    case available
    /// Le binaire ne peut pas l'utiliser (droit d'équipe absent : `errSecMissingEntitlement`…).
    case unavailable
    /// Droits en règle, mais le trousseau est verrouillé à cet instant (`errSecInteractionNotAllowed`,
    /// -25308) : on ne sait pas ENCORE, et surtout on ne retombe pas sur l'ancien trousseau.
    case locked

    /// Classe le statut de l'ajout d'un élément de sonde.
    static func classify(_ status: OSStatus) -> ProtectedKeychainState {
        switch status {
        case errSecSuccess, errSecDuplicateItem: .available
        case errSecInteractionNotAllowed: .locked
        default: .unavailable
        }
    }
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
/// MIGRATION : au premier accès à un compte, si le trousseau protégé ne l'a pas, la clé est COPIÉE
/// depuis l'ancien, puis l'ancienne entrée est SUPPRIMÉE (décision de Ben du 2026-11-14, mission C6 :
/// une clé ne doit pas rester en double dans `login.keychain` une fois migrée). La suppression n'a
/// lieu qu'après avoir RELU la copie dans le trousseau protégé et constaté qu'elle est identique : en
/// cas de doute (écriture ou relecture en échec), l'ancienne entrée reste, et la clé reste lisible.
/// Seul le retour à une version antérieure perd alors la clé de ce compte. Un drapeau par compte (`UserDefaults`)
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
/// `SecItemCopyMatching` répond « introuvable », ce qui ressemble à une clé absente. On sonde donc
/// par un ajout/retrait d'élément de test (`protectedKeychainState`) et on choisit le trousseau en
/// conséquence. Indisponible : tout reste dans l'ancien trousseau, exactement comme avant ce
/// changement, sans migration ni perte. Écran verrouillé, le sondage répond -25308 : c'est « verrouillé »,
/// PAS « indisponible » (état non retenu, les opérations échouent franchement au lieu de lire l'ancien
/// trousseau, où la clé n'est plus).
///
/// DEUX TROUSSEAUX, UNE REQUÊTE (mission Z, 2026-11-25) : sur Mac, une requête sans
/// `kSecUseDataProtectionKeychain` lit et SUPPRIME dans les deux trousseaux. Les requêtes `.legacy`
/// portent donc `kSecUseDataProtectionKeychain = false` (voir `query`). Avant ce correctif, sur un Mac
/// où le trousseau protégé fonctionnait, `save` effaçait la clé qu'il venait d'écrire et la migration
/// effaçait sa propre copie : la clé disparaissait aussitôt.
struct KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    /// Nom de la suite `UserDefaults` qui porte les drapeaux de migration, `nil` pour la suite
    /// standard. Un nom plutôt que l'objet : `UserDefaults` n'est pas `Sendable`, alors que ce
    /// magasin doit l'être et lire depuis n'importe quel contexte (`@concurrent`).
    private let migrationFlagsSuite: String?
    /// Lisible par les tests : la valeur de production (`.whenUnlocked`) est épinglée par un test.
    let accessibility: KeychainAccessibility

    init(
        service: String = "com.benpodrojsky.Triva.cloudBYOK",
        migrationFlagsSuite: String? = nil,
        accessibility: KeychainAccessibility = .whenUnlocked
    ) {
        self.service = service
        self.migrationFlagsSuite = migrationFlagsSuite
        self.accessibility = accessibility
    }

    /// Ce qu'une opération doit savoir du magasin (hors compte). Regroupé pour les fonctions
    /// statiques `nonisolated`, qui ne peuvent pas lire `self`.
    nonisolated struct Target: Sendable {
        let service: String
        let flags: String?
        let accessible: String
    }

    nonisolated private var target: Target {
        Target(service: service, flags: migrationFlagsSuite, accessible: accessibility.attribute)
    }

    func apiKey(account: String) throws -> String? {
        try Self.read(target, account: account)
    }

    /// Lecture réelle hors du main actor : `@concurrent` est indispensable, une
    /// fonction `nonisolated async` s'exécuterait sinon sur l'acteur de l'appelant
    /// (voir CLAUDE.md, section concurrence). Sert à `CloudProviderModelPickerViewModel`.
    @concurrent
    func readAPIKey(account: String) async throws -> String? {
        try Self.read(target, account: account)
    }

    /// Copie, hors du fil principal, toutes les clés de l'ancien trousseau Mac vers le trousseau
    /// protégé, au lancement. Sans effet sur iOS/iPadOS. Renvoie les comptes dont la copie a échoué
    /// (vide si tout va bien) : une erreur sur un compte ne bloque pas les autres.
    @concurrent
    func migrateLegacyKeys() async -> [String] {
        #if os(macOS)
        let target = self.target
        guard Self.isProtectedKeychainAvailable else { return [] }
        var failed: [String] = []
        for account in Self.legacyAccounts(target) {
            do {
                _ = try Self.read(target, account: account)
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
        let target = self.target
        let data = Data(apiKey.utf8)
        try Self.write(data, target, account: account, scope: Self.activeScope)
        // La clé remplacée ne doit pas survivre dans l'ancien trousseau. Au mieux : la nouvelle clé est
        // enregistrée, un échec ici ne doit pas faire croire à l'inverse (elle ne serait de toute façon
        // jamais relue, le drapeau ci-dessous l'écarte).
        // MAC SEULEMENT (VE2c) : sur iOS/iPadOS, la requête `.legacy` désigne LE MÊME trousseau que
        // `.primary` : cette ligne y effaçait la clé qu'on venait d'enregistrer (mesuré : round-trip
        // rouge sur simulateur iOS).
        #if os(macOS)
        if Self.activeScope == .primary {
            try? Self.remove(target, account: account, scope: .legacy)
        }
        #endif
        Self.markHandled(target, account: account)
    }

    /// Supprime la clé des deux trousseaux (le protégé et, sur Mac, l'ancien). Une erreur est levée
    /// sans poser le drapeau : la clé encore présente quelque part reste lisible, et l'écran le dit.
    func deleteAPIKey(account: String) throws {
        let target = self.target
        try Self.remove(target, account: account, scope: Self.activeScope)
        // Mac seulement : sur iOS, `.legacy` est le même trousseau (voir `save`).
        #if os(macOS)
        if Self.activeScope == .primary {
            try Self.remove(target, account: account, scope: .legacy)
        }
        #endif
        Self.markHandled(target, account: account)
    }

    // MARK: - Lecture et migration

    /// Lit dans le trousseau protégé ; sinon, tant que le compte n'est pas traité, copie depuis
    /// l'ancien trousseau (Mac).
    nonisolated private static func read(_ target: Target, account: String) throws -> String? {
        guard isProtectedKeychainAvailable else {
            return try copyAPIKey(target, account: account, scope: .legacy)
        }
        if let key = try copyAPIKey(target, account: account, scope: .primary) {
            return key
        }
        return try migrateFromLegacy(target, account: account)
    }

    nonisolated private static func migrateFromLegacy(_ target: Target, account: String) throws -> String? {
        #if os(macOS)
        guard !isHandled(target, account: account) else { return nil }
        let legacyKey = try copyAPIKey(target, account: account, scope: .legacy)
        if let legacyKey {
            // Copie au mieux : si elle échoue, la clé reste lisible dans l'ancien trousseau et la
            // prochaine lecture réessaiera (le drapeau n'est posé qu'après une copie réussie).
            guard (try? write(Data(legacyKey.utf8), target, account: account, scope: .primary)) != nil else {
                return legacyKey
            }
            // Suppression de l'ancienne entrée SEULEMENT si la copie est relue à l'identique. Au mieux :
            // un échec ici laisse un doublon inoffensif (le drapeau ci-dessous l'écarte des lectures).
            if (try? copyAPIKey(target, account: account, scope: .primary)) == legacyKey {
                try? remove(target, account: account, scope: .legacy)
            }
        }
        markHandled(target, account: account)
        return legacyKey
        #else
        return nil
        #endif
    }

    /// `SecItemCopyMatching` seul, sans état : appelable de n'importe quel contexte.
    nonisolated private static func copyAPIKey(
        _ target: Target,
        account: String,
        scope: KeychainScope
    ) throws -> String? {
        var query = query(target, account: account, scope: scope)
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
            throw failure("lecture \(scope)", status)
        }
    }

    /// Journalise le seul code d'erreur (jamais de clé, de compte ni de service) et le renvoie.
    nonisolated private static func failure(_ operation: String, _ status: OSStatus) -> KeychainAPIKeyStoreError {
        logger.error("Trousseau, \(operation, privacy: .public) refusée : OSStatus \(status, privacy: .public)")
        return .unexpectedStatus(status)
    }

    /// Comptes présents dans l'ancien trousseau pour ce service (attributs seulement : aucune
    /// invite, les secrets ne sont pas lus ici).
    nonisolated private static func legacyAccounts(_ target: Target) -> [String] {
        var query = query(target, account: nil, scope: .legacy)
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
        _ target: Target,
        account: String,
        scope: KeychainScope
    ) throws {
        let query = query(target, account: account, scope: scope)

        let addStatus = SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw failure("écriture \(scope)", addStatus)
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw failure("mise à jour \(scope)", updateStatus)
        }
    }

    nonisolated private static func remove(_ target: Target, account: String, scope: KeychainScope) throws {
        let status = SecItemDelete(query(target, account: account, scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure("suppression \(scope)", status)
        }
    }

    // MARK: - Requête et drapeaux

    nonisolated static func query(
        _ target: Target,
        account: String?,
        scope: KeychainScope
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: target.service
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        switch scope {
        case .primary:
            query[kSecAttrAccessible as String] = target.accessible
            query[kSecUseDataProtectionKeychain as String] = true
        case .legacy:
            // PIÈGE MAC (mission Z, prouvé par essai le 2026-11-25) : SANS cette clé, une lecture ou une
            // suppression vise les DEUX trousseaux, protégé compris. `remove(.legacy)` effaçait donc la
            // clé qu'on venait d'écrire dans le protégé (`save`, migration), et la lecture « ancienne »
            // la retrouvait. `false` borne l'opération au trousseau « fichier ». `kSecAttrAccessible`
            // n'existe que pour le protégé : absent ici.
            query[kSecUseDataProtectionKeychain as String] = false
        }
        return query
    }

    /// Trousseau où se font lectures et écritures : le protégé s'il est disponible, sinon l'ancien.
    nonisolated private static var activeScope: KeychainScope {
        isProtectedKeychainAvailable ? .primary : .legacy
    }

    /// Vrai si le binaire a le droit d'utiliser le trousseau protégé (toujours vrai sur iOS/iPadOS),
    /// qu'il soit verrouillé ou non : un trousseau verrouillé fait ÉCHOUER les opérations
    /// (`unexpectedStatus(-25308)`), il ne renvoie pas vers l'ancien trousseau, où la clé n'est plus.
    nonisolated static var isProtectedKeychainAvailable: Bool {
        protectedKeychainState != .unavailable
    }

    /// Vrai si le trousseau protégé accepte des écritures MAINTENANT (les tests Mac en dépendent).
    nonisolated static var isProtectedKeychainUsableNow: Bool {
        protectedKeychainState == .available
    }

    /// Dernier statut brut du sondage (diagnostic des tests), `nil` tant qu'il n'a pas eu lieu.
    nonisolated static var lastProbeStatus: OSStatus? {
        probeStatus.withLock { $0 }
    }

    nonisolated private static let probeCache = OSAllocatedUnfairLock<ProtectedKeychainState?>(initialState: nil)
    nonisolated private static let probeStatus = OSAllocatedUnfairLock<OSStatus?>(initialState: nil)
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "Keychain"
    )

    /// État du trousseau protégé. Sondé par un ajout/retrait d'élément de test. Un résultat DÉFINITIF
    /// (`available`, `unavailable`) est retenu pour le processus ; `locked` ne l'est pas : avant ce
    /// correctif un sondage fait écran verrouillé (-25308) classait le trousseau « indisponible » pour
    /// toute la vie du processus, et les lectures retombaient sur l'ancien trousseau, vide.
    nonisolated static var protectedKeychainState: ProtectedKeychainState {
        #if os(macOS)
        if let cached = probeCache.withLock({ $0 }) { return cached }
        let state = probeProtectedKeychain()
        if state != .locked { probeCache.withLock { $0 = state } }
        return state
        #else
        return .available
        #endif
    }

    #if os(macOS)
    nonisolated private static func probeProtectedKeychain() -> ProtectedKeychainState {
        // `afterFirstUnlock` : le sondage ne mesure que le DROIT d'utiliser le trousseau protégé, pas
        // l'état de l'écran ; en `whenUnlocked` il échouerait à chaque verrouillage.
        let probe = query(
            Target(service: "com.benpodrojsky.Triva.keychainProbe", flags: nil, accessible: KeychainAccessibility.afterFirstUnlock.attribute),
            account: "probe",
            scope: .primary
        )
        let status = SecItemAdd(probe.merging([kSecValueData as String: Data("probe".utf8)]) { _, new in new } as CFDictionary, nil)
        probeStatus.withLock { $0 = status }
        let state = ProtectedKeychainState.classify(status)
        if state == .available { SecItemDelete(probe as CFDictionary) }
        logger.notice("Sondage du trousseau protégé : OSStatus \(status, privacy: .public), état \(String(describing: state), privacy: .public)")
        return state
    }
    #endif

    nonisolated private static func flagKey(_ target: Target, account: String) -> String {
        "triva.keychainMigrated.\(target.service).\(account)"
    }

    nonisolated private static func defaults(_ suite: String?) -> UserDefaults {
        suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    nonisolated private static func isHandled(_ target: Target, account: String) -> Bool {
        defaults(target.flags).bool(forKey: flagKey(target, account: account))
    }

    nonisolated private static func markHandled(_ target: Target, account: String) {
        defaults(target.flags).set(true, forKey: flagKey(target, account: account))
    }
}
