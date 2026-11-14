//
//  TestDefaults.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Foundation

/// Suites `UserDefaults` jetables des tests, et leur nettoyage (mission C2, K9).
///
/// Les tests tournent HÉBERGÉS dans l'app Triva : une suite créée par un test écrit un fichier
/// `<nom>.plist` dans les préférences du conteneur de l'app (le même que celui de l'app de Ben).
/// `removePersistentDomain` ne supprime pas ce fichier, et un nom à UUID par test en laissait des
/// milliers. Toute suite de test passe donc par ici : le nom est retenu, puis, à la fin du processus
/// de test, le domaine est vidé ET son fichier supprimé.
///
/// Seuls les noms créés PAR ce processus sont nettoyés en fin de run : une autre exécution des tests
/// qui tourne en même temps (autre mission, autre `-derivedDataPath`) garde les siens.
///
/// LIMITE CONNUE : à la déconnexion du processus de test, `cfprefsd` réécrit parfois un fichier vide
/// (42 octets) pour un domaine qu'on vient de supprimer. Le nettoyage de fin de run ne suffit donc pas
/// toujours ; au démarrage du run suivant, `sweepStaleFiles()` supprime les fichiers de suite de test
/// laissés par les runs précédents (plus vieux que `staleAge`, jamais ceux d'un run en cours).
enum TestDefaults {
    /// Âge minimal d'un fichier pour être balayé au démarrage : bien plus long qu'un run, pour ne
    /// jamais toucher une suite qu'un autre run (parallèle) utilise.
    static let staleAge: TimeInterval = 30 * 60

    /// Motifs EXACTS des noms de suite créés par les tests de ce dépôt : un préfixe suivi d'un UUID.
    /// Rien d'autre n'est jamais supprimé (jamais les préférences réelles de l'app).
    static var stalePattern: Regex<AnyRegexOutput> {
        // Calculé et non stocké : `Regex` n'est pas `Sendable`.
        try! Regex(
        #"^(test\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.|triva\.tests\.keychainFlags\.|"#
        + #"(AIEngineSettingsStoreTests|TrivaSharedStoresTests|ChatViewModelTests|CustomInstanceStoreAutomaticTests|"#
        + #"DirectoryPersistenceToSectionTests)\.|(SearXNGReliabilityTests|PublicInstanceListNeutralTests)-)"#
        + #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist$"#
        )
    }

    /// Supprime les fichiers de suite de test devenus périmés. Appelé une fois, au premier usage.
    static func sweepStaleFiles(now: Date = .now) {
        guard let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appending(path: "Preferences", directoryHint: .isDirectory),
            let files = try? FileManager.default.contentsOfDirectory(
                at: preferences, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
        for file in files where file.lastPathComponent.wholeMatch(of: stalePattern) != nil {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > staleAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        init() {
            // Une seule fois par processus : ménage des runs précédents, puis nettoyage à la fin de celui-ci
            // (`exit()` exécute ce gestionnaire).
            TestDefaults.sweepStaleFiles()
            atexit { TestDefaults.cleanUp() }
        }

        func add(_ name: String) {
            lock.withLock {
                if !names.contains(name) { names.append(name) }
            }
        }

        func all() -> [String] {
            lock.withLock { names }
        }
    }

    private static let registry = Registry()

    /// Remplace `UserDefaults(suiteName:)` : même valeur (y compris `nil` pour un nom réservé), mais la
    /// suite sera supprimée en fin de processus.
    static func suite(named name: String) -> UserDefaults? {
        registry.add(name)
        return UserDefaults(suiteName: name)
    }

    /// Retient un nom de suite que le code testé ouvre lui-même (par exemple les drapeaux de
    /// migration de `KeychainAPIKeyStore`, qui reçoit un NOM et non l'objet).
    static func track(suiteName name: String) {
        registry.add(name)
    }

    /// Vide chaque domaine retenu et supprime son fichier de préférences. Appelé en fin de processus.
    ///
    /// `removePersistentDomain` laisse un fichier VIDE : c'est `cfprefsd` qui le réécrit, de façon
    /// asynchrone. Le supprimer tout de suite ne sert à rien, le démon le recrée juste après. On vide
    /// donc tous les domaines, on laisse au démon le temps d'écrire, on supprime les fichiers, puis on
    /// repasse une fois sur ceux qui seraient réapparus. Les noms restent retenus : le passage final, à la
    /// fin du processus, repasse sur TOUS (une écriture tardive du démon peut recréer un fichier).
    static func cleanUp() {
        let names = registry.all()
        guard !names.isEmpty else { return }
        let preferences = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Preferences", directoryHint: .isDirectory)
        for name in names {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        for pass in 0..<2 {
            Thread.sleep(forTimeInterval: pass == 0 ? 0.3 : 0.2)
            for name in names {
                if let file = preferences?.appending(path: "\(name).plist") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}
