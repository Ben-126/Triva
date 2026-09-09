import SwiftUI

/// Écran de chat complet (0.8, 3e étape) : liste défilante des messages (une
/// `MessageBubbleView` par message), champ de saisie + bouton d'envoi, et
/// affichage de l'erreur courante (`ChatViewModel.errorDescription`) s'il y
/// en a une — seul endroit de l'écran qui affiche une erreur (voir
/// `ChatViewModel.fail(assistantMessageID:error:)` : le texte de l'erreur
/// n'est jamais aussi écrit dans une bulle, pour ne pas le dupliquer).
///
/// Ne crée jamais son `ChatViewModel` lui-même : reçu en paramètre, pour que
/// l'appelant (`ContentView.swift`) reste seul responsable de résoudre le
/// provider IA et le `FailoverManager` actifs
/// (`resolveProvider`/`resolveFailoverManager`, voir le commentaire de tête
/// de `ChatViewModel`) et de mettre ce ViewModel en cache — un par écran,
/// jamais recréé à chaque re-render.
struct ChatView: View {
    let viewModel: ChatViewModel

    @State private var draft = ""
    /// `Task` de la génération en cours, créée par `send()` — jamais une
    /// `Task {}` perdue (le handle serait alors immédiatement jeté) : gardée
    /// ici pour pouvoir l'annuler explicitement dans `.onDisappear`. Sans
    /// cela, quitter cet écran pendant une génération (ex. changement de
    /// moteur IA depuis `ContentView`) laisserait le flux tourner
    /// indéfiniment en arrière-plan, invisible et impossible à arrêter —
    /// alors que `ChatViewModel.send(query:)` réagit correctement à
    /// l'annulation de cette `Task` (voir son commentaire de tête).
    @State private var sendTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var isDraftFocused: Bool

    /// Largeur de contenu plafonnée en `regular` (iPad/Mac) — même principe
    /// que `TrivaHomeReferenceView` (padding horizontal de 20 partout), pour
    /// éviter des bulles de chat qui s'étirent sur toute la largeur d'un
    /// écran Mac.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    private var isSendDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isGenerating
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            composer
        }
        .onDisappear {
            sendTask?.cancel()
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorDescription = viewModel.errorDescription {
                        Label("Erreur : \(errorDescription)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    GlassEffectContainer(spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.messages) { message in
                                MessageBubbleView(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
            }
            .onChange(of: viewModel.messages.count) {
                scrollToLastMessage(proxy: proxy)
            }
            .onChange(of: viewModel.messages.last?.text) {
                scrollToLastMessage(proxy: proxy)
            }
        }
    }

    private func scrollToLastMessage(proxy: ScrollViewProxy) {
        guard let lastID = viewModel.messages.last?.id else { return }
        withAnimation {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private var composer: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                TextField("Pose ta question…", text: $draft)
                    .focused($isDraftFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.glassProminent)
                .disabled(isSendDisabled)
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func send() {
        guard !isSendDisabled else { return }
        let query = draft
        draft = ""
        sendTask = Task { await viewModel.send(query: query) }
    }
}

// MARK: - Previews

/// Client SearXNG factice pour les previews uniquement — jamais de vrai
/// réseau dans une préview. Même principe que `MockSearXNGClient` dans
/// `TrivaTests/SearchOrchestratorTests.swift` (un `actor`, requis par
/// `SearXNGSearching: Sendable`), dupliqué ici car `private` est scopé au
/// fichier.
private actor PreviewSearXNGClient: SearXNGSearching {
    static let instance = URL(string: "https://searxng.preview.example")!

    static let sampleResults: [SearXNGSearchResult] = [
        SearXNGSearchResult(
            title: "Documentation Swift Concurrency",
            url: "https://developer.apple.com/documentation/swift/concurrency",
            content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        ),
        SearXNGSearchResult(
            title: "SearXNG — moteur de recherche",
            url: "https://docs.searxng.org",
            content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        ),
    ]

    private let results: [SearXNGSearchResult]

    init(results: [SearXNGSearchResult]) {
        self.results = results
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Provider IA factice pour les previews : une seule réponse fixe, streamée
/// via l'implémentation par défaut de `streamGenerate` (un seul yield, voir
/// `AppleIntelligenceProvider.swift`). Même principe que `MockAIGenerating`
/// dans `TrivaTests/SearchOrchestratorTests.swift` (une `final class` simple,
/// pas d'acteur), dupliqué ici car `private` est scopé au fichier.
private final class PreviewAIProvider: AIGenerating {
    private let response: String

    init(response: String) {
        self.response = response
    }

    func generate(prompt: String) async throws -> String { response }
}

private func previewViewModel(response: String, sources: [SearXNGSearchResult]) -> ChatViewModel {
    ChatViewModel(
        resolveProvider: { PreviewAIProvider(response: response) },
        resolveFailoverManager: {
            FailoverManager(client: PreviewSearXNGClient(results: sources), instances: [PreviewSearXNGClient.instance])
        }
    )
}

#Preview("Vide") {
    ChatView(viewModel: previewViewModel(response: "", sources: []))
}

#Preview("Avec sources — clair") {
    let viewModel = previewViewModel(
        response: "Voici un résumé basé sur plusieurs sources récentes.",
        sources: PreviewSearXNGClient.sampleResults
    )
    return ChatView(viewModel: viewModel)
        .task { await viewModel.send(query: "Résume l'actualité tech d'aujourd'hui.") }
}

#Preview("Sans sources — sombre") {
    let viewModel = previewViewModel(
        response: "Réponse directe, sans recherche associée.",
        sources: []
    )
    return ChatView(viewModel: viewModel)
        .task { await viewModel.send(query: "Explique-moi un concept.") }
        .preferredColorScheme(.dark)
}

#Preview("Une seule source") {
    let viewModel = previewViewModel(
        response: "Réponse générée via un fournisseur cloud personnel.",
        sources: [PreviewSearXNGClient.sampleResults[0]]
    )
    return ChatView(viewModel: viewModel)
        .task { await viewModel.send(query: "Compare deux produits.") }
}
