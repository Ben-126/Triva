//
//  SystemIntegrationPreferences.swift
//  Triva
//
//  Chantier 2.1 (mission A) : les trois réglages de la section « Intégrations » (l'écran vient de la mission F).
//  Dans les `UserDefaults` de l'app, jamais dans l'App Group : seul leur EFFET est publié aux extensions.
//  Valeurs par défaut décidées par Ben le 2026-11-24 : Spotlight allumé, activité en direct allumée, dernière
//  question dans le widget ÉTEINTE (le widget n'écrit alors aucune question dans l'App Group).
//

import Foundation

nonisolated struct SystemIntegrationPreferences {
    static let spotlightKey = "system.spotlight.enabled"
    static let widgetLastQuestionKey = "system.widget.showsLastQuestion"
    static let liveActivityKey = "system.liveActivity.enabled"

    static let spotlightDefault = true
    static let widgetLastQuestionDefault = false
    static let liveActivityDefault = true

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Historique (titres et dates) dans la recherche de l'appareil.
    var isSpotlightEnabled: Bool {
        get { value(for: Self.spotlightKey, default: Self.spotlightDefault) }
        nonmutating set { defaults.set(newValue, forKey: Self.spotlightKey) }
    }

    /// Dernière question visible dans le widget (et donc écrite dans l'App Group).
    var showsLastQuestionInWidget: Bool {
        get { value(for: Self.widgetLastQuestionKey, default: Self.widgetLastQuestionDefault) }
        nonmutating set { defaults.set(newValue, forKey: Self.widgetLastQuestionKey) }
    }

    /// Activité en direct (écran verrouillé, Dynamic Island) pendant une recherche. iPhone et iPad.
    var isLiveActivityEnabled: Bool {
        get { value(for: Self.liveActivityKey, default: Self.liveActivityDefault) }
        nonmutating set { defaults.set(newValue, forKey: Self.liveActivityKey) }
    }

    /// Une clé absente (ou d'un autre type) donne la valeur par défaut : jamais un « faux » par accident.
    private func value(for key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
