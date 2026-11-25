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
    /// Information affichée sous les capsules (texte coupé, fichier non copié), rien d'autre n'a changé.
    case noticeShown
    /// Route sans effet (texte vide ou illisible).
    case ignored
}

extension TrivaRootCoordinator {
    /// Applique une route du système dans CETTE fenêtre.
    ///
    /// - `newQuestion` : le fil repart à neuf, la Recherche s'affiche, le curseur va dans la barre de saisie (demande
    ///   gardée jusqu'à l'apparition de la vue), SANS la garde du menu : l'item de menu est grisé quand le fil est
    ///   vide, la route doit quand même demander le clavier. Une réponse en cours n'est PAS arrêtée : elle finit en
    ///   arrière-plan, dans l'historique (`startNewConversationFromSystem`, le même chemin que le bouton et ⇧⌘O). Les
    ///   fichiers joints, envoyés ou non, sont retirés avec leur copie ; un partage qui arrive ENSUITE est joint normalement.
    /// - `draft` : texte assaini ajouté à la barre de saisie (le brouillon en cours est gardé), Recherche affichée, JAMAIS envoyé.
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
        let outcome: SystemRouteOutcome
        switch route {
        case .newQuestion:
            outcome = applyNewQuestion()
        case .draft(let text):
            outcome = applyDraft(text)
        case .conversation(let id):
            outcome = applyConversation(id, canUseOtherWindows: canUseOtherWindows, openInWindow: openInWindow)
        case .attachment(let url):
            outcome = applyAttachment(url)
        case .notice(let notice):
            outcome = applyNotice(notice)
        }
        // Une feuille ou une couverture ouverte (choix du moteur, Réglages, Coup d'œil, Safari intégré) cacherait ce que
        // la route vient de faire : l'utilisateur verrait toujours l'ancien écran (X2, R2-11). Une route sans effet
        // ne ferme rien.
        if outcome != .ignored { closePresentations() }
        return outcome
    }

    /// Prend les routes du système en attente (iPhone, iPad) et les applique à CETTE fenêtre, sauf pendant la feuille
    /// d'accord « IA cloud » : elle est modale et son envoi appartient au fil affiché ; une route qui changerait de fil ou
    /// de pièces jointes dessous ferait partir la question vers le mauvais endroit (X2, C1). Les routes restent dans la file
    /// et sont prises à la fermeture de la feuille (la coquille rappelle cette méthode quand l'attente disparaît).
    /// - Returns: le nombre de routes rendues par la file.
    @discardableResult
    func consumeSystemRoutes(
        from center: SystemRouteCenter = .shared,
        canUseOtherWindows: Bool,
        openInWindow: (UUID) -> Void
    ) -> Int {
        guard session.chatViewModel?.pendingConsent == nil else { return 0 }
        let routes = center.drain()
        // Des fichiers qui se suivent (plusieurs partages repris d'un coup) sont joints D'UN BLOC : un dépôt remplace les
        // informations déjà affichées, et la limite de fichiers doit citer tous les refusés, pas seulement le dernier.
        var attachments: [URL] = []
        for route in routes {
            if case .attachment(let url) = route {
                attachments.append(url)
                continue
            }
            applyAttachments(attachments)
            attachments = []
            apply(route, canUseOtherWindows: canUseOtherWindows, openInWindow: openInWindow)
        }
        applyAttachments(attachments)
        return routes.count
    }

    // MARK: - Privé

    private func applyNewQuestion() -> SystemRouteOutcome {
        selection = .search
        session.ensureChatViewModel()
        session.chatViewModel?.startNewConversationFromSystem()
        syncWindowTarget()
        return .newQuestion
    }

    /// Le texte partagé s'AJOUTE au brouillon en cours (décision de Ben, QUESTIONS-BEN 54 : rien n'est perdu), comme un
    /// texte déposé (`receiveDrop`). Coupé à la limite, une note le dit sous la barre de saisie.
    private func applyDraft(_ text: String) -> SystemRouteOutcome {
        guard let clean = ExternalQuerySanitizer.sanitizeReportingTruncation(text) else { return .ignored }
        session.draft.text = DropPlan.appending([clean.text], to: session.draft.text)
        selection = .search
        if clean.wasTruncated {
            session.ensureChatViewModel()
            session.chatViewModel?.attachmentController.reportTruncatedText()
        }
        return .draftPlaced
    }

    /// Fichier partagé (PDF ou image) : joint à la conversation de la fenêtre par le point d'entrée du glisser-déposer
    /// (`receiveDrop`), donc lu en local, copie pour le Coup d'œil, JAMAIS envoyé. Seul un fichier des dépôts de l'app est
    /// accepté : une route ne peut pas faire lire un autre fichier de l'utilisateur.
    private func applyAttachment(_ url: URL) -> SystemRouteOutcome {
        applyAttachmentBatch([url])
    }

    /// Plusieurs fichiers partagés d'un bloc (même effet qu'une `apply` par fichier, sans perdre les refus des premiers).
    @discardableResult
    private func applyAttachments(_ urls: [URL]) -> SystemRouteOutcome {
        guard !urls.isEmpty else { return .ignored }
        let outcome = applyAttachmentBatch(urls)
        if outcome != .ignored { closePresentations() }
        return outcome
    }

    private func applyAttachmentBatch(_ urls: [URL]) -> SystemRouteOutcome {
        let items: [DroppedItem] = urls
            .filter { SystemRouteCenter.isDeposit($0, root: AttachmentFileVault.defaultRootDirectory) }
            .map { AttachmentKind(fileName: $0.lastPathComponent) == .image ? .image($0) : .attachment($0) }
        guard !items.isEmpty, receiveDrop(items) != nil else { return .ignored }
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
