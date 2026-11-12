//
//  StoredAnswerNotes.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Ce que la bulle sait dire d'une réponse sur ses sources, et qu'une conversation relue (ou un
/// favori) doit redire à l'identique (mission E1a, trous 1 et 2 de la vérification V) :
/// - `uncitableSourceNumbers` : sources affichées mais jamais lues, citées en texte simple et
///   marquées « non lue » (`SearchArtifacts.uncitableSourceNumbers`) ;
/// - `answeredWithoutSearch` : « Réponse sans recherche » ;
/// - `answeredOffline` : « Hors connexion, sans source », qui REMPLACE la mention précédente — la
///   persister seule ferait relire « Réponse sans recherche » sous une réponse hors connexion ;
/// - `answeredWithoutReadableSource` : « Réponse sans source lisible » (recherche faite, rien de lisible).
///
/// Valeur pure : le modèle SwiftData n'en garde que des scalaires à valeur par défaut (migration
/// légère des bases existantes, voir `StoredMessage`).
nonisolated struct StoredAnswerNotes: Sendable, Equatable {
    var uncitableSourceNumbers: Set<Int> = []
    var answeredWithoutSearch = false
    var answeredOffline = false
    var answeredWithoutReadableSource = false
}

/// Les numéros de sources sont stockés en `String` (« 2,3 ») et non en `[Int]` ou `Set<Int>` : un
/// scalaire à valeur par défaut est le seul cas dont la migration légère de SwiftData est certaine,
/// alors qu'un attribut collection ajouté à un store existant ne l'est pas. Lecture défensive :
/// un fichier écrit par une autre version ne fait jamais échouer l'ouverture d'une conversation.
nonisolated enum SourceNumberCodec {
    static func encode(_ numbers: Set<Int>) -> String {
        numbers.filter { $0 > 0 }.sorted().map(String.init).joined(separator: ",")
    }

    /// Ignore ce qui n'est pas un entier strictement positif (les numéros `[n]` sont en base 1).
    static func decode(_ raw: String) -> Set<Int> {
        Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 })
    }
}
