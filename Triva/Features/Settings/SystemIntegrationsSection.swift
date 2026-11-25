//
//  SystemIntegrationsSection.swift
//  Triva
//
//  Chantier 2.1 (mission F) : section « Intégrations » des Réglages : ce que Triva montre en dehors de l'app
//  (recherche de l'appareil, widget, activité en direct) et le lien vers Raccourcis.
//
//  Composants système (`Form`, `Toggle`) comme le reste de l'écran (DESIGN.md : pas de verre dans un `Form`).
//  Les trois réglages sont des `UserDefaults` de l'app ; `SystemIntegrations` les observe et agit tout de suite
//  (index Spotlight vidé, instantané du widget effacé). Valeurs par défaut décidées par Ben le 2026-11-24 :
//  Spotlight allumé, activité en direct allumée, dernière question dans le widget ÉTEINTE.
//
//  Tous les textes de cette section sont « à valider par Ben ».
//

import AppIntents
import SwiftUI

nonisolated enum SystemIntegrationsText {
    static let header = "Intégrations"

    static let spotlightTitle = "Historique dans la recherche de l'appareil"
    static let spotlightDetail =
        "Le titre et la date de tes conversations se retrouvent dans la recherche de l'appareil. Jamais le texte des réponses."

    static let widgetTitle = "Dernière question dans le widget"
    static let widgetDetail =
        "Le widget affiche le titre de ta dernière conversation. Éteint, rien de ta question n'est partagé avec lui."

    static let liveActivityTitle = "Activité en direct pendant une recherche"
    static let liveActivityDetail =
        "Montre ta question et l'avancement de la recherche sur l'écran verrouillé, dans la Dynamic Island et, selon tes appareils, sur une montre, un Mac ou un écran CarPlay associés. Elle peut donc se lire sans déverrouiller l'appareil."

    static let footer =
        "Éteindre la recherche de l'appareil ou la dernière question du widget retire tout de suite ce que Triva avait publié. « Tout effacer » vide aussi le widget et la recherche de l'appareil."
}

struct SystemIntegrationsSection: View {
    @AppStorage private var spotlight: Bool
    @AppStorage private var widgetLastQuestion: Bool
    @AppStorage private var liveActivity: Bool

    /// - Parameter defaults: les réglages de l'app (`.standard`) ; une suite jetable dans les aperçus.
    init(defaults: UserDefaults = .standard) {
        _spotlight = AppStorage(
            wrappedValue: SystemIntegrationPreferences.spotlightDefault,
            SystemIntegrationPreferences.spotlightKey,
            store: defaults
        )
        _widgetLastQuestion = AppStorage(
            wrappedValue: SystemIntegrationPreferences.widgetLastQuestionDefault,
            SystemIntegrationPreferences.widgetLastQuestionKey,
            store: defaults
        )
        _liveActivity = AppStorage(
            wrappedValue: SystemIntegrationPreferences.liveActivityDefault,
            SystemIntegrationPreferences.liveActivityKey,
            store: defaults
        )
    }

    var body: some View {
        Section {
            toggleRow(
                SystemIntegrationsText.spotlightTitle,
                detail: SystemIntegrationsText.spotlightDetail,
                isOn: $spotlight,
                id: "settings.integrations.spotlight"
            )
            toggleRow(
                SystemIntegrationsText.widgetTitle,
                detail: SystemIntegrationsText.widgetDetail,
                isOn: $widgetLastQuestion,
                id: "settings.integrations.widget"
            )
            #if os(iOS)
            // L'activité en direct n'existe pas sur Mac (ActivityKit).
            toggleRow(
                SystemIntegrationsText.liveActivityTitle,
                detail: SystemIntegrationsText.liveActivityDetail,
                isOn: $liveActivity,
                id: "settings.integrations.liveActivity"
            )
            #endif
            #if os(iOS)
            // `ShortcutsLink` n'existe pas sur Mac (SDK 27.2, vérifié dans `_AppIntents_SwiftUI`).
            ShortcutsLink()
                .accessibilityIdentifier("settings.integrations.shortcuts")
            #endif
        } header: {
            Text(SystemIntegrationsText.header)
        } footer: {
            Text(SystemIntegrationsText.footer)
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(id)
    }
}

#Preview("Intégrations") {
    Form {
        SystemIntegrationsSection(defaults: UserDefaults(suiteName: "TrivaPreviews") ?? .standard)
    }
    .formStyle(.grouped)
}
