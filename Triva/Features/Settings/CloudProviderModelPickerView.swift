//
//  CloudProviderModelPickerView.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import SwiftUI

/// Écran de choix du fournisseur cloud BYOK actif et de son modèle (0.6
/// élargi — sélection de fournisseur/modèle), parmi les fournisseurs pour
/// lesquels une clé API est déjà enregistrée (voir `BYOKProvidersView` pour
/// la configuration des clés elles-mêmes, un écran distinct). Réutilisable
/// de façon autonome, comme `AIEngineSelectionView` (0.3) — l'écran Réglages
/// qui l'accueillera reste le scope de 1.15. Ne construit aucun pipeline de
/// recherche/génération (0.7, hors scope ici) : seule la sélection est
/// persistée, via `CloudProviderModelPickerViewModel`.
struct CloudProviderModelPickerView: View {
    @State private var viewModel: CloudProviderModelPickerViewModel
    @State private var customModelText: String = ""

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Largeur de contenu plafonnée hors `compact` (iPad plein écran, Split
    /// View large, Stage Manager, Mac — où la size class vaut `nil`) : même
    /// principe que `BYOKProvidersView.contentMaxWidth`, pour que les cartes
    /// et le menu des modèles ne s'étirent pas bord à bord.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .compact ? nil : 640
    }

    init(viewModel: CloudProviderModelPickerViewModel = CloudProviderModelPickerViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                if !viewModel.hasLoadedProviders {
                    // Lecture du Trousseau en cours (hors main actor) : ni liste
                    // ni « aucune clé », qui serait faux pendant ce court instant.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if viewModel.configuredProviders.isEmpty {
                    emptyState
                } else {
                    GlassEffectContainer(spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.configuredProviders) { provider in
                                providerCard(provider)
                            }
                        }
                    }

                    if let selectedProviderID = viewModel.selectedConfiguredProviderID {
                        modelSection(for: selectedProviderID)
                    }

                    Text(CloudWebSearchCostNotice.sentence)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .task { await viewModel.loadConfiguredProviders() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fournisseur & modèle")
                .font(.system(size: 28, weight: .semibold))
            Text("Seuls les fournisseurs dont la clé est enregistrée apparaissent ici.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text("Configure au moins une clé API pour choisir un fournisseur.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func providerCard(_ provider: ConfiguredCloudProvider) -> some View {
        let isSelected = provider.id == viewModel.selectedProviderID

        Button {
            viewModel.selectProvider(id: provider.id)
        } label: {
            HStack {
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isSelected ? .regular.tint(.accentColor.opacity(0.12)) : .regular,
                in: .rect(cornerRadius: 20)
            )
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func modelSection(for providerID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MODÈLE")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.tertiary)

            // Saisie manuelle UNIQUEMENT quand la liste ne peut pas être
            // obtenue (voir `showsManualModelEntry`) ; sinon le menu.
            if viewModel.showsManualModelEntry {
                customModelField
            } else {
                modelMenu
            }

            modelListStatus
        }
        .task(id: providerID) { await viewModel.loadModels() }
        .onChange(of: viewModel.showsManualModelEntry, initial: true) { _, showsField in
            if showsField { customModelText = viewModel.selectedModel ?? "" }
        }
    }

    /// Menu natif de tous les modèles récupérés chez le fournisseur.
    private var modelMenu: some View {
        Picker(
            "Modèle",
            selection: Binding(
                get: { viewModel.selectedModel ?? "" },
                set: { viewModel.updateModel(to: $0) }
            )
        ) {
            ForEach(viewModel.modelMenuOptions) { option in
                Text(option.displayName)
                    .tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private var modelListStatus: some View {
        switch viewModel.modelListState {
        case .idle, .loaded:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Chargement des modèles…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .noKey:
            statusText("Aucune clé lisible pour ce fournisseur : la liste des modèles ne peut pas être chargée. Saisis le nom exact du modèle.")
        case .unavailable(let message):
            statusText(message)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                statusText(message)
                Button("Réessayer") {
                    Task { await viewModel.loadModels(forceRefresh: true) }
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var customModelField: some View {
        TextField(
            "Nom du modèle",
            text: Binding(
                get: { customModelText },
                set: { newValue in
                    customModelText = newValue
                    viewModel.updateModel(to: newValue)
                }
            )
        )
        .autocorrectionDisabled()
        .padding(16)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

/// Construit l'écran avec des clés factices et un faux réseau : les previews
/// ne doivent jamais appeler un vrai fournisseur.
@MainActor
private func previewPicker(suiteName: String) -> CloudProviderModelPickerView {
    struct PreviewAPIKeyStore: APIKeyStoring {
        func apiKey(account: String) throws -> String? {
            ["claude": "sk-demo", "groq": "sk-demo", "mistral": "sk-demo"][account]
        }
        func save(apiKey: String, account: String) throws {}
        func deleteAPIKey(account: String) throws {}
    }

    struct PreviewRequester: HTTPDataRequesting {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let body = #"{"data":[{"id":"llama-3.3-70b-versatile"},{"id":"llama-3.1-8b-instant"}]}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    let selectionStore = CloudProviderSelectionStore(userDefaults: UserDefaults(suiteName: suiteName)!)
    selectionStore.selection = CloudProviderSelection(providerID: "groq", model: "llama-3.3-70b-versatile")
    return CloudProviderModelPickerView(
        viewModel: CloudProviderModelPickerViewModel(
            keyStore: PreviewAPIKeyStore(),
            customPresets: [],
            selectionStore: selectionStore,
            modelListService: CloudModelListService(requester: PreviewRequester(), cache: CloudModelListCache())
        )
    )
}

#Preview("iPhone") {
    previewPicker(suiteName: "preview.cloudProviderModelPicker")
}

#Preview("iPad paysage", traits: .fixedLayout(width: 1180, height: 820)) {
    previewPicker(suiteName: "preview.cloudProviderModelPicker.ipad")
        .environment(\.horizontalSizeClass, .regular)
}
