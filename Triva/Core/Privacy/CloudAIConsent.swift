//
//  CloudAIConsent.swift
//  Triva
//
//  Created by ben podrojsky on 14/11/2026.
//

import Foundation

// Consentement explicite avant tout envoi à une IA cloud (mission C2, audit légal n° 2).
// Source : App Review Guidelines 5.1.2(i) — « clearly disclose where personal data will be
// shared with third parties, including with third-party AI, and obtain explicit permission
// before doing so ». Un accord par fournisseur, mémorisé avec la date et la version du texte.
//
// Trois étages, du plus bas au plus haut :
// 1. `CloudAIConsentStorage` : lecture/écriture pures dans `UserDefaults` (nonisolated).
// 2. `CloudAIConsentGate` : LA porte, `require()` lève `CloudAIConsentError.notGranted` avant
//    tout appel réseau. Les providers cloud (`CloudBYOKProvider`, `OpenAICompatibleProvider`,
//    `PerplexityAgentProvider`) et la recherche web du fournisseur (`CloudWebSearchProvider`)
//    l'appellent TOUS en premier geste, avant même de lire la clé.
// 3. `CloudAIConsentStore` : le store observable partagé (Réglages, feuille de consentement).

/// Ce qu'il faut pour savoir si l'envoi à un fournisseur est autorisé. `Sendable` et nonisolated :
/// lu depuis les providers, hors du main actor. La lecture est « vivante » (pas de copie) : un
/// accord retiré dans les Réglages vaut dès l'appel suivant.
nonisolated protocol CloudAIConsentChecking: Sendable {
    func isGranted(providerID: String) -> Bool
}

nonisolated enum CloudAIConsentError: Error, Sendable, Equatable {
    /// Aucun accord valide pour ce fournisseur : rien n'a été envoyé.
    case notGranted(providerID: String)
}

/// Un accord : quelle version du texte l'utilisateur a vue, et quand.
nonisolated struct CloudAIConsentRecord: Codable, Equatable, Sendable {
    let textVersion: Int
    let grantedAt: Date
}

/// Stockage pur des accords, dans un seul dictionnaire JSON de `UserDefaults`
/// (`providerID` → `CloudAIConsentRecord`). Jamais de clé API ici.
/// `@unchecked Sendable` : `UserDefaults` n'est pas annoté `Sendable` mais Apple documente ses lectures
/// et écritures comme thread-safe ; la struct n'a aucun autre état (deux `let`).
nonisolated struct CloudAIConsentStorage: CloudAIConsentChecking, @unchecked Sendable {
    static let defaultsKey = "legal.cloudAIConsents"

    /// Version du texte de consentement affiché (`CloudAIConsentText`). À AUGMENTER dès que la liste
    /// des données envoyées ou le texte change : tous les accords antérieurs sont alors invalides et
    /// l'écran est redemandé (audit § 5.5).
    /// Version 2 : règle des PDF protégés (Q3) précisée dans la liste des données envoyées.
    static let currentTextVersion = 2

    private let userDefaults: UserDefaults
    private let textVersion: Int

    init(userDefaults: UserDefaults = .standard, textVersion: Int = CloudAIConsentStorage.currentTextVersion) {
        self.userDefaults = userDefaults
        self.textVersion = textVersion
    }

    func record(providerID: String) -> CloudAIConsentRecord? {
        readAll()[providerID]
    }

    /// Accord présent ET donné pour la version courante du texte.
    func isGranted(providerID: String) -> Bool {
        record(providerID: providerID)?.textVersion == textVersion
    }

    func grant(providerID: String, at date: Date = .now) {
        var all = readAll()
        all[providerID] = CloudAIConsentRecord(textVersion: textVersion, grantedAt: date)
        write(all)
    }

    func revoke(providerID: String) {
        var all = readAll()
        guard all.removeValue(forKey: providerID) != nil else { return }
        write(all)
    }

    /// Fournisseurs dont l'accord est valide.
    func grantedProviderIDs() -> Set<String> {
        Set(readAll().filter { $0.value.textVersion == textVersion }.keys)
    }

    private func readAll() -> [String: CloudAIConsentRecord] {
        guard let data = userDefaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: CloudAIConsentRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func write(_ records: [String: CloudAIConsentRecord]) {
        if records.isEmpty {
            userDefaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            userDefaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// LA porte unique : tout appel réseau vers un fournisseur IA cloud commence par `require()`.
nonisolated struct CloudAIConsentGate: Sendable {
    let providerID: String
    let checker: any CloudAIConsentChecking

    init(providerID: String, checker: any CloudAIConsentChecking) {
        self.providerID = providerID
        self.checker = checker
    }

    func require() throws {
        guard checker.isGranted(providerID: providerID) else {
            throw CloudAIConsentError.notGranted(providerID: providerID)
        }
    }
}

/// Store observable PARTAGÉ (un seul pour toute l'app, voir `TrivaSharedStores`) : les Réglages
/// l'observent pour afficher l'état de l'accord, la feuille de consentement y écrit.
@Observable
final class CloudAIConsentStore {
    /// Le stockage nonisolated, à passer tel quel aux providers (`CloudAIConsentChecking`).
    @ObservationIgnored let storage: CloudAIConsentStorage
    /// Copie observée des fournisseurs autorisés ; réécrite à chaque changement.
    private(set) var grantedProviderIDs: Set<String>

    init(userDefaults: UserDefaults = .standard, textVersion: Int = CloudAIConsentStorage.currentTextVersion) {
        let storage = CloudAIConsentStorage(userDefaults: userDefaults, textVersion: textVersion)
        self.storage = storage
        self.grantedProviderIDs = storage.grantedProviderIDs()
    }

    func isGranted(providerID: String) -> Bool {
        grantedProviderIDs.contains(providerID)
    }

    func record(providerID: String) -> CloudAIConsentRecord? {
        guard isGranted(providerID: providerID) else { return nil }
        return storage.record(providerID: providerID)
    }

    func grant(providerID: String, at date: Date = .now) {
        storage.grant(providerID: providerID, at: date)
        grantedProviderIDs = storage.grantedProviderIDs()
    }

    func revoke(providerID: String) {
        storage.revoke(providerID: providerID)
        grantedProviderIDs = storage.grantedProviderIDs()
    }

    /// Réaligne la copie observée sur `UserDefaults` (une autre fenêtre ou un test a pu écrire).
    func reload() {
        grantedProviderIDs = storage.grantedProviderIDs()
    }
}
