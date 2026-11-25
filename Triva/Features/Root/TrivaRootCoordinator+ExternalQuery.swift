//
//  TrivaRootCoordinator+ExternalQuery.swift
//  Triva
//
//  Chantier 2.2 (M7) : une fenêtre ouverte par le Service « Rechercher avec Triva » ou la barre des menus
//  reprend la question qui l'attend. Mission F3 : la question TAPÉE dans la barre des menus est envoyée.
//

import Foundation

/// Ce que la fenêtre a fait d'une question reçue de l'extérieur.
nonisolated enum ExternalQueryOutcome: Equatable, Sendable {
    /// Aucune question n'attendait cette fenêtre.
    case none
    /// La question est dans la barre de saisie, rien n'est parti (Service, partage, dépôt ; ou envoi impossible).
    case draftPlaced
    /// La question est partie.
    case sent
    /// La question est dans la barre de saisie et la feuille d'accord « IA cloud » attend la réponse de
    /// l'utilisateur ; rien n'est parti.
    case awaitingConsent
}

extension TrivaRootCoordinator {
    /// Voir `deliverExternalQuery(from:)`. `true` si une question attendait cette fenêtre.
    @discardableResult
    func receiveExternalQuery(from inbox: ExternalQueryInbox?) -> Bool {
        deliverExternalQuery(from: inbox) != .none
    }

    /// Si la cible de la fenêtre est une recherche neuve dont la question attend dans la boîte d'entrée, la place
    /// dans la barre de saisie et affiche la Recherche. Ensuite, selon l'ORIGINE (`ExternalQueryOrigin`) :
    /// - `.draft` (Service, partage, dépôt) : la question n'est PAS envoyée, elle quitterait l'appareil sans que
    ///   l'utilisateur ait relu ce qu'il avait sélectionné ;
    /// - `.typedInMenuBar` : l'utilisateur l'a tapée dans le panneau de Triva, c'est son envoi. Elle part comme
    ///   si elle avait été validée dans la barre de saisie, accord « IA cloud » demandé avant si besoin.
    ///
    /// La boîte rend le texte une seule fois : une fenêtre restaurée au relancement (identifiant ancien) ou
    /// une seconde fenêtre sur la même cible n'obtient rien.
    func deliverExternalQuery(from inbox: ExternalQueryInbox?) -> ExternalQueryOutcome {
        guard let inbox,
              case .newSearch(let id) = windowTarget,
              let query = inbox.takeQuery(for: id) else { return .none }
        session.draft.text = query.text
        selection = .search
        if query.wasTruncated { announceTruncatedQuery() }
        switch query.origin {
        case .draft: return .draftPlaced
        case .typedInMenuBar: return sendTypedQuery(query.text)
        }
    }

    /// Texte coupé à 2000 caractères : une note discrète sous la barre de saisie (K2), jamais un blocage.
    private func announceTruncatedQuery() {
        session.ensureChatViewModel()
        session.chatViewModel?.attachmentController.reportTruncatedText()
    }

    /// Même enchaînement que `ChatView.request` : accord cloud d'abord (la question reste alors dans la barre de
    /// saisie, la feuille d'accord de la Recherche l'attend), puis la barre est vidée et l'envoi part.
    ///
    /// Moteur pas prêt (Apple Intelligence indisponible, aucun modèle MLX, aucun fournisseur cloud) : la Recherche
    /// montre alors l'écran qui explique quoi faire, pas le chat ; la question reste dans la barre de saisie
    /// plutôt que de partir vers un chat invisible.
    private func sendTypedQuery(_ text: String) -> ExternalQueryOutcome {
        session.refreshAppleIntelligenceAvailabilityIfNeeded()
        guard session.setupRequirement == nil else { return .draftPlaced }
        session.ensureChatViewModel()
        guard let chat = session.chatViewModel, !chat.isGenerating else { return .draftPlaced }
        let action = PendingSendAction.send(query: text)
        if chat.requestConsent(resuming: action) { return .awaitingConsent }
        session.draft.text = ""
        chat.start(action)
        return .sent
    }
}
