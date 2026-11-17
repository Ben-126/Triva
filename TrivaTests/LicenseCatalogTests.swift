//
//  LicenseCatalogTests.swift
//  TrivaTests
//
//  Mission C3 (M5) : chargement du fichier de licences embarqué et de sa mise en forme.
//

import Foundation
import Testing
@testable import Triva

@Suite("Licences et attributions")
struct LicenseCatalogTests {
    private func realCatalog() throws -> LicenseCatalog {
        try LicenseCatalog.load()
    }

    @Test("Le fichier embarqué se charge, avec les cinq familles dans l'ordre")
    func loadsRealFile() throws {
        let catalog = try realCatalog()
        #expect(catalog.sections.map(\.kind) == LicenseCatalog.Kind.allCases)
        #expect(catalog.allEntries.count > 30)
    }

    @Test("Chaque identifiant est unique (il sert de clé de navigation)")
    func uniqueIDs() throws {
        let ids = try realCatalog().allEntries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Les dépendances Apache 2.0 affichent le texte complet ; MIT leur propre texte")
    func licenseTextsAreFull() throws {
        let catalog = try realCatalog()
        let apache = try #require(catalog.allEntries.first { $0.id == "swift-huggingface" })
        #expect(apache.licenseText?.contains("Apache License") == true)
        #expect(apache.licenseText?.contains("TERMS AND CONDITIONS") == true)
        let mit = try #require(catalog.allEntries.first { $0.id == "eventsource" })
        #expect(mit.licenseText?.contains("Permission is hereby granted") == true)
    }

    @Test("« WITH Swift-exception » ajoute l'exception au texte Apache")
    func swiftExceptionAppended() throws {
        let entry = try #require(try realCatalog().allEntries.first { $0.id == "swift-collections" })
        #expect(entry.licenseText?.contains("Runtime Library Exception") == true)
    }

    @Test("Le NOTICE de XGrammar est reproduit")
    func noticeIsKept() throws {
        let entry = try #require(try realCatalog().allEntries.first { $0.id == "xgrammar" })
        #expect(entry.notice?.contains("XGrammar Contributors") == true)
    }

    @Test("Les outils de build non livrés (embedded: false) n'apparaissent pas")
    func buildOnlyToolsHidden() throws {
        let ids = Set(try realCatalog().allEntries.map(\.id))
        #expect(!ids.contains("swift-syntax"))
        #expect(!ids.contains("swift-argument-parser"))
        #expect(!ids.contains("swift-asn1"))
    }

    @Test("Les sept modèles Qwen3 et Alibaba Cloud sont cités avec leur licence Apache 2.0")
    func qwenModelsListed() throws {
        let models = try #require(try realCatalog().sections.first { $0.kind == .model })
        #expect(models.entries.count == 7)
        for entry in models.entries {
            #expect(entry.summary == "Apache-2.0")
            #expect(entry.copyright?.contains("Alibaba Cloud") == true)
            #expect(entry.licenseText?.contains("Apache License") == true)
        }
    }

    @Test("Open-Meteo : attribution CC BY 4.0 et liens vers le site et la licence")
    func openMeteoAttribution() throws {
        let entry = try #require(try realCatalog().allEntries.first { $0.id == "open-meteo" })
        #expect(entry.summary == "CC-BY-4.0")
        #expect(entry.notes.contains { $0.contains("Open-Meteo.com") })
        #expect(entry.links.contains { $0.url.absoluteString == "https://open-meteo.com/" })
        #expect(entry.links.contains { $0.url.absoluteString == "https://creativecommons.org/licenses/by/4.0/" })
    }

    @Test("Chaque lien du fichier est une adresse https")
    func linksAreHTTPS() throws {
        for entry in try realCatalog().allEntries {
            for link in entry.links {
                #expect(link.url.scheme == "https", "\(entry.id) : \(link.url)")
            }
        }
    }

    @Test("La recherche ignore la casse et les accents, et vide, rend tout")
    func search() throws {
        let catalog = try realCatalog()
        #expect(catalog.filtered(by: "").count == catalog.sections.count)
        let wiki = catalog.filtered(by: "WIKIPEDIA").flatMap(\.entries)
        #expect(wiki.map(\.id) == ["wikipedia"])
        #expect(catalog.filtered(by: "qwen3 32").flatMap(\.entries).map(\.id) == ["qwen3-32b"])
        #expect(!catalog.filtered(by: "qwen3").isEmpty)
        #expect(catalog.filtered(by: "zzzz-introuvable").isEmpty)
    }

    @Test("Un fichier illisible lève une erreur claire, jamais un écran vide silencieux")
    func invalidDataThrows() {
        #expect(throws: LicenseCatalog.LoadError.invalidData) {
            try LicenseCatalog.parse(data: Data("pas du JSON".utf8))
        }
        #expect(throws: LicenseCatalog.LoadError.resourceMissing) {
            try LicenseCatalog.load(resourceName: "fichier-inexistant")
        }
    }
}
