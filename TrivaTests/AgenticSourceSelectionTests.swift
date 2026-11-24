//
//  AgenticSourceSelectionTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/11/2026.
//

import Testing
import Foundation
@testable import Triva

private func page(_ result: SearXNGSearchResult, content: String = "Texte", succeeded: Bool = true, refused: Bool = false) -> ScrapedPage {
    ScrapedPage(url: result.url, title: "Page", content: content, succeeded: succeeded, refusedBySite: refused)
}

private func select(
    seeded: [SearXNGSearchResult] = [],
    found: [SearXNGSearchResult] = [],
    readPages: [ScrapedPage] = [],
    ranked: [SearXNGSearchResult] = [],
    limit: Int = 5,
    trusted: Bool = false
) -> AgenticSourceSelection.Selection {
    AgenticSourceSelection.finalSources(
        seeded: seeded, found: found, readPages: readPages,
        ranked: ranked, limit: limit, trustedDomainsOnly: trusted
    )
}

@Suite("AgenticSourceSelection : union")
struct AgenticSourceSelectionUnionTests {
    @Test("Départ puis trouvés, dans l'ordre d'arrivée")
    func keepsArrivalOrder() {
        let union = AgenticSourceSelection.union(seeded: [agenticResult(1), agenticResult(2)], found: [agenticResult(3)])
        #expect(union.map(\.url) == [1, 2, 3].map { agenticResult($0).url })
    }

    @Test("Déduplication par urlKey : la première occurrence gagne")
    func deduplicatesByURLKey() {
        let first = makeSourceResult(url: "https://www.exemple.fr/a/", title: "Premier")
        let second = makeSourceResult(url: "https://exemple.fr/a", title: "Second")
        let union = AgenticSourceSelection.union(seeded: [first], found: [second, agenticResult(2)])
        #expect(union.count == 2)
        #expect(union.first?.title == "Premier")
    }

    @Test("Entrées vides")
    func emptyInputs() {
        #expect(AgenticSourceSelection.union(seeded: [], found: []).isEmpty)
    }
}

@Suite("AgenticSourceSelection : finalSources")
struct AgenticSourceSelectionFinalTests {
    @Test("Les pages lues avec succès passent en tête, dans l'ordre de lecture, puis le classement")
    func readPagesComeFirst() {
        let all = (1...6).map { agenticResult($0) }
        let selection = select(
            seeded: Array(all.prefix(3)), found: Array(all.suffix(3)),
            readPages: [page(all[4]), page(all[1])],
            ranked: all
        )
        #expect(selection.sources.map(\.url) == [all[4], all[1], all[0], all[2], all[3]].map(\.url))
    }

    @Test("Sans cette priorité la page lue serait jetée : elle reste dans pages même hors du classement")
    func readPageOutsideRankingIsKept() {
        let all = (1...7).map { agenticResult($0) }
        let selection = select(
            seeded: Array(all.prefix(5)), found: Array(all.suffix(2)),
            readPages: [page(all[6])],
            ranked: Array(all.prefix(5))
        )
        #expect(selection.sources.first?.url == all[6].url)
        #expect(selection.sources.count == 5)
        #expect(selection.pages.map(\.url) == [all[6].url])
    }

    @Test("Borné par limit, sans doublon")
    func boundedByLimitWithoutDuplicates() {
        let all = (1...9).map { agenticResult($0) }
        let selection = select(seeded: all, readPages: [page(all[3]), page(all[3])], ranked: all + all, limit: 5)
        #expect(selection.sources.count == 5)
        #expect(Set(selection.sources.map(\.url)).count == 5)
        #expect(selection.sources.first?.url == all[3].url)
    }

    @Test("Plus de pages lues que de places : les premières lues gagnent, les autres tombent")
    func moreReadPagesThanRoom() {
        let all = (1...6).map { agenticResult($0) }
        let selection = select(seeded: all, readPages: all.map { page($0) }, ranked: all, limit: 3)
        #expect(selection.sources.map(\.url) == all.prefix(3).map(\.url))
        #expect(selection.pages.count == 3)
    }

    @Test("Une page lue absente du départ et des résultats trouvés est écartée")
    func unbackedReadPageIsDropped() {
        let known = agenticResult(1)
        let stranger = agenticResult(2)
        let selection = select(seeded: [known], readPages: [page(stranger)], ranked: [known])
        #expect(selection.sources.map(\.url) == [known.url])
        #expect(selection.pages.isEmpty)
    }

    @Test("Une page en échec ou refusée ne passe pas en tête, mais reste dans pages si sa source est retenue")
    func failedPagesAreNotPrioritisedButStayInPages() {
        let all = (1...3).map { agenticResult($0) }
        let selection = select(
            seeded: all,
            readPages: [page(all[2], content: "", succeeded: false), page(all[1], content: "", succeeded: false, refused: true)],
            ranked: all
        )
        #expect(selection.sources.map(\.url) == all.map(\.url))
        #expect(selection.pages.count == 2)
        #expect(selection.pages.allSatisfy { !$0.succeeded })
        #expect(selection.pages.contains { $0.refusedBySite })
    }

    @Test("Une page « réussie » au contenu blanc ne passe pas en tête")
    func blankSuccessfulPageIsNotPrioritised() {
        let all = (1...3).map { agenticResult($0) }
        let selection = select(seeded: all, readPages: [page(all[2], content: "  \n ")], ranked: all)
        #expect(selection.sources.map(\.url) == all.map(\.url))
    }

    @Test("L'URL d'une page est réécrite sur celle de la source retenue")
    func pageURLIsRewrittenOnTheSource() {
        let source = makeSourceResult(url: "https://exemple.fr/a")
        let variant = ScrapedPage(url: "https://www.exemple.fr/a/", title: "t", content: "texte", succeeded: true)
        let selection = select(seeded: [source], readPages: [variant], ranked: [source])
        #expect(selection.sources.map(\.url) == ["https://exemple.fr/a"])
        #expect(selection.pages.map(\.url) == ["https://exemple.fr/a"])
    }

    @Test("limit 0 : rien")
    func zeroLimit() {
        let all = [agenticResult(1)]
        let selection = select(seeded: all, readPages: [page(all[0])], ranked: all, limit: 0)
        #expect(selection.sources.isEmpty)
        #expect(selection.pages.isEmpty)
    }

    @Test("Aucune lecture : le classement tel quel")
    func noReadPagesKeepsRanking() {
        let all = (1...4).map { agenticResult($0) }
        let ranked = [all[2], all[0], all[3], all[1]]
        let selection = select(seeded: all, ranked: ranked)
        #expect(selection.sources.map(\.url) == ranked.map(\.url))
        #expect(selection.pages.isEmpty)
    }

    @Test("Entrées vides")
    func everythingEmpty() {
        #expect(select() == AgenticSourceSelection.Selection(sources: [], pages: []))
    }
}

@Suite("AgenticSourceSelection : mode Fiable")
struct AgenticSourceSelectionReliableTests {
    @Test("Fiable : une page lue non fiable n'apparaît jamais, même lue avec succès")
    func untrustedReadPageNeverAppears() {
        let trusted = agenticTrustedResult(1)
        let untrusted = agenticResult(2)
        let selection = select(
            seeded: [trusted, untrusted],
            readPages: [page(untrusted), page(trusted)],
            ranked: [untrusted, trusted],
            trusted: true
        )
        #expect(selection.sources.map(\.url) == [trusted.url])
        #expect(selection.pages.map(\.url) == [trusted.url])
        #expect(selection.sources.allSatisfy { SourceRanker.isTrustedDomain($0.url) })
    }

    @Test("Fiable : le classement est re-filtré, les domaines fiables seuls")
    func rankingIsRefiltered() {
        let mixed = [agenticResult(1), agenticTrustedResult(2), agenticResult(3), agenticTrustedResult(4)]
        let selection = select(seeded: mixed, ranked: mixed, trusted: true)
        #expect(selection.sources.map(\.url) == [mixed[1].url, mixed[3].url])
    }

    @Test("Fiable : aucun domaine fiable = aucune source")
    func noTrustedSourceMeansNoSource() {
        let untrusted = (1...3).map { agenticResult($0) }
        let selection = select(seeded: untrusted, readPages: untrusted.map { page($0) }, ranked: untrusted, trusted: true)
        #expect(selection.sources.isEmpty)
        #expect(selection.pages.isEmpty)
    }

    @Test("Hors Fiable, les mêmes sources non fiables sont gardées")
    func notReliableKeepsEverything() {
        let mixed = [agenticResult(1), agenticTrustedResult(2)]
        let selection = select(seeded: mixed, ranked: mixed, trusted: false)
        #expect(selection.sources.count == 2)
    }
}
