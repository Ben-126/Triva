//
//  KeychainMigration.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Lance, une fois par processus, la copie des clés de l'ancien trousseau Mac vers le trousseau
/// protégé (voir `KeychainAPIKeyStore`) pour les deux services de clés de l'app : fournisseurs IA et
/// clés de recherche. Sans effet sur iOS/iPadOS, et jamais dans les tests unitaires, qui ne doivent
/// pas toucher au vrai trousseau de la machine.
///
/// La copie se fait hors du fil principal (`@concurrent`) : sur Mac, lire une entrée d'un ancien
/// trousseau peut afficher une invite d'autorisation, qui gèlerait l'écran si elle bloquait le fil
/// principal. Elle ne supprime jamais l'ancienne entrée.
@MainActor
enum KeychainMigration {
    private static var hasRun = false

    /// Services dont les clés sont migrées : fournisseurs IA (`KeychainAPIKeyStore` par défaut) et
    /// clés de recherche personnelles.
    static var services: [String] {
        ["com.benpodrojsky.Triva.cloudBYOK", SearchKeyStore.keychainService]
    }

    /// Migre tous les services une seule fois par lancement. Renvoie les comptes en échec (pour les
    /// tests et le diagnostic), jamais d'erreur affichée : une clé non copiée reste lisible dans
    /// l'ancien trousseau et sera retentée à la prochaine lecture.
    @discardableResult
    static func runOnce(isHostingTests: Bool = TrivaTestHost.isHostingUnitTests()) async -> [String] {
        guard !hasRun, !isHostingTests else { return [] }
        hasRun = true
        var failed: [String] = []
        for service in services {
            failed += await KeychainAPIKeyStore(service: service).migrateLegacyKeys()
        }
        return failed
    }
}
