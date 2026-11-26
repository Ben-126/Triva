//
//  HandoffReceiver.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : ce que fait le receveur d'une activité Handoff.
//    - l'en-tête annonce une discussion : on la demande par les flux, on la vérifie, on l'enregistre (fusion ou nouvelle
//      conversation), puis on l'ouvre ; le texte tapé, s'il y en a un, va dans la barre de saisie ;
//    - le flux échoue (délai, coupure, refus, contenu refusé, base indisponible) : repli sur le texte de H1 (brouillon, ou
//      dernière question), et un message clair dit que la discussion n'est pas arrivée ;
//    - pas de discussion annoncée : le texte seul, comme H1.
//  Rien n'est jamais envoyé : le résultat ne se traduit qu'en routes qui naviguent ou remplissent la barre de saisie.
//

import Foundation

/// Les flux de continuation, tels que le système les donne (ou non).
protocol HandoffStreamSource: Sendable {
    func streams() async throws -> HandoffStreamPair
}

@MainActor
protocol HandoffConversationFetching {
    func fetch(expectedID: UUID) async throws -> HandoffConversationSnapshot
}

@MainActor
protocol HandoffConversationImporting {
    func importHandoff(_ snapshot: HandoffConversationSnapshot, isHeldByAWindow: Bool) throws -> HandoffImportResult
}

/// Récupère la discussion par les flux d'une source (le système, ou des tuyaux factices dans les tests).
struct HandoffStreamFetcher: HandoffConversationFetching {
    let source: any HandoffStreamSource
    var timeout: Duration = HandoffStreamTransfer.defaultTimeout

    init(source: any HandoffStreamSource, timeout: Duration = HandoffStreamTransfer.defaultTimeout) {
        self.source = source
        self.timeout = timeout
    }

    func fetch(expectedID: UUID) async throws -> HandoffConversationSnapshot {
        let streams = try await source.streams()
        return try await HandoffStreamTransfer.fetchSnapshot(over: streams, expectedID: expectedID, timeout: timeout)
    }
}

nonisolated enum HandoffReceiveResult: Equatable, Sendable {
    /// Discussion enregistrée (sous cet identifiant) ; `draft` : le texte tapé à mettre dans la barre.
    case conversation(id: UUID, draft: String?)
    /// Aucune discussion annoncée : le texte seul (comportement de H1).
    case draft(String)
    /// La discussion n'est pas arrivée : le texte seul, et un message le dit.
    case fellBack(draft: String)
    /// Annulé (une autre activité est arrivée) : rien à faire.
    case cancelled
}

@MainActor
enum HandoffReceiver {
    /// « À valider par Ben ».
    static let fallbackNotice = "La discussion n'a pas pu arriver depuis l'autre appareil. Seul le texte de ta question a été repris."

    static func receive(
        payload: HandoffPayload,
        fetcher: (any HandoffConversationFetching)?,
        importer: any HandoffConversationImporting,
        isHeldByAWindow: (UUID) -> Bool
    ) async -> HandoffReceiveResult {
        guard let announcedID = payload.conversationID, let fetcher else { return .draft(payload.draft) }
        do {
            let snapshot = try await fetcher.fetch(expectedID: announcedID)
            guard snapshot.id == announcedID else { return .fellBack(draft: payload.draft) }
            let imported = try importer.importHandoff(snapshot, isHeldByAWindow: isHeldByAWindow(announcedID))
            return .conversation(id: imported.conversationID, draft: payload.draftIsTyped ? payload.draft : nil)
        } catch is CancellationError {
            return .cancelled
        } catch HandoffTransferError.cancelled {
            return .cancelled
        } catch {
            return .fellBack(draft: payload.draft)
        }
    }

    /// Les routes à appliquer : ouvrir la conversation, puis remplir la barre. Jamais un envoi.
    static func routes(for result: HandoffReceiveResult) -> [SystemRoute] {
        switch result {
        case .conversation(let id, let draft):
            [SystemRoute.conversation(id)] + (draft.map { [SystemRoute.draft($0)] } ?? [])
        case .draft(let text), .fellBack(let text):
            [.draft(text)]
        case .cancelled:
            []
        }
    }

    /// Mac : ouvrir une conversation dans une NOUVELLE fenêtre ne peut pas y déposer le texte tapé (le lanceur de fenêtres
    /// ouvrirait une seconde fenêtre pour le texte). La conversation passe, le texte tapé est laissé de côté.
    static func routesForNewWindow(_ routes: [SystemRoute]) -> [SystemRoute] {
        let hasConversation = routes.contains { if case .conversation = $0 { true } else { false } }
        guard hasConversation else { return routes }
        return routes.filter { if case .draft = $0 { false } else { true } }
    }
}
