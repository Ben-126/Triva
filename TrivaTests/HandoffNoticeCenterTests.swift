//
//  HandoffNoticeCenterTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : le message clair quand la discussion n'a pas pu arriver et que seul le texte est repris.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Handoff conversation : message de repli")
struct HandoffNoticeCenterTests {
    @Test("Le message est posé, lu une seule fois, puis plus rien")
    func postedThenTakenOnce() {
        let center = HandoffNoticeCenter()
        #expect(center.take() == nil)
        center.post("Message")
        #expect(center.revision == 1)
        #expect(center.take() == "Message")
        #expect(center.take() == nil)
    }

    @Test("Un nouveau message remplace l'ancien non lu et réveille les fenêtres")
    func newerReplacesOlder() {
        let center = HandoffNoticeCenter()
        center.post("Un")
        center.post("Deux")
        #expect(center.revision == 2)
        #expect(center.take() == "Deux")
    }

    @Test("Un message que personne n'a pris (aucune fenêtre devant) expire")
    func staleMessageExpires() {
        let center = HandoffNoticeCenter()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        center.post("Vieux", now: start)
        #expect(center.take(now: start.addingTimeInterval(HandoffNoticeCenter.lifetime + 1)) == nil)
        center.post("Frais", now: start)
        #expect(center.take(now: start.addingTimeInterval(1)) == "Frais")
    }

    @Test("Un message vide n'est pas posé")
    func emptyIsIgnored() {
        let center = HandoffNoticeCenter()
        center.post("  ")
        #expect(center.revision == 0)
        #expect(center.take() == nil)
    }
}
