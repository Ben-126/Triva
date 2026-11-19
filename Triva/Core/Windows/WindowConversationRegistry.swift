//
//  WindowConversationRegistry.swift
//  Triva
//
//  Chantier 2.2 (M2) : quelle fenêtre affiche quelle conversation.
//

import Foundation

extension TrivaWindowTarget {
    /// Identifiant de la scène `WindowGroup` des recherches (Mac et iPad).
    static let sceneID = "recherche"
}

/// Qui affiche quoi, pour toutes les fenêtres de l'app (Mac, iPad).
///
/// Sert à une seule règle : une conversation n'est tenue que par UNE fenêtre.
/// Deux fenêtres sur la même conversation écriraient toutes deux dans
/// `ChatHistoryStore` (écritures croisées). Une conversation est « tenue » par la fenêtre qui
/// l'AFFICHE, et aussi par celle dont une réponse continue d'y écrire en arrière-plan (la fenêtre
/// a rouvert une autre conversation pendant la génération, `ChatViewModel+Background`).
///
/// La règle est vérifiée aux DEUX endroits où une fenêtre prend une conversation :
/// - Bibliothèque ou favori (`openConversationFromHistory`) : si une autre fenêtre la tient, la coquille
///   demande `openWindow(value: .conversation(id))`, qui ramène la fenêtre existante au premier plan ;
/// - restauration d'une fenêtre (`restoreWindowTarget`) : une fenêtre créée sur une conversation qu'une
///   autre tient déjà (valeur de scène pas encore publiée, panneau de la barre des menus, fenêtre
///   recréée) ne la charge PAS et devient une recherche neuve. Le registre est à jour avant la valeur de
///   scène, que SwiftUI ne publie qu'au tour suivant : c'est lui qui fait foi.
///
/// En mémoire seulement : aucune donnée n'est écrite, et rien ne survit à l'app.
/// Une instance d'app (`shared`) ; les tests en créent une jetable.
@MainActor
final class WindowConversationRegistry {
    static let shared = WindowConversationRegistry()

    private var displayed: [UUID: UUID] = [:]
    /// Par fenêtre : la conversation dans laquelle une réponse continue d'écrire alors qu'elle est
    /// affichée ailleurs. Lue à la demande (pas de copie à tenir à jour).
    private var backgroundConversations: [UUID: @MainActor () -> UUID?] = [:]

    init() {}

    /// La fenêtre `window` affiche `conversation` (`nil` : une recherche neuve).
    func setDisplayed(_ conversation: UUID?, in window: UUID) {
        if let conversation {
            displayed[window] = conversation
        } else {
            displayed[window] = nil
        }
    }

    /// Dit au registre comment lire la conversation qu'une génération en arrière-plan de `window`
    /// continue d'écrire (`nil` : aucune).
    func setBackgroundConversation(_ conversation: @escaping @MainActor () -> UUID?, in window: UUID) {
        backgroundConversations[window] = conversation
    }

    /// Fenêtre fermée ou reconstruite : elle ne tient plus rien.
    func remove(window: UUID) {
        displayed[window] = nil
        backgroundConversations[window] = nil
    }

    /// `conversation` est-elle AFFICHÉE par une AUTRE fenêtre que `window` ?
    func isDisplayed(_ conversation: UUID, excluding window: UUID) -> Bool {
        displayed.contains { $0.key != window && $0.value == conversation }
    }

    /// `conversation` est-elle tenue par une AUTRE fenêtre que `window` : affichée, ou encore écrite
    /// par une réponse en arrière-plan ? C'est cette question que posent les deux endroits où une
    /// fenêtre prend une conversation.
    func isHeld(_ conversation: UUID, excluding window: UUID) -> Bool {
        isDisplayed(conversation, excluding: window)
            || backgroundConversations.contains { $0.key != window && $0.value() == conversation }
    }
}

/// Cible de restauration d'une fenêtre, consommable UNE seule fois.
///
/// `TrivaRootView` en détient une (par fenêtre) ; seule la PREMIÈRE coquille
/// qui apparaît la reçoit. Une coquille reconstruite parce que le moteur IA a
/// changé (`.id(selected)`) n'en reçoit plus : la conversation repart à zéro,
/// comme l'a décidé Ben (2026-10-04), au lieu de rouvrir l'ancienne.
@MainActor
final class WindowRestoration {
    private var pending: TrivaWindowTarget?

    init(initial: TrivaWindowTarget) {
        pending = initial
    }

    func take() -> TrivaWindowTarget? {
        defer { pending = nil }
        return pending
    }
}
