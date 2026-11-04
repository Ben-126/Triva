//
//  CustomInstanceStore+Automatic.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation

/// Section « Ajoutées automatiquement » de Réglages > Recherche > Avancé : les
/// instances que l'annuaire searx.space ajoute à la liste de recherche.
///
/// Le masquage réutilise `hiddenDefaultInstances`, que
/// `SearXNGInstanceOverrides.visibleDefaults` applique déjà à l'annuaire : une
/// instance masquée reste masquée même si l'annuaire la propose encore, et
/// « Revenir à la liste par défaut » la fait revenir.
extension CustomInstanceStore {
    /// Instances que la recherche essaie en plus de `effectiveInstances`, dans
    /// l'ordre d'essai. Dérivée de `TrivaSharedStores.searXNGInstances`, la règle
    /// de la recherche elle-même : l'écran ne peut donc pas la contredire
    /// (notamment : toutes les instances par défaut masquées, aucune ici).
    var automaticInstances: [URL] {
        let knownKeys = Set((defaultInstances + overrides.addedURLs).compactMap(SearXNGInstanceAddress.comparisonKey(for:)))
        return TrivaSharedStores.searXNGInstances(
            bundled: defaultInstances,
            directory: directory.refreshedInstances,
            overrides: overrides
        )
        .filter { url in
            guard let key = SearXNGInstanceAddress.comparisonKey(for: url) else { return false }
            return !knownKeys.contains(key)
        }
    }

    /// Instances de l'annuaire masquées par l'utilisateur. Celles de la liste par
    /// défaut sont comptées à part (`hiddenDefaultCount`).
    var hiddenAutomaticCount: Int {
        let defaultKeys = Set(defaultInstances.compactMap(SearXNGInstanceAddress.comparisonKey(for:)))
        let hiddenKeys = Set(overrides.hiddenDefaultInstances.compactMap { stored in
            URL(string: stored).flatMap(SearXNGInstanceAddress.comparisonKey(for:))
        })
        let directoryKeys = Set(directory.refreshedInstances.compactMap(SearXNGInstanceAddress.comparisonKey(for:)))
        return directoryKeys.intersection(hiddenKeys).subtracting(defaultKeys).count
    }

    /// Tout ce que l'écran affiche et peut tester.
    var testableInstances: [URL] {
        effectiveInstances + automaticInstances
    }

    func isAutomatic(_ url: URL) -> Bool {
        automaticInstances.contains(url)
    }

    /// Une instance de l'annuaire peut être masquée tant qu'il en reste une autre
    /// à essayer (le cas limite : liste du bundle illisible, l'annuaire seul sert).
    /// Les autres suivent `canRemoveInstance` : masquer la dernière instance par
    /// défaut retirerait aussi tout l'annuaire, l'annuaire ne compte donc pas.
    func canRemove(_ url: URL) -> Bool {
        isAutomatic(url) ? testableInstances.count > 1 : canRemoveInstance
    }

    func hideAutomaticInstance(_ url: URL) throws {
        guard canRemove(url) else { throw CustomInstanceError.cannotRemoveLastInstance }
        apply(overrides.removing(url, defaults: defaultInstances + directory.refreshedInstances))
    }
}
