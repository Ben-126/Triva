//
//  EngineBadge.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

/// Badge moteur IA + légende de confidentialité (DESIGN.md, « Badge moteur IA ») : LE composant
/// unique, utilisé par la Recherche (`EngineStatusView`) et les Réglages (`SettingsView`).
///
/// Avant la mission C1, trois copies vivaient côte à côte (Recherche, Réglages, référence) et
/// ont divergé : à AX3, celle de la Recherche coupait « Apple Intelligence · Sur l'app… »
/// alors que celle des Réglages passait à la ligne (QA Q3, findings 1 et 16). Or la mention
/// coupée est justement celle que DESIGN.md rend obligatoire. `TrivaHomeReferenceView` garde sa
/// propre copie : c'est la référence qui fait foi, on ne la recâble pas.
///
/// Contenu : toujours `AIEngineOption.privacyBadge` / `privacyBadge(appleRoute:)` (source unique
/// de vérité : jamais « Sur l'appareil » pour `.cloudBYOK` ni pour le cloud privé d'Apple). Ce
/// composant ne calcule rien, il affiche.
///
/// - `.fixedSize(horizontal: false, vertical: true)` sur le badge ET la légende : sans lui, un
///   parent à court de hauteur (en-tête, clavier ouvert) compressait le texte en « … » au lieu
///   de le laisser passer à la ligne.
/// - Légende en `.secondary` (décision de Ben, 2026-11-11, finding 29) : en `.tertiary`, elle
///   mesurait 1,72:1 en clair, alors qu'elle porte la promesse de confidentialité. Les dates et
///   libellés de groupe restent en `.tertiary` ailleurs.
struct EngineBadge: View {
    let badge: (icon: String, text: String, caption: String)
    /// Masque la légende (en-tête replié de la Recherche) : le badge, lui, reste toujours visible.
    var showsCaption = true
    /// Identifiants XCUITest posés séparément sur le badge et la légende (`search.engineBadge`,
    /// `search.engineCaption`) : le parcours 01 lit le texte de la légende.
    var badgeIdentifier: String?
    var captionIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(badge.text, systemImage: badge.icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)
                .accessibilityIdentifier(badgeIdentifier ?? "")

            if showsCaption {
                Text(badge.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                    .accessibilityIdentifier(captionIdentifier ?? "")
            }
        }
    }
}

#Preview("Trois moteurs") {
    GlassEffectContainer(spacing: 12) {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([AIEngineOption.appleIntelligence, .mlxLocal, .cloudBYOK], id: \.self) { engine in
                EngineBadge(badge: engine.privacyBadge)
            }
        }
    }
    .padding(20)
}

#Preview("AX3") {
    GlassEffectContainer(spacing: 12) {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([AIEngineOption.appleIntelligence, .mlxLocal, .cloudBYOK], id: \.self) { engine in
                EngineBadge(badge: engine.privacyBadge)
            }
        }
    }
    .padding(20)
    .dynamicTypeSize(.accessibility3)
}
