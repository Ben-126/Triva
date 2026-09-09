//
//  ChatViewModel.swift
//  Triva
//
//  Created by ben podrojsky on 07/09/2026.
//

import Foundation

/// Erreurs propres à `ChatViewModel`, distinctes de celles remontées par le
/// provider IA ou la recherche.
enum ChatViewModelError: Error, Sendable, Equatable {
    /// Le flux IA (`streamGenerate`) s'est terminé normalement (aucune erreur
    /// levée) sans jamais produire de texte non vide — que ce soit parce
    /// qu'il n'a émis aucun yield (0 yield) ou parce que son dernier snapshot
    /// cumulatif est une chaîne vide/blanche (ex. un unique yield de `""`) —
    /// cas réaliste avec un vrai LLM (filtrage de contenu, complétion vide).
    /// Sans ce cas dédié, `message.text` resterait `""` et `isStreaming`
    /// passerait à `false` sans qu'aucune erreur ne soit jamais reportée : un
    /// échec totalement silencieux et invisible dans l'UI (`MessageBubbleView`
    /// n'affiche le `ProgressView` que tant que `isStreaming` est vrai).
    case emptyResponse
}

/// Logique de l'UI de chat minimale (0.8, 2e étape) : orchestre un échange
/// complet (message utilisateur -> recherche -> génération en streaming) en
/// s'appuyant sur `SearchOrchestrator.streamAnswer(query:)` (1re étape de
/// 0.8, déjà écrite). Ne connaît ni SwiftUI ni la façon dont le provider IA
/// et le `FailoverManager` sont résolus : ces deux résolutions sont injectées
/// par closures, même principe que `SearchTestSection` dans
/// `ContentView.swift` (`resolveProvider`/`resolveFailoverManager`), pour que
/// ce ViewModel reste testable sans dépendre d'Apple Intelligence, de MLX, ni
/// d'un vrai réseau.
@Observable
@MainActor
final class ChatViewModel {
    /// Un message du fil de conversation. `Equatable`/`Sendable` pour rester
    /// facile à tester et à faire transiter hors de `@MainActor` si besoin
    /// (ex. prévisualisations SwiftUI). `text` est `var` : c'est le champ mis
    /// à jour en continu pendant le streaming (voir `send(query:)`).
    struct Message: Identifiable, Sendable, Equatable {
        enum Role: Sendable, Equatable {
            case user
            case assistant
        }

        let id: UUID
        let role: Role
        var text: String
        var sources: [SearXNGSearchResult]
        var isStreaming: Bool

        init(
            id: UUID = UUID(),
            role: Role,
            text: String = "",
            sources: [SearXNGSearchResult] = [],
            isStreaming: Bool = false
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.sources = sources
            self.isStreaming = isStreaming
        }
    }

    private(set) var messages: [Message] = []
    private(set) var isGenerating = false
    private(set) var errorDescription: String?

    private let resolveProvider: () async throws -> any AIGenerating
    private let resolveFailoverManager: () throws -> FailoverManager
    private let maxResultsUsedForContext: Int

    init(
        resolveProvider: @escaping () async throws -> any AIGenerating,
        resolveFailoverManager: @escaping () throws -> FailoverManager,
        maxResultsUsedForContext: Int = 5
    ) {
        self.resolveProvider = resolveProvider
        self.resolveFailoverManager = resolveFailoverManager
        self.maxResultsUsedForContext = maxResultsUsedForContext
    }

    /// Envoie `query` : ignore silencieusement les requêtes vides/blanches et
    /// les envois concurrents (une seule génération à la fois). Ajoute
    /// immédiatement un message utilisateur (texte trimmé) puis un message
    /// assistant vide en streaming, résout provider + `FailoverManager`,
    /// attache les sources dès qu'elles sont connues (avant même de
    /// commencer à consommer `textStream`), puis remplace le texte du
    /// message assistant par CHAQUE valeur reçue du flux — ce sont des
    /// snapshots cumulatifs (voir `AppleIntelligenceProvider.streamGenerate`),
    /// pas des deltas, donc jamais de concaténation ici. Toute erreur
    /// (résolution du provider, recherche, flux qui échoue, ou flux qui se
    /// termine sans jamais avoir produit de texte non vide — 0 yield ou
    /// dernier snapshot vide/blanc, `.emptyResponse`) est
    /// reportée dans `errorDescription` (voir `fail(assistantMessageID:error:)`
    /// — seule source affichée par `ChatView`, pour éviter le message
    /// dupliqué) ; `isStreaming` repasse à `false` sur le message assistant
    /// concerné dans tous les cas — jamais d'état bloqué en streaming
    /// indéfiniment. Si la `Task` englobante (créée par `ChatView.send()`)
    /// est annulée pendant le streaming — écran de chat quitté, moteur
    /// changé — `streamingAnswer.textStream` se termine alors normalement
    /// (sans lever d'erreur, voir `AsyncThrowingStream`) : ce cas est détecté
    /// via `Task.isCancelled` et traité comme un arrêt volontaire, jamais
    /// comme un échec ni comme une réponse vide.
    func send(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !isGenerating else { return }

        isGenerating = true
        errorDescription = nil
        defer { isGenerating = false }

        messages.append(Message(role: .user, text: trimmedQuery))
        let assistantMessageID = UUID()
        messages.append(Message(id: assistantMessageID, role: .assistant, isStreaming: true))

        do {
            let provider = try await resolveProvider()
            let failoverManager = try resolveFailoverManager()
            let orchestrator = SearchOrchestrator(
                failoverManager: failoverManager,
                aiProvider: provider,
                maxResultsUsedForContext: maxResultsUsedForContext
            )
            let streamingAnswer = try await orchestrator.streamAnswer(query: trimmedQuery)

            // Sources attachées avant toute itération de `textStream`, comme
            // demandé : `StreamingAnswer.sources` est déjà connu à ce stade
            // (la recherche est terminée et awaited par `streamAnswer`).
            updateAssistantMessage(id: assistantMessageID) { message in
                message.sources = streamingAnswer.sources
            }

            do {
                // Snapshots cumulatifs (voir le commentaire de tête) : c'est le
                // CONTENU du dernier snapshot reçu qui détermine si le flux a
                // réellement produit une réponse — pas le simple fait d'avoir
                // reçu au moins un yield. Un flux qui yield une unique fois une
                // chaîne vide ("") est tout aussi silencieux pour l'utilisateur
                // qu'un flux à 0 yield (`MessageBubbleView` n'affiche le
                // `ProgressView` que tant que `isStreaming` est vrai, donc une
                // fois `isStreaming = false` avec `text == ""`, la bulle est
                // vide sans indication d'erreur) : les deux cas doivent aboutir
                // à `.emptyResponse`.
                var lastSnapshot = ""
                for try await snapshot in streamingAnswer.textStream {
                    lastSnapshot = snapshot
                    updateAssistantMessage(id: assistantMessageID) { message in
                        message.text = snapshot
                    }
                }
                let hasContent = !lastSnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if Task.isCancelled || hasContent {
                    updateAssistantMessage(id: assistantMessageID) { message in
                        message.isStreaming = false
                    }
                } else {
                    fail(assistantMessageID: assistantMessageID, error: ChatViewModelError.emptyResponse)
                }
            } catch {
                fail(assistantMessageID: assistantMessageID, error: error)
            }
        } catch {
            fail(assistantMessageID: assistantMessageID, error: error)
        }
    }

    /// Représente clairement un échec : reporté UNIQUEMENT dans
    /// `errorDescription` (seule source lue par `ChatView` pour son bandeau
    /// d'erreur) — jamais aussi écrit dans `message.text`, pour ne pas
    /// dupliquer le même texte technique brut à deux endroits de l'écran
    /// (DESIGN.md : "chaque texte a un rôle, pas de sous-titre qui répète le
    /// titre"). Conserve tel quel le texte déjà streamé sur le message
    /// assistant s'il y en a (pour ne pas faire disparaître ce qui a déjà été
    /// affiché) et marque `isStreaming = false` — jamais de message qui reste
    /// vide en streaming pour toujours.
    private func fail(assistantMessageID: UUID, error: Error) {
        errorDescription = String(describing: error)
        updateAssistantMessage(id: assistantMessageID) { message in
            message.isStreaming = false
        }
    }

    private func updateAssistantMessage(id: UUID, _ update: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }
}
