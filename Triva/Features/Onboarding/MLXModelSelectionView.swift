//
//  MLXModelSelectionView.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

/// Écran de choix d'un modèle MLX (0.5) : 3 cartes (recommandé / plus
/// performant-plus lent / plus rapide-moins performant) calculées à partir de
/// la capacité/vitesse détectée de l'appareil, + liste complète dépliable.
/// Le modèle choisi passe toujours par un téléchargement annulable avec
/// progression, puis un mode essai (1-2 questions) avant validation.
struct MLXModelSelectionView: View {
    private let catalog: [MLXModelCatalogEntry]
    private let recommendation: MLXModelRecommendation?
    @State private var coordinator: MLXModelSelectionCoordinator
    @State private var showingFullCatalog = false
    /// Dernier palier de progression (0/25/50/75/100) déjà annoncé à
    /// VoiceOver pour le téléchargement en cours — évite de reposter une
    /// annonce à chaque tick de `fractionCompleted` (potentiellement des
    /// dizaines par seconde), voir `handlePhaseChange`.
    @State private var lastAnnouncedProgressMilestone = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    /// Largeur de contenu plafonnée en `regular` (iPad/Mac) — même principe
    /// que `AIEngineSelectionView.contentMaxWidth` / `ChatView.contentMaxWidth`,
    /// pour que cet écran garde la même largeur que celui qui le précède dans
    /// l'onboarding et n'étire pas ses cartes bord à bord sur un grand écran.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    init(
        capabilityProvider: any MLXDeviceCapabilityProviding = SystemMLXDeviceCapabilityProvider(),
        onValidated: @escaping (MLXModelCatalogEntry) -> Void
    ) {
        let loadedCatalog = (try? MLXModelCatalog.load()) ?? []
        catalog = loadedCatalog
        recommendation = MLXModelRecommender.recommend(from: loadedCatalog, for: capabilityProvider)
        _coordinator = State(initialValue: MLXModelSelectionCoordinator(onValidated: onValidated))
    }

    /// `NavigationStack` ET non une seconde feuille pour « Voir tous les modèles » : deux feuilles
    /// empilées se voyaient l'une derrière l'autre et, en fermant la seconde, on retombait sur la
    /// première sans repère (finding Q3 n°23, HIG sheets.md : « Display only one sheet at a time »).
    /// La liste complète est poussée dans la pile de cette feuille, avec son bouton retour.
    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Modèle local")
                .macSheetTitleBar("Modèle local")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Seule sortie visible de la feuille sur iPhone et iPad : jusqu'ici, seul le geste
                    // de glissement la fermait, sans que rien ne l'indique (finding Q3 n°22). Sur Mac,
                    // la barre du bas de `EngineStatusView` porte déjà « Fermer ».
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { dismiss() }
                            .accessibilityIdentifier("mlx.selection.close")
                    }
                }
                #endif
                .navigationDestination(isPresented: $showingFullCatalog) {
                    fullCatalogList
                }
        }
        .onChange(of: coordinator.phase) { oldValue, newValue in
            handlePhaseChange(from: oldValue, to: newValue)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                switch coordinator.phase {
                case .idle:
                    choosingContent
                case .downloading(let fractionCompleted):
                    downloadingContent(fractionCompleted: fractionCompleted)
                case .trial:
                    trialContent
                case .ready:
                    readyContent
                case .failed(let description, let isEnvironmentLimitation):
                    failedContent(description: description, isEnvironmentLimitation: isEnvironmentLimitation)
                }
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
    }

    /// Annonce à VoiceOver la progression du téléchargement (par paliers de
    /// ~25 %) et chaque changement de phase (téléchargement → essai →
    /// prêt/échec) — sans ceci, un utilisateur VoiceOver n'a aucun signal
    /// qu'un téléchargement potentiellement long progresse, se termine, ou
    /// échoue. Reprend le pattern déjà validé par `ChatView.announce(error:)`.
    private func handlePhaseChange(
        from oldValue: MLXModelSelectionCoordinator.Phase,
        to newValue: MLXModelSelectionCoordinator.Phase
    ) {
        switch newValue {
        case .idle:
            break
        case .downloading(let fractionCompleted):
            if case .downloading = oldValue {
                // Simple progression du même téléchargement : seuls les
                // paliers ci-dessous doivent déclencher une annonce.
            } else {
                lastAnnouncedProgressMilestone = 0
            }
            let percent = Int(fractionCompleted * 100)
            let milestones = [25, 50, 75, 100]
            if let milestone = milestones.last(where: { percent >= $0 }),
               milestone != lastAnnouncedProgressMilestone {
                lastAnnouncedProgressMilestone = milestone
                AccessibilityNotification.Announcement("Téléchargement : \(milestone) %").post()
            }
        case .trial:
            AccessibilityNotification.Announcement("Téléchargement terminé. Mode essai.").post()
        case .ready:
            AccessibilityNotification.Announcement("Modèle prêt.").post()
        case .failed(let description, _):
            AccessibilityNotification.Announcement(description).post()
        }
    }

    // MARK: - Choix initial

    @ViewBuilder
    private var choosingContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choisis ton modèle local")
                .screenTitleFont()
            Text("Basé sur la puissance de ton appareil. Tu pourras en changer à tout moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        if let recommendation {
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    if let fasterLessPerformant = recommendation.fasterLessPerformant {
                        modelCard(fasterLessPerformant, badge: "Plus rapide")
                    }
                    modelCard(recommendation.recommended, badge: "Recommandé")
                    if let morePerformantSlower = recommendation.morePerformantSlower {
                        modelCard(morePerformantSlower, badge: "Plus performant")
                    }
                }
            }
        } else {
            Text("Aucun modèle disponible pour le moment.")
                .foregroundStyle(.secondary)
        }

        Button("Voir tous les modèles") {
            showingFullCatalog = true
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func modelCard(_ entry: MLXModelCatalogEntry, badge: String) -> some View {
        Button {
            coordinator.select(entry)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CardTitleRow(title: entry.displayName, badge: badge) {
                    Text(Self.formattedSize(entry.downloadSizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Téléchargement

    @ViewBuilder
    private func downloadingContent(fractionCompleted: Double) -> some View {
        if let entry = coordinator.selectedEntry {
            VStack(alignment: .leading, spacing: 4) {
                Text("Téléchargement de \(entry.displayName)")
                    .screenTitleFont()
                Text("\(Self.formattedSize(entry.downloadSizeBytes)) • Wi-Fi requis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fractionCompleted)
                    .tint(.accentColor)
                Text("\(Int(fractionCompleted * 100)) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Annuler", role: .destructive) {
                coordinator.cancelDownload()
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - Mode essai

    @ViewBuilder
    private var trialContent: some View {
        if let entry = coordinator.selectedEntry {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mode essai — \(entry.displayName)")
                    .screenTitleFont()
                Text("Pose quelques questions de démo avant de valider ce modèle par défaut.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(coordinator.trialAnswers.enumerated()), id: \.offset) { index, answer in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MLXModelSelectionCoordinator.trialQuestions[index])
                                .font(.subheadline.weight(.semibold))
                            Text(answer)
                                .font(.body)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                }
            }

            if let nextQuestion = coordinator.nextTrialQuestion {
                Text(nextQuestion)
                    .font(.subheadline)
                Button {
                    Task { await coordinator.askNextTrialQuestion() }
                } label: {
                    if coordinator.isGeneratingTrialAnswer {
                        ProgressView()
                            .accessibilityLabel("Génération de la réponse en cours")
                    } else {
                        Text("Poser cette question")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(coordinator.isGeneratingTrialAnswer)
            }

            if coordinator.hasCompletedTrial {
                Button("Valider comme modèle par défaut") {
                    coordinator.validateAsDefault()
                }
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
            } else {
                // L'essai reste proposé mais jamais imposé (demande de Ben,
                // 2026-10-04) : le modèle est déjà téléchargé et fonctionnel.
                Button("Passer l'essai et valider") {
                    coordinator.validateAsDefault()
                }
                .buttonStyle(.glass)
                .disabled(coordinator.isGeneratingTrialAnswer)
            }

            Button("Choisir un autre modèle") {
                coordinator.chooseAnotherModel()
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - États finaux

    @ViewBuilder
    private var readyContent: some View {
        if let entry = coordinator.selectedEntry {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(entry.displayName) est prêt")
                    .screenTitleFont()
                Text("Ce modèle est maintenant ton choix par défaut.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func failedContent(description: String, isEnvironmentLimitation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // "Le téléchargement a échoué" serait factuellement faux pour une
            // limitation d'environnement (ex. Simulateur sans GPU Metal
            // complet) : rien n'a jamais été téléchargé dans ce cas.
            Text(isEnvironmentLimitation ? "Indisponible dans cet environnement" : "Le téléchargement a échoué")
                .screenTitleFont()
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button("Choisir un autre modèle") {
            coordinator.chooseAnotherModel()
        }
        .buttonStyle(.glassProminent)
    }

    // MARK: - Liste complète

    private var fullCatalogList: some View {
        List(catalog) { entry in
            Button {
                showingFullCatalog = false
                coordinator.select(entry)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 6) {
                        CardTitleRow(title: entry.displayName) {
                            Text(Self.formattedSize(entry.downloadSizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(entry.displayName), \(Self.formattedSize(entry.downloadSizeBytes)), \(entry.summary)"
                    )

                    if !entry.strengths.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entry.strengths, id: \.self) { strength in
                                HangingLabel(strength, systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Points forts : \(entry.strengths.joined(separator: ", "))")
                    }

                    if !entry.tradeoffs.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entry.tradeoffs, id: \.self) { tradeoff in
                                HangingLabel(tradeoff, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Compromis : \(entry.tradeoffs.joined(separator: ", "))")
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Tous les modèles")
        #if os(iOS)
        // Titre en ligne : le grand titre était tronqué à AX3 (« Tous les modè… », finding Q3 n°15).
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private static func formattedSize(_ bytes: UInt64) -> String {
        ByteCountText.string(forByteCount: bytes)
    }
}

#Preview {
    MLXModelSelectionView { _ in }
}
