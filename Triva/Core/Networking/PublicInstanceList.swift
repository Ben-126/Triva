//
//  PublicInstanceList.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

nonisolated enum PublicInstanceListError: Error, Sendable, Equatable {
    case resourceMissing
    case invalidFormat
}

/// Charge la liste statique d'instances SearXNG publiques depuis
/// `Resources/searxng-instances.json`, dans l'ordre de priorité à essayer.
///
/// `nonisolated` : logique pure sur des fichiers et des `URL`, appelée aussi bien depuis le main
/// actor (Réglages) que depuis une tâche de fond (rafraîchissement de l'annuaire).
nonisolated enum PublicInstanceList {
    static func load(bundle: Bundle = .main, resourceName: String = "searxng-instances") throws -> [URL] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw PublicInstanceListError.resourceMissing
        }

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(InstanceListFile.self, from: data)
        let urls = decoded.instances.compactMap { URL(string: $0) }

        guard !urls.isEmpty else {
            throw PublicInstanceListError.invalidFormat
        }

        return urls
    }

    /// Clé `UserDefaults` (passée en `-triva.uiTestNeutralInstances YES` au lancement) qui remplace la
    /// liste embarquée par `uiTestNeutralInstances`. Réservée aux tests UI, dont les captures, les
    /// vidéos d'échec et les arbres d'accessibilité finissent dans des `.xcresult` que l'on partage :
    /// le `searxng-instances.json` d'une machine de développement peut porter une instance
    /// personnelle, qui ne doit jamais s'y retrouver. Sans effet hors DEBUG.
    static let uiTestNeutralArgumentKey = "triva.uiTestNeutralInstances"

    /// Hôtes fictifs de la liste neutre : `.invalid` est réservé (RFC 2606), jamais résolu.
    static let uiTestNeutralInstances: [URL] = [
        "https://defaut-un.invalid",
        "https://defaut-deux.invalid",
    ].compactMap { URL(string: $0) }

    /// La liste embarquée telle que l'app la lit : `load`, sauf sous l'argument de lancement des tests
    /// UI (DEBUG seulement), qui la remplace par `uiTestNeutralInstances`.
    static func loadForApp(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        resourceName: String = "searxng-instances"
    ) throws -> [URL] {
        #if DEBUG
        if defaults.bool(forKey: uiTestNeutralArgumentKey) {
            return uiTestNeutralInstances
        }
        #endif
        return try load(bundle: bundle, resourceName: resourceName)
    }

    /// Liste embarquée PUIS instances rafraîchies depuis l'annuaire searx.space
    /// (`SearXNGDirectoryRefresher`). `FailoverManager` classe ensuite le tout par fiabilité mesurée.
    ///
    /// La liste embarquée reste en tête, dans son ordre : c'est la liste de référence (elle
    /// peut commencer par l'instance personnelle de l'utilisateur, qui doit rester prioritaire)
    /// et le seul contenu garanti hors ligne au premier lancement. Les instances de l'annuaire
    /// ne font que la compléter. Sans rafraîchissement (jamais fait, échec, hors ligne), le
    /// résultat est exactement `load`.
    ///
    /// - Throws: les mêmes erreurs que `load` : une liste embarquée illisible est un défaut
    ///   d'empaquetage qui doit rester visible, même si l'annuaire a des instances à proposer.
    static func loadMerged(
        bundle: Bundle = .main,
        resourceName: String = "searxng-instances",
        directoryStore: SearXNGDirectoryStore = .shared
    ) throws -> [URL] {
        merging(try load(bundle: bundle, resourceName: resourceName), with: directoryStore.refreshedInstances)
    }

    /// Ajoute à `base` les instances de `extras` qui n'y figurent pas déjà. Comparaison par
    /// `SearXNGInstanceAddress.comparisonKey` : `https://Searx.be/` et `https://searx.be` sont
    /// la même instance. L'ordre de `base` est conservé tel quel, doublons internes compris.
    static func merging(_ base: [URL], with extras: [URL]) -> [URL] {
        var known = Set(base.map(InstanceReliabilityStore.key(for:)))
        let additions = extras.filter { known.insert(InstanceReliabilityStore.key(for: $0)).inserted }
        return base + additions
    }

    private struct InstanceListFile: Decodable {
        let instances: [String]
    }
}
