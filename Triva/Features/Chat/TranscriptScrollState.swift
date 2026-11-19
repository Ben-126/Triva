//
//  TranscriptScrollState.swift
//  Triva
//
//  Mission I1 (2.0, iPhone Duo).
//

import Foundation

/// Position de lecture du fil de la Recherche, détenue par la `SearchSession` plutôt que par
/// `ChatView`. Plier ou déplier l'iPhone Duo change la classe de taille : la coquille passe de la
/// barre d'onglets à la barre latérale (ou l'inverse), `ChatView` est démontée puis remontée, et ses
/// `@State` seraient perdus (retour en bas du fil, ou au début de la dernière réponse, alors que le
/// lecteur relisait un passage). Ici, la position survit au remontage.
///
/// Trois valeurs, les mêmes que celles que `ChatView` gardait en `@State` :
/// - `anchorMessageID` : le message qui se trouve en haut de la zone visible, `nil` tant que le fil
///   n'a pas défilé ;
/// - `isPinnedToBottom` : le fil suit-il le bas (génération en cours, lecteur en bas) ? Voir
///   `ChatScrollFollowing` ;
/// - `lastPositionedConversationID` : dernière conversation dont le début de réponse a été montré,
///   pour ne recentrer qu'à l'OUVERTURE d'une autre conversation.
/// Aucune des valeurs n'est observée (`@ObservationIgnored`) : elles changent à chaque image de
/// défilement, et aucune vue ne s'affiche d'après elles, seulement les gestes qui les lisent. Observées,
/// elles réévalueraient le fil à chaque pixel.
@Observable
@MainActor
final class TranscriptScrollState {
    @ObservationIgnored var anchorMessageID: UUID?
    @ObservationIgnored var isPinnedToBottom = true
    @ObservationIgnored var lastPositionedConversationID: UUID?
    /// Réponse dont le volet de sources (Duo déplié, mission I2) montre les sources : touchée par une citation.
    /// `nil` : la dernière réponse (voir `SourcesPaneFocus`). OBSERVÉE, contrairement aux autres : seul le
    /// volet la lit, et elle ne change qu'à un toucher, jamais à une image de défilement.
    var focusedAnswerID: UUID?
    /// Dernière réponse vue par `noteLastAnswer` : une réponse NOUVELLE (question de suite, autre conversation)
    /// fait repartir le volet de sources sur elle. Non observée : seul `focusedAnswerID` pilote l'affichage.
    @ObservationIgnored private var lastSeenAnswerID: UUID?
    /// Signale la dernière réponse du fil (`nil` : aucune). Quand elle CHANGE, la réponse ciblée par une citation
    /// est oubliée : le volet de sources suit la nouvelle réponse, dont les citations renvoient à ses sources
    /// (correction C3 de la revue R1). Idempotent : l'appeler de nouveau avec la même valeur (remontage de la
    /// vue au pliage) ne touche pas à la réponse ciblée. Appelée à chaque changement, y compris quand la
    /// génération vient d'une feuille de consentement ou qu'elle s'est faite hors de l'écran.
    func noteLastAnswer(_ id: UUID?) {
        guard id != lastSeenAnswerID else { return }
        lastSeenAnswerID = id
        focusedAnswerID = nil
    }

    /// Haut de chaque message dans le contenu défilant (pt), mis à jour par la mise en page.
    @ObservationIgnored var rowTops: [UUID: CGFloat] = [:]

    /// Ce que `ChatView` doit faire quand elle apparaît.
    enum AppearanceAction: Equatable, Sendable {
        /// Conversation pas encore positionnée par cette session (ouverture depuis la Bibliothèque ou un
        /// favori) : début de la dernière réponse.
        case showLastAnswerStart
        /// Remontage de la même conversation, lecteur en bas : l'ancrage par défaut en bas suffit.
        case stayAtBottom
        /// Remontage de la même conversation, lecteur remonté : retour au message gardé.
        case restore(messageID: UUID)
    }

    /// Règle pure, testée sans interface.
    nonisolated static func appearanceAction(
        currentConversationID: UUID?,
        lastPositionedConversationID: UUID?,
        isPinnedToBottom: Bool,
        anchorMessageID: UUID?
    ) -> AppearanceAction {
        if ChatScrollFollowing.shouldPositionOnAppear(current: currentConversationID, lastPositioned: lastPositionedConversationID) {
            return .showLastAnswerStart
        }
        guard !isPinnedToBottom, let anchorMessageID else { return .stayAtBottom }
        return .restore(messageID: anchorMessageID)
    }

    /// Message qui se trouve en haut de la zone visible : le dernier dont le haut est au plus à
    /// `offsetY`. `nil` tant qu'aucun haut n'est mesuré. Règle pure.
    nonisolated static func topVisibleMessage(orderedIDs: [UUID], rowTops: [UUID: CGFloat], offsetY: CGFloat) -> UUID? {
        var found: UUID?
        for id in orderedIDs {
            guard let top = rowTops[id] else { continue }
            if top <= offsetY + 1 || found == nil { found = id }
            if top > offsetY + 1 { break }
        }
        return found
    }

    /// Enregistre la position de lecture (appelée à chaque changement de géométrie du défilement).
    func recordPosition(orderedIDs: [UUID], offsetY: CGFloat) {
        anchorMessageID = Self.topVisibleMessage(orderedIDs: orderedIDs, rowTops: rowTops, offsetY: offsetY)
    }
}
