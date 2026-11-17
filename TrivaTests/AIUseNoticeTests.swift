//
//  AIUseNoticeTests.swift
//  TrivaTests
//
//  Mission C3 : écran « Triva répond avec une IA » (une seule fois) et avertissement sous les réponses.
//

import Foundation
import Testing
@testable import Triva

@Suite("Information IA")
struct AIUseNoticeTests {
    private func makeDefaults() throws -> UserDefaults {
        try #require(TestDefaults.suite(named: "test.aiNotice.\(UUID().uuidString)"))
    }

    @Test("Au premier lancement l'écran n'a pas été vu ; une fois acquitté, il ne revient plus")
    func shownOnlyOnce() throws {
        let defaults = try makeDefaults()
        #expect(!AIUseNoticeStore.isAcknowledged(in: defaults))
        AIUseNoticeStore.acknowledge(in: defaults)
        #expect(AIUseNoticeStore.isAcknowledged(in: defaults))
        // Idempotent.
        AIUseNoticeStore.acknowledge(in: defaults)
        #expect(AIUseNoticeStore.isAcknowledged(in: defaults))
    }

    @Test("Le drapeau est lu sous la clé que les tests UI posent par argument de lancement")
    func keyMatchesUITests() throws {
        #expect(AIUseNoticeStore.defaultsKey == "legal.aiNotice.acknowledged")
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "legal.aiNotice.acknowledged")
        #expect(AIUseNoticeStore.isAcknowledged(in: defaults))
    }

    @Test("L'avertissement s'affiche sous une réponse terminée ou interrompue qui a du texte")
    func disclaimerAppearsWithText() {
        #expect(AIDisclaimerPolicy.shows(state: .completed, hasText: true))
        #expect(AIDisclaimerPolicy.shows(state: .interrupted, hasText: true))
    }

    @Test("Jamais pendant l'écriture, sur un échec, sur le message fixe ni sans texte")
    func disclaimerAbsentOtherwise() {
        #expect(!AIDisclaimerPolicy.shows(state: .streaming, hasText: true))
        #expect(!AIDisclaimerPolicy.shows(state: .failed, hasText: true))
        #expect(!AIDisclaimerPolicy.shows(state: .noReliableSources, hasText: true))
        #expect(!AIDisclaimerPolicy.shows(state: .completed, hasText: false))
    }

    @Test("La version courte tient en une phrase plus brève que la longue")
    func shortFooterIsShorter() {
        #expect(AIUseNoticeText.footerShort.count < AIUseNoticeText.footer.count)
        #expect(AIUseNoticeText.footer.contains("IA"))
        #expect(AIUseNoticeText.footerShort.contains("IA"))
    }
}
