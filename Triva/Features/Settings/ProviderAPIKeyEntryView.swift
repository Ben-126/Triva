//
//  ProviderAPIKeyEntryView.swift
//  Triva
//
//  Created by ben podrojsky on 03/09/2026.
//

import SwiftUI

/// Écran de saisie de la clé API d'**un** fournisseur BYOK (0.6, élargi à
/// tout preset de `CloudProviderCatalog` + Claude + "Personnalisé" — voir
/// `BYOKProvidersView`, qui liste tous les fournisseurs et pousse cette vue
/// pour celui choisi). La clé est validée par un vrai appel au fournisseur
/// avant d'être enregistrée en Keychain, et n'est jamais réaffichée en clair
/// une fois stockée.
struct ProviderAPIKeyEntryView: View {
    let providerDisplayName: String
    @State private var viewModel: APIKeysViewModel
    @State private var rawKey: String = ""
    /// Accord d'envoi (mission C2) : `nil` dans les aperçus.
    private let consentStore: CloudAIConsentStore?
    private let providerID: String?
    @State private var isConfirmingRevoke = false

    init(
        providerDisplayName: String,
        viewModel: APIKeysViewModel,
        providerID: String? = nil,
        consentStore: CloudAIConsentStore? = nil
    ) {
        self.providerID = providerID
        self.consentStore = consentStore
        self.providerDisplayName = providerDisplayName
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                GlassEffectContainer(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        if viewModel.hasStoredKey {
                            storedKeyCard
                        } else {
                            entryField
                        }
                    }
                }

                if let consentStore, let providerID {
                    consentSection(store: consentStore, providerID: providerID)
                }

                if case .failed(let message) = viewModel.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .navigationTitle(providerDisplayName)
        .onChange(of: viewModel.state) { _, newValue in
            if case .failed(let message) = newValue {
                announce(error: message)
            }
        }
    }

    /// Annonce l'échec à VoiceOver dès qu'il survient, sur le modèle de
    /// `ChatView.announce(error:)` : sans ceci, un utilisateur VoiceOver n'a
    /// aucun moyen de savoir que la validation vient d'échouer tant qu'il ne
    /// réexplore pas l'écran.
    private func announce(error description: String) {
        AccessibilityNotification.Announcement("Erreur : \(description)").post()
    }

    /// Accord d'envoi à ce fournisseur et son retrait (textes A.2 de `ecrans.md`).
    /// Validé par Ben le 2026-11-18 (texte légal).
    @ViewBuilder
    private func consentSection(store: CloudAIConsentStore, providerID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isGranted(providerID: providerID) {
                HStack {
                    Label(CloudAIConsentText.revokeStatus, systemImage: "checkmark.circle")
                        .font(.headline)
                    Spacer()
                    Button(CloudAIConsentText.revokeButton, role: .destructive) {
                        isConfirmingRevoke = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("consent.revoke")
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .confirmationDialog(
                    CloudAIConsentText.revokeConfirmTitle(providerDisplayName),
                    isPresented: $isConfirmingRevoke,
                    titleVisibility: .visible
                ) {
                    Button(CloudAIConsentText.revokeConfirmAction, role: .destructive) {
                        store.revoke(providerID: providerID)
                    }
                    Button(CloudAIConsentText.cancel, role: .cancel) {}
                } message: {
                    Text(CloudAIConsentText.revokeConfirmBody(providerDisplayName))
                }
            }
            Text(CloudAIConsentText.revokeFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        Text("Envoyée directement à \(providerDisplayName) — jamais à un serveur Triva.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var entryField: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Clé API \(providerDisplayName)", text: $rawKey)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))

            Button {
                Task { await viewModel.save(rawKey: rawKey) }
            } label: {
                Group {
                    if viewModel.state == .validating {
                        ProgressView()
                            .accessibilityLabel("Validation de la clé en cours")
                    } else {
                        Text("Enregistrer")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.state == .validating || rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var storedKeyCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clé enregistrée")
                    .font(.headline)
                Text("Stockée uniquement sur cet appareil (Keychain).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Supprimer", role: .destructive) {
                viewModel.deleteStoredKey()
                rawKey = ""
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

#Preview {
    NavigationStack {
        ProviderAPIKeyEntryView(providerDisplayName: "Claude", viewModel: APIKeysViewModel())
    }
}
