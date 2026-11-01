//
//  TrivaModelContainer.swift
//  Triva
//
//  Created by ben podrojsky on 24/09/2026.
//

import Foundation
import SwiftData

/// Erreurs de création du conteneur SwiftData.
///
/// L'erreur SwiftData sous-jacente n'est pas conservée telle quelle : elle
/// n'est ni `Sendable` ni `Equatable`, donc intestable et impossible à faire
/// traverser une frontière d'isolation. On garde sa description, ce qui suffit
/// au diagnostic. Aucune clé BYOK n'entre dans cette couche, mais on applique
/// le même principe de prudence que `ChatViewModel.userFacingMessage(for:)` :
/// ce texte technique n'est pas destiné à être affiché brut à l'utilisateur.
nonisolated enum TrivaModelContainerError: Error, Sendable, Equatable {
    /// Le conteneur n'a pas pu être créé : fichier illisible, schéma
    /// incompatible avec le store existant, disque plein…
    case creationFailed(String)

    /// Détail réservé aux logs et aux tests, jamais à l'UI.
    var diagnosticDescription: String {
        switch self {
        case .creationFailed(let reason):
            return "Création du conteneur SwiftData impossible : \(reason)"
        }
    }
}

/// Propriétaire unique du conteneur SwiftData de l'app (1.9).
///
/// ## Un seul conteneur, pour toute la base locale
/// Un `ModelContainer` doit être créé **une seule fois** par lancement : en
/// créer deux sur le même fichier SQLite revient à ouvrir deux stores
/// concurrents dont les objets ne se voient pas entre eux, et dont les
/// écritures se marchent dessus. D'où le `shared` paresseux ci-dessous.
///
/// Ce conteneur n'appartient pas à l'historique, il appartient à l'app :
/// l'agent des Favoris (1.10) l'étendra en ajoutant son modèle à `models`.
/// Surtout **ne pas créer un second `ModelContainer`**, sinon les favoris et
/// l'historique vivraient dans deux fichiers qui s'ignorent, et un favori ne
/// pourrait plus référencer la conversation qu'il marque.
///
/// ## Isolation
/// `@MainActor` explicite, pour deux raisons : (1) le seul contexte utilisé par
/// l'app est `container.mainContext`, que le SDK déclare `@MainActor` — rendre
/// la fabrique `nonisolated` inviterait à créer le conteneur depuis une tâche
/// d'arrière-plan puis à toucher `mainContext` depuis celle-ci ; (2)
/// `sharedResult` est un état global paresseux, et l'isoler au main actor est
/// la façon la plus simple de le rendre sûr en mode de langage Swift 6 sans
/// aucune échappatoire de type `nonisolated(unsafe)`.
///
/// À l'inverse, les modèles (`StoredConversation` & co.) sont `nonisolated` :
/// justification complète en tête de `ChatHistoryModels.swift`.
///
/// ## Stockage 100 % local, sans iCloud
/// `cloudKitDatabase: .none` est explicite et non un défaut subi : la
/// synchronisation iCloud privée n'est envisagée qu'en V2, et seulement en
/// opt-in (décision de Ben, plan 1.9). De même `groupContainer: .none` :
/// aucune extension ni widget système ne partage cette base aujourd'hui, et un
/// app group demanderait un entitlement supplémentaire pour rien.
@MainActor
enum TrivaModelContainer {
    /// Nom logique de la configuration, qui détermine le nom du fichier sur
    /// disque.
    ///
    /// Volontairement neutre, et non « ChatHistory » : le même fichier
    /// accueillera les favoris (1.10) et tout ce que la V1 ajoutera. **Figé à
    /// partir du premier build livré** : le changer ensuite ferait repartir
    /// l'utilisateur d'une base vide, sans message d'erreur ni moyen de
    /// récupérer l'ancien fichier depuis l'app.
    static let configurationName = "TrivaLocalStore"

    /// Modèles composant le schéma. **C'est ici qu'un nouveau `@Model`
    /// s'ajoute** — un modèle absent de cette liste existe en Swift mais
    /// n'existe pas en base, et toute insertion le concernant échoue.
    ///
    /// Propriété **calculée** et non stockée : un tableau statique de
    /// métatypes serait un état global de plus à justifier, alors qu'on veut
    /// juste une liste reconstruite au point d'appel (deux appels par
    /// lancement au maximum).
    static var models: [any PersistentModel.Type] {
        [
            StoredConversation.self,
            StoredMessage.self,
            StoredSource.self,
            // Favoris (1.10) : dans le MÊME schéma et donc le même fichier que
            // l'historique, sans aucune relation vers lui (copie autonome,
            // justifiée en tête de `FavoriteModels.swift`).
            StoredFavorite.self,
            StoredFavoriteSource.self,
        ]
    }

    /// Conteneur partagé par toute l'app, créé à la première utilisation.
    static var shared: ModelContainer { sharedResult.container }

    /// `true` quand `shared` a dû se rabattre sur un conteneur volatil : rien
    /// ne sera conservé après la fermeture de l'app.
    ///
    /// La Library doit le signaler à l'utilisateur plutôt que d'afficher une
    /// liste vide trompeuse — « ton historique est vide » et « ton historique
    /// est illisible » ne veulent pas dire la même chose.
    static var isUsingVolatileFallback: Bool { sharedResult.usedFallback }

    /// Si le store sur disque est inutilisable (fichier corrompu, schéma
    /// incompatible après une mise à jour), on ne laisse PAS l'app planter au
    /// lancement pour un historique : on bascule sur un conteneur en mémoire.
    /// L'app reste entièrement fonctionnelle, seule la persistance de
    /// l'historique est perdue pour cette session.
    private static let sharedResult: (container: ModelContainer, usedFallback: Bool) = {
        do {
            return (try makeOnDisk(), false)
        } catch {
            do {
                return (try makeInMemory(), true)
            } catch {
                // Un conteneur en mémoire ne dépend d'aucune donnée externe :
                // s'il échoue, c'est forcément le schéma qui est invalide,
                // donc un bug de développement, jamais une entrée
                // utilisateur — la règle « pas de `fatalError` sur une entrée
                // externe » n'est pas en cause ici. Échouer bruyamment est la
                // bonne réponse : masquer ça livrerait une app silencieusement
                // dépourvue de persistance.
                preconditionFailure(
                    "Schéma SwiftData invalide : même un conteneur en mémoire est impossible. \(error)"
                )
            }
        }
    }()

    /// Conteneur persistant sur disque, celui de l'utilisateur.
    static func makeOnDisk() throws -> ModelContainer {
        try make(isStoredInMemoryOnly: false)
    }

    /// Conteneur **en mémoire**, à utiliser par TOUS les tests.
    ///
    /// Chaque appel construit un `ModelContainer` neuf, donc son propre store,
    /// **même si le nom de configuration est identique** : deux conteneurs en
    /// mémoire créés sous `configurationName` ne se voient pas l'un l'autre
    /// (comportement vérifié à l'exécution, et re-vérifié par le premier test
    /// de `ChatHistoryStoreTests` parce que tous les autres en dépendent).
    /// Aucun test ne touche donc jamais le fichier réel de l'utilisateur, et
    /// aucun ne peut polluer un autre.
    static func makeInMemory() throws -> ModelContainer {
        try make(isStoredInMemoryOnly: true)
    }

    private static func make(isStoredInMemoryOnly: Bool) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            throw TrivaModelContainerError.creationFailed(String(describing: error))
        }
    }
}
