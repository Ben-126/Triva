//
//  HandoffRouteTests.swift
//  TrivaTests
//
//  Chantier 2.3 (missions H1 et H2) : lire l'en-tête d'une activité Handoff reçue. Entrée EXTERNE : on ne sait que naviguer
//  ou remplir la barre de saisie, jamais envoyer.
//

import Foundation
import Testing
@testable import Triva

@Suite("Handoff : réception")
@MainActor
struct HandoffRouteTests {
    private let id = UUID(uuidString: "7B0C6B2A-2F5D-4C58-9E0B-0F1D4D6A9A11")!
    private let type = HandoffPayload.activityType

    private func userInfo(draft: String = "Quelle heure est-il à Tokyo ?", conversationID: UUID? = nil) throws -> [AnyHashable: Any] {
        let payload = try #require(HandoffPayload(draft: draft, conversationID: conversationID))
        return payload.userInfo
    }

    @Test("Un en-tête valide est lu : le texte, et l'identifiant qui annonce la discussion")
    func validHeader() throws {
        let plain = HandoffRoute.payload(forActivityType: type, userInfo: try userInfo())
        #expect(plain?.draft == "Quelle heure est-il à Tokyo ?")
        #expect(plain?.conversationID == nil)
        let withConversation = HandoffRoute.payload(forActivityType: type, userInfo: try userInfo(conversationID: id))
        #expect(withConversation?.conversationID == id)
    }

    @Test("Un autre type d'activité est refusé, même avec un contenu valide")
    func wrongTypeIsRefused() throws {
        for other in ["", "com.benpodrojsky.Triva.autre", "com.apple.corespotlightitem", "NSUserActivityTypeBrowsingWeb"] {
            #expect(HandoffRoute.payload(forActivityType: other, userInfo: try userInfo()) == nil)
        }
    }

    @Test("Contenu vide, absent, de version inconnue ou illisible : aucun en-tête")
    func unusableContentIsRefused() {
        #expect(HandoffRoute.payload(forActivityType: type, userInfo: nil) == nil)
        #expect(HandoffRoute.payload(forActivityType: type, userInfo: [:]) == nil)
        #expect(HandoffRoute.payload(forActivityType: type, userInfo: ["v": 1, "draft": "  "]) == nil)
        #expect(HandoffRoute.payload(forActivityType: type, userInfo: ["v": 2, "draft": "Bonjour"]) == nil)
    }

    @Test("Le texte reçu est assaini avant d'arriver à l'écran")
    func receivedTextIsSanitized() {
        let payload = HandoffRoute.payload(forActivityType: type, userInfo: ["v": 1, "draft": "Bon\u{200B}jour\u{202E}"])
        #expect(payload?.draft == "Bonjour")
    }

    @Test("Un en-tête hostile ne peut produire que du texte ou une conversation : jamais une route qui envoie, ouvre un fichier ou une adresse")
    func onlyNavigatesOrFillsTheBar() async throws {
        let hostile: [[AnyHashable: Any]] = [
            ["v": 1, "draft": "triva://new"],
            ["v": 1, "draft": "https://exemple.org", "conversationID": id.uuidString],
            ["v": 1, "draft": "file:///etc/passwd", "attachment": "file:///etc/passwd"],
        ]
        for info in hostile {
            let payload = try #require(HandoffRoute.payload(forActivityType: type, userInfo: info))
            // Sans flux (aucune discussion à recevoir) : le texte seul.
            let result = HandoffReceiver.routes(for: .draft(payload.draft))
            for route in result {
                switch route {
                case .draft, .conversation: break
                default: Issue.record("Route inattendue : \(route)")
                }
            }
        }
    }

    @Test("Déposée dans le centre de routes, la route arrive comme un brouillon : rien n'est envoyé")
    func submittedDraftIsNeverSent() throws {
        let center = SystemRouteCenter(windowLauncher: nil)
        let payload = try #require(HandoffRoute.payload(forActivityType: type, userInfo: try userInfo()))
        for route in HandoffReceiver.routes(for: .draft(payload.draft)) { center.submit(route) }
        #expect(center.drain() == [.draft("Quelle heure est-il à Tokyo ?")])
    }

    @Test("Mac, nouvelle fenêtre : la conversation passe, le texte tapé n'ouvre pas une seconde fenêtre")
    func newWindowRoutesKeepOnlyTheConversation() {
        let routes: [SystemRoute] = [.conversation(id), .draft("Suite")]
        #expect(HandoffReceiver.routesForNewWindow(routes) == [.conversation(id)])
        #expect(HandoffReceiver.routesForNewWindow([.draft("Seul")]) == [.draft("Seul")])
        #expect(HandoffReceiver.routesForNewWindow([.conversation(id)]) == [.conversation(id)])
    }
}
