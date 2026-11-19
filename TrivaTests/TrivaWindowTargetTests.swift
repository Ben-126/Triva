//
//  TrivaWindowTargetTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M1) : cible de fenêtre « une recherche = une fenêtre ».
//

import Foundation
import Testing
@testable import Triva

struct TrivaWindowTargetTests {
    @Test("Codable : aller-retour pour les deux cas")
    func codableRoundTrip() throws {
        let targets: [TrivaWindowTarget] = [.newSearch(UUID()), .conversation(UUID())]
        for target in targets {
            let data = try JSONEncoder().encode(target)
            let decoded = try JSONDecoder().decode(TrivaWindowTarget.self, from: data)
            #expect(decoded == target)
        }
    }

    @Test("Deux .newSearch fabriqués par fresh() ne sont jamais égaux (sinon openWindow ramènerait la même fenêtre)")
    func freshSearchesAreDistinct() {
        let first = TrivaWindowTarget.freshSearch()
        let second = TrivaWindowTarget.freshSearch()
        #expect(first != second)
        #expect(first.conversationID == nil)
    }

    @Test("Un .newSearch et une .conversation de même UUID sont différents")
    func casesWithSameUUIDDiffer() {
        let id = UUID()
        #expect(TrivaWindowTarget.newSearch(id) != TrivaWindowTarget.conversation(id))
        #expect(Set([TrivaWindowTarget.newSearch(id), .conversation(id)]).count == 2)
    }

    @Test("conversationID : présent seulement pour .conversation")
    func conversationIDAccessor() {
        let id = UUID()
        #expect(TrivaWindowTarget.conversation(id).conversationID == id)
        #expect(TrivaWindowTarget.newSearch(id).conversationID == nil)
    }

    @Test("Restauration : une conversation qui existe encore est conservée")
    func restoredKeepsExistingConversation() {
        let id = UUID()
        let target = TrivaWindowTarget.conversation(id)
        #expect(TrivaWindowTarget.restored(target, existingIDs: [id, UUID()]) == target)
    }

    @Test("Restauration : une conversation supprimée entre-temps devient une nouvelle recherche neuve")
    func restoredDropsDeletedConversation() {
        let deleted = UUID()
        let fresh = UUID()
        let restored = TrivaWindowTarget.restored(.conversation(deleted), existingIDs: [UUID()], makeID: { fresh })
        #expect(restored == .newSearch(fresh))
    }

    @Test("Restauration : un .newSearch est conservé tel quel, même si la liste est vide")
    func restoredKeepsNewSearch() {
        let target = TrivaWindowTarget.newSearch(UUID())
        #expect(TrivaWindowTarget.restored(target, existingIDs: []) == target)
    }

    @Test("Restauration sans fabrique : l'identifiant de remplacement est neuf à chaque appel")
    func restoredFallbackIsFreshEachTime() {
        let deleted = TrivaWindowTarget.conversation(UUID())
        let first = TrivaWindowTarget.restored(deleted, existingIDs: [])
        let second = TrivaWindowTarget.restored(deleted, existingIDs: [])
        #expect(first != second)
    }

    @Test("Aucun texte de question dans la valeur écrite sur disque : seulement un type et un UUID")
    func encodedValueCarriesOnlyIdentifiers() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(TrivaWindowTarget.conversation(id))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(id.uuidString))
        #expect(json.count < 120)
    }
}
