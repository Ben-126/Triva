//
//  CloudProviderModelPickerView.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import SwiftUI
import ClaudeForFoundationModels

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

    init(viewModel: CloudProviderModelPickerViewModel = CloudProviderModelPickerViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                if viewModel.configuredProviders.isEmpty {
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
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .onAppear { syncCustomModelText() }
        .onChange(of: viewModel.selectedConfiguredProviderID) { _, _ in syncCustomModelText() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fournisseur & modèle")
                .font(.system(size: 28, weight: .semibold))
            Text("Choisis le fournisseur cloud et le modèle à utiliser.")
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
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isSelected ? .regular.tint(.accentColor.opacity(0.12)) : .regular,
                in: .rect(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func modelSection(for providerID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MODÈLE")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.tertiary)

            if providerID == CloudProviderSelectionResolver.claudeProviderID {
                claudeModelPicker
            } else {
                customModelField
            }
        }
    }

    private var claudeModelPicker: some View {
        Picker(
            "Modèle",
            selection: Binding(
                get: { viewModel.selectedModel ?? ClaudeModel.sonnet5.id },
                set: { viewModel.updateModel(to: $0) }
            )
        ) {
            ForEach(CloudProviderSelectionResolver.knownClaudeModels, id: \.id) { model in
                Text(CloudProviderModelPickerViewModel.claudeModelDisplayName(for: model))
                    .tag(model.id)
            }
        }
        .pickerStyle(.menu)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// Le `TextField` des modèles non-Claude est un état local (`customModelText`),
    /// pas directement lié à `viewModel.selectedModel` — sinon chaque frappe
    /// clavier ferait un aller-retour par le view model. Il est resynchronisé
    /// ici à l'apparition et à chaque changement de fournisseur sélectionné.
    private func syncCustomModelText() {
        guard let selectedProviderID = viewModel.selectedConfiguredProviderID,
              selectedProviderID != CloudProviderSelectionResolver.claudeProviderID else {
            return
        }
        customModelText = viewModel.selectedModel ?? ""
    }
}

#Preview {
    struct PreviewAPIKeyStore: APIKeyStoring {
        func apiKey(account: String) throws -> String? {
            ["claude": "sk-demo", "groq": "sk-demo", "mistral": "sk-demo"][account]
        }
        func save(apiKey: String, account: String) throws {}
        func deleteAPIKey(account: String) throws {}
    }

    return CloudProviderModelPickerView(
        viewModel: CloudProviderModelPickerViewModel(
            keyStore: PreviewAPIKeyStore(),
            customPresets: [],
            selectionStore: CloudProviderSelectionStore(
                userDefaults: UserDefaults(suiteName: "preview.cloudProviderModelPicker")!
            )
        )
    )
}
