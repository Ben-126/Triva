//
//  TrivaRootCoordinator+Commands.swift
//  Triva
//
//  Chantier 2.2 (M4) : ce que font les items de la barre de menus (`TrivaCommands`). Chaque item agit sur la
//  fenêtre au premier plan, donc sur SON coordinateur ; la logique vit ici, testée sans interface.
//

import Foundation

extension TrivaRootCoordinator {
    // MARK: - États (grisent les items)

    /// « Nouvelle conversation » : sans message affiché, il n'y a rien à fermer (comme le bouton de la barre d'outils).
    var canStartNewConversation: Bool {
        !(session.chatViewModel?.messages.isEmpty ?? true)
    }

    /// « Arrêter la réponse » : seulement pendant une génération.
    var canStopGeneration: Bool {
        session.chatViewModel?.isGenerating ?? false
    }

    /// « Copier la réponse » : la dernière réponse du fil, quand elle est terminée.
    var copyableAnswerText: String? {
        Self.copyableAnswerText(in: session.chatViewModel?.messages ?? [])
    }

    // MARK: - Actions

    /// Aller > Recherche / Découvrir / Bibliothèque / Favoris (⌘1 à ⌘4).
    func go(to destination: TrivaRootDestination) {
        selection = destination
    }

    /// Fichier > Nouvelle conversation (⇧⌘O) : dans CETTE fenêtre, depuis n'importe quelle destination. Sans
    /// effet quand le fil est vide (item grisé : le raccourci ne doit pas non plus agir).
    func startNewConversationFromMenu() {
        guard canStartNewConversation else { return }
        selection = .search
        session.chatViewModel?.startNewConversationFromUser()
    }

    /// Conversation > Arrêter la réponse (⌘.) : même effet que le bouton Stop, réponse partielle gardée.
    func stopGeneration() {
        guard canStopGeneration else { return }
        session.chatViewModel?.stop()
    }

    /// Édition > Copier la réponse (⇧⌘C) : même presse-papiers que le bouton sous la réponse (texte marqué
    /// « généré par IA » + métadonnée).
    /// - Returns: `false` quand il n'y avait rien à copier (pour les tests).
    @discardableResult
    func copyLastAnswer(writer: (String) -> Void = { AnswerPasteboard.copy($0) }) -> Bool {
        guard let text = copyableAnswerText else { return false }
        writer(text)
        return true
    }

    /// Fichier > Joindre des fichiers… (⇧⌘A) : ouvre le sélecteur de la Recherche (limites 1.11 comprises).
    ///
    /// Le sélecteur appartient au composeur de la Recherche : hors de cette destination, on y revient d'abord et
    /// on laisse à la vue le temps d'apparaître, sans quoi `fileImporter` serait créé en même temps que son
    /// drapeau et pourrait ne jamais s'ouvrir.
    func requestAttachFiles() {
        session.ensureChatViewModel()
        guard let controller = session.chatViewModel?.attachmentController else { return }
        guard selection != .search else {
            controller.requestPicker()
            return
        }
        selection = .search
        Task { [weak self] in
            try? await Task.sleep(for: Self.searchAppearanceDelay)
            // L'utilisateur est reparti ailleurs pendant l'attente : le sélecteur ne doit pas s'ouvrir « tout seul »
            // à son prochain retour sur la Recherche.
            guard self?.selection == .search else { return }
            controller.requestPicker()
        }
    }

    /// Édition > Rechercher dans l'historique (⌘F) : Bibliothèque, curseur dans le champ de recherche.
    func requestHistorySearch() {
        selection = .library
        isHistorySearchRequested = true
    }

    // MARK: - Règles pures

    /// Laisse la Recherche (re)apparaître avant d'ouvrir le sélecteur.
    private static let searchAppearanceDelay: Duration = .milliseconds(350)

    /// Texte à copier : la DERNIÈRE réponse du fil, seulement si elle est terminée et a du texte. Une réponse
    /// en cours, arrêtée ou en échec ne se copie pas (comme les boutons sous la bulle, `AnswerShareText.isOffered`).
    static func copyableAnswerText(in messages: [ChatViewModel.Message]) -> String? {
        guard let last = messages.last(where: { $0.role == .assistant }), last.status == .completed else { return nil }
        let segments = last.segments
        guard AnswerShareText.isOffered(state: .completed, hasText: segments.tldr != nil || !segments.body.isEmpty) else {
            return nil
        }
        return AnswerShareText.text(tldr: segments.tldr, body: segments.body, sources: last.sources)
    }
}
