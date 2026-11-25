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
    /// Par fenêtre : les conversations dans lesquelles une réponse continue d'écrire alors qu'elles sont
    /// affichées ailleurs (plusieurs réponses peuvent finir en même temps). Lues à la demande (pas de copie à tenir à jour).
    private var backgroundConversations: [UUID: @MainActor () -> Set<UUID>] = [:]
    /// Par fenêtre : comment la ramener au premier plan.
    private var focusActions: [UUID: @MainActor () -> Bool] = [:]
    /// Par fenêtre : comment lui faire AFFICHER une conversation qu'elle tient (Recherche, fil rouvert).
    private var revealActions: [UUID: @MainActor (UUID) -> Void] = [:]

    init() {}

    /// La fenêtre `window` affiche `conversation` (`nil` : une recherche neuve).
    func setDisplayed(_ conversation: UUID?, in window: UUID) {
        if let conversation {
            displayed[window] = conversation
        } else {
            displayed[window] = nil
        }
    }

    /// Dit au registre comment lire les conversations que les générations en arrière-plan de `window`
    /// continuent d'écrire (vide : aucune).
    func setBackgroundConversations(_ conversations: @escaping @MainActor () -> Set<UUID>, in window: UUID) {
        backgroundConversations[window] = conversations
    }

    /// Une seule conversation (`nil` : aucune) : même chose que `setBackgroundConversations`.
    func setBackgroundConversation(_ conversation: @escaping @MainActor () -> UUID?, in window: UUID) {
        setBackgroundConversations({ conversation().map { [$0] } ?? [] }, in: window)
    }

    /// Dit au registre comment ramener `window` au premier plan (fenêtre AppKit sur Mac, scène sur iPad). Posée
    /// par la coquille de la fenêtre ; sans elle, `focusHolder` ne peut rien faire pour cette fenêtre. L'action
    /// rend `false` quand elle n'a pas pu (fenêtre système pas encore connue) : l'appelant se replie alors.
    func setFocusAction(_ action: @escaping @MainActor () -> Bool, in window: UUID) {
        focusActions[window] = action
    }

    /// Dit au registre comment faire afficher une conversation par `window` (X2, R2-03) : ramener la fenêtre devant ne
    /// suffit pas quand elle est sur la Bibliothèque ou qu'elle écrit la conversation en arrière-plan en montrant
    /// un autre fil. Appelée par `focusHolder` une fois la fenêtre devant.
    func setRevealAction(_ action: @escaping @MainActor (UUID) -> Void, in window: UUID) {
        revealActions[window] = action
    }

    /// Ramène au premier plan la fenêtre qui tient `conversation` (affichée d'abord, puis écrite en arrière-plan),
    /// autre que `window` (`nil` : aucune exclue), et lui fait afficher cette conversation sur la Recherche.
    /// - Returns: `true` si une fenêtre a été ramenée ; `false` si personne ne la tient ou si la fenêtre qui la
    ///   tient ne sait pas se mettre devant (l'appelant se replie alors sur `openWindow`).
    @discardableResult
    func focusHolder(of conversation: UUID, excluding window: UUID?) -> Bool {
        let showing = displayed.filter { $0.key != window && $0.value == conversation }.keys
        let writing = backgroundConversations.filter { $0.key != window && $0.value().contains(conversation) }.keys
        for candidate in Array(showing) + Array(writing) {
            if let action = focusActions[candidate], action() {
                revealActions[candidate]?(conversation)
                return true
            }
        }
        return false
    }

    /// Fenêtre fermée ou reconstruite : elle ne tient plus rien.
    func remove(window: UUID) {
        displayed[window] = nil
        backgroundConversations[window] = nil
        focusActions[window] = nil
        revealActions[window] = nil
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
            || backgroundConversations.contains { $0.key != window && $0.value().contains(conversation) }
    }
}

/// Cible de restauration d'une fenêtre, et mémoire de ce que cette fenêtre a déjà tenu.
///
/// `TrivaRootView` en détient une (par fenêtre) ; seule la PREMIÈRE coquille qui apparaît reçoit la cible
/// (`take`). Une coquille reconstruite parce que le moteur IA a changé (`.id(selected)`) n'en reçoit plus :
/// la conversation repart à zéro, comme l'a décidé Ben (2026-10-04), au lieu de rouvrir l'ancienne.
///
/// ## Valeur restaurée qui arrive APRÈS le premier rendu (mission F3)
/// La valeur de scène (`WindowGroup(for:)`) n'est pas forcément celle de l'écran à la création de la vue : au
/// relancement, la valeur restaurée peut arriver après le premier rendu, quand la cible lue par `take` était
/// déjà consommée, et la fenêtre restait vide. La coquille observe donc la valeur de scène, et `lateTarget`
/// décide si un changement est une restauration tardive ou seulement l'écho de ce que la fenêtre a elle-même
/// publié. `held` retient chaque cible que la fenêtre a affichée (toutes coquilles confondues, moteur changé
/// compris) : ce qu'elle a déjà tenu n'est jamais « restauré » une seconde fois, sinon un écho en retard
/// rouvrirait une conversation que l'utilisateur vient de quitter.
@MainActor
final class WindowRestoration {
    private var pending: TrivaWindowTarget?
    private var held: Set<TrivaWindowTarget> = []

    init(initial: TrivaWindowTarget) {
        pending = initial
    }

    func take() -> TrivaWindowTarget? {
        if let pending { held.insert(pending) }
        defer { pending = nil }
        return pending
    }

    /// Comme `take()`, mais tient compte de la valeur de scène à la première apparition. Au relancement, la valeur
    /// restaurée peut être déjà remise quand la coquille apparaît, alors que la cible lue à la création de la vue
    /// (avant que SwiftUI la remette) était la recherche neuve par défaut : la conversation de la scène l'emporte
    /// sur cette cible périmée (constat du 25/11). Une cible lue qui est déjà une conversation reste prioritaire,
    /// une cible déjà consommée (coquille reconstruite) ne revient pas, et une valeur que la fenêtre a déjà tenue
    /// est un écho, pas une restauration.
    func take(sceneValue: TrivaWindowTarget) -> TrivaWindowTarget? {
        if case .newSearch? = pending, case .conversation = sceneValue, !held.contains(sceneValue) {
            pending = sceneValue
        }
        return take()
    }

    /// La fenêtre affiche (ou publie) cette cible : un écho de cette valeur n'est pas une restauration.
    func noteHeld(_ target: TrivaWindowTarget) {
        held.insert(target)
    }

    /// Cible à restaurer pour une valeur de scène arrivée après coup, `nil` si ce n'en est pas une.
    ///
    /// Seule une CONVERSATION jamais tenue par cette fenêtre est restaurée, et seulement dans une fenêtre encore
    /// vierge (`isPristine` : aucune conversation affichée) : une recherche neuve ne porte rien à restaurer, et on
    /// ne remplace jamais ce que l'utilisateur lit. Une valeur n'est rendue qu'une fois.
    func lateTarget(for value: TrivaWindowTarget, isPristine: Bool) -> TrivaWindowTarget? {
        guard isPristine, case .conversation = value, !held.contains(value) else { return nil }
        held.insert(value)
        return value
    }
}
