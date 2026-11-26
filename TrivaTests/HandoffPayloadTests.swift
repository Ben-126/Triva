//
//  HandoffPayloadTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H1) : ce que Triva propose à un autre appareil par Handoff. Le texte vient de l'extérieur à
//  l'arrivée (entrée EXTERNE) : assaini, coupé, jamais envoyé. Taille : la doc d'Apple demande moins de 3 Ko.
//

import Foundation
import Testing
@testable import Triva

@Suite("Handoff : contenu de l'activité")
struct HandoffPayloadTests {
    private let id = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!

    @Test("Le type d'activité est celui déclaré dans NSUserActivityTypes (Config/)")
    func activityTypeIsStable() {
        #expect(HandoffPayload.activityType == "com.benpodrojsky.Triva.search")
    }

    @Test("Le type d'activité est bien déclaré dans l'Info.plist de l'app construite")
    func activityTypeIsDeclaredInTheBuiltApp() throws {
        let declared = Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]
        #expect(declared == [HandoffPayload.activityType])
    }

    @Test("Un texte simple : version 1, le texte, et rien d'autre")
    func minimalUserInfo() throws {
        let payload = try #require(HandoffPayload(draft: "Quelle heure est-il à Tokyo ?"))
        let info = payload.userInfo
        #expect(info["v"] as? Int == 1)
        #expect(info["draft"] as? String == "Quelle heure est-il à Tokyo ?")
        #expect(info["conversationID"] == nil)
        #expect(Set(info.keys) == ["v", "draft"])
    }

    @Test("Avec un identifiant de conversation, il part en texte : il annonce que la discussion peut être demandée")
    func conversationIDIsCarried() throws {
        let payload = try #require(HandoffPayload(draft: "Suite", conversationID: id))
        #expect(payload.userInfo["conversationID"] as? String == id.uuidString)
    }

    @Test("Accents, emoji et écritures non latines passent l'aller-retour")
    func roundTrip() throws {
        for text in ["Où sont passés les élèves ?", "Café ☕️ à Zürich", "東京の天気は？", "👨‍👩‍👧‍👦 en famille", "ligne un\nligne deux"] {
            let payload = try #require(HandoffPayload(draft: text, conversationID: id))
            let decoded = try #require(HandoffPayload(userInfo: payload.userInfo))
            #expect(decoded == payload)
            #expect(decoded.draft == text)
            #expect(decoded.conversationID == id)
        }
    }

    @Test("Le texte est coupé à 1 200 caractères visibles")
    func draftIsCutAtTwelveHundredCharacters() throws {
        let payload = try #require(HandoffPayload(draft: String(repeating: "a", count: 5_000)))
        #expect(payload.draft.count == HandoffPayload.maxDraftCharacters)
        #expect(HandoffPayload.maxDraftCharacters == 1_200)
    }

    @Test("Le plus gros contenu possible tient sous 2 500 octets, même en caractères lourds")
    func sizeStaysUnderTheBudget() throws {
        let heavy = [
            String(repeating: "a", count: 5_000),
            String(repeating: "é", count: 5_000),
            String(repeating: "東", count: 5_000),
            String(repeating: "😀", count: 5_000),
            String(repeating: "👨‍👩‍👧‍👦", count: 1_500),
            String(repeating: "🏳️‍🌈", count: 1_500),
        ]
        for text in heavy {
            let payload = try #require(HandoffPayload(draft: text, conversationID: id))
            #expect(payload.encodedByteCount < HandoffPayload.maxEncodedBytes)
            #expect(payload.draft.count <= HandoffPayload.maxDraftCharacters)
            #expect(!payload.draft.isEmpty)
        }
        #expect(HandoffPayload.maxEncodedBytes == 2_500)
    }

    @Test("Couper pour la taille ne casse jamais un emoji composé")
    func cutDoesNotSplitACharacter() throws {
        let family = "👨‍👩‍👧‍👦"
        let payload = try #require(HandoffPayload(draft: String(repeating: family, count: 1_500)))
        #expect(payload.draft.allSatisfy { String($0) == family })
    }

    @Test("Les caractères invisibles et de contrôle sont retirés (même assainissement que les autres entrées externes)")
    func draftIsSanitized() throws {
        let tagCharacter = "\u{E0041}"
        let payload = try #require(HandoffPayload(draft: "  Bon\u{200B}jour\(tagCharacter)\u{202E}  \t"))
        #expect(payload.draft == "Bonjour")
    }

    @Test("Rien à proposer si le texte est vide, blanc ou absent")
    func emptyDraftIsRefused() {
        #expect(HandoffPayload(draft: nil) == nil)
        #expect(HandoffPayload(draft: "") == nil)
        #expect(HandoffPayload(draft: "  \n\t ") == nil)
        #expect(HandoffPayload(draft: "\u{200B}\u{200B}") == nil)
    }

    // MARK: Lecture (entrée externe)

    @Test("Une version inconnue, absente ou mal typée est refusée")
    func unknownVersionIsRefused() {
        #expect(HandoffPayload(userInfo: ["v": 2, "draft": "Bonjour"]) == nil)
        #expect(HandoffPayload(userInfo: ["v": 0, "draft": "Bonjour"]) == nil)
        #expect(HandoffPayload(userInfo: ["draft": "Bonjour"]) == nil)
        #expect(HandoffPayload(userInfo: ["v": "1", "draft": "Bonjour"]) == nil)
    }

    @Test("Un contenu illisible est refusé : pas de userInfo, texte absent, mal typé ou vide")
    func malformedUserInfoIsRefused() {
        #expect(HandoffPayload(userInfo: nil) == nil)
        #expect(HandoffPayload(userInfo: [:]) == nil)
        #expect(HandoffPayload(userInfo: ["v": 1]) == nil)
        #expect(HandoffPayload(userInfo: ["v": 1, "draft": 42]) == nil)
        #expect(HandoffPayload(userInfo: ["v": 1, "draft": "   "]) == nil)
    }

    @Test("Un texte reçu est assaini et recoupé : l'autre appareil n'est pas digne de confiance")
    func receivedDraftIsSanitizedAndCut() throws {
        let hostile = "Bon\u{200B}jour" + String(repeating: "b", count: 5_000)
        let decoded = try #require(HandoffPayload(userInfo: ["v": 1, "draft": hostile]))
        #expect(decoded.draft.hasPrefix("Bonjourb"))
        #expect(decoded.draft.count == HandoffPayload.maxDraftCharacters)
    }

    @Test("Un identifiant de conversation illisible est ignoré, le texte reste")
    func invalidConversationIDIsIgnored() throws {
        let decoded = try #require(HandoffPayload(userInfo: ["v": 1, "draft": "Bonjour", "conversationID": "pas-un-uuid"]))
        #expect(decoded.conversationID == nil)
        #expect(decoded.draft == "Bonjour")
        let typed = try #require(HandoffPayload(userInfo: ["v": 1, "draft": "Bonjour", "conversationID": 12]))
        #expect(typed.conversationID == nil)
    }

    @Test("Le genre du texte : tapé (par défaut, rien d'écrit en plus) ou dernière question (clé typed = false)")
    func draftKindRoundTrips() throws {
        let typed = try #require(HandoffPayload(draft: "Texte"))
        #expect(typed.draftIsTyped)
        #expect(typed.userInfo["typed"] == nil)
        let last = try #require(HandoffPayload(draft: "Texte", conversationID: id, draftIsTyped: false))
        #expect(last.userInfo["typed"] as? Bool == false)
        let decoded = try #require(HandoffPayload(userInfo: last.userInfo))
        #expect(decoded == last)
        #expect(decoded.draftIsTyped == false)
        // Une valeur mal typée est lue comme « tapé » (le texte reste utilisable).
        let odd = try #require(HandoffPayload(userInfo: ["v": 1, "draft": "Texte", "typed": "non"]))
        #expect(odd.draftIsTyped)
    }

    @Test("Les clés inconnues sont ignorées (une version future qui ajoute un champ reste lisible tant que v vaut 1)")
    func unknownKeysAreIgnored() throws {
        let decoded = try #require(HandoffPayload(userInfo: ["v": 1, "draft": "Bonjour", "answer": "Une réponse"]))
        #expect(decoded == HandoffPayload(draft: "Bonjour"))
        #expect(decoded.userInfo["answer"] == nil)
    }
}
