//
//  HandoffConversationCodecTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : le codage versionné de la discussion envoyée par Handoff. ENTRÉE EXTERNE à la lecture :
//  taille, version, identifiant, nombres, textes et adresses de sources sont vérifiés avant d'écrire quoi que ce soit.
//

import Foundation
import Testing
@testable import Triva

@Suite("Handoff conversation : codage")
struct HandoffConversationCodecTests {
    private let id = HandoffFixtures.conversationID

    @Test("Aller-retour : tout ce qui est fini revient à l'identique (questions, réponses, sources, mentions)")
    func roundTripKeepsEverything() throws {
        var snapshot = HandoffFixtures.snapshot(pairs: 3)
        snapshot.messages[1].notes = HandoffConversationSnapshot.Notes(uncitableSourceNumbers: [2, 3], answeredWithoutSearch: true)
        snapshot.messages[3].reportsNoReliableSources = true
        let encoded = try #require(HandoffSnapshotCodec.encode(snapshot))
        #expect(encoded.droppedMessageCount == 0)
        let decoded = try HandoffSnapshotCodec.decode(encoded.data, expectedConversationID: id)
        #expect(decoded == snapshot)
    }

    @Test("Accents, emoji composés et retours à la ligne traversent le codage sans perte")
    func unicodeSurvives() throws {
        var snapshot = HandoffFixtures.snapshot(pairs: 1)
        snapshot.messages[0].text = "Où est l'été ? 🇫🇷 👨‍👩‍👧‍👦\nSeconde ligne\tavec tabulation"
        let encoded = try #require(HandoffSnapshotCodec.encode(snapshot))
        let decoded = try HandoffSnapshotCodec.decode(encoded.data, expectedConversationID: id)
        #expect(decoded.messages[0].text == snapshot.messages[0].text)
    }

    @Test("Plafond : une discussion trop lourde perd ses plus anciens échanges, jamais les derniers")
    func oversizedConversationDropsOldestPairs() throws {
        var snapshot = HandoffFixtures.snapshot(pairs: 0)
        let bigText = String(repeating: "mot ", count: 10_000)   // 40 000 caractères
        for index in 0..<40 {
            snapshot.messages.append(HandoffFixtures.message(index, text: bigText))
        }
        let limit = 300_000
        let encoded = try #require(HandoffSnapshotCodec.encode(snapshot, maxBytes: limit))
        #expect(encoded.data.count <= limit)
        #expect(encoded.droppedMessageCount > 0)
        let decoded = try HandoffSnapshotCodec.decode(encoded.data, expectedConversationID: id, maxBytes: limit)
        #expect(decoded.messages.count == snapshot.messages.count - encoded.droppedMessageCount)
        #expect(decoded.messages.last?.id == snapshot.messages.last?.id)
        #expect(decoded.messages.first?.role == .user)
    }

    @Test("Un seul message qui dépasse le plafond à lui seul : rien n'est envoyé")
    func singleHugeMessageIsRefused() {
        var snapshot = HandoffFixtures.snapshot(pairs: 0)
        snapshot.messages = [HandoffFixtures.message(0, text: String(repeating: "x", count: 50_000))]
        #expect(HandoffSnapshotCodec.encode(snapshot, maxBytes: 20_000) == nil)
    }

    @Test("Plafond d'envoi : au plus 200 messages, les plus récents")
    func messageCountIsCapped() throws {
        var snapshot = HandoffFixtures.snapshot(pairs: 0)
        snapshot.messages = (0..<260).map { HandoffFixtures.message($0, text: "m\($0)") }
        let encoded = try #require(HandoffSnapshotCodec.encode(snapshot))
        let decoded = try HandoffSnapshotCodec.decode(encoded.data, expectedConversationID: id)
        #expect(decoded.messages.count <= HandoffSnapshotCodec.maxMessages)
        #expect(decoded.messages.last?.text == "m259")
    }

    @Test("Lecture : un contenu plus gros que le plafond est refusé avant d'être lu")
    func tooLargeIsRefused() {
        let data = Data(repeating: 0x20, count: 1_000)
        #expect(throws: HandoffSnapshotError.tooLarge) {
            try HandoffSnapshotCodec.decode(data, expectedConversationID: nil, maxBytes: 999)
        }
    }

    @Test("Lecture : version inconnue, JSON cassé ou tronqué, type faux : refusés")
    func hostilePayloadsAreRefused() throws {
        let good = try #require(HandoffSnapshotCodec.encode(HandoffFixtures.snapshot())).data
        let wrongVersion = try replacing(in: good, "\"v\":1", with: "\"v\":2")
        #expect(throws: HandoffSnapshotError.unsupportedVersion) {
            try HandoffSnapshotCodec.decode(wrongVersion, expectedConversationID: id)
        }
        #expect(throws: HandoffSnapshotError.malformed) {
            try HandoffSnapshotCodec.decode(good.prefix(good.count / 2), expectedConversationID: id)
        }
        #expect(throws: HandoffSnapshotError.malformed) {
            try HandoffSnapshotCodec.decode(Data("[1,2,3]".utf8), expectedConversationID: id)
        }
        #expect(throws: HandoffSnapshotError.malformed) {
            try HandoffSnapshotCodec.decode(Data(), expectedConversationID: id)
        }
        let wrongRole = try replacing(in: good, "\"role\":\"user\"", with: "\"role\":\"system\"")
        #expect(throws: HandoffSnapshotError.malformed) {
            try HandoffSnapshotCodec.decode(wrongRole, expectedConversationID: id)
        }
    }

    @Test("Lecture : l'identifiant doit être celui annoncé dans l'en-tête")
    func mismatchedConversationIsRefused() throws {
        let encoded = try #require(HandoffSnapshotCodec.encode(HandoffFixtures.snapshot())).data
        #expect(throws: HandoffSnapshotError.mismatchedConversation) {
            try HandoffSnapshotCodec.decode(encoded, expectedConversationID: UUID())
        }
    }

    @Test("Lecture : une conversation sans message est refusée")
    func emptyConversationIsRefused() throws {
        var snapshot = HandoffFixtures.snapshot(pairs: 0)
        snapshot.messages = []
        let data = try HandoffSnapshotCodec.encodeUnchecked(snapshot)
        #expect(throws: HandoffSnapshotError.empty) {
            try HandoffSnapshotCodec.decode(data, expectedConversationID: id)
        }
    }

    @Test("Lecture : trop de messages, trop de sources ou deux messages de même identifiant : refusés")
    func structuralOverflowIsRefused() throws {
        var tooMany = HandoffFixtures.snapshot(pairs: 0)
        tooMany.messages = (0..<(HandoffSnapshotCodec.maxMessages + 1)).map { HandoffFixtures.message($0, text: "m") }
        #expect(throws: HandoffSnapshotError.tooManyItems) {
            try HandoffSnapshotCodec.decode(try HandoffSnapshotCodec.encodeUnchecked(tooMany), expectedConversationID: id)
        }

        var manySources = HandoffFixtures.snapshot(pairs: 1)
        manySources.messages[1].sources = (0...HandoffSnapshotCodec.maxSourcesPerMessage).map { HandoffFixtures.source($0) }
        #expect(throws: HandoffSnapshotError.tooManyItems) {
            try HandoffSnapshotCodec.decode(try HandoffSnapshotCodec.encodeUnchecked(manySources), expectedConversationID: id)
        }

        var duplicate = HandoffFixtures.snapshot(pairs: 1)
        duplicate.messages[1].id = duplicate.messages[0].id
        #expect(throws: HandoffSnapshotError.malformed) {
            try HandoffSnapshotCodec.decode(try HandoffSnapshotCodec.encodeUnchecked(duplicate), expectedConversationID: id)
        }
    }

    @Test("Lecture : les adresses de sources autres que http et https sont vidées (jamais un lien file: ou javascript:)")
    func nonWebSourceURLsAreBlanked() throws {
        var snapshot = HandoffFixtures.snapshot(pairs: 1)
        snapshot.messages[1].sources = [
            HandoffFixtures.source(0, url: "https://example.org/ok"),
            HandoffFixtures.source(1, url: "javascript:alert(1)"),
            HandoffFixtures.source(2, url: "file:///Users/ben/secret.txt"),
            HandoffFixtures.source(3, url: "triva://conversation/00000000-0000-0000-0000-000000000000"),
            HandoffFixtures.source(4, url: "HTTP://example.org/majuscules"),
            HandoffFixtures.source(5, url: "https://\u{0}example.org"),
        ]
        let decoded = try HandoffSnapshotCodec.decode(
            try HandoffSnapshotCodec.encodeUnchecked(snapshot), expectedConversationID: id
        )
        let urls = decoded.messages[1].sources.map(\.url)
        #expect(urls.count == 6)   // les numéros [n] ne se décalent jamais
        #expect(urls[0] == "https://example.org/ok")
        #expect(urls[1].isEmpty && urls[2].isEmpty && urls[3].isEmpty && urls[5].isEmpty)
        #expect(urls[4] == "HTTP://example.org/majuscules")
    }

    @Test("Lecture : textes rognés aux plafonds, caractères de contrôle retirés, ordres recalculés")
    func textsAreNormalised() throws {
        var snapshot = HandoffFixtures.snapshot(pairs: 1)
        snapshot.title = String(repeating: "t", count: 5_000)
        snapshot.messages[0].text = "Bon\u{0}jour\u{7}\u{1B}[31m\r\nsuite"
        snapshot.messages[1].text = String(repeating: "r", count: HandoffSnapshotCodec.maxMessageCharacters + 500)
        snapshot.messages[0].order = 40
        snapshot.messages[1].order = 7
        let decoded = try HandoffSnapshotCodec.decode(
            try HandoffSnapshotCodec.encodeUnchecked(snapshot), expectedConversationID: id
        )
        #expect(decoded.title.count <= HandoffSnapshotCodec.maxTitleCharacters)
        #expect(!decoded.messages[1].text.contains("\u{0}"))
        let first = decoded.messages.first { $0.id == snapshot.messages[0].id }
        #expect(first?.text == "Bonjour[31m\nsuite")
        let second = decoded.messages.first { $0.id == snapshot.messages[1].id }
        #expect((second?.text.count ?? Int.max) <= HandoffSnapshotCodec.maxMessageCharacters)
        // L'ordre relatif (le message d'ordre 7 vient avant celui d'ordre 40) et des ordres consécutifs.
        #expect(decoded.messages.map(\.id) == [snapshot.messages[1].id, snapshot.messages[0].id])
        #expect(decoded.messages.map(\.order) == [0, 1])
    }

    // MARK: Aide

    private func replacing(in data: Data, _ target: String, with replacement: String) throws -> Data {
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(target))
        return Data(text.replacingOccurrences(of: target, with: replacement).utf8)
    }
}
