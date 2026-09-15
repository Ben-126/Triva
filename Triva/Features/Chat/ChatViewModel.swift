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
    /// indéfiniment. Erreurs connues du pipeline (voir
    /// `userFacingMessage(for:)`) traduites en message français clair plutôt
    /// que le nom brut de l'enum. Si la `Task` englobante (créée par
    /// `ChatView.send()`) est annulée — écran de chat quitté, moteur changé —
    /// à N'IMPORTE quelle étape (résolution du provider, recherche encore en
    /// vol dans `FailoverManager.search`, ou pendant `textStream`), ce cas est
    /// détecté via `Task.isCancelled` (vérifié dans LES DEUX `catch`, pas
    /// seulement celui qui entoure `textStream`) et traité comme un arrêt
    /// volontaire (`stopStreamingWithoutError`), jamais comme un échec ni
    /// comme une réponse vide — sinon une erreur fantôme écrite dans
    /// `errorDescription` survivrait à la fermeture de l'écran (effacée
    /// seulement au début du PROCHAIN `send(query:)` réussi) et s'afficherait
    /// au prochain retour sur ce même écran.
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
            let chatHistory = Self.classifierHistory(from: messages)
            let streamingAnswer = try await orchestrator.streamAnswer(query: trimmedQuery, chatHistory: chatHistory)

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
                // Même garde que la branche de succès juste au-dessus : une
                // erreur levée par le flux PENDANT que la Task englobante est
                // déjà annulée (ex. le provider ferme sa propre session au
                // moment où l'utilisateur quitte l'écran) est un arrêt
                // volontaire, jamais un vrai échec — sinon `errorDescription`
                // serait renseigné pour rien voir plus haut.
                if Task.isCancelled {
                    stopStreamingWithoutError(assistantMessageID: assistantMessageID)
                } else {
                    fail(assistantMessageID: assistantMessageID, error: error)
                }
            }
        } catch {
            // Même raisonnement que le catch interne ci-dessus, mais pour un
            // échec survenant AVANT même de commencer `textStream` (résolution
            // du provider, du `FailoverManager`, ou recherche encore en vol
            // dans `orchestrator.streamAnswer`) : annuler la Task englobante
            // pendant que `failoverManager.search(query:)` est en vol fait
            // remonter ici l'erreur produite par cette annulation (voir
            // `FailoverManager.search`), qui ne doit jamais être traitée comme
            // un vrai échec — sinon ce message fantôme survivrait à la
            // fermeture de l'écran (`errorDescription` n'est effacé qu'au
            // début du PROCHAIN `send(query:)` réussi) et s'afficherait au
            // prochain retour sur cet écran, sans rapport avec un vrai
            // problème.
            if Task.isCancelled {
                stopStreamingWithoutError(assistantMessageID: assistantMessageID)
            } else {
                fail(assistantMessageID: assistantMessageID, error: error)
            }
        }
    }

    /// Arrête proprement le streaming d'un message assistant SANS reporter
    /// d'erreur — cas de l'annulation volontaire (écran quitté, moteur
    /// changé), à distinguer d'un vrai échec (voir `fail(assistantMessageID:error:)`).
    /// Conserve, comme `fail`, le texte déjà streamé s'il y en a.
    private func stopStreamingWithoutError(assistantMessageID: UUID) {
        updateAssistantMessage(id: assistantMessageID) { message in
            message.isStreaming = false
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
        errorDescription = Self.userFacingMessage(for: error)
        updateAssistantMessage(id: assistantMessageID) { message in
            message.isStreaming = false
        }
    }

    /// Traduit une erreur technique en message français compréhensible pour
    /// les cas connus du pipeline recherche -> génération (0.7/0.8), chacun
    /// documenté par son enum d'origine pour permettre justement ce mapping
    /// (voir le commentaire de tête d'`ActiveAIProviderResolverError`). Pour
    /// tout le reste (ex. erreur interne d'un provider tiers, erreur de test),
    /// retombe sur `String(describing:)` plutôt que d'inventer un message
    /// générique qui masquerait une information utile en debug — mieux vaut un
    /// nom d'enum brut mais réel qu'un message inventé qui ne correspond à
    /// rien. Exception volontaire : `OpenAICompatibleProviderError` et
    /// `CloudBYOKError` sont mappés vers un message fixe plutôt que
    /// `String(describing:)`, car leur cas `generationFailed(description:)`
    /// peut porter un texte brut renvoyé par le serveur du fournisseur BYOK
    /// (risque de fuite de clé API — voir plus bas).
    static func userFacingMessage(for error: Error) -> String {
        if let resolverError = error as? ActiveAIProviderResolverError {
            switch resolverError {
            case .noEngineSelected:
                return "Aucun moteur IA sélectionné. Choisis-en un dans les Réglages."
            case .appleIntelligenceUnavailable:
                return "Apple Intelligence n'est pas disponible sur cet appareil."
            case .noMLXModelSelected:
                return "Aucun modèle local choisi. Sélectionne un modèle MLX dans les Réglages."
            case .mlxModelNotInCatalog:
                return "Le modèle local choisi n'est plus disponible. Choisis-en un autre dans les Réglages."
            case .noCloudSelectionStored:
                return "Aucun fournisseur configuré. Va dans Réglages pour en choisir un."
            case .cloudSelectionUnresolvable:
                return "Le fournisseur choisi n'est plus disponible. Vérifie tes Réglages."
            }
        }

        if let failoverError = error as? FailoverError {
            switch failoverError {
            case .noInstancesConfigured:
                return "Aucune instance de recherche n'est configurée."
            case .allInstancesUnavailable:
                return "Aucune instance de recherche n'a répondu. Réessaie dans un instant."
            }
        }

        // Cas précis introduit par le garde-fou anti-crash de `MLXProvider`
        // (voir son commentaire de tête) : sans ce mapping, choisir MLX local
        // et envoyer un message sur le Simulateur afficherait littéralement
        // "Erreur : simulatorUnsupported" — exactement le défaut que ce
        // mapping existe pour éviter. Les autres cas de `MLXProviderError`
        // (téléchargement, génération) retombent volontairement sur
        // `String(describing:)` : ils portent déjà une `description` texte
        // utile, pas un simple nom de cas.
        if let mlxError = error as? MLXProviderError, mlxError == .simulatorUnsupported {
            return "Les modèles locaux (MLX) ne fonctionnent pas sur le Simulateur — teste sur un appareil réel."
        }

        if error is ChatViewModelError {
            return "Le moteur IA n'a renvoyé aucune réponse. Réessaie."
        }

        // Ces deux cas ne peuvent PAS retomber sur `String(describing:)` comme
        // le reste : leur `generationFailed(description:)` peut encapsuler un
        // message d'erreur brut renvoyé par le serveur du fournisseur BYOK
        // (voir `OpenAICompatibleClientError.apiError(message:)`) — pour un
        // fournisseur "Personnalisé", ce serveur est entièrement contrôlé par
        // l'utilisateur (baseURL non liste blanche) et pourrait donc échoer
        // délibérément l'en-tête `Authorization: Bearer <clé>` reçu dans son
        // JSON d'erreur pour la faire fuiter en clair dans le chat. Message
        // fixe uniquement, jamais d'interpolation du texte du fournisseur.
        if error is OpenAICompatibleProviderError || error is CloudBYOKError {
            return "Le fournisseur IA n'a pas pu répondre. Vérifie ta clé API et réessaie."
        }

        return String(describing: error)
    }

    private func updateAssistantMessage(id: UUID, _ update: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }

    /// Convertit l'historique de conversation UI vers `ClassifierChatMessage`
    /// (branché sur `QueryClassifier` via `SearchOrchestrator.streamAnswer`,
    /// tâche 1.2) : EXCLUT les deux derniers messages, qu'on vient d'ajouter
    /// nous-mêmes juste avant l'appel (le message utilisateur courant et le
    /// placeholder assistant vide en streaming, voir `send(query:)`) — les
    /// inclure dupliquerait la requête courante à l'intérieur de
    /// `<conversation_history>` en plus de `<user_query>`, et injecterait une
    /// ligne "AI: " vide pour le placeholder.
    private static func classifierHistory(from messages: [Message]) -> [ClassifierChatMessage] {
        messages.dropLast(2).map { message in
            ClassifierChatMessage(role: message.role == .user ? .user : .assistant, content: message.text)
        }
    }
}
