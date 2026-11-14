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
    /// `nil` à la première ouverture (aucun moteur encore choisi : il n'y a rien
    /// vers quoi revenir) ; fourni quand on CHANGE de moteur, pour pouvoir
    /// renoncer sans devoir reconfirmer un moteur (demande de Ben, 2026-10-08).
    /// Les Réglages ne le passent pas : leur feuille a déjà son propre « Annuler ».
    private let onCancel: (() -> Void)?
    /// Cloud privé d'Apple ou appareil (mission A4). Le choix n'est montré que si le cloud est
    /// proposé, et n'est ÉCRIT qu'à « Continuer » : « Annuler » ne change rien (vérifié par Q1).
    private let appleModel: AppleIntelligenceModelCoordinator
    @State private var appleModelChoice: AppleIntelligenceModelKind

    /// `true` au premier lancement (aucun moteur encore choisi) : logo, titre d'accroche et phrase
    /// d'accueil. En changement de moteur, ce texte n'a pas de sens — on y est déjà, depuis les
    /// Réglages, et il n'y a pas de « suite » (finding Q3 n°18, HIG writing.md : « Match your tone
    /// to the context »). Le titre est alors porté par la barre de navigation de l'appelant.
    private let isFirstLaunch: Bool
    /// Hauteur visible de la zone de défilement, pour centrer le contenu sur un grand écran (iPad).
    @State private var viewportHeight: CGFloat = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Largeur de contenu plafonnée en `regular` (iPad/Mac) — même principe
    /// que `ChatView.contentMaxWidth`, pour éviter que les cartes et le
    /// bouton "Continuer" ne s'étirent bord à bord sur un grand écran.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    init(
        capabilityProvider: any DeviceCapabilityProviding = SystemDeviceCapabilityProvider(),
        currentSelection: AIEngineOption? = nil,
        onCancel: (() -> Void)? = nil,
        appleModel: AppleIntelligenceModelCoordinator = .shared,
        onConfirm: @escaping (AIEngineOption) -> Void
    ) {
        let recommendation = AIProviderSelector.recommend(for: capabilityProvider)
        self.recommendation = recommendation
        _selection = State(initialValue: currentSelection ?? recommendation.option)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.isFirstLaunch = currentSelection == nil
        self.appleModel = appleModel
        _appleModelChoice = State(initialValue: appleModel.effectivePreference)
    }

    /// Le sélecteur cloud privé / appareil n'existe que si le cloud est proposé.
    private var showsAppleModelChoice: Bool {
        selection == .appleIntelligence && appleModel.isPrivateCloudOffered
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if isFirstLaunch {
                    header
                }

                GlassEffectContainer(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        engineCard(
                            option: .appleIntelligence,
                            title: "Apple Intelligence",
                            subtitle: appleModel.isPrivateCloudOffered
                                ? AppleIntelligenceModelCopy.engineCardSubtitle
                                : "Gratuit, sur l'appareil. Nécessite un appareil compatible avec Apple Intelligence activé."
                        )
                        if showsAppleModelChoice {
                            AppleIntelligenceModelSegmentedChoice(selection: $appleModelChoice)
                        }
                        engineCard(
                            option: .mlxLocal,
                            title: "Modèle local (MLX)",
                            subtitle: "Gratuit, sur l'appareil. Un modèle adapté à la puissance de ton appareil te sera proposé au choix."
                        )
                        engineCard(
                            option: .cloudBYOK,
                            title: "Clé API personnelle",
                            subtitle: Self.cloudKeyCardSubtitle
                        )
                    }
                }

                Button(isFirstLaunch ? "Continuer" : "Utiliser ce moteur") {
                    if showsAppleModelChoice {
                        appleModel.preference = appleModelChoice
                    }
                    onConfirm(selection)
                }
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("engine.continue")

                if let onCancel {
                    Button("Annuler", action: onCancel)
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("engine.cancel")
                }
            }
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
            // Sur grand écran, le contenu est centré dans la hauteur visible : calé en haut, il
            // laissait ≈ 60 % de l'iPad vide et se lisait comme un écran d'iPhone posé là
            // (finding Q3 n°52). Sur iPhone la hauteur du contenu dépasse déjà la zone visible.
            .frame(maxWidth: .infinity, minHeight: horizontalSizeClass == .regular ? viewportHeight : nil)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .task {
            appleModel.refreshStatus()
        }
    }

    /// Texte de la carte « Clé API personnelle » (finding Q3 n°2). L'ancienne phrase, « ta clé reste
    /// uniquement sur cet appareil », était fausse dans le sens rassurant : la clé part à chaque
    /// requête chez le fournisseur, avec les questions, et rien ne le disait au moment du choix.
    /// Ce texte dit les deux : où vont les questions, et où reste la clé. Il n'y a aucun serveur de
    /// Triva entre les deux (À VALIDER PAR BEN).
    static let cloudKeyCardSubtitle =
        "Le plus puissant. Payant selon le fournisseur choisi. Tes questions lui sont envoyées "
        + "directement\u{00A0}; ta clé reste dans le Trousseau de cet appareil."

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image("TrivaLockup")
                .resizable()
                .scaledToFit()
                .frame(height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("Choisis ton moteur IA")
                    .screenTitleFont()
                Text("Tu pourras en changer à tout moment depuis les Réglages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
                CardTitleRow(title: title, badge: isRecommended ? "Recommandé" : nil) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                }
                Text(subtitle)
                    .font(.subheadline)
                    // Encre des légendes sur verre (DESIGN.md) : `.secondary` y mesure 2,88:1, et ce
                    // sous-titre porte la promesse de confidentialité (revue R3-4).
                    .foregroundStyle(MessageBubbleView.legendStyle)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isSelected ? .regular.tint(.accentColor.opacity(0.12)).interactive() : .regular.interactive(),
                in: .rect(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("engine.card.\(option.rawValue)")
    }
}

#Preview("Premier lancement") {
    AIEngineSelectionView { _ in }
}

#Preview("Changement de moteur") {
    AIEngineSelectionView(currentSelection: .cloudBYOK, onCancel: {}) { _ in }
}

#Preview("Cloud privé d'Apple proposé") {
    AIEngineSelectionView(
        currentSelection: .appleIntelligence,
        appleModel: AppleIntelligenceModelCoordinator(
            probe: FixedPrivateCloudProbe(status: .available),
            preferenceStore: AppleIntelligenceModelPreference(userDefaults: UserDefaults(suiteName: "preview.appleModel") ?? .standard)
        )
    ) { _ in }
}
