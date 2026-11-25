//
//  SpotlightActivityRouteTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : toucher un résultat Spotlight. Entrée externe : ne fait que naviguer, refuse le reste.
//

import Foundation
import Testing
@testable import Triva

@Suite("Spotlight : toucher un résultat")
struct SpotlightActivityRouteTests {
    private let id = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!

    @Test("Un identifiant UUID mène à la conversation")
    func plainUUID() {
        #expect(SpotlightActivityRoute.route(forIdentifier: id.uuidString) == .conversation(id))
        #expect(SpotlightActivityRoute.route(forIdentifier: "  \(id.uuidString.lowercased())\n") == .conversation(id))
    }

    @Test("Un identifiant préfixé par un type (… / … ou … : …) mène aussi à la conversation")
    func prefixedUUID() {
        #expect(SpotlightActivityRoute.route(forIdentifier: "ConversationEntity/\(id.uuidString)") == .conversation(id))
        #expect(SpotlightActivityRoute.route(forIdentifier: "com.benpodrojsky.Triva:\(id.uuidString)") == .conversation(id))
    }

    @Test("Tout le reste est refusé", arguments: [
        "",
        "   ",
        "pas-un-uuid",
        "triva://new",
        "https://exemple.org/7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11?q=envoie",
        "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11 envoie ceci",
        "7B0C6B2A-2F5D-4C58-9E0B",
        "../7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A1",
    ])
    func rejectsEverythingElse(identifier: String) {
        #expect(SpotlightActivityRoute.route(forIdentifier: identifier) == nil)
    }

    @Test("Pas d'identifiant : rien")
    func nilIdentifier() {
        #expect(SpotlightActivityRoute.route(forIdentifier: nil) == nil)
    }
}
