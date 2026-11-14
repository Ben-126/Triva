//
//  CloudWebSearchCostNoticeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 10/11/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("CloudWebSearchCostNotice")
struct CloudWebSearchCostNoticeTests {
    @Test("La phrase dit que c'est facturé, chiffre OpenAI, et ne promet pas d'être le dernier recours")
    func saysItIsBilledAndKeepsTheOrderTruthful() {
        let sentence = CloudWebSearchCostNotice.sentence
        #expect(sentence.contains("facturé sur ton compte"))
        #expect(sentence.contains("OpenAI"))
        #expect(sentence.contains("1\u{00A0}centime"))
        // Les sources ouvertes (Wikipédia…) passent APRÈS la recherche du fournisseur : la phrase ne
        // doit pas laisser croire que celle-ci n'a lieu que quand « aucune autre source » ne répond.
        #expect(!sentence.contains("aucune autre source"))
        #expect(sentence.contains("SearXNG"))
        // Deux phrases courtes : un point après « IA » et un point final.
        #expect(sentence.filter { $0 == "." }.count == 2)
    }

    @Test("Le nombre de services cités reste égal à CloudWebSearchService : un nouveau service force à relire la phrase")
    func coversAllSearchServices() {
        #expect(CloudWebSearchService.allCases.count == 3)
    }
}
