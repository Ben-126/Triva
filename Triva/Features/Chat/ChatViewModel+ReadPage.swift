//
//  ChatViewModel+ReadPage.swift
//  Triva
//
//  « Lire cette page » refait la réponse en cours (décision de Ben, 2026-11-17, mission C5).
//  Une page que le site refusait à la lecture automatique, lue à la demande de l'utilisateur,
//  est mémorisée (`UserReadPages`) ; `ScrapeService` la consulte avant tout réseau. Relancer la
//  MÊME question la fait donc entrer dans le contexte, à la place du simple extrait du moteur.
//  Mécanisme de relance réutilisé : celui de `retryInQuickMode` (même question, même bulle).
//

import Foundation

extension ChatViewModel {
    /// Ce que devient un clic sur « Lire cette page ».
    nonisolated enum ReadPageOutcome: Equatable, Sendable {
        /// Lecture échouée (ou refusée faute de place : génération en cours) : rien n'est relancé.
        case failed
        /// Page lue et gardée pour les questions suivantes, mais la réponse concernée n'est plus
        /// la dernière du fil (la refaire l'écrirait hors ordre), ou rien ne peut être refait.
        case readOnly
        /// Page lue : la dernière réponse peut être refaite (`startRegenerationWithReadPages`).
        case readyToRegenerate
    }

    /// La dernière réponse du fil peut être refaite avec la page `url` : hors génération, elle est
    /// terminée (réussie ou non, jamais en cours), et cite cette URL parmi ses sources.
    func canRegenerate(afterReading url: String) -> Bool {
        guard !isGenerating,
              let last = messages.last, last.role == .assistant, last.status != .streaming,
              messages.dropLast().contains(where: { $0.role == .user }) else { return false }
        let key = SourceRanker.normalizedURLKey(for: url)
        return last.sources.contains { SourceRanker.normalizedURLKey(for: $0.url) == key }
    }

    /// Le bouton « Lire cette page » est inactif pendant une génération : une seule à la fois.
    var canReadPage: Bool { !isGenerating }

    /// Lit la page (via `pageReader`, qui rend vrai si elle est lue) puis dit s'il faut refaire la
    /// réponse. Ne lance rien elle-même : la vue passe par le consentement IA cloud d'abord.
    func readPage(
        url: String,
        pageReader: @MainActor (String) async -> Bool = ChatViewModel.readOnUserRequest
    ) async -> ReadPageOutcome {
        guard canReadPage else { return .failed }
        guard await pageReader(url) else { return .failed }
        return canRegenerate(afterReading: url) ? .readyToRegenerate : .readOnly
    }

    /// Lecture réelle : `SiteReadRefusals` garde l'état affiché par la liste des sources.
    static func readOnUserRequest(_ url: String) async -> Bool {
        let refusals = SiteReadRefusals.shared
        await refusals.readPage(url: url)
        return refusals.state(for: url) == .read
    }

    /// Refait la dernière réponse : même question, même historique, mode mémorisé, même bulle.
    /// Rien n'est fait si une génération a démarré entre-temps.
    func regenerateLastAnswerWithReadPages() async {
        guard !isGenerating, let index = messages.indices.last, messages[index].role == .assistant,
              messages[index].status != .streaming,
              let questionIndex = messages[..<index].lastIndex(where: { $0.role == .user }) else { return }
        await rerunAnswer(at: index, questionIndex: questionIndex, mode: readResponseMode())
    }

    /// Lance la relance dans la tâche d'envoi (le bouton Stop l'arrête comme un envoi tapé).
    func startRegenerationWithReadPages() {
        guard !isGenerating else { return }
        sendTask = Task { await self.regenerateLastAnswerWithReadPages() }
    }
}
