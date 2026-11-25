//
//  AppGroupAccessPolicy.swift
//  Triva
//
//  Chantier 2.1 (mission F) : quand l'app a le droit de toucher le conteneur de l'App Group.
//
//  Sur Mac, un groupe hors préfixe d'équipe peut déclencher une invite d'accès dès qu'on résout son conteneur
//  (`containerURL`). Le widget n'écrit rien tant que « Dernière question dans le widget » n'a jamais été allumé
//  (défaut : éteint) : on ne touche donc pas le conteneur avant ce jour-là. Le drapeau est local (réglages de l'app).
//

import Foundation

nonisolated struct AppGroupAccessPolicy {
    static let widgetEverEnabledKey = "system.widget.everEnabled"
    let isMac: Bool
    private let defaults: UserDefaults

    init(isMac: Bool, defaults: UserDefaults) {
        self.isMac = isMac
        self.defaults = defaults
    }

    /// Le widget (instantané) : sur Mac, seulement une fois le réglage allumé un jour. Rien n'a pu y être écrit avant.
    var mayTouchWidgetContainer: Bool {
        !isMac || defaults.bool(forKey: Self.widgetEverEnabledKey)
    }

    /// La boîte de partage : l'extension de partage n'existe que sur iPhone et iPad, jamais d'accès sur Mac.
    var mayTouchShareInbox: Bool { !isMac }

    /// Le réglage « Dernière question dans le widget » vient d'être (ou est) allumé : le drapeau reste posé même
    /// s'il est éteint ensuite, pour qu'un instantané existant puisse toujours être retiré.
    func noteWidgetEnabled() {
        guard !defaults.bool(forKey: Self.widgetEverEnabledKey) else { return }
        defaults.set(true, forKey: Self.widgetEverEnabledKey)
    }
}
