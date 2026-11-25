//
//  ExternalQuery.swift
//  Triva
//
//  Mission F3 : d'où vient une question reçue de l'extérieur, donc ce qu'on a le droit d'en faire.
//

import Foundation

/// Origine d'une question reçue de l'extérieur de la fenêtre. Le type est DISTINCT du texte à dessein : ce qu'on
/// a le droit d'en faire en dépend, et un simple booléen « envoyer » se perdrait en route.
nonisolated enum ExternalQueryOrigin: Equatable, Sendable {
    /// Texte venu d'AILLEURS que du panneau de Triva (Service « Rechercher avec Triva », partage, dépôt d'un
    /// texte) : il va dans la barre de saisie et n'est JAMAIS envoyé. Il peut être privé, l'utilisateur doit
    /// pouvoir le relire avant qu'il quitte l'appareil.
    case draft
    /// Question que l'utilisateur vient de TAPER dans le panneau de la barre des menus de Triva : c'est son
    /// geste d'envoi, la fenêtre l'envoie directement (l'accord pour une IA cloud reste demandé avant).
    case typedInMenuBar
}

/// Une question reçue de l'extérieur, avec son origine.
nonisolated struct ExternalQuery: Equatable, Sendable {
    let text: String
    let origin: ExternalQueryOrigin
    /// La fin du texte d'origine a été coupée à `ExternalQuerySanitizer.maxLength` : la fenêtre le dit (K2).
    var wasTruncated = false
}
