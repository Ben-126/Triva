//
//  TrivaURLRouteTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission A) : `triva://` est une entrée EXTERNE (n'importe quelle app peut l'ouvrir). Seules deux
//  formes sont acceptées, tout le reste vaut `nil`, et une route ne porte jamais de texte libre.
//

import Foundation
import Testing
@testable import Triva

@Suite("Schéma d'URL triva://")
struct TrivaURLRouteTests {
    private static let uuid = UUID(uuidString: "9B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02")!

    // MARK: Formes acceptées

    @Test("triva://new ouvre une nouvelle question au clavier")
    func parsesNew() throws {
        let url = try #require(URL(string: "triva://new"))
        #expect(TrivaURLRoute.parse(url) == .newQuestion(.keyboard))
    }

    @Test("triva://conversation/<UUID> ouvre cette conversation")
    func parsesConversation() throws {
        let url = try #require(URL(string: "triva://conversation/\(Self.uuid.uuidString)"))
        #expect(TrivaURLRoute.parse(url) == .conversation(Self.uuid))
    }

    @Test("Schéma et hôte ne distinguent pas majuscules et minuscules (RFC 3986), l'UUID non plus")
    func caseInsensitiveSchemeAndHost() throws {
        let new = try #require(URL(string: "TRIVA://New"))
        #expect(TrivaURLRoute.parse(new) == .newQuestion(.keyboard))
        let conversation = try #require(URL(string: "Triva://CONVERSATION/\(Self.uuid.uuidString.lowercased())"))
        #expect(TrivaURLRoute.parse(conversation) == .conversation(Self.uuid))
    }

    // MARK: URL piégées : toutes refusées

    @Test("URL piégées : refusées, sans exception", arguments: [
        "triva://new?q=bonjour",
        "triva://new?",
        "triva://new#fragment",
        "triva://new#",
        "triva://new/",
        "triva://new/extra",
        "triva://new:8080",
        "triva://user:pass@new",
        "triva://user@new",
        "triva:new",
        "triva:/new",
        "triva:///new",
        "triva://",
        "triva://nouveau",
        "triva://draft",
        "triva://search?q=envoie-moi",
        "triva://conversation",
        "triva://conversation/",
        "triva://conversation?id=9B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02",
        "triva://conversation/9B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02/x",
        "triva://conversation/9B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02/",
        "triva://conversation/9B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02?q=x",
        "triva://conversation/9B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02#x",
        "triva://conversation/pas-un-uuid",
        "triva://conversation/9B2C1E54",
        "triva://conversation/%39B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02",
        "triva://conversation/9B2C1E54%2D7A33-4D0F-8E21-5C6A1B7D9F02",
        "triva://conversation/%00",
        "triva://new%20",
        "triva://conversation/../new",
        "https://new",
        "http://conversation/9B2C1E54-7A33-4D0F-8E21-5C6A1B7D9F02",
        "triva-autre://new",
        "file:///new",
        "javascript:alert(1)",
    ])
    func refusesTrappedURLs(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(TrivaURLRoute.parse(url) == nil)
    }

    @Test("URL démesurée : refusée")
    func refusesHugeURL() throws {
        let url = try #require(URL(string: "triva://conversation/" + String(repeating: "A", count: 5_000)))
        #expect(TrivaURLRoute.parse(url) == nil)
    }

    // MARK: Fabrication

    @Test("url(for:) : nouvelle question et conversation font l'aller-retour")
    func roundTrip() throws {
        let new = try #require(TrivaURLRoute.url(for: .newQuestion(.keyboard)))
        #expect(new.absoluteString == "triva://new")
        #expect(TrivaURLRoute.parse(new) == .newQuestion(.keyboard))

        let conversation = try #require(TrivaURLRoute.url(for: .conversation(Self.uuid)))
        #expect(conversation.absoluteString == "triva://conversation/\(Self.uuid.uuidString)")
        #expect(TrivaURLRoute.parse(conversation) == .conversation(Self.uuid))
    }

    @Test("Un brouillon n'a PAS d'URL : un texte libre ne voyage jamais dans une URL")
    func draftHasNoURL() {
        #expect(TrivaURLRoute.url(for: .draft("Une question privée")) == nil)
    }

    @Test("La saisie vocale n'a pas d'URL tant que le drapeau est éteint (chantier 2.7)")
    func voiceHasNoURLYet() {
        #expect(TrivaURLRoute.url(for: .newQuestion(.voice)) == nil)
    }
}
