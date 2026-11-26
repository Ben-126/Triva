//
//  ChatViewModel+Exchange.swift
//  Triva
//
//  Created by ben podrojsky on 07/09/2026.
//

import Foundation
import os

/// Déroulé d'un échange : résolution, recherche, lecture du flux, fin ou échec. Rangé à part de
/// `ChatViewModel.swift` (rangement W4-R, code déplacé ; seuls changements : `private` retiré de ce qui
/// est appelé depuis l'autre fichier, et écritures de `searchKeyInvitation` / `errorDescription` par leurs
/// points d'écriture, ces propriétés étant `private(set)` dans l'autre fichier).
extension ChatViewModel {
    func perform(_ exchange: Exchange, exchangeID: UUID) async {
        var answer = AnswerDraft()
        defer { persistAnswer(answer, exchange: exchange) }
        // Hors connexion (tâche 1.16) : lu AVANT toute résolution. Un moteur cloud ne tente rien, et le
        // `prepare()` de MLX, qui téléchargerait un modèle absent, n'est jamais lancé dans le vide.
        let offlinePlan = resolveOfflinePlan()
        if case .blocked(let reason)? = offlinePlan {
            blockOffline(exchange, exchangeID: exchangeID, reason: reason)
            return
        }
        // Hors connexion avec un modèle local : aucune recherche n'aura lieu, « Recherche des sources… »
        // serait faux pendant toute la résolution du modèle (revue R3-6).
        if offlinePlan == .answerWithoutSearch {
            updateMessage(id: exchange.answerID) { $0.generationStage = .writing }
        }
        do {
            let provider = try await resolveProvider()
            let failoverManager = try resolveFailoverManager()
            let orchestrator = makeOrchestrator(OrchestratorInputs(
                failoverManager: failoverManager,
                provider: provider,
                responseMode: exchange.mode,
                configuration: resolvePipelineConfiguration(),
                webSearchChain: try resolveWebSearchChain(failoverManager),
                isOffline: offlinePlan != nil,
                // Sans suspension depuis `resolveProvider` : l'enquêteur suit la route de CE même envoi (tâche 2.4).
                agenticResearcher: resolveAgenticResearcher()
            ))
            // `media: []` : images et vidéos À LA DEMANDE (décision (a)).
            let streamingAnswer = try await orchestrator.streamAnswer(
                query: exchange.question,
                chatHistory: exchange.history,
                attachments: exchange.attachments,
                media: [],
                onSearchStarted: { [weak self] in
                    self?.emitProgress(.searching, answerID: exchange.answerID)
                    self?.updateMessage(id: exchange.answerID) { message in
                        // Jamais en arrière depuis « Rédaction… » (hors connexion avec un fichier joint).
                        if message.generationStage == .analyzing { message.generationStage = .searching }
                    }
                }
            )
            let artifacts = streamingAnswer.artifacts
            if let reason = artifacts.offlineBlockReason {
                // Météo hors connexion, ou mode Fiable sans source (`SearchArtifacts+Offline.swift`).
                blockOffline(exchange, exchangeID: exchangeID, reason: reason)
                return
            }
            // Mission A2 : SearXNG laissé de côté, une source de secours a répondu.
            // Remplacée par `fail` si l'échange échoue ensuite (erreur du moteur IA).
            if activeExchangeID == exchangeID, !fallbackInvitationOffered {
                setSearchKeyInvitation(SearchKeyInvitation(
                    afterFallback: artifacts.webSearchReport,
                    retainedSource: artifacts.webSourceKind,
                    webSourceCount: artifacts.sources.count - artifacts.attachmentSourceCount,
                    isDeviceLocked: DeviceLock.isLocked
                ))
                fallbackInvitationOffered = searchKeyInvitation != nil
            }
            if Self.lacksReliableSources(artifacts) {
                // Décision (c) : jamais de réponse sans source en mode Fiable.
                // Flux non lu ; relâché, son `onTermination` annule la génération.
                concludeWithoutReliableSources(exchange, searchQuery: artifacts.searchQuery)
                return
            }
            answer.sources = Self.displayedSources(of: artifacts)
            emitProgress(.sources(count: answer.sources.count), answerID: exchange.answerID)
            answer.notes = Message.storedNotes(of: artifacts)
            updateMessage(id: exchange.answerID) { $0.generationStage = .writing }
            // Mission A1 : en Fiable sans widget, artefacts et texte attendent la
            // première citation d'une page lue (`CitedAnswerGate`, dans `consume`) :
            // une liste de sources sous le spinner, puis effacée par un refus, non.
            if !artifacts.requiresCitedAnswer {
                updateMessage(id: exchange.answerID) { $0.attach(artifacts) }
            }
            answer = await consume(streamingAnswer.textStream, into: answer, artifacts: artifacts, exchange: exchange, exchangeID: exchangeID)
            if answer.isComplete {
                didComplete(exchange, exchangeID: exchangeID, text: answer.text, artifacts: artifacts, orchestrator: orchestrator, provider: provider)
            }
        } catch {
            // Échec AVANT le flux (résolution, recherche encore en vol) : même
            // garde que dans `consume`, une erreur due à l'annulation n'est pas un échec.
            if Task.isCancelled {
                finishAnswer(exchange.answerID, as: .interrupted)
            } else if offlinePlan != nil, Self.isLocalModelDownloadFailure(error) {
                // Modèle MLX présumé sur le disque mais impossible à charger sans Internet.
                blockOffline(exchange, exchangeID: exchangeID, reason: .localModelUnavailable)
            } else {
                fail(answerID: exchange.answerID, exchangeID: exchangeID, error: error)
            }
        }
    }

    /// Lit le flux. C'est le CONTENU du dernier snapshot qui dit si le modèle a
    /// répondu : un unique yield de `""` vaut un flux à 0 yield (`.emptyResponse`).
    ///
    /// Mode Fiable sans widget (mission A1) : texte RETENU tant qu'il ne cite
    /// aucune page lue (`CitedAnswerGate`), puis contrôlé une fois fini
    /// (`SearchArtifacts.rejectsReliableAnswer`) : refus exact ou aucune page
    /// lue citée -> état `.noReliableSources`, avec la relance en Rapide. Un
    /// texte jamais montré (Stop, erreur, refus) n'est jamais persisté non
    /// plus : le brouillon rendu est vide, `persistAnswer` n'écrit rien.
    private func consume(
        _ textStream: AsyncThrowingStream<String, Error>,
        into draft: AnswerDraft,
        artifacts: SearchArtifacts,
        exchange: Exchange,
        exchangeID: UUID
    ) async -> AnswerDraft {
        var answer = draft
        var gate = CitedAnswerGate(artifacts: artifacts)
        var announcedWriting = false
        var announcedReasoning = false
        do {
            for try await snapshot in textStream {
                answer.text = snapshot
                // « Rédaction » à partir du premier MOT de réponse du FLUX, même si la porte du mode Fiable retient
                // encore le texte : le modèle écrit, l'affichage attend seulement une citation. Tant que le modèle n'a
                // écrit que son raisonnement : « Réflexion » (le nom de l'étape, jamais le contenu).
                if !announcedWriting, let event = SearchProgressEvent.forStreamSnapshot(snapshot) {
                    switch event {
                    case .writing:
                        announcedWriting = true
                        emitProgress(.writing, answerID: exchange.answerID)
                    case .reasoning where !announcedReasoning:
                        announcedReasoning = true
                        emitProgress(.reasoning, answerID: exchange.answerID)
                    default:
                        break
                    }
                }
                let wasOpen = gate.isOpen
                guard gate.admits(snapshot) else { continue }
                reveal(snapshot, attaching: wasOpen ? nil : artifacts, answerID: exchange.answerID)
            }
            let hasContent = !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if Task.isCancelled {
                finishAnswer(exchange.answerID, as: .interrupted)
            } else if hasContent, artifacts.rejectsReliableAnswer(answer.text) {
                concludeWithoutReliableSources(exchange, searchQuery: artifacts.searchQuery)
                return AnswerDraft()
            } else if hasContent {
                if !gate.isOpen {
                    gate.open()
                    reveal(answer.text, attaching: artifacts, answerID: exchange.answerID)
                }
                answer.isComplete = true
                finishAnswer(exchange.answerID, as: .completed)
            } else {
                fail(answerID: exchange.answerID, exchangeID: exchangeID, error: ChatViewModelError.emptyResponse)
            }
        } catch {
            // Erreur levée alors que la tâche est déjà annulée (le provider
            // ferme sa session quand l'écran se ferme) : arrêt volontaire.
            if Task.isCancelled {
                finishAnswer(exchange.answerID, as: .interrupted)
            } else {
                fail(answerID: exchange.answerID, exchangeID: exchangeID, error: error)
            }
        }
        if !gate.isOpen { answer.text = "" }
        return answer
    }

    /// Affiche un instantané ; `artifacts` à l'ouverture de la porte Fiable
    /// seulement (mission A1), sinon ils sont déjà attachés (`perform`).
    private func reveal(_ snapshot: String, attaching artifacts: SearchArtifacts?, answerID: UUID) {
        let date = now()
        updateMessage(id: answerID) { message in
            if let artifacts { message.attach(artifacts) }
            message.apply(snapshot: snapshot, at: date)
        }
    }

    /// État fixe « Aucune source fiable » (décision (c)), persisté : avant la
    /// génération (rien de citable), ou depuis la mission A1 à la fin d'un flux
    /// Fiable refusé — `markNoReliableSources` efface alors ce qu'il portait.
    private func concludeWithoutReliableSources(_ exchange: Exchange, searchQuery: String) {
        let date = now()
        updateMessage(id: exchange.answerID) { $0.markNoReliableSources(searchQuery: searchQuery, at: date) }
        emitProgress(.failed, answerID: exchange.answerID)
        persistNoReliableSources(exchange: exchange)
    }

    /// Réponse terminée et non vide : diagnostic de structure, puis
    /// suggestions dans une tâche à part — rien n'attend, annulées par l'envoi
    /// suivant ; le service ne lève jamais (échec = `[]`), aucune erreur affichée.
    private func didComplete(
        _ exchange: Exchange,
        exchangeID: UUID,
        text: String,
        artifacts: SearchArtifacts,
        orchestrator: SearchOrchestrator,
        provider: any AIGenerating
    ) {
        let report = ResponseStructureValidator().validate(
            text,
            mode: artifacts.mode,
            complexity: artifacts.promptComplexity,
            citableSourceCount: artifacts.citableSourceCount,
            uncitableNumbers: artifacts.uncitableSourceNumbers
        )
        updateMessage(id: exchange.answerID) { $0.structureReport = report }
        guard activeExchangeID == exchangeID,
              Self.offersSuggestions(question: exchange.question, artifacts: artifacts) else { return }

        let history = orchestrator.suggestionsHistory(previousTurns: exchange.history, query: exchange.question, answer: text)
        let answerID = exchange.answerID
        suggestionsTask = Task {
            let suggestions = await self.generateSuggestions(provider, history)
            guard !Task.isCancelled else { return }
            self.updateMessage(id: answerID) { $0.suggestions = suggestions }
        }
    }

    /// Échec : `errorDescription` (seulement par l'échange actif), texte
    /// déjà streamé conservé tel quel.
    private func fail(answerID: UUID, exchangeID: UUID, error: any Error) {
        if activeExchangeID == exchangeID {
            setErrorDescription(Self.userFacingMessage(for: error))
            let errorInvitation = SearchKeyInvitation(for: error, isDeviceLocked: DeviceLock.isLocked)
            // Une invitation de repli posée dans CET échange disparaît sans avoir été vue : elle
            // reste à faire (seule une invitation de repli peut exister ici, l'envoi l'a remise à nil).
            if errorInvitation == nil, searchKeyInvitation != nil { fallbackInvitationOffered = false }
            setSearchKeyInvitation(errorInvitation)
        }
        finishAnswer(answerID, as: .failed)
    }

    func finishAnswer(_ answerID: UUID, as status: Message.Status) {
        let date = now()
        updateMessage(id: answerID) { $0.finish(status, at: date) }
        emitProgress(for: status, answerID: answerID)
    }
}
