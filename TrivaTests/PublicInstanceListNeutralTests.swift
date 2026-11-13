//
//  PublicInstanceListNeutralTests.swift
//  TrivaTests
//
//  Liste neutre des tests UI (mission E2x2) : les captures et vidéos d'échec des tests UI ne
//  doivent jamais montrer la liste embarquée d'une machine de développement.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("PublicInstanceList : liste neutre des tests UI")
struct PublicInstanceListNeutralTests {
    private func makeBundle(json: String) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicInstanceListNeutralTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(to: directory.appendingPathComponent("searxng-instances.json"), atomically: true, encoding: .utf8)
        return try #require(Bundle(path: directory.path))
    }

    private func makeDefaults(neutral: Bool) throws -> (UserDefaults, String) {
        let name = "PublicInstanceListNeutralTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(neutral, forKey: PublicInstanceList.uiTestNeutralArgumentKey)
        return (defaults, name)
    }

    @Test("Sans l'argument, loadForApp lit la liste embarquée")
    func readsTheBundleWithoutTheArgument() throws {
        let bundle = try makeBundle(json: #"{ "instances": ["https://reelle.example.org"] }"#)
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let (defaults, suite) = try makeDefaults(neutral: false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let urls = try PublicInstanceList.loadForApp(defaults: defaults, bundle: bundle)

        #expect(urls == [URL(string: "https://reelle.example.org")!])
    }

    #if DEBUG
    @Test("Avec l'argument, loadForApp ignore la liste embarquée et rend des hôtes .invalid")
    func replacesTheBundleWithNeutralHosts() throws {
        let bundle = try makeBundle(json: #"{ "instances": ["https://reelle.example.org"] }"#)
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let (defaults, suite) = try makeDefaults(neutral: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        let urls = try PublicInstanceList.loadForApp(defaults: defaults, bundle: bundle)

        #expect(urls == PublicInstanceList.uiTestNeutralInstances)
        #expect(!urls.isEmpty)
        #expect(urls.allSatisfy { $0.host()?.hasSuffix(".invalid") == true })
    }

    @Test("Avec l'argument, un bundle illisible ne fait pas échouer la liste neutre")
    func neutralListDoesNotNeedTheBundle() throws {
        let bundle = try makeBundle(json: "pas du JSON")
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let (defaults, suite) = try makeDefaults(neutral: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(try PublicInstanceList.loadForApp(defaults: defaults, bundle: bundle) == PublicInstanceList.uiTestNeutralInstances)
    }
    #endif
}
