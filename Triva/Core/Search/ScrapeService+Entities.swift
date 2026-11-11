//
//  ScrapeService+Entities.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Décodage des entités HTML de `ScrapeService`, déplacé ici (mission A5)
/// pour ramener `ScrapeService.swift` sous la limite de 800 lignes avant d'y
/// brancher le détecteur de pages anti-robot. Comportement inchangé.
nonisolated extension ScrapeService {
    /// Motif constant (`try!` assumé comme pour les autres regex du service :
    /// aucun motif ne vient de l'extérieur, les tests de décodage l'exercent).
    private static let entityRegex = try! NSRegularExpression(
        pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});"
    )

    /// UNE passe de gauche à droite, qui ne relit jamais le texte produit. BUG
    /// corrigé : les remplacements successifs (`&amp;` en premier) décodaient
    /// deux fois `&amp;lt;` (→ `<` au lieu de `&lt;`) et `&amp;#233;` ;
    /// décoder `&amp;` en dernier n'aurait réglé que le premier cas. Formes
    /// numériques : toutes, 128 à 159 lues en windows-1252 comme les
    /// navigateurs (`&#146;` = ’) ; point de code invalide (0, demi-codet,
    /// > U+10FFFF) et entité inconnue laissés tels quels.
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in entityRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += decodedEntity(nsText.substring(with: match.range(at: 1))) ?? nsText.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return result + nsText.substring(from: cursor)
    }

    private static func decodedEntity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return namedEntities[name] }
        let digits = name.dropFirst()
        let isHexadecimal = digits.first == "x" || digits.first == "X"
        guard let code = UInt32(isHexadecimal ? digits.dropFirst() : digits, radix: isHexadecimal ? 16 : 10), code != 0 else {
            return nil
        }
        if (0x80...0x9F).contains(code), let windows1252 = String(bytes: [UInt8(code)], encoding: .windowsCP1252) {
            return windows1252
        }
        return Unicode.Scalar(code).map { String(Character($0)) }
    }

    /// Bloc Latin-1 complet (U+00A0–U+00FF), entités « spéciales » de HTML 4
    /// (guillemets, tirets, œ, €…) et symboles courants ; le reste de HTML5 est
    /// rarissime. Fusion tolérante : un doublon futur ne peut pas planter.
    private static let namedEntities: [String: String] = {
        // Ordre des points de code, 16 par ligne : ligne n = U+00A0 + 16 n.
        let latin1Names = [
            "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
            "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
            "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
            "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
            "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml",
            "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
        ]
        let latin1 = latin1Names.enumerated().map { offset, name in
            (name, String(Character(Unicode.Scalar(UInt8(0xA0 + offset)))))
        }
        return Dictionary(latin1, uniquingKeysWith: { first, _ in first }).merging(otherNamedEntities) { latin1Value, _ in latin1Value }
    }()

    private static let otherNamedEntities: [String: String] = [
        "quot": "\"", "amp": "&", "lt": "<", "gt": ">", "apos": "'", "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
        "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}", "ndash": "\u{2013}", "mdash": "\u{2014}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "dagger": "†", "Dagger": "‡", "bull": "•", "hellip": "…", "permil": "‰", "prime": "\u{2032}", "Prime": "\u{2033}",
        "lsaquo": "‹", "rsaquo": "›", "oline": "‾", "frasl": "⁄", "euro": "€", "trade": "™", "larr": "←", "uarr": "↑", "rarr": "→",
        "darr": "↓", "harr": "↔", "lArr": "⇐", "rArr": "⇒", "hArr": "⇔", "minus": "\u{2212}", "le": "≤", "ge": "≥", "ne": "≠",
        "asymp": "≈", "infin": "∞", "sum": "∑", "prod": "∏", "radic": "√", "part": "∂", "int": "∫", "equiv": "≡", "sdot": "⋅",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω", "Delta": "Δ", "Sigma": "Σ", "Omega": "Ω",
    ]
}
