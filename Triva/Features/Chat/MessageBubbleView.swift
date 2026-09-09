import SwiftUI

/// Une bulle de message du fil de chat (0.8, 3e étape). Apparence différente
/// selon `role` :
/// - `.user` : hugue son contenu, poussée à droite (`Spacer` côté gauche),
///   verre teinté à l'accent — même principe que la carte sélectionnée dans
///   DESIGN.md (teinte plutôt que bordure `.stroke` pour indiquer un état).
/// - `.assistant` : occupe toute la largeur disponible, verre neutre, avec
///   sous le texte la liste des sources (`SourcesListView`) si le message en
///   a — même style que `resultSection` de l'ancienne `SearchTestSection`
///   (`ContentView.swift`, test 0.7) avant son remplacement par cette vue.
///
/// Utilise exclusivement `.rect(cornerRadius: 20)` (DESIGN.md : un seul rayon
/// de coin pour les conteneurs de cette taille).
struct MessageBubbleView: View {
    let message: ChatViewModel.Message

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            bubbleContent
                .padding(16)
                .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
                .glassEffect(glass, in: .rect(cornerRadius: 20))
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.isStreaming && message.text.isEmpty {
                ProgressView()
            } else {
                Text(message.text)
            }

            if message.role == .assistant, !message.sources.isEmpty {
                SourcesListView(sources: message.sources)
            }
        }
    }

    private var glass: Glass {
        message.role == .user ? .regular.tint(.accentColor.opacity(0.12)) : .regular
    }
}

#Preview("Utilisateur") {
    MessageBubbleView(message: .init(role: .user, text: "Résume l'actualité tech d'aujourd'hui."))
        .padding(20)
}

#Preview("Assistant — en streaming, sans texte") {
    MessageBubbleView(message: .init(role: .assistant, text: "", isStreaming: true))
        .padding(20)
}

#Preview("Assistant — avec sources") {
    MessageBubbleView(message: .init(
        role: .assistant,
        text: "Voici un résumé basé sur plusieurs sources récentes.",
        sources: [
            SearXNGSearchResult(
                title: "Documentation Swift Concurrency",
                url: "https://developer.apple.com/documentation/swift/concurrency",
                content: nil,
                imgSrc: nil,
                thumbnailSrc: nil,
                thumbnail: nil,
                author: nil,
                iframeSrc: nil
            ),
        ]
    ))
    .padding(20)
}

#Preview("Assistant — sans sources, sombre") {
    MessageBubbleView(message: .init(role: .assistant, text: "Réponse sans recherche associée."))
        .padding(20)
        .preferredColorScheme(.dark)
}
