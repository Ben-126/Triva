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
    /// Suit si l'utilisateur est actuellement ancré en bas de la liste — voir
    /// `messagesList`/`onScrollGeometryChange` : tant que c'est vrai, chaque
    /// nouveau morceau de texte streamé réancre le scroll en bas ; dès que
    /// l'utilisateur remonte manuellement pendant un streaming, ça devient
    /// faux et le scroll automatique s'arrête jusqu'au prochain envoi.
    @State private var isPinnedToBottom = true
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

    /// Ancre fixe placée après le dernier message ET le bandeau d'erreur (s'il
    /// y en a un) : le scroll automatique cible TOUJOURS cette ancre plutôt
    /// que l'id du dernier message, pour que le bandeau d'erreur — quand il
    /// apparaît juste après un échec, donc juste après le dernier message
    /// assistant — soit systématiquement révélé par le scroll au lieu de
    /// rester au-dessus de la zone visible (le bandeau était auparavant en
    /// TÊTE de liste, hors du chemin du scroll qui, lui, ancre en bas).
    private static let bottomAnchorID = "chat-bottom-anchor"

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlassEffectContainer(spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(viewModel.messages) { message in
                                // `.equatable()` juste après l'initialiseur
                                // (avant `.id()`, qui rendrait le type
                                // englobant non-Equatable) : évite de
                                // ré-évaluer le corps des bulles dont le
                                // `message` n'a pas changé à chaque snapshot
                                // de streaming reçu par une AUTRE bulle (voir
                                // le commentaire de tête de
                                // `MessageBubbleView`).
                                MessageBubbleView(message: message)
                                    .equatable()
                                    .id(message.id)
                            }
                        }
                    }

                    if let errorDescription = viewModel.errorDescription {
                        Label("Erreur : \(errorDescription)", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distanceFromBottom < 80
            } action: { _, isNearBottom in
                isPinnedToBottom = isNearBottom
            }
            .onChange(of: viewModel.messages.count) {
                // Un nouvel échange (nouvelle question envoyée) reprend
                // toujours le suivi automatique, même si l'utilisateur avait
                // remonté pour relire une réponse précédente.
                isPinnedToBottom = true
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.messages.last?.text) {
                // Pendant le streaming d'une réponse longue, ne réancre PAS le
                // scroll si l'utilisateur a délibérément remonté pour relire
                // le début — sinon chaque token reçu annulerait son geste.
                guard isPinnedToBottom else { return }
                // Sans animation ici : ce `onChange` se déclenche à chaque
                // snapshot reçu de `textStream` (potentiellement des dizaines
                // par réponse), et envelopper chacun dans `withAnimation`
                // relançait autant de transactions d'animation/scroll en
                // rafale. Les scrolls déclenchés par un nouvel échange ou une
                // erreur (événements ponctuels, pas un flux) restent animés.
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.errorDescription) { _, newValue in
                scrollToBottom(proxy: proxy)
                if let newValue {
                    announce(error: newValue)
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// Annonce l'échec à VoiceOver dès qu'il survient : sans ceci, un
    /// utilisateur VoiceOver n'a aucun moyen de savoir qu'une erreur vient de
    /// s'afficher (le bandeau est un `Label` statique, pas un élément qui
    /// prend le focus tout seul).
    private func announce(error description: String) {
        AccessibilityNotification.Announcement("Erreur : \(description)").post()
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
                    if viewModel.isGenerating {
                        // Affordance d'annulation : sans elle, une génération
                        // qui ne répond plus (ex. connexion BYOK qui pend)
                        // tourne jusqu'au timeout réseau par défaut, sans
                        // aucun moyen de l'arrêter autrement qu'en quittant
                        // l'écran (ce qui annule aussi via `.onDisappear`,
                        // mais fait perdre l'écran).
                        sendTask?.cancel()
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: viewModel.isGenerating ? "stop.fill" : "arrow.up")
                }
                .buttonStyle(.glassProminent)
                .disabled(viewModel.isGenerating ? false : isSendDisabled)
                .accessibilityLabel(viewModel.isGenerating ? "Arrêter la génération" : "Envoyer")
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

/// `FailoverManager` factice qui réussit une première fois, puis échoue
/// systématiquement ensuite (aucune instance configurée à partir du 2e appel)
/// — jamais vu par le processus de previews normal jusqu'ici (finding 16 de la
/// revue 0.8) : sert à vérifier à quoi ressemble réellement le bandeau
/// d'erreur quand un échange précédent existe déjà dans la liste (police,
/// alignement, cohabitation avec le scroll auto-ancré en bas).
private final class FlakyFailoverManagerFactory: @unchecked Sendable {
    private var callCount = 0

    func make() -> FailoverManager {
        defer { callCount += 1 }
        if callCount == 0 {
            return FailoverManager(
                client: PreviewSearXNGClient(results: PreviewSearXNGClient.sampleResults),
                instances: [PreviewSearXNGClient.instance]
            )
        }
        return FailoverManager(client: PreviewSearXNGClient(results: []), instances: [])
    }
}

#Preview("Erreur — après un échange déjà réussi") {
    let factory = FlakyFailoverManagerFactory()
    let viewModel = ChatViewModel(
        resolveProvider: { PreviewAIProvider(response: "Voici une première réponse, qui réussit.") },
        resolveFailoverManager: factory.make
    )
    return ChatView(viewModel: viewModel)
        .task {
            await viewModel.send(query: "Première question, qui réussit.")
            await viewModel.send(query: "Deuxième question, qui échoue.")
        }
}
