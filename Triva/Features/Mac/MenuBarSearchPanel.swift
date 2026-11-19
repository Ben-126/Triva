//
//  MenuBarSearchPanel.swift
//  Triva
//
//  Chantier 2.2 (M7) : panneau de l'icône de la barre des menus (Mac, optionnel).
//

#if os(macOS)
import AppKit
import SwiftUI

/// Panneau qui s'ouvre sous l'icône : un champ pour poser une question, les dernières conversations, et
/// « Ouvrir Triva ». Style fenêtre (et non menu) parce qu'il faut un champ de saisie.
///
/// Aucune `SearchSession` ici (mémoire, modèle local, historique en double) : valider la question la dépose dans
/// `ExternalSearchLauncher`, qui ouvre une vraie fenêtre de recherche, champ pré-rempli et non envoyé.
struct MenuBarSearchPanel: View {
    let stores: TrivaSharedStores
    let launcher: ExternalSearchLauncher

    @State private var question = ""
    @State private var recent: [MenuBarRecentConversation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Pose ta question", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .accessibilityIdentifier("menuBar.question")

            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Récentes")
                        .font(.caption)
                        .foregroundStyle(MessageBubbleView.legendStyle)
                    ForEach(recent) { conversation in
                        Button {
                            open(conversation)
                        } label: {
                            Text(conversation.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }

            Divider()

            Button("Ouvrir Triva", action: openTriva)
                .accessibilityIdentifier("menuBar.open")
        }
        .padding(16)
        .frame(width: 300)
        .task { refreshRecent() }
        .onChange(of: stores.chatHistory.revision) { refreshRecent() }
    }

    private func submit() {
        guard launcher.requestSearch(question: question) else { return }
        question = ""
    }

    private func open(_ conversation: MenuBarRecentConversation) {
        launcher.requestConversation(conversation.id)
    }

    /// Active l'app, et ouvre une fenêtre neuve seulement s'il n'y en a aucune sur l'écran.
    private func openTriva() {
        if launcher.visibleWindowCount == 0 {
            launcher.requestNewSearch()
        }
        NSApp.activate()
    }

    /// Base illisible : la liste reste vide, le champ de question marche quand même.
    private func refreshRecent() {
        let stored = (try? stores.chatHistory.conversations(limit: MenuBarRecentConversation.maxCount)) ?? []
        recent = MenuBarRecentConversation.recent(from: stored)
    }
}
#endif
