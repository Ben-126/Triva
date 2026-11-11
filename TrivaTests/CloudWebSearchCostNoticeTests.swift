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
    @Test("La phrase nomme chaque fournisseur qui sait chercher, et dit que c'est payant")
    func mentionsEverySearchProviderAndCost() {
        let sentence = CloudWebSearchCostNotice.sentence
        #expect(sentence.contains("OpenAI"))
        #expect(sentence.contains("Anthropic"))
        #expect(sentence.contains("Gemini"))
        #expect(sentence.contains("Perplexity"))
        #expect(sentence.contains("facturée"))
        #expect(sentence.contains("jetons d'entrée"))
        // Une seule phrase : un seul point final.
        #expect(sentence.filter { $0 == "." }.count == 1)
    }

    @Test("Le nombre de services cités reste égal à CloudWebSearchService : un nouveau service force à relire la phrase")
    func coversAllSearchServices() {
        #expect(CloudWebSearchService.allCases.count == 4)
    }
}
