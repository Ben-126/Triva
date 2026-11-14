//
//  SearXNGAutomaticInstancesTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation
import Testing
@testable import Triva

private enum F {
    static let mine = URL(string: "https://mine.example")!
    static let publicA = URL(string: "https://public-a.example")!
    static let directoryA = URL(string: "https://annuaire-a.example")!
    static let directoryB = URL(string: "https://annuaire-b.example")!
    static let added = URL(string: "https://ajoutee.example")!
}

private actor RespondingClient: SearXNGSearching {
    private(set) var calledInstances: [URL] = []

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        calledInstances.append(instance)
        return SearXNGSearchResponse(results: [], suggestions: [])
    }
}

@MainActor
@Suite("CustomInstanceStore — Ajoutées automatiquement")
struct CustomInstanceStoreAutomaticTests {
    private func makeStore(
        defaults: [URL] = [F.mine, F.publicA],
        directory: [URL] = [F.directoryA, F.directoryB],
        client: any SearXNGSearching = RespondingClient()
    ) throws -> CustomInstanceStore {
        let directoryStore = SearXNGDirectoryStore()
        directoryStore.save(SearXNGDirectorySnapshot(instances: directory.map(\.absoluteString)))
        let suite = "CustomInstanceStoreAutomaticTests.\(UUID().uuidString)"
        let userDefaults = try #require(TestDefaults.suite(named: suite))
        userDefaults.removePersistentDomain(forName: suite)
        return CustomInstanceStore(
            defaultInstances: defaults,
            userDefaults: userDefaults,
            client: client,
            directory: directoryStore
        )
    }

    /// La liste de la recherche telle que la compose l'app.
    private func searchList(of store: CustomInstanceStore) -> [URL] {
        TrivaSharedStores.searXNGInstances(
            bundled: store.defaultInstances,
            directory: store.directory.refreshedInstances,
            overrides: store.overrides
        )
    }

    @Test("montre les instances de l'annuaire, sans celles déjà listées ailleurs")
    func listsOnlyDirectoryExtras() throws {
        let store = try makeStore(directory: [F.publicA, F.directoryA])
        #expect(store.automaticInstances == [F.directoryA])
        #expect(store.isAutomatic(F.directoryA))
        #expect(!store.isAutomatic(F.publicA))
    }

    @Test("annuaire vide : section vide, sans masquage ni erreur")
    func emptyDirectory() throws {
        let store = try makeStore(directory: [])
        #expect(store.automaticInstances.isEmpty)
        #expect(store.hiddenAutomaticCount == 0)
    }

    @Test("masquer une instance la retire de la recherche, individuellement")
    func hidingRemovesFromSearch() throws {
        let store = try makeStore()

        try store.remove(F.directoryA)

        #expect(store.automaticInstances == [F.directoryB])
        #expect(searchList(of: store) == [F.mine, F.publicA, F.directoryB])
        #expect(store.hiddenAutomaticCount == 1)
        #expect(store.hiddenDefaultCount == 0, "une instance de l'annuaire n'est pas une instance par défaut")
    }

    @Test("le masquage survit au redémarrage et « Revenir à la liste par défaut » l'annule")
    func hidingPersistsAndResets() throws {
        let directoryStore = SearXNGDirectoryStore()
        directoryStore.save(SearXNGDirectorySnapshot(instances: [F.directoryA.absoluteString]))
        let suite = "CustomInstanceStoreAutomaticTests.\(UUID().uuidString)"
        let userDefaults = try #require(TestDefaults.suite(named: suite))
        userDefaults.removePersistentDomain(forName: suite)
        let make = {
            CustomInstanceStore(defaultInstances: [F.mine], userDefaults: userDefaults, client: RespondingClient(), directory: directoryStore)
        }
        let store = make()
        try store.remove(F.directoryA)

        let reopened = make()
        #expect(reopened.automaticInstances.isEmpty)
        #expect(reopened.isCustomized)

        reopened.resetToDefaults()
        #expect(reopened.automaticInstances == [F.directoryA])
        userDefaults.removePersistentDomain(forName: suite)
    }

    /// Décision de Ben : l'annuaire n'est pas ajouté si tout est masqué.
    @Test("toutes les instances par défaut masquées : aucune instance automatique")
    func hidingEveryDefaultDropsAutomatic() throws {
        let store = try makeStore(defaults: [F.mine])
        let candidate = try store.candidate(from: F.added.absoluteString)
        try store.add(candidate)

        try store.remove(F.mine)

        #expect(store.overrides.hidesEveryDefault(of: store.defaultInstances))
        #expect(store.automaticInstances.isEmpty)
        #expect(searchList(of: store) == [F.added])
    }

    @Test("une instance ajoutée à la main, déjà dans l'annuaire, ne s'affiche qu'une fois")
    func addedInstanceLeavesTheSection() throws {
        let store = try makeStore()
        try store.add(try store.candidate(from: F.directoryA.absoluteString))

        #expect(store.customInstances == [F.directoryA])
        #expect(store.automaticInstances == [F.directoryB])

        try store.remove(F.directoryA)
        #expect(store.automaticInstances == [F.directoryA, F.directoryB], "retirer l'ajout rend l'instance à l'annuaire")
    }

    /// Bundle illisible : l'annuaire est la seule source, sa dernière instance ne
    /// peut pas être masquée (la recherche n'aurait plus aucune instance).
    @Test("liste du bundle illisible : garde la dernière instance de l'annuaire")
    func keepsLastInstanceWhenBundleUnreadable() throws {
        let store = try makeStore(defaults: [], directory: [F.directoryA, F.directoryB])

        #expect(store.canRemove(F.directoryA))
        try store.remove(F.directoryA)

        #expect(!store.canRemove(F.directoryB))
        #expect(throws: CustomInstanceError.cannotRemoveLastInstance) {
            try store.remove(F.directoryB)
        }
    }

    /// `canRemoveInstance` ne compte pas l'annuaire : masquer la dernière instance
    /// par défaut le retirerait aussi, et la recherche n'aurait plus rien.
    @Test("la dernière instance par défaut reste protégée malgré l'annuaire")
    func lastDefaultStaysProtected() throws {
        let store = try makeStore(defaults: [F.mine])
        #expect(!store.canRemove(F.mine))
        #expect(throws: CustomInstanceError.cannotRemoveLastInstance) {
            try store.remove(F.mine)
        }
    }

    @Test("les tests de connectivité couvrent les instances automatiques")
    func connectivityCoversAutomaticInstances() async throws {
        let client = RespondingClient()
        let store = try makeStore(defaults: [F.mine], directory: [F.directoryA], client: client)

        await store.testConnectivity(of: F.directoryA)
        #expect(await client.calledInstances == [F.directoryA])
        #expect(store.connectivity(for: F.directoryA) != nil)

        await store.testAllConnectivity()
        #expect(Set(await client.calledInstances) == [F.mine, F.directoryA])

        try store.remove(F.directoryA)
        #expect(store.connectivity(for: F.directoryA) == nil, "le résultat d'une instance masquée est purgé")
    }

    @Test("l'app : le store d'instances lit le même annuaire que la recherche")
    func liveStoreSharesTheDirectory() {
        #expect(TrivaSharedStores.live().searchInstances.directory === SearXNGDirectoryStore.shared)
    }
}

@Suite("TrivaTestHost")
struct TrivaTestHostTests {
    @Test("hors hôte de test : faux ; avec la variable d'xcodebuild : vrai")
    func readsTheEnvironment() {
        #expect(!TrivaTestHost.isHostingUnitTests(environment: [:]))
        #expect(TrivaTestHost.isHostingUnitTests(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    /// Le cas réel : ces tests tournent dans l'app hôte, donc l'entretien y est coupé.
    @Test("le processus de ces tests est bien reconnu")
    func detectsTheRealTestHost() {
        #expect(TrivaTestHost.isHostingUnitTests())
    }
}

@MainActor
@Suite("Annuaire persistant vers la section")
struct DirectoryPersistenceToSectionTests {
    @Test("instantané persisté, relu au lancement : visible dans la section")
    func persistedSnapshotReachesTheSection() throws {
        let suite = "DirectoryPersistenceToSectionTests.\(UUID().uuidString)"
        let userDefaults = try #require(TestDefaults.suite(named: suite))
        defer { userDefaults.removePersistentDomain(forName: suite) }
        let json = #"{"instances":["https://annuaire-un.example","https://annuaire-deux.example"],"nextAttemptAt":900000000}"#
        userDefaults.set(Data(json.utf8), forKey: SearXNGDirectoryStore.defaultsKey)

        let directory = SearXNGDirectoryStore(userDefaults: userDefaults)
        #expect(directory.refreshedInstances.count == 2)
        let store = CustomInstanceStore(
            defaultInstances: [URL(string: "https://mine.example")!],
            userDefaults: userDefaults,
            client: RespondingClient(),
            directory: directory
        )
        #expect(store.automaticInstances.count == 2)
    }
}
