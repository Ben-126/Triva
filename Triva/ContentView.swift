import SwiftUI

struct ContentView: View {
    @State private var engineSettings = AIEngineSettingsStore()

    var body: some View {
        if let selected = engineSettings.selectedOption {
            EngineStatusView(
                selectedEngine: selected,
                onChangeEngine: { engineSettings.selectedOption = nil }
            )
        } else {
            AIEngineSelectionView { chosen in
                engineSettings.selectedOption = chosen
            }
        }
    }
}

/// Écran temporaire de V0 : affiche le moteur choisi et permet de tester une
/// vraie génération Apple Intelligence sur l'appareil, pour valider 0.4 en
/// conditions réelles (l'outil de snippet Xcode n'y arrive pas de façon fiable).
/// Contient aussi, depuis 0.7, un test du pipeline recherche -> génération
/// complet (`SearchTestSection`) pour les 3 moteurs IA, sur le même principe.
/// Sera remplacé par le vrai chat (0.8).
private struct EngineStatusView: View {
    let selectedEngine: AIEngineOption
    let onChangeEngine: () -> Void

    @State private var appleIntelligenceResult: Result<String, AppleIntelligenceError>?
    @State private var isTesting = false
    @State private var showingMLXSelection = false
    @State private var validatedMLXModel: MLXModelCatalogEntry?
    @State private var mlxSelectionStore = MLXModelSelectionStore()
    @State private var cloudSelectionStore = CloudProviderSelectionStore()
    @State private var customProviderStore = CustomProviderStore()
    /// Provider IA déjà résolu (et, pour MLX, déjà préparé) pour la sélection
    /// actuelle — évite de recréer un `MLXProvider` et de refaire un
    /// `prepare()` coûteux (voir son commentaire de tête) à chaque recherche
    /// de `SearchTestSection`. Invalidé explicitement quand la sélection
    /// change (nouveau modèle MLX choisi).
    @State private var preparedProvider: (any AIGenerating)?
    /// `FailoverManager` unique pour la durée de vie de cet écran, comme
    /// `mlxSelectionStore`/`cloudSelectionStore` — recréer un
    /// `FailoverManager` à chaque recherche annulerait son cache de dernière
    /// instance SearXNG fonctionnelle (voir son commentaire de tête).
    @State private var failoverManager: FailoverManager?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
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

                if selectedEngine == .appleIntelligence {
                    appleIntelligenceTestSection
                }

                if selectedEngine == .mlxLocal {
                    mlxTestSection
                }

                if selectedEngine == .cloudBYOK {
                    cloudBYOKTestSection
                }

                Button("Changer de moteur", action: onChangeEngine)
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
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
        .onAppear { rehydrateValidatedMLXModel() }
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

    @ViewBuilder
    private var mlxTestSection: some View {
        if let validatedMLXModel {
            // Un seul `GlassEffectContainer` partagé pour tous les éléments de
            // verre frères de ce groupe (voir DESIGN.md) plutôt que de les
            // laisser hors container à côté du container interne de
            // `SearchTestSection`.
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Modèle actif : \(validatedMLXModel.displayName)")
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    Button("Changer de modèle MLX") {
                        showingMLXSelection = true
                    }
                    .buttonStyle(.glass)

                    SearchTestSection(resolveProvider: resolveActiveProvider, resolveFailoverManager: resolveFailoverManager)
                }
            }
        } else {
            Button("Choisir un modèle MLX") {
                showingMLXSelection = true
            }
            .buttonStyle(.glassProminent)
        }
    }

    @ViewBuilder
    private var appleIntelligenceTestSection: some View {
        if let error = AppleIntelligenceProvider().availabilityError {
            Label("Indisponible : \(String(describing: error))", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            // Même principe que `mlxTestSection` : un seul container partagé
            // pour ce groupe de verre plutôt que deux containers côte à côte.
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        Task { await testGeneration() }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Text("Tester une génération")
                        }
                    }
                    // Action secondaire : la recherche ci-dessous est
                    // désormais le test principal de cette section — une
                    // seule action `.glassProminent` par écran (DESIGN.md).
                    .buttonStyle(.glass)
                    .disabled(isTesting)

                    if let appleIntelligenceResult {
                        switch appleIntelligenceResult {
                        case .success(let text):
                            Text(text)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        case .failure(let error):
                            Text("Erreur : \(String(describing: error))")
                                .foregroundStyle(.red)
                        }
                    }

                    SearchTestSection(resolveProvider: resolveActiveProvider, resolveFailoverManager: resolveFailoverManager)
                }
            }
        }
    }

    @ViewBuilder
    private var cloudBYOKTestSection: some View {
        GlassEffectContainer(spacing: 12) {
            SearchTestSection(resolveProvider: resolveActiveProvider, resolveFailoverManager: resolveFailoverManager)
        }
    }

    private func testGeneration() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let text = try await AppleIntelligenceProvider().generate(prompt: "Dis bonjour en une phrase courte.")
            appleIntelligenceResult = .success(text)
        } catch let error as AppleIntelligenceError {
            appleIntelligenceResult = .failure(error)
        } catch {
            appleIntelligenceResult = .failure(.generationFailed(description: String(describing: error)))
        }
    }
}

/// Test bout-en-bout du pipeline recherche -> génération minimal (0.7),
/// commun aux 3 moteurs IA — seule la façon de résoudre le provider change
/// d'un moteur à l'autre (`resolveProvider`, fourni par l'appelant). Reste
/// volontairement bricolé (pas de scoring de sources, pas de citations,
/// liste de sources en simple titre + lien) : ce n'est pas l'UI de chat
/// finale (0.8).
private struct SearchTestSection: View {
    let resolveProvider: () async throws -> any AIGenerating
    /// Fourni par l'écran parent (`EngineStatusView`) plutôt que créé ici, pour
    /// que le cache de dernière instance SearXNG fonctionnelle de
    /// `FailoverManager` survive à plusieurs recherches successives.
    let resolveFailoverManager: () throws -> FailoverManager

    @State private var query = ""
    @State private var isSearching = false
    @State private var result: SearchOrchestratorResult?
    @State private var errorDescription: String?

    /// Ne s'enveloppe plus dans son propre `GlassEffectContainer` : c'est
    /// désormais l'appelant qui fournit un container partagé englobant cette
    /// section et ses éventuels frères de verre (voir DESIGN.md).
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TESTER UNE RECHERCHE")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tint)
                TextField("Pose ta question…", text: $query)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))

            Button {
                Task { await search() }
            } label: {
                if isSearching {
                    ProgressView()
                } else {
                    Text("Rechercher")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(isSearching || query.isEmpty)

            if let errorDescription {
                Text("Erreur : \(errorDescription)")
                    .foregroundStyle(.red)
            }

            if let result {
                resultSection(result)
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ result: SearchOrchestratorResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.answer)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))

            if !result.sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.title)
                                .font(.footnote.weight(.medium))
                            Text(source.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func search() async {
        isSearching = true
        errorDescription = nil
        result = nil
        defer { isSearching = false }
        do {
            let aiProvider = try await resolveProvider()
            let failoverManager = try resolveFailoverManager()
            let orchestrator = SearchOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)
            result = try await orchestrator.answer(query: query)
        } catch {
            errorDescription = String(describing: error)
        }
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
