//
//  AIUseNotice.swift
//  Triva
//
//  Mission C3 (audit légal, constats 9 et 10 ; AI Act art. 50(1)).
//

import Foundation

/// Mémoire de l'écran « Triva répond avec une IA » : affiché UNE fois, avant la première question.
/// Un seul drapeau `UserDefaults`, lu par `@AppStorage` dans la racine et par les tests UI (qui le
/// posent par argument de lancement pour ne pas être bloqués par l'écran).
nonisolated enum AIUseNoticeStore {
    static let defaultsKey = "legal.aiNotice.acknowledged"

    static func isAcknowledged(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func acknowledge(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: defaultsKey)
    }
}

/// Textes de l'information IA (`textes/ecrans.md`, section B).
nonisolated enum AIUseNoticeText {
    // Validé par Ben le 2026-11-18 (texte légal) — tous les textes de cette énumération.
    static let title = "Triva répond avec une IA"
    static let what = "Triva cherche sur le web, puis une intelligence artificielle rédige la réponse à partir des sources trouvées."
    static let errors = "Une IA peut se tromper, mal comprendre une source ou inventer un détail. Vérifie les sources citées avant de t'y fier."
    static let advice = "Ce n'est pas un avis médical, juridique ou financier. Pour ces sujets, demande à un professionnel."
    /// Le badge n'est pas toujours en haut : quand la place manque, il passe dans la barre de saisie,
    /// réduit à son icône. Et « sur l'appareil » n'empêche pas la question de partir aux moteurs de recherche :
    /// le badge dit seulement si une IA en ligne est utilisée (V2 O4).
    static let engine = "Le badge du moteur indique toujours quel moteur d'IA répond et si ta question est envoyée à une IA en ligne."
    static let continueLabel = "J'ai compris"

    /// Avertissement permanent sous chaque réponse (B.2).
    static let footer = "Réponse générée par IA. Elle peut contenir des erreurs : vérifie les sources. Pas un avis médical, juridique ou financier."
    /// Version courte, quand la place manque (très grand texte).
    static let footerShort = "Générée par IA, peut se tromper. Vérifie les sources."
}
