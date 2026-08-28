//
//  AIEngineSelectionView.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

/// Écran de choix du moteur IA (0.3) : 3 cartes (Apple Intelligence / MLX local /
/// clé API perso), avec présélection automatique de l'option recommandée pour
/// l'appareil détecté — le choix reste libre. Réutilisable depuis l'onboarding
/// initial ou depuis les Réglages (1.15) pour changer de moteur à tout moment.
struct AIEngineSelectionView: View {
    @State private var selection: AIEngineOption
    private let recommendation: AIEngineRecommendation
    private let onConfirm: (AIEngineOption) -> Void

    init(
        capabilityProvider: any DeviceCapabilityProviding = SystemDeviceCapabilityProvider(),
        currentSelection: AIEngineOption? = nil,
        onConfirm: @escaping (AIEngineOption) -> Void
    ) {
        let recommendation = AIProviderSelector.recommend(for: capabilityProvider)
        self.recommendation = recommendation
        _selection = State(initialValue: currentSelection ?? recommendation.option)
        self.onConfirm = onConfirm
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choisis ton moteur IA")
                    .font(.title2.bold())
                Text("Tu pourras en changer à tout moment depuis les Réglages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                engineCard(
                    option: .appleIntelligence,
                    title: "Apple Intelligence",
                    subtitle: "Gratuit, sur l'appareil. Nécessite un iPhone/Mac compatible avec Apple Intelligence activé."
                )
                engineCard(
                    option: .mlxLocal,
                    title: "Modèle local (MLX)",
                    subtitle: "Gratuit, sur l'appareil. Un modèle adapté à la puissance de ton appareil te sera proposé au choix (0.5)."
                )
                engineCard(
                    option: .cloudBYOK,
                    title: "Clé API personnelle",
                    subtitle: "Le plus puissant. Payant selon le fournisseur choisi, ta clé reste uniquement sur cet appareil."
                )

                Button("Continuer") {
                    onConfirm(selection)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func engineCard(option: AIEngineOption, title: String, subtitle: String) -> some View {
        let isSelected = selection == option
        let isRecommended = recommendation.option == option

        Button {
            selection = option
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    if isRecommended {
                        Text("Recommandé")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AIEngineSelectionView { _ in }
}
