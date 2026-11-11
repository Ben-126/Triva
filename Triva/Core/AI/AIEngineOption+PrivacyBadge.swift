//
//  AIEngineOption+PrivacyBadge.swift
//  Triva
//

import Foundation

extension AIEngineOption {
    /// Icône, libellé et légende de confidentialité associés à ce moteur (voir DESIGN.md,
    /// section "Badge moteur IA"). Source unique de vérité : la mention "sur l'appareil" ne
    /// doit apparaître que pour les moteurs réellement locaux, jamais pour `.cloudBYOK`.
    ///
    /// Pour Apple Intelligence, c'est le badge du modèle SUR L'APPAREIL : celui de toute l'app tant
    /// que le cloud privé d'Apple n'est pas proposé. Un écran qui connaît le modèle réellement
    /// retenu passe par `privacyBadge(appleRoute:)`.
    var privacyBadge: (icon: String, text: String, caption: String) {
        switch self {
        case .appleIntelligence:
            ("lock.fill", "Apple Intelligence · Sur l'appareil", "Aucune IA cloud utilisée")
        case .mlxLocal:
            ("lock.fill", "Modèle local (MLX) · Sur l'appareil", "Aucune IA cloud utilisée")
        case .cloudBYOK:
            ("key.fill", "Clé API personnelle", "Envoyé directement à ton fournisseur — jamais à un serveur Triva")
        }
    }

    /// Badge du modèle que le prochain envoi utilisera (mission A4). `appleRoute` : la route de
    /// `AppleIntelligenceModelCoordinator.displayedRoute(isOffline:)`, ignorée pour les autres
    /// moteurs ; `nil` = le badge historique.
    ///
    /// - Cloud privé : jamais « Sur l'appareil », jamais « Aucune IA cloud » (ce serait faux : la
    ///   demande part chez Apple). La légende dit où elle part et ce qu'Apple garantit (prompts
    ///   jamais conservés, WWDC26 session 319).
    /// - Sur l'appareil après un quota atteint : la seule mention de repli visible (voulue par
    ///   Ben) ; les autres replis gardent la légende historique, vraie elle aussi.
    /// - Sur l'appareil sinon (choix de l'utilisateur, cloud non proposé) : exactement le badge
    ///   d'avant A4 (`privacyBadge`), mot pour mot — `TrivaUITests` le vérifie.
    func privacyBadge(appleRoute: AppleModelRoute?) -> (icon: String, text: String, caption: String) {
        guard self == .appleIntelligence, let appleRoute else { return privacyBadge }
        switch (appleRoute.kind, appleRoute.fallback) {
        case (.privateCloud, _):
            return ("lock.icloud.fill", "Apple · Cloud privé", "Envoyé au cloud privé d'Apple, rien n'y est conservé")
        case (.onDevice, .quotaReached):
            return (privacyBadge.icon, privacyBadge.text, "Limite du cloud privé atteinte : réponses sur l'appareil")
        case (.onDevice, _):
            return privacyBadge
        }
    }
}
