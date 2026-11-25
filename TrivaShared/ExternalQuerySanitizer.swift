//
//  ExternalQuerySanitizer.swift
//  Triva
//
//  Chantier 2.2 (M1) : assainissement du texte venu de l'extérieur (Services du Mac,
//  barre des menus, dépôt). C'est une entrée EXTERNE : on ne lui fait pas confiance.
//

import Foundation

/// Texte assaini, et si sa fin a été coupée (K2 : la troncature à `ExternalQuerySanitizer.maxLength` est annoncée à
/// l'utilisateur, plus silencieuse).
nonisolated struct SanitizedExternalText: Sendable, Equatable {
    let text: String
    let wasTruncated: Bool
}

nonisolated enum ExternalQuerySanitizer {
    /// Longueur maximale (en caractères visibles) d'une question venue de l'extérieur.
    static let maxLength = 2_000

    /// Borne du travail : au-delà, le reste d'une sélection gigantesque est ignoré
    /// avant tout nettoyage (aucune question utile n'en a besoin).
    private static let inputScalarLimit = 100_000

    /// Texte propre, ou `nil` s'il ne reste rien à chercher.
    /// - sauts de ligne (CRLF, CR, NEL, séparateurs de ligne/paragraphe Unicode) ramenés à `\n` ;
    /// - tabulation remplacée par une espace ;
    /// - autres caractères de contrôle retirés, ainsi que tout caractère de mise en forme INVISIBLE (catégorie
    ///   Unicode « Cf » : espace de largeur nulle U+200B, marques de sens U+200E/200F/061C, contrôles de sens
    ///   d'écriture U+202A–202E et U+2066–2069, BOM U+FEFF, et les « caractères Tag » U+E0000–E007F avec lesquels
    ///   une page web peut cacher des instructions au modèle). Seuls le joint et le non-joint de largeur nulle
    ///   (U+200D, U+200C) sont gardés : sans eux, les emoji composés et certaines écritures se cassent ;
    /// - espaces et retours rognés aux deux bouts ;
    /// - tronqué à `maxLength` caractères, sans couper un emoji ni laisser d'espace final (la fin d'un texte
    ///   plus long est ignorée ; `sanitizeReportingTruncation` le dit, pour que l'appelant en avertisse l'utilisateur).
    static func sanitize(_ text: String?) -> String? {
        sanitizeReportingTruncation(text)?.text
    }

    /// Comme `sanitize(_:)`, et dit si du texte a été COUPÉ : au-delà de `maxLength` caractères visibles, ou au-delà
    /// de la borne de travail (une sélection gigantesque). Des espaces de fin retirés ne sont pas une troncature.
    static func sanitizeReportingTruncation(_ text: String?) -> SanitizedExternalText? {
        guard let text else { return nil }
        let exceedsInputLimit = text.unicodeScalars.dropFirst(inputScalarLimit).first != nil
        var cleaned = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars.prefix(inputScalarLimit) {
            defer { previousWasCarriageReturn = (scalar == "\r") }
            if scalar == "\n" && previousWasCarriageReturn { continue }
            if let replacement = replacement(for: scalar) {
                cleaned.append(contentsOf: replacement.unicodeScalars)
            } else if !isRemoved(scalar) {
                cleaned.append(scalar)
            }
        }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else {
            return SanitizedExternalText(text: trimmed, wasTruncated: exceedsInputLimit)
        }
        let truncated = String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated.isEmpty ? nil : SanitizedExternalText(text: truncated, wasTruncated: true)
    }

    private static func replacement(for scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}": return "\n"
        case "\t": return " "
        default: return nil
        }
    }

    private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control:
            return true
        case .format:
            // ZWJ / ZWNJ : nécessaires aux emoji composés et à certaines écritures (persan, indiennes).
            return scalar.value != 0x200D && scalar.value != 0x200C
        default:
            return false
        }
    }
}
