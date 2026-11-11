//
//  PublicInstanceListTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Écrit un fichier JSON dans un dossier temporaire et retourne un `Bundle`
/// pointant vers ce dossier, pour simuler `Bundle.main` sans dépendre du
/// vrai bundle de l'app.
private func makeBundle(fileName: String = "searxng-instances", json: String?) throws -> Bundle {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PublicInstanceListTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    if let json {
        let fileURL = directory.appendingPathComponent("\(fileName).json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    return try #require(Bundle(path: directory.path))
}

/// Supprime le dossier temporaire créé par `makeBundle`. Sans cela, chaque
/// exécution laissait 9 dossiers `PublicInstanceListTests-<UUID>` dans le
/// dossier temporaire (54 constatés dans celui de l'app Mac par la mission Q2).
/// Appelé via `defer` : le nettoyage a lieu aussi quand un `#expect` ou un
/// `throw` interrompt le test. L'échec de suppression est ignoré (`try?`) :
/// un reste dans le dossier temporaire ne doit pas faire échouer un test.
private func removeBundle(_ bundle: Bundle) {
    try? FileManager.default.removeItem(at: bundle.bundleURL)
}

@MainActor
@Suite("PublicInstanceList")
struct PublicInstanceListTests {
    @Test("Charge une liste valide d'instances dans l'ordre du fichier")
    func loadsValidInstanceList() throws {
        let bundle = try makeBundle(json: """
        { "instances": ["https://searx.example.org", "https://searx2.example.org"] }
        """)
        defer { removeBundle(bundle) }

        let urls = try PublicInstanceList.load(bundle: bundle)

        #expect(urls == [
            URL(string: "https://searx.example.org")!,
            URL(string: "https://searx2.example.org")!
        ])
    }

    @Test("Lève resourceMissing quand le fichier .json est absent du bundle")
    func throwsResourceMissingWhenFileAbsent() throws {
        let bundle = try makeBundle(json: nil)
        defer { removeBundle(bundle) }

        #expect(throws: PublicInstanceListError.resourceMissing) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Lève invalidFormat quand le JSON est mal formé")
    func throwsInvalidFormatWhenJSONMalformed() throws {
        let bundle = try makeBundle(json: "{ ceci n'est pas du JSON valide")
        defer { removeBundle(bundle) }

        #expect(throws: (any Error).self) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Lève invalidFormat quand la liste d'instances est vide")
    func throwsInvalidFormatWhenInstancesEmpty() throws {
        let bundle = try makeBundle(json: #"{ "instances": [] }"#)
        defer { removeBundle(bundle) }

        #expect(throws: PublicInstanceListError.invalidFormat) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Lève invalidFormat quand toutes les URLs sont invalides")
    func throwsInvalidFormatWhenAllURLsInvalid() throws {
        // Une chaîne vide ne produit pas d'URL valide : compactMap doit tout filtrer.
        let bundle = try makeBundle(json: #"{ "instances": [""] }"#)
        defer { removeBundle(bundle) }

        #expect(throws: PublicInstanceListError.invalidFormat) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Filtre les URLs invalides tout en gardant les valides (compactMap)")
    func filtersInvalidURLsButKeepsValidOnes() throws {
        let bundle = try makeBundle(json: #"{ "instances": ["", "https://searx.example.org"] }"#)
        defer { removeBundle(bundle) }

        let urls = try PublicInstanceList.load(bundle: bundle)

        #expect(urls == [URL(string: "https://searx.example.org")!])
    }

    // MARK: Fusion avec l'annuaire rafraîchi

    @Test("merging : la liste embarquée reste en tête, dans son ordre, les nouvelles s'ajoutent")
    func mergingKeepsBaseFirst() {
        let base = [URL(string: "https://perso.example.org")!, URL(string: "https://a.example.org")!]
        let extras = [URL(string: "https://b.example.org")!, URL(string: "https://c.example.org")!]

        #expect(PublicInstanceList.merging(base, with: extras) == base + extras)
    }

    @Test("merging : une instance déjà présente (casse, barre finale) n'est pas ajoutée deux fois")
    func mergingDeduplicatesEquivalentAddresses() {
        let base = [URL(string: "https://searx.be")!]
        let extras = [URL(string: "https://Searx.be/")!, URL(string: "https://neuve.example.org")!]

        #expect(PublicInstanceList.merging(base, with: extras) == [
            URL(string: "https://searx.be")!,
            URL(string: "https://neuve.example.org")!
        ])
    }

    @Test("merging : sans instance rafraîchie, le résultat est la liste embarquée telle quelle")
    func mergingWithoutExtrasIsIdentity() {
        let base = [URL(string: "https://a.example.org")!, URL(string: "https://b.example.org")!]

        #expect(PublicInstanceList.merging(base, with: []) == base)
    }

    @Test("loadMerged : liste embarquée puis instances de l'annuaire persistées")
    func loadMergedAppendsDirectoryInstances() throws {
        let bundle = try makeBundle(json: #"{ "instances": ["https://base.example.org"] }"#)
        defer { removeBundle(bundle) }
        let store = SearXNGDirectoryStore()
        store.save(SearXNGDirectorySnapshot(instances: ["https://annuaire.example.org"]))

        let urls = try PublicInstanceList.loadMerged(bundle: bundle, directoryStore: store)

        #expect(urls == [URL(string: "https://base.example.org")!, URL(string: "https://annuaire.example.org")!])
    }

    @Test("loadMerged : sans rafraîchissement, le résultat est exactement load")
    func loadMergedWithoutRefreshEqualsLoad() throws {
        let bundle = try makeBundle(json: #"{ "instances": ["https://base.example.org"] }"#)
        defer { removeBundle(bundle) }

        let merged = try PublicInstanceList.loadMerged(bundle: bundle, directoryStore: SearXNGDirectoryStore())

        #expect(merged == (try PublicInstanceList.load(bundle: bundle)))
    }

    @Test("loadMerged : une liste embarquée illisible reste une erreur, même si l'annuaire a des instances")
    func loadMergedPropagatesBundleErrors() throws {
        let bundle = try makeBundle(json: nil)
        defer { removeBundle(bundle) }
        let store = SearXNGDirectoryStore()
        store.save(SearXNGDirectorySnapshot(instances: ["https://annuaire.example.org"]))

        #expect(throws: PublicInstanceListError.resourceMissing) {
            try PublicInstanceList.loadMerged(bundle: bundle, directoryStore: store)
        }
    }

    @Test("makeBundle + removeBundle : le dossier temporaire disparaît en fin de test")
    func removeBundleDeletesTheTemporaryDirectory() throws {
        let bundle = try makeBundle(json: #"{ "instances": ["https://base.example.org"] }"#)
        let directory = bundle.bundleURL
        #expect(FileManager.default.fileExists(atPath: directory.path))

        removeBundle(bundle)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
