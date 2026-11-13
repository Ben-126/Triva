//
//  ResponseMode.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation

/// Les 3 modes de réponse proposés à l'utilisateur (voir 1.13 du plan).
///
/// Portage de `ResponseMode` de la version web d'origine, qui compte un 4e cas
/// `debate` (arguments Pour/Contre) — **hors périmètre V1** (décision de Ben) :
/// seuls `quick`, `deep` et `reliable` existent ici. Le mode par défaut est
/// `quick` (décision de Ben, 2026-09-30), contrairement à la version web d'origine qui part sur
/// `deep` (voir `ResponseModeSettingsStore`).
///
/// `String`-backed pour un `Codable` stable dans le temps (le brut stocké en
/// `UserDefaults` reste lisible même si l'ordre des cas change), et pour
/// pouvoir servir de valeur de segmentation directe dans une UI SwiftUI
/// (`Picker(selection:)`, comparaison de tag, etc.).
enum ResponseMode: String, Sendable, Codable, CaseIterable, Equatable {
    case quick
    case deep
    case reliable

    /// Libellé court affiché dans le sélecteur UI (1.13, `ResponseModeSelector`).
    var title: String {
        switch self {
        case .quick:
            return "Rapide"
        case .deep:
            return "Approfondie"
        case .reliable:
            return "Fiable"
        }
    }

    /// Phrase d'explication d'une ligne, affichée en complément du libellé
    /// (infobulle ou légende sous le sélecteur) — reprend l'esprit des
    /// tooltips du sélecteur de la version web d'origine, adapté au français et au
    /// fonctionnement réel du pipeline Swift (pas de garantie de longueur de
    /// texte : la génération n'est pas déterministe, voir `PromptBuilder` 1.4).
    var explanation: String {
        switch self {
        case .quick:
            return "Réponse directe, sans détour, pour une question simple."
        case .deep:
            return "Recherche plus large et réponse structurée en plusieurs parties."
        case .reliable:
            return "Se limite aux sources les plus vérifiables disponibles."
        }
    }

    /// Symbole SF Symbols associé, vérifié existant dans le catalogue système
    /// (aucune invention de nom — voir DESIGN.md, zéro emoji dans l'UI).
    var systemImage: String {
        switch self {
        case .quick:
            return "bolt"
        case .deep:
            return "text.magnifyingglass"
        case .reliable:
            return "checkmark.seal"
        }
    }

    /// Nombre de sources visé pour construire le contexte envoyé au modèle
    /// (borne haute passée à `SearchOrchestrator.init(maxResultsUsedForContext:)`).
    ///
    /// - `quick` : 3 — le strict nécessaire pour appuyer une réponse courte,
    ///   important car Apple Intelligence dispose d'une fenêtre de contexte
    ///   d'environ 4k tokens et un modèle MLX 0.6B encore moins : un contexte
    ///   trop chargé n'est pas juste plus lent, c'est un échec dur (troncature
    ///   ou refus de génération), pas une simple dégradation de qualité.
    /// - `deep` : 5 — reprend la valeur par défaut historique de
    ///   `SearchOrchestrator` (`maxResultsUsedForContext: Int = 5`), déjà
    ///   calibrée pour ce budget de contexte ; `deep` ne doit rien changer au
    ///   comportement existant du pipeline, qui a été validé avec ces valeurs.
    /// - `reliable` : 5 — même volume que `deep` : le filtrage sur domaines
    ///   fiables réduit déjà le bruit en amont, inutile de sacrifier en plus
    ///   le nombre de sources pour compenser.
    var targetSourceCount: Int {
        switch self {
        case .quick:
            return 3
        case .deep:
            return 5
        case .reliable:
            return 5
        }
    }

    /// Nombre maximal d'itérations de recherche
    /// (`SearchOrchestrator.init(maxIterations:)`) : 1 itération = seulement
    /// le tour seedé par la classification (1.1), sans boucle planner ;
    /// au-delà, la boucle planner tourne `2...maxIterations` (voir
    /// `SearchOrchestrator.runResearch`).
    ///
    /// - `quick` : 1 — pas de boucle planner du tout. Une réponse "rapide"
    ///   qui repart chercher 2-3 tours de plus n'en est plus une ; le coût
    ///   d'itérations supplémentaires (latence + tokens) va à l'encontre du
    ///   mode.
    /// - `deep` : 3 — reprend la valeur par défaut de `SearchOrchestrator`
    ///   (`maxIterations: Int = 3`), pour la même raison que
    ///   `targetSourceCount` : `deep` ne doit rien changer au comportement
    ///   déjà validé du pipeline.
    /// - `reliable` : 2 — un seul tour planner de plus que le seed. Le
    ///   filtrage sur domaines fiables réduit le nombre de résultats
    ///   exploitables par itération ; il est donc utile de pouvoir relancer
    ///   une recherche complémentaire si le premier tour seedé ne suffit pas,
    ///   sans pour autant aller jusqu'à 3 itérations qui ferait de `reliable`
    ///   la variante la plus lente de toutes (contre-intuitif pour un mode
    ///   pensé pour la fiabilité, pas l'exhaustivité).
    var maxSearchIterations: Int {
        switch self {
        case .quick:
            return 1
        case .deep:
            return 3
        case .reliable:
            return 2
        }
    }

    /// Indique si le pipeline doit restreindre les résultats de recherche aux
    /// domaines jugés fiables (liste et logique de filtrage propriétés de la
    /// tâche 1.3 — `ResponseMode` expose seulement l'intention, pas
    /// l'implémentation du filtre, pour rester une simple description de
    /// paramétrage sans dépendre de 1.3).
    ///
    /// Seul `reliable` l'active : c'est la raison d'être de ce mode (la version web d'origine
    /// vise `.gov`, `.edu`, Wikipédia…).
    var restrictsToTrustedDomains: Bool {
        self == .reliable
    }
}

/// Stocke le mode de réponse choisi par l'utilisateur, pour un accès depuis
/// le sélecteur de chat (1.13) et les Réglages (1.15).
///
/// Même style que `AIEngineSettingsStore`
/// (`Triva/Core/AI/AIProviderSelector.swift`), à une différence près : le mode
/// de réponse a une valeur par défaut non optionnelle (`.quick`, décision de
/// Ben du 2026-09-30) plutôt qu'un choix "non fait" — il n'y a pas d'écran d'onboarding
/// dédié au mode de réponse, il doit donc toujours y en avoir un de défini.
@Observable
final class ResponseModeSettingsStore {
    private static let storageKey = "chat.responseMode.selected"

    /// Valeur de repli si aucun mode n'est stocké, ou si la valeur stockée est
    /// invalide (ancien format, corruption, ou cas `debate` retiré de la version web d'origine —
    /// voir le commentaire de `ResponseMode`). Ce repli est silencieux mais
    /// documenté : il n'y a rien d'autre à faire ici, `UserDefaults` ne peut
    /// pas signaler une erreur de lecture à l'appelant.
    static let defaultMode: ResponseMode = .quick

    private let userDefaults: UserDefaults

    var selectedMode: ResponseMode {
        didSet {
            userDefaults.set(selectedMode.rawValue, forKey: Self.storageKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let rawValue = userDefaults.string(forKey: Self.storageKey),
           let storedMode = ResponseMode(rawValue: rawValue) {
            selectedMode = storedMode
        } else {
            selectedMode = Self.defaultMode
        }
    }
}
