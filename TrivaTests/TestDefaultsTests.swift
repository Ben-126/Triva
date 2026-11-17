//
//  TestDefaultsTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("TestDefaults (nettoyage des suites jetables)")
struct TestDefaultsTests {
    private func preferencesFile(named name: String) throws -> URL {
        let library = try #require(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        return library.appending(path: "Preferences/\(name).plist")
    }

    @Test("cleanUp() vide le domaine ET supprime le fichier de préférences laissé par removePersistentDomain")
    func cleanUpRemovesTheDomainAndItsFile() throws {
        let name = "test.testDefaults.\(UUID().uuidString)"
        let defaults = try #require(TestDefaults.suite(named: name))
        defaults.set("valeur", forKey: "cle")
        defaults.synchronize()
        let file = try preferencesFile(named: name)
        // Le fichier est écrit par cfprefsd, de façon asynchrone : on attend qu'il apparaisse.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(FileManager.default.fileExists(atPath: file.path), "le fichier de la suite doit exister avant le nettoyage")

        TestDefaults.cleanUp(only: [name])

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(defaults.string(forKey: "cle") == nil)
    }

    @Test("cleanUp(only:) ne touche pas aux suites des autres tests qui tournent en parallèle")
    func cleanUpLeavesOtherSuitesAlone() throws {
        let mine = "test.testDefaults.mine.\(UUID().uuidString)"
        let other = "test.testDefaults.other.\(UUID().uuidString)"
        let myDefaults = try #require(TestDefaults.suite(named: mine))
        let otherDefaults = try #require(TestDefaults.suite(named: other))
        myDefaults.set("a", forKey: "cle")
        otherDefaults.set("b", forKey: "cle")

        TestDefaults.cleanUp(only: [mine])

        #expect(myDefaults.string(forKey: "cle") == nil)
        #expect(otherDefaults.string(forKey: "cle") == "b")
    }

    @Test("Le motif de balayage n'accepte que des noms de suite de test (préfixe + UUID), jamais les préférences réelles")
    func staleSweepPatternIsExact() {
        let uuid = "0B6E2E3C-1111-4222-8333-444455556666"
        let accepted = [
            "test.customProviderStore.\(uuid).plist",
            "test.activeAIProviderResolver.mlx.\(uuid).plist",
            "AIEngineSettingsStoreTests.\(uuid).plist",
            "SearXNGReliabilityTests-\(uuid).plist",
            "triva.tests.keychainFlags.\(uuid).plist",
        ]
        let refused = [
            "com.benpodrojsky.Triva.plist",
            "TrivaPreviews.plist",
            "test.customProviderStore.plist",
            "test.customProviderStore.\(uuid).plist.lock",
            "com.apple.Safari.WebApp.\(uuid).plist",
            "MyAppTests.\(uuid).plist",
        ]
        for name in accepted { #expect(name.wholeMatch(of: TestDefaults.stalePattern) != nil, "\(name)") }
        for name in refused { #expect(name.wholeMatch(of: TestDefaults.stalePattern) == nil, "\(name)") }
    }
}
