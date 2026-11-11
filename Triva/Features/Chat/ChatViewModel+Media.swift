//
//  ChatViewModel+Media.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Médias à la demande (1.6, décision (a)), sortis de `ChatViewModel.swift` pour le garder sous les
/// 800 lignes (tâche 1.16). Seul changement de comportement nul : l'écriture de `.loading` passe par
/// `updateMessage`, `messages` étant `private(set)` dans l'autre fichier.
extension ChatViewModel {
    enum MediaKind: Hashable {
        case images
        case videos
    }

    struct MediaRequest: Hashable {
        let messageID: UUID
        let kind: MediaKind
    }

    /// Bouton de `ImageResultsView` : la recherche ne part QUE sur demande.
    /// Sujet : `searchQuery` de la réponse (pas d'appel LLM de plus), ou la
    /// question d'un message relu. Ignorée pendant le streaming ou si la même
    /// recherche est déjà en cours.
    func searchImages(messageID: UUID) {
        startMediaSearch(.images, messageID: messageID)
    }

    /// Bouton de `VideoResultsView`, mêmes règles que `searchImages(messageID:)`.
    func searchVideos(messageID: UUID) {
        startMediaSearch(.videos, messageID: messageID)
    }

    private func startMediaSearch(_ kind: MediaKind, messageID: UUID) {
        let request = MediaRequest(messageID: messageID, kind: kind)
        guard mediaTasks[request] == nil,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .assistant, !messages[index].isStreaming else { return }
        let query = messages[index].searchQuery ?? precedingQuestion(beforeIndex: index) ?? ""
        guard !query.isEmpty else { return }
        // `messages` n'est modifiable que depuis `ChatViewModel.swift` (`private(set)`) :
        // `updateMessage` est le seul point d'écriture.
        updateMessage(id: messageID) { message in
            switch kind {
            case .images: message.images = .loading
            case .videos: message.videos = .loading
            }
        }
        mediaTasks[request] = Task {
            await self.runMediaSearch(kind, query: query, messageID: messageID)
            self.mediaTasks[request] = nil
        }
    }

    /// Erreur -> `.failed`, jamais son texte (contrat de 1.6). Un résultat
    /// arrivé après une nouvelle conversation ne trouve plus son message.
    private func runMediaSearch(_ kind: MediaKind, query: String, messageID: UUID) async {
        do {
            let searcher = makeMediaSearcher(try resolveFailoverManager())
            switch kind {
            case .images:
                let images = try await searcher.searchImages(query: query)
                updateMessage(id: messageID) { $0.images = .loaded(images) }
            case .videos:
                let videos = try await searcher.searchVideos(query: query)
                updateMessage(id: messageID) { $0.videos = .loaded(videos) }
            }
        } catch {
            updateMessage(id: messageID) { message in
                switch kind {
                case .images: message.images = .failed
                case .videos: message.videos = .failed
                }
            }
        }
    }
}
