//
//  InstanceAutoUpdatePolicy.swift
//  Triva
//
//  Mission C3 (audit légal, constat 20 ; M13).
//

import Foundation

/// Réglage « Mettre à jour la liste automatiquement » (Réglages > Avancé), ACTIVÉ par défaut.
///
/// Désactivé, il coupe À LA FOIS les deux choses que Triva fait seul au premier plan, et qui
/// exposent l'adresse IP de l'appareil à des tiers sans action de l'utilisateur :
/// 1. le téléchargement de l'annuaire searx.space (`SearXNGDirectoryRefresher`) ;
/// 2. la re-sonde des instances médiocres avec la recherche « test » (`FailoverManager.retestExpiredInstances`).
/// Les deux vivent dans un même passage (`SearXNGMaintenance.runPass`) : le garde se pose donc
/// UNE fois, à l'entrée du passage. Désactivé, Triva garde la dernière liste connue (la liste du
/// bundle, plus le dernier annuaire déjà téléchargé et mis en cache : `searchDirectory` est lu par
/// `searXNGInstances` sans réseau).
nonisolated enum InstanceAutoUpdatePolicy {
    /// Clé `UserDefaults` / `@AppStorage` de l'interrupteur.
    static let defaultsKey = "searxng.autoUpdate.enabled"
    /// Valeur quand la clé n'a jamais été écrite. Unique source du défaut (l'interrupteur
    /// `@AppStorage` l'utilise aussi).
    static let enabledByDefault = true

    /// Évalué à chaque passage au premier plan : pris en compte sans relancer l'app.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? enabledByDefault
    }
}

/// Textes du réglage (`textes/ecrans.md`, section F).
nonisolated enum InstanceAutoUpdateText {
    // Validé par Ben le 2026-11-18 (texte légal)
    static let toggle = "Mettre à jour la liste automatiquement"
    static let footer = "Quand tu ouvres Triva, l'app télécharge la liste des instances publiques sur searx.space (au plus une fois par jour) et teste quelques instances avec la recherche «\u{00A0}test\u{00A0}». Aucune de tes questions n'est envoyée, mais ces sites voient l'adresse IP de ton appareil. Désactivé, Triva garde la dernière liste connue."
}
