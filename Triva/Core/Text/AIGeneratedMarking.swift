//
//  AIGeneratedMarking.swift
//  Triva
//
//  Marquage d'une réponse générée par IA quand elle quitte l'app (copie, partage, export).
//  Règlement (UE) 2024/1689, art. 50(2) : portée et forme exactes À FAIRE VALIDER PAR UN JURISTE
//  (audit AUDIT-LEGAL.md constat 10). Mission C4, M12.
//

import Foundation

nonisolated enum AIGeneratedMarking {
    /// Ligne finale ajoutée à tout texte de réponse copié ou partagé. Validé par Ben le 2026-11-18 (texte légal).
    static let footer = "— Réponse générée par IA avec Triva"

    /// Le texte suivi d'une ligne vide puis de la mention. Idempotent : un texte déjà marqué
    /// n'est pas marqué deux fois. Un texte vide reste vide (rien à marquer).
    static func marked(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard !trimmed.hasSuffix(footer) else { return trimmed }
        return trimmed + "\n\n" + footer
    }
}
