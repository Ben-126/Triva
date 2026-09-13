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

@Suite("PublicInstanceList")
struct PublicInstanceListTests {
    @Test("Charge une liste valide d'instances dans l'ordre du fichier")
    func loadsValidInstanceList() throws {
        let bundle = try makeBundle(json: """
        { "instances": ["https://searx.example.org", "https://searx2.example.org"] }
        """)

        let urls = try PublicInstanceList.load(bundle: bundle)

        #expect(urls == [
            URL(string: "https://searx.example.org")!,
            URL(string: "https://searx2.example.org")!
        ])
    }

    @Test("Lève resourceMissing quand le fichier .json est absent du bundle")
    func throwsResourceMissingWhenFileAbsent() throws {
        let bundle = try makeBundle(json: nil)

        #expect(throws: PublicInstanceListError.resourceMissing) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Lève invalidFormat quand le JSON est mal formé")
    func throwsInvalidFormatWhenJSONMalformed() throws {
        let bundle = try makeBundle(json: "{ ceci n'est pas du JSON valide")

        #expect(throws: (any Error).self) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Lève invalidFormat quand la liste d'instances est vide")
    func throwsInvalidFormatWhenInstancesEmpty() throws {
        let bundle = try makeBundle(json: #"{ "instances": [] }"#)

        #expect(throws: PublicInstanceListError.invalidFormat) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Lève invalidFormat quand toutes les URLs sont invalides")
    func throwsInvalidFormatWhenAllURLsInvalid() throws {
        // Une chaîne vide ne produit pas d'URL valide : compactMap doit tout filtrer.
        let bundle = try makeBundle(json: #"{ "instances": [""] }"#)

        #expect(throws: PublicInstanceListError.invalidFormat) {
            try PublicInstanceList.load(bundle: bundle)
        }
    }

    @Test("Filtre les URLs invalides tout en gardant les valides (compactMap)")
    func filtersInvalidURLsButKeepsValidOnes() throws {
        let bundle = try makeBundle(json: #"{ "instances": ["", "https://searx.example.org"] }"#)

        let urls = try PublicInstanceList.load(bundle: bundle)

        #expect(urls == [URL(string: "https://searx.example.org")!])
    }
}
