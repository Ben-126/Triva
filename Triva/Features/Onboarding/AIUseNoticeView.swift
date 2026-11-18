//
//  AIUseNoticeView.swift
//  Triva
//
//  Mission C3 (audit légal, constats 9 et 10 ; AI Act art. 50(1)).
//

import SwiftUI

/// « Triva répond avec une IA » : première étape du premier lancement, avant le choix du moteur,
/// donc avant toute première question. Affiché UNE fois (`AIUseNoticeStore`) ; un bouton, aucune
/// case à cocher (c'est une information, pas un consentement).
///
/// Même gabarit que `SearchKeyOnboardingView` (titre d'écran, texte, bouton verre proéminent,
/// colonne limitée sur iPad et Mac, défilement aux grandes tailles de texte).
struct AIUseNoticeView: View {
    let onContinue: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    var body: some View {
        GeometryReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // À VALIDER (texte légal) — tous les textes de cet écran (`AIUseNoticeText`).
                Text(AIUseNoticeText.title)
                    .screenTitleFont()
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 12) {
                    Text(AIUseNoticeText.what)
                    Text(AIUseNoticeText.errors)
                    Text(AIUseNoticeText.advice)
                    Text(AIUseNoticeText.engine)
                        // `.subheadline` et non `.footnote` : sur Mac, `.footnote` (10 pt) est bien
                        // plus petit que le corps et, en gris secondaire, peu lisible.
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(AIUseNoticeText.continueLabel, action: onContinue)
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("onboarding.aiNotice.continue")
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            // Contenu centré verticalement quand il tient dans la fenêtre (grand écran, Mac) :
            // sans cela il restait collé en haut avec un grand vide dessous. Il défile toujours
            // quand il est plus haut que la fenêtre (très grand texte).
            .frame(minHeight: proxy.size.height, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        }
    }
}

#Preview("Triva répond avec une IA") {
    AIUseNoticeView {}
}

#Preview("AX3") {
    AIUseNoticeView {}
        .dynamicTypeSize(.accessibility3)
}
