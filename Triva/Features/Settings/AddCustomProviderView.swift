//
//  AddCustomProviderView.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import SwiftUI

/// Formulaire d'ajout d'un fournisseur BYOK "personnalisé" (0.6 élargi) :
/// n'importe quel fournisseur compatible OpenAI non couvert par
/// `CloudProviderCatalog` — l'utilisateur saisit lui-même son nom, l'URL de
/// base de son API et le nom du modèle. La clé API se configure ensuite sur
/// `ProviderAPIKeyEntryView`, une fois l'entrée créée (même flux de
/// validation avant sauvegarde que les autres fournisseurs).
struct AddCustomProviderView: View {
    let customStore: CustomProviderStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var baseURLText: String = ""
    @State private var model: String = ""
    @State private var errorMessage: String?

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: baseURLText)?.scheme?.hasPrefix("http") == true
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("Nom (ex. Mon LLM)", text: $displayName)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))

                    TextField("URL de base (ex. https://api.exemple.com/v1)", text: $baseURLText)
                        .autocorrectionDisabled()
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))

                    TextField("Nom du modèle", text: $model)
                        .autocorrectionDisabled()
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .navigationTitle("Fournisseur personnalisé")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        guard let url = URL(string: baseURLText) else {
            errorMessage = "URL invalide."
            return
        }
        customStore.add(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: url,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}

#Preview {
    AddCustomProviderView(customStore: CustomProviderStore())
}
