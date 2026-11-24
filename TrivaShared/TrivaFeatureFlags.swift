//
//  TrivaFeatureFlags.swift
//  TrivaShared
//
//  Chantier 2.1 (mission A) : interrupteurs de fonctions codées mais pas encore branchées.
//

import Foundation

nonisolated enum TrivaFeatureFlags {
    /// Saisie vocale (chantier 2.7). Faux : la route `.newQuestion(.voice)` ouvre simplement le clavier.
    /// Passer à `true` seulement quand le micro est branché.
    static let voiceInput = false
}
