//
//  SpotlightIndexPlanTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission F) : ce qui part dans l'index Spotlight, et ce qui en est retiré. Pur : aucune
//  base, aucun index réel.
//

import Foundation
import Testing
@testable import Triva

@Suite("Spotlight : plan d'indexation")
struct SpotlightIndexPlanTests {
    private func entry(_ n: Int, title: String? = nil, at seconds: TimeInterval = 1_000) -> SpotlightEntry {
        SpotlightEntry(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            title: title ?? "Conversation \(n)",
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func table(_ entries: [SpotlightEntry]) -> [UUID: SpotlightEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    @Test("Premier passage (rien en mémoire) : tout est indexé, rien n'est retiré")
    func firstPassIndexesEverything() {
        let desired = [entry(1), entry(2)]
        let plan = SpotlightIndexPlan.make(desired: desired, previous: nil, indexedIDs: [])
        #expect(plan.toIndex == desired)
        #expect(plan.toDelete.isEmpty)
    }

    @Test("Premier passage : un identifiant indexé lors d'un lancement précédent et disparu depuis est retiré")
    func firstPassDeletesVanishedIDs() {
        let kept = entry(1)
        let gone = entry(2)
        let plan = SpotlightIndexPlan.make(desired: [kept], previous: nil, indexedIDs: [kept.id, gone.id])
        #expect(plan.toIndex == [kept])
        #expect(plan.toDelete == [gone.id])
    }

    @Test("Rien n'a changé : plan vide, ni indexation ni retrait")
    func nothingChangedIsEmpty() {
        let desired = [entry(1), entry(2)]
        let plan = SpotlightIndexPlan.make(desired: desired, previous: table(desired), indexedIDs: Set(desired.map(\.id)))
        #expect(plan.isEmpty)
    }

    @Test("Une nouvelle conversation est indexée seule")
    func newConversationOnly() {
        let old = [entry(1)]
        let added = entry(2)
        let plan = SpotlightIndexPlan.make(desired: [added] + old, previous: table(old), indexedIDs: [old[0].id])
        #expect(plan.toIndex == [added])
        #expect(plan.toDelete.isEmpty)
    }

    @Test("Une conversation renommée ou modifiée est réindexée, les autres non")
    func changedTitleOrDateIsReindexed() {
        let a = entry(1)
        let b = entry(2)
        let renamed = entry(1, title: "Nouveau titre")
        let touched = entry(2, at: 2_000)
        let ids = Set([a.id, b.id])

        let byTitle = SpotlightIndexPlan.make(desired: [renamed, b], previous: table([a, b]), indexedIDs: ids)
        #expect(byTitle.toIndex == [renamed])

        let byDate = SpotlightIndexPlan.make(desired: [a, touched], previous: table([a, b]), indexedIDs: ids)
        #expect(byDate.toIndex == [touched])
    }

    @Test("Une conversation supprimée est retirée de l'index")
    func deletedConversationIsRemoved() {
        let a = entry(1)
        let b = entry(2)
        let plan = SpotlightIndexPlan.make(desired: [a], previous: table([a, b]), indexedIDs: [a.id, b.id])
        #expect(plan.toIndex.isEmpty)
        #expect(plan.toDelete == [b.id])
    }

    @Test("Historique vidé : tout ce qui était indexé est retiré, dans un ordre stable")
    func emptyHistoryRemovesAll() {
        let ids = (1...4).map { entry($0).id }
        let plan = SpotlightIndexPlan.make(desired: [], previous: nil, indexedIDs: Set(ids))
        #expect(plan.toIndex.isEmpty)
        #expect(plan.toDelete == ids.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("Au plus 500 conversations : les plus récentes (les premières reçues) ; les autres sont retirées")
    func capsAtFiveHundredMostRecent() {
        let desired = (1...(SpotlightIndexPlan.maxEntries + 20)).map { entry($0) }
        let overflow = Set(desired.dropFirst(SpotlightIndexPlan.maxEntries).map(\.id))
        let plan = SpotlightIndexPlan.make(desired: desired, previous: nil, indexedIDs: overflow)
        #expect(SpotlightIndexPlan.maxEntries == 500)
        #expect(plan.toIndex == Array(desired.prefix(500)))
        #expect(Set(plan.toDelete) == overflow)
    }

    @Test("Un identifiant en double n'est indexé qu'une fois (le premier gagne)")
    func duplicateIDsKeepFirst() {
        let first = entry(1, title: "Premier")
        let second = entry(1, title: "Second")
        let plan = SpotlightIndexPlan.make(desired: [first, second], previous: nil, indexedIDs: [])
        #expect(plan.toIndex == [first])
    }

    @Test("Titre vide : repli lisible ; titre sur plusieurs lignes : une seule ligne ; date arrondie à la seconde")
    func entryCleansTitleAndDate() {
        let blank = SpotlightEntry(id: UUID(), title: "  \n ", updatedAt: Date(timeIntervalSince1970: 10.9))
        #expect(blank.title == "Conversation sans titre")
        #expect(blank.updatedAt == Date(timeIntervalSince1970: 10))

        let multiline = SpotlightEntry(id: UUID(), title: "Recette\n  de crêpes ", updatedAt: Date(timeIntervalSince1970: 0))
        #expect(multiline.title == "Recette de crêpes")
    }
}
