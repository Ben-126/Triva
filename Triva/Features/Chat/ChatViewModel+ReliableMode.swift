//
//  ChatViewModel+ReliableMode.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import Foundation

// Mode Fiable côté fil de discussion (mission A1). Sorti de `ChatViewModel.swift`,
// qui frôlait 800 lignes ; le câblage (`perform`, `consume`) y reste, parce qu'il
// touche des membres privés.
extension ChatViewModel {
    /// Décision (c) : mode Fiable, recherche faite, rien de CITABLE (le filtre
    /// « domaines fiables » a tout retiré, rien trouvé, ou — depuis A1 — aucune
    /// page n'a pu être lue) ni widget. Critère partagé avec l'orchestrateur,
    /// défini une fois : `SearchArtifacts.lacksReliableSources`.
    static func lacksReliableSources(_ artifacts: SearchArtifacts) -> Bool {
        artifacts.lacksReliableSources
    }

    /// Porte d'affichage d'une réponse Fiable sans widget (mission A1, choix de
    /// la mission À VALIDER PAR BEN) : le texte du flux n'est montré qu'à partir
    /// du premier instantané qui cite une page LUE
    /// (`SearchArtifacts.citesReadSource(in:isStreaming:)`), puis la porte reste
    /// ouverte jusqu'à la fin. Hors de ce cas (`requiresCitedAnswer` faux), elle
    /// est ouverte dès le départ et ne change rien.
    ///
    /// Pourquoi retenir plutôt que montrer puis effacer : une réponse non
    /// sourcée qui s'affiche dix secondes avant de disparaître derrière « Aucune
    /// source fiable » serait pire que le refus lui-même — l'utilisateur l'aurait
    /// déjà lue. Coût : en Fiable, le texte apparaît à la première citation (la
    /// fin de la première phrase, d'ordinaire) plutôt qu'au premier mot.
    struct CitedAnswerGate {
        private let artifacts: SearchArtifacts
        private(set) var isOpen: Bool

        init(artifacts: SearchArtifacts) {
            self.artifacts = artifacts
            self.isOpen = !artifacts.requiresCitedAnswer
        }

        /// Vrai si `snapshot` (cumulatif) peut s'afficher. Ouvre la porte, pour
        /// de bon, dès qu'il cite une page lue : une citation ne se « retire »
        /// pas d'un instantané au suivant, et revalider chaque instantané
        /// coûterait une passe de texte à chaque morceau pour rien.
        mutating func admits(_ snapshot: String) -> Bool {
            if !isOpen, artifacts.citesReadSource(in: snapshot, isStreaming: true) {
                isOpen = true
            }
            return isOpen
        }

        /// Fin de flux ACCEPTÉE alors que la porte n'a jamais cédé : la
        /// segmentation d'un instantané (`isStreaming: true`) et celle du texte
        /// final peuvent différer sur une balise restée ouverte. Le texte final
        /// fait foi : l'appelant l'affiche, la porte s'ouvre.
        mutating func open() {
            isOpen = true
        }
    }
}
