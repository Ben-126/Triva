import SwiftUI

struct ContentView: View {
    @State private var engineSettings = AIEngineSettingsStore()
    /// Stores de sélection partagés entre toutes les fenêtres de l'app (créés
    /// une seule fois par `TrivaApp` et injectés ici) — sur macOS, chaque
    /// nouvelle fenêtre (Cmd-N) instancie un `ContentView` distinct ; sans ce
    /// partage, chaque fenêtre aurait sa propre copie de la sélection MLX/BYOK
    /// et ne verrait jamais les changements faits dans une autre fenêtre. Les
    /// valeurs par défaut ne servent qu'aux previews et aux tests isolés.
    let mlxSelectionStore: MLXModelSelectionStore
    let cloudSelectionStore: CloudProviderSelectionStore
    let customProviderStore: CustomProviderStore

    init(
        mlxSelectionStore: MLXModelSelectionStore = MLXModelSelectionStore(),
        cloudSelectionStore: CloudProviderSelectionStore = CloudProviderSelectionStore(),
        customProviderStore: CustomProviderStore = CustomProviderStore()
    ) {
        self.mlxSelectionStore = mlxSelectionStore
        self.cloudSelectionStore = cloudSelectionStore
        self.customProviderStore = customProviderStore
    }

    var body: some View {
        if let selected = engineSettings.selectedOption {
            EngineStatusView(
                selectedEngine: selected,
                onChangeEngine: { engineSettings.selectedOption = nil },
                mlxSelectionStore: mlxSelectionStore,
                cloudSelectionStore: cloudSelectionStore,
                customProviderStore: customProviderStore
            )
        } else {
            AIEngineSelectionView { chosen in
                engineSettings.selectedOption = chosen
            }
        }
    }
}

/// Affiche le moteur IA choisi (badge + légende de confidentialité,
/// DESIGN.md) et l'écran de chat réel (`ChatView`, 0.8) pour ce moteur. Gère
/// aussi tout ce qui est spécifique à la sélection du moteur : choix/
/// changement de modèle MLX, indisponibilité d'Apple Intelligence.
private struct EngineStatusView: View {
    let selectedEngine: AIEngineOption
    let onChangeEngine: () -> Void

    /// Stores de sélection injectés depuis `ContentView` (eux-mêmes uniques
    /// pour toute l'app, voir son commentaire) — surtout PAS de `@State` ici :
    /// `EngineStatusView` est recréée à chaque changement de moteur ou à
    /// chaque nouvelle fenêtre sur macOS, et un `@State` réinitialisé à
    /// chaque instance romprait le partage que `ContentView` établit.
    let mlxSelectionStore: MLXModelSelectionStore
    let cloudSelectionStore: CloudProviderSelectionStore
    let customProviderStore: CustomProviderStore

    /// Valeurs par défaut réservées aux previews ci-dessous (qui n'ont pas de
    /// `ContentView` parent pour fournir les stores partagés) — l'app réelle
    /// passe toujours les stores injectés par `ContentView`.
    init(
        selectedEngine: AIEngineOption,
        onChangeEngine: @escaping () -> Void,
        mlxSelectionStore: MLXModelSelectionStore = MLXModelSelectionStore(),
        cloudSelectionStore: CloudProviderSelectionStore = CloudProviderSelectionStore(),
        customProviderStore: CustomProviderStore = CustomProviderStore()
    ) {
        self.selectedEngine = selectedEngine
        self.onChangeEngine = onChangeEngine
        self.mlxSelectionStore = mlxSelectionStore
        self.cloudSelectionStore = cloudSelectionStore
        self.customProviderStore = customProviderStore
    }

    @State private var showingMLXSelection = false
    @State private var validatedMLXModel: MLXModelCatalogEntry?
    /// Erreur de disponibilité Apple Intelligence, calculée une seule fois
    /// (`onAppear`) plutôt qu'à chaque évaluation de `body` — même principe de
    /// cache que `preparedProvider`/`failoverManager`/`chatViewModel`
    /// ci-dessous : reconstruire `AppleIntelligenceProvider()` et relire
    /// `SystemLanguageModel.availability` à chaque re-render (déclenché par
    /// n'importe lequel des `@State` de cet écran, pas seulement ceux liés à
    /// Apple Intelligence) est un travail inutile.
    @State private var appleIntelligenceError: AppleIntelligenceError?
    /// Provider IA déjà résolu (et, pour MLX, déjà préparé) pour la sélection
    /// actuelle — évite de recréer un `MLXProvider` et de refaire un
    /// `prepare()` coûteux (voir son commentaire de tête) à chaque échange du
    /// chat. Invalidé explicitement quand la sélection change (nouveau
    /// modèle MLX choisi).
    @State private var preparedProvider: (any AIGenerating)?
    /// `FailoverManager` unique pour la durée de vie de cet écran — recréer un
    /// `FailoverManager` à chaque échange annulerait son cache de dernière
    /// instance SearXNG fonctionnelle (voir son commentaire de tête).
    @State private var failoverManager: FailoverManager?
    /// Un seul `ChatViewModel` pour la durée de vie de cet écran — recréé
    /// systématiquement à chaque re-render, il perdrait le fil de
    /// conversation en cours à chaque rafraîchissement de `body`. Même
    /// principe de cache que `preparedProvider`/`failoverManager`.
    @State private var chatViewModel: ChatViewModel?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Même plafond que `ChatView.contentMaxWidth` (640pt en `regular`,
    /// iPad/Mac) — sans lui, le badge moteur IA et le bouton "Changer de
    /// moteur" restaient collés au bord gauche pendant que `ChatView`
    /// juste en dessous centrait ses messages, sur le même écran.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if selectedEngine == .appleIntelligence, let error = appleIntelligenceError {
                Label("Indisponible : \(String(describing: error))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else if selectedEngine == .mlxLocal, validatedMLXModel == nil {
                // Le CTA "Choisir un modèle MLX" vit désormais dans `header`
                // (voir son commentaire), AVANT "Changer de moteur" — rien à
                // afficher ici tant qu'aucun modèle n'est validé : le chat ne
                // peut de toute façon pas être utilisé sans modèle.
                EmptyView()
            } else if let chatViewModel {
                ChatView(viewModel: chatViewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
        .sheet(isPresented: $showingMLXSelection) {
            MLXModelSelectionView { chosen in
                validatedMLXModel = chosen
                mlxSelectionStore.selectedModelID = chosen.id
                // Un autre modèle a été choisi : le provider déjà préparé (si
                // il y en avait un) ne correspond plus à la sélection.
                preparedProvider = nil
                showingMLXSelection = false
            }
        }
        .onChange(of: cloudSelectionStore.selection) {
            // La sélection cloud BYOK a changé (ou a été effacée ailleurs,
            // p. ex. `CustomProviderStore.remove(id:)` sur un fournisseur
            // personnalisé actif) : le provider déjà préparé, s'il y en avait
            // un, ne correspond plus forcément à la sélection actuelle.
            preparedProvider = nil
        }
        .onAppear {
            appleIntelligenceError = AppleIntelligenceProvider().availabilityError
            rehydrateValidatedMLXModel()
            ensureChatViewModel()
        }
    }

    /// Badge moteur IA + légende de confidentialité, et pour MLX local le CTA
    /// de choix de modèle (ou le modèle actif + bouton pour en changer) — la
    /// seule partie de cet écran qui ne fait pas partie du chat lui-même.
    /// Tous les éléments de verre de ce bloc (badge, CTA "Choisir un modèle
    /// MLX", carte "Modèle actif", bouton "Changer de modèle MLX", bouton
    /// "Changer de moteur") partagent un seul `GlassEffectContainer` commun
    /// (DESIGN.md : "toujours envelopper des éléments de verre frères dans un
    /// `GlassEffectContainer`") — jamais de container imbriqué dans un autre.
    ///
    /// Ordre volontaire : le CTA "Choisir un modèle MLX" (`.glassProminent`,
    /// l'action OBLIGATOIRE sans laquelle le chat est inutilisable) est
    /// TOUJOURS rendu avant "Changer de moteur" (`.glass`, une simple
    /// échappatoire secondaire) — DESIGN.md réserve `.glassProminent` à
    /// l'action principale d'un écran, ce que contredirait le fait de la
    /// faire suivre visuellement une action secondaire en scannant l'écran de
    /// haut en bas.
    private var header: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(selectedEngine.privacyBadge.text, systemImage: selectedEngine.privacyBadge.icon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)

                    Text(selectedEngine.privacyBadge.caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }

                if selectedEngine == .mlxLocal, validatedMLXModel == nil {
                    Button("Choisir un modèle MLX") {
                        showingMLXSelection = true
                    }
                    .buttonStyle(.glassProminent)
                }

                if selectedEngine == .mlxLocal, let validatedMLXModel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Modèle actif : \(validatedMLXModel.displayName)")
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        Button("Changer de modèle MLX") {
                            showingMLXSelection = true
                        }
                        .buttonStyle(.glass)
                    }
                }

                Button("Changer de moteur", action: onChangeEngine)
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    /// Retrouve le modèle MLX précédemment validé (0.5) à partir de son id
    /// persisté (`MLXModelSelectionStore`) — sinon cet écran perdrait le
    /// choix de l'utilisateur à chaque relance de l'app, ce que ni
    /// `MLXModelSelectionCoordinator` ni cet écran temporaire ne
    /// persistaient jusqu'ici.
    private func rehydrateValidatedMLXModel() {
        guard validatedMLXModel == nil, let id = mlxSelectionStore.selectedModelID else { return }
        guard let catalog = try? MLXModelCatalog.load() else { return }
        validatedMLXModel = catalog.first { $0.id == id }
    }

    /// Résout le provider IA correspondant au moteur actuellement sélectionné
    /// (0.7 : pont entre la sélection persistée et un `AIGenerating` prêt à
    /// l'emploi, voir `ActiveAIProviderResolver`), en préparant un
    /// `MLXProvider` si besoin — `ActiveAIProviderResolver` ne le fait
    /// jamais lui-même (voir sa documentation), c'est donc le rôle de cet
    /// écran qui, lui, sait qu'un chargement potentiellement long est
    /// acceptable ici. Le résultat est mis en cache (`preparedProvider`) pour
    /// qu'une 2e recherche dans le même écran réutilise le provider déjà prêt
    /// au lieu de refaire un `prepare()` complet à chaque fois.
    private func resolveActiveProvider() async throws -> any AIGenerating {
        if let preparedProvider {
            return preparedProvider
        }

        let provider = try ActiveAIProviderResolver.resolve(
            engineSettings: AIEngineSettingsStore(),
            mlxSelection: mlxSelectionStore,
            mlxCatalog: try MLXModelCatalog.load(),
            cloudSelection: cloudSelectionStore,
            customCloudPresets: customProviderStore.customPresets
        )

        if let mlxProvider = provider as? MLXProvider {
            try await mlxProvider.prepare()
        }

        preparedProvider = provider
        return provider
    }

    /// Résout le `FailoverManager` de cet écran, en le créant et en le mettant
    /// en cache au premier appel (comme `preparedProvider`) — recréer un
    /// `FailoverManager` à chaque recherche perdrait son cache de dernière
    /// instance SearXNG fonctionnelle.
    private func resolveFailoverManager() throws -> FailoverManager {
        if let failoverManager {
            return failoverManager
        }
        let manager = FailoverManager(instances: try PublicInstanceList.load())
        failoverManager = manager
        return manager
    }

    /// Crée le `ChatViewModel` de cet écran au besoin et le met en cache
    /// (comme `preparedProvider`/`failoverManager`) — jamais recréé à chaque
    /// re-render de `body`, ce qui perdrait le fil de conversation en cours.
    /// Appelée depuis `.onAppear`, jamais depuis `body`, pour ne pas écrire
    /// dans `@State` pendant l'évaluation de la vue (SwiftUI l'interdit :
    /// "Modifying state during view update"). Ses closures de résolution
    /// pointent vers `resolveActiveProvider`/`resolveFailoverManager`
    /// ci-dessus : elles restent valables même après un changement de modèle
    /// MLX (`preparedProvider` est alors invalidé, mais pas ce
    /// `ChatViewModel`).
    private func ensureChatViewModel() {
        guard chatViewModel == nil else { return }
        chatViewModel = ChatViewModel(
            resolveProvider: resolveActiveProvider,
            resolveFailoverManager: resolveFailoverManager
        )
    }
}

#Preview {
    ContentView()
}

#Preview("Statut — Apple Intelligence") {
    EngineStatusView(selectedEngine: .appleIntelligence, onChangeEngine: {})
}

#Preview("Statut — MLX local") {
    EngineStatusView(selectedEngine: .mlxLocal, onChangeEngine: {})
}

#Preview("Statut — Cloud BYOK") {
    EngineStatusView(selectedEngine: .cloudBYOK, onChangeEngine: {})
}
