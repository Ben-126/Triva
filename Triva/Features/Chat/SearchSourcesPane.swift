//
//  SearchSourcesPane.swift
//  Triva
//
//  Mission I2 (2.0, iPhone Duo déplié).
//

import SwiftUI

extension EnvironmentValues {
    /// Les sources des réponses sont affichées dans un volet à part (`SearchSourcesPane`) : les bulles ne
    /// répètent pas leur liste. Les citations `[n]` restent dans le texte. Faux partout hors du Duo déplié.
    @Entry var sourcesShownInPane: Bool = false
}

/// Quelle réponse le volet de sources montre-t-il ? Règle pure, testée sans interface.
nonisolated enum SourcesPaneFocus {
    /// La réponse ciblée (celle dont on a touché une citation) tant qu'elle existe encore dans le fil ;
    /// sinon la DERNIÈRE réponse. `nil` : aucune réponse (fil vide ou seulement des questions).
    ///
    /// - Parameter answerIDs: identifiants des réponses (rôle assistant), dans l'ordre du fil.
    static func answerID(focusedID: UUID?, answerIDs: [UUID]) -> UUID? {
        if let focusedID, answerIDs.contains(focusedID) { return focusedID }
        return answerIDs.last
    }
}

/// Bloc « Sources » d'une réponse : l'en-tête, la liste, la mention « hors sujet » et l'origine des résultats.
/// Partagé par la bulle (une colonne) et le volet de droite (Duo déplié), pour que les deux disent la même chose.
struct AnswerSourcesSection: View {
    let message: ChatViewModel.Message
    let answer: MessageBubblePresentation.AnswerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Même label que le détail d'un favori (FavoritesView, finding 32) : même contenu, même présentation.
            HistorySectionHeader(title: "Sources")
            SourcesListView(sources: message.sources, unreadNumbers: message.uncitableSourceNumbers)

            OffTopicSourcesNote(answer: answer)

            // Rôle de la légende de confidentialité (DESIGN.md) : une précision factuelle, sans verre ni icône.
            if let origin = MessageBubblePresentation.resultsOriginLabel(answer) {
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(MessageBubbleView.legendStyle)
            }
        }
    }
}

/// Volet de droite de la Recherche sur l'iPhone Duo déplié en paysage : les sources de la réponse ciblée
/// (par défaut la dernière ; une citation touchée dans une réponse la cible). Pas de verre : du texte et des
/// liens, comme la liste sous une bulle (DESIGN.md).
struct SearchSourcesPane: View {
    let messages: [ChatViewModel.Message]
    let focusedAnswerID: UUID?

    private var answers: [ChatViewModel.Message] { messages.filter { $0.role == .assistant } }

    private var shown: ChatViewModel.Message? {
        guard let id = SourcesPaneFocus.answerID(focusedID: focusedAnswerID, answerIDs: answers.map(\.id)) else { return nil }
        return answers.first { $0.id == id }
    }

    /// Question qui précède la réponse montrée : dit de quelle réponse viennent les sources.
    private func question(for answer: ChatViewModel.Message) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == answer.id }), index > 0 else { return nil }
        let previous = messages[index - 1]
        return previous.role == .user ? previous.text : nil
    }

    var body: some View {
        Group {
            if let answer = shown, !answer.sources.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let question = question(for: answer) {
                            Text(verbatim: question)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        AnswerSourcesSection(message: answer, answer: MessageBubbleView.answerSnapshot(of: answer))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(shown == nil ? "Les sources de la réponse s'affichent ici." : "Cette réponse n'a pas de source.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.sourcesPane")
    }
}
