//
//  HandoffSnapshotSource.swift
//  Triva
//
//  Chantier 2.3 (mission H2) : ce que l'appareil d'origine accepte de servir quand l'autre demande la discussion.
//  Il répond pour la conversation ANNONCÉE par l'activité (pas celle qui s'affiche maintenant : l'utilisateur a pu en
//  changer depuis), et REVÉRIFIE à ce moment le réglage, l'interrupteur de code et l'existence de la conversation.
//  Il lit la BASE : une réponse encore en cours n'y est pas, donc n'est pas envoyée (« envoyer ce qui est fini »).
//

import Foundation

@MainActor
enum HandoffSnapshotSource {
    /// - Returns: la discussion codée, ou `nil` : rien n'est servi (réglage éteint, conversation absente ou vide, base
    ///   indisponible, discussion qui ne tient pas dans les plafonds).
    static func data(for conversationID: UUID?, isEnabled: Bool, store: ChatHistoryStore) -> Data? {
        guard isEnabled, HandoffPlan.offersConversation, let conversationID,
              let conversation = try? store.conversation(with: conversationID),
              !conversation.messageList.isEmpty else { return nil }
        return HandoffSnapshotCodec.encode(HandoffConversationSnapshot(conversation: conversation))?.data
    }
}
