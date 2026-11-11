//
//  OfflineViews.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

/// Vues du mode hors connexion (tâche 1.16). Direction artistique : DESIGN.md. SF Symbols seulement,
/// couleurs sémantiques, espacements de la grille, verre pour les seuls boutons.

/// Ligne d'état de l'écran de recherche tant que l'appareil est hors connexion : dit ce qui change
/// (réponses sans recherche, ou envoi impossible) sans attendre que l'utilisateur envoie une question.
/// Texte en `.primary` : c'est l'information principale de la ligne, pas une légende (le rapport Q3,
/// finding 8, a mesuré `.secondary` à 2,88:1 sur verre).
struct OfflineStatusLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("search.offlineStatus")
    }
}

/// Bandeau d'un envoi bloqué hors connexion, en bas du fil, avec ses boutons :
/// - « Relancer ma question » : même question, normalement. Actif seulement quand le système annonce
///   une connexion (`ChatViewModel.canRelaunchAfterReconnect`) ; grisé avant, avec la raison dite en
///   clair plutôt qu'un bouton qui ne fait rien.
/// - « Répondre sans source » (mode Fiable seulement) : le modèle local répond en mode Rapide, avec
///   la mention « Hors connexion, sans source ». Choix explicite de l'utilisateur, jamais automatique.
struct OfflineNoticeView: View {
    let reason: OfflineBlockReason
    let canRelaunch: Bool
    let canAnswerWithoutSource: Bool
    /// `true` = réponse sans source en mode Rapide.
    let onRelaunch: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(reason.message, systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.primary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chat.offlineNotice")

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Relancer ma question", systemImage: "arrow.clockwise") {
                        onRelaunch(false)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canRelaunch)
                    .accessibilityIdentifier("chat.offlineRelaunch")

                    if reason.offersQuickModeAnswer {
                        Button("Répondre sans source", systemImage: ResponseMode.quick.systemImage) {
                            onRelaunch(true)
                        }
                        .buttonStyle(.glass)
                        .disabled(!canAnswerWithoutSource)
                        .accessibilityIdentifier("chat.offlineAnswerWithoutSource")
                    }
                }
                .font(.subheadline)
            }

            if !canRelaunch {
                Text("Le bouton s'active au retour de la connexion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Envoi bloqué — hors connexion") {
    OfflineNoticeView(reason: .reliableMode, canRelaunch: false, canAnswerWithoutSource: true, onRelaunch: { _ in })
        .padding(20)
}

#Preview("Envoi bloqué — connexion revenue, sombre") {
    OfflineNoticeView(reason: .cloudKey, canRelaunch: true, canAnswerWithoutSource: false, onRelaunch: { _ in })
        .padding(20)
        .preferredColorScheme(.dark)
}

#Preview("Ligne d'état — hors connexion") {
    OfflineStatusLine(text: OfflinePlan.answerWithoutSearch.statusText)
        .padding(20)
}
