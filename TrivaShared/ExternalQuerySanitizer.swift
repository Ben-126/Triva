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

    /// Plafond en scalaires Unicode APRÈS nettoyage. La limite de `maxLength` compte des caractères visibles : un
    /// emoji suivi de dizaines de milliers de marques invisibles ou combinantes n'en fait qu'UN et passerait entier.
    static let maxScalarCount = 8_000

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
            } else if !isRemoved(scalar, after: cleaned.last) {
                cleaned.append(scalar)
            }
        }
        let exceedsScalarCap = cleaned.count > maxScalarCount
        let capped = exceedsScalarCap ? String(String.UnicodeScalarView(cleaned.prefix(maxScalarCount))) : String(cleaned)
        let trimmed = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else {
            return SanitizedExternalText(text: trimmed, wasTruncated: exceedsInputLimit || exceedsScalarCap)
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

    /// - Parameter previous: le dernier scalaire GARDÉ (ou `nil` au début) : un sélecteur de variante ou un joint
    ///   n'a de sens qu'après autre chose que lui-même ; répétés, ils ne portent que des octets invisibles.
    private static func isRemoved(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        if isIdeographicVariationSelector(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .control:
            return true
        case .format:
            // ZWJ / ZWNJ : nécessaires aux emoji composés et à certaines écritures (persan, indiennes), mais jamais
            // deux de suite.
            guard isJoiner(scalar) else { return true }
            return previous.map(isJoiner) ?? false
        default:
            // Un seul sélecteur de variante (U+FE00–FE0F : texte ou emoji) par caractère de base.
            return isVariationSelector(scalar) && (previous.map(isVariationSelector) ?? false)
        }
    }

    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 0x200D || scalar.value == 0x200C }

    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool { (0xFE00...0xFE0F).contains(scalar.value) }

    /// U+E0100–E01EF : sélecteurs de variante idéographiques, inutiles dans une question et invisibles.
    private static func isIdeographicVariationSelector(_ scalar: Unicode.Scalar) -> Bool { (0xE0100...0xE01EF).contains(scalar.value) }
}
