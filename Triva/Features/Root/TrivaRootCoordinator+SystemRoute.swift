//
//  TrivaRootCoordinator+SystemRoute.swift
//  Triva
//
//  Chantier 2.1 (mission A) : ce que fait UNE fenêtre d'une route du système. Aucune route n'envoie de question.
//

import Foundation

/// Ce que la fenêtre a fait d'une route (pour les tests et le journal).
nonisolated enum SystemRouteOutcome: Equatable, Sendable {
    /// Recherche vide affichée, clavier demandé.
    case newQuestion
    /// Texte placé dans la barre de saisie, rien n'est parti.
    case draftPlaced
    /// Conversation ouverte (ici, ou fenêtre qui la tenait passée devant).
    case conversationOpened
    /// Conversation introuvable : la Recherche dit « Cette conversation n'existe plus. ».
    case conversationMissing
    /// Fichier partagé joint à la conversation de la fenêtre (PDF ou image), rien n'est parti.
    case attachmentPlaced
    /// Route sans effet (texte vide ou illisible).
    case ignored
}

extension TrivaRootCoordinator {
    /// Applique une route du système dans CETTE fenêtre.
    ///
    /// - `newQuestion` : le fil repart à neuf, la Recherche s'affiche, le curseur va dans la barre de saisie (demande
    ///   gardée jusqu'à l'apparition de la vue), SANS la garde du menu : l'item de menu est grisé quand le fil est
    ///   vide, la route doit quand même demander le clavier. Une réponse en cours n'est PAS arrêtée : elle finit en
    ///   arrière-plan, dans l'historique (`startNewConversationFromSystem`). Les fichiers déjà ENVOYÉS restent à
    ///   l'ancienne conversation ; ceux joints mais pas encore envoyés passent à la nouvelle.
    /// - `draft` : texte assaini dans la barre de saisie, Recherche affichée, JAMAIS envoyé.
    /// - `attachment` : fichier partagé, joint à la conversation de la fenêtre (voir `applyAttachment`).
    /// - `conversation` : comme depuis la Bibliothèque (`openConversationFromHistory`) : une conversation tenue par
    ///   une autre fenêtre la ramène devant. Inconnue, la Recherche affiche l'erreur « Cette conversation n'existe
    ///   plus. » et garde le fil en cours.
    ///
    /// - Parameters:
    ///   - canUseOtherWindows: l'appareil ouvre plusieurs fenêtres (`supportsMultipleWindows`).
    ///   - openInWindow: ouvre ou ramène la fenêtre d'une conversation (repli, `openWindow(value:)`).
    @discardableResult
    func apply(
        _ route: SystemRoute,
        canUseOtherWindows: Bool = false,
        openInWindow: (UUID) -> Void = { _ in }
    ) -> SystemRouteOutcome {
        switch route {
        case .newQuestion:
            return applyNewQuestion()
        case .draft(let text):
            return applyDraft(text)
        case .conversation(let id):
            return applyConversation(id, canUseOtherWindows: canUseOtherWindows, openInWindow: openInWindow)
        case .attachment(let url):
            return applyAttachment(url)
        }
    }

    // MARK: - Privé

    private func applyNewQuestion() -> SystemRouteOutcome {
        selection = .search
        session.ensureChatViewModel()
        session.chatViewModel?.startNewConversationFromSystem()
        syncWindowTarget()
        return .newQuestion
    }

    private func applyDraft(_ text: String) -> SystemRouteOutcome {
        guard let clean = ExternalQuerySanitizer.sanitize(text) else { return .ignored }
        session.draft.text = clean
        selection = .search
        return .draftPlaced
    }

    /// Fichier partagé (PDF ou image) : joint à la conversation de la fenêtre par le point d'entrée du glisser-déposer
    /// (`receiveDrop`), donc lu en local, copie pour le Coup d'œil, JAMAIS envoyé. Seul un fichier des dépôts de l'app est
    /// accepté : une route ne peut pas faire lire un autre fichier de l'utilisateur.
    private func applyAttachment(_ url: URL) -> SystemRouteOutcome {
        guard SystemRouteCenter.isDeposit(url, root: AttachmentFileVault.defaultRootDirectory) else { return .ignored }
        let item: DroppedItem = AttachmentKind(fileName: url.lastPathComponent) == .image ? .image(url) : .attachment(url)
        guard receiveDrop([item]) != nil else { return .ignored }
        return .attachmentPlaced
    }

    private func applyConversation(
        _ id: UUID,
        canUseOtherWindows: Bool,
        openInWindow: (UUID) -> Void
    ) -> SystemRouteOutcome {
        let exists = conversationIsKnown(id)
        openConversationFromHistory(id: id, canUseOtherWindows: canUseOtherWindows, openInWindow: openInWindow)
        return exists ? .conversationOpened : .conversationMissing
    }

    /// Faux si la conversation est absente. Une lecture qui échoue compte comme « existe » : le chat affiche alors
    /// lui-même l'erreur de lecture (même règle que la restauration des fenêtres).
    private func conversationIsKnown(_ id: UUID) -> Bool {
        do {
            return try session.stores.chatHistory.conversation(with: id) != nil
        } catch {
            return true
        }
    }
}
