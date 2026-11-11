//
//  FeedText.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Met en texte brut le titre ou le résumé d'un flux. Logique pure, sans
/// `NSAttributedString(html:)` : celui-ci passe par WebKit et exige le fil principal, alors
/// que la lecture d'un flux se fait hors du main actor.
///
/// ## Ce qu'on fait, et seulement ça
/// Retirer le balisage, décoder les entités, fusionner les espaces. Rien d'autre : ESPN
/// (« vous ne pouvez pas modifier le contenu fourni, y compris titres, résumés et URL ») et
/// PMC (« vous ne pouvez pas modifier le texte, le contenu ni les liens fournis ») posent
/// une clause « ne pas modifier ». Mettre en forme pour l'affichage n'est pas réécrire :
/// aucun mot n'est ajouté, retiré ni tronqué ici (la coupe à deux lignes est l'affaire de
/// la vue).
///
/// Deux niveaux d'échappement coexistent dans les flux : `XMLParser` décode déjà le XML,
/// mais un résumé en CDATA garde ses entités HTML (`&#8217;` chez Deadline) et un résumé
/// échappé (`&lt;p&gt;`) devient du HTML une fois le XML décodé. D'où le passage ici.
nonisolated enum FeedText {
    /// Entités nommées rencontrées dans les flux réels. Les autres restent telles quelles
    /// (un `&inconnu;` visible vaut mieux qu'un caractère inventé).
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "ndash": "–", "mdash": "—", "laquo": "«", "raquo": "»", "eacute": "é",
        "egrave": "è", "agrave": "à", "ccedil": "ç", "euro": "€", "copy": "©",
    ]

    /// Balises qui séparent deux blocs de texte : remplacées par une espace, sinon
    /// `<p>Un</p><p>Deux</p>` donnerait « UnDeux ».
    private static let blockTags: Set<String> = [
        "p", "br", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "blockquote",
    ]
    /// Balises dont le contenu n'est pas du texte à lire.
    private static let invisibleTags: Set<String> = ["script", "style"]

    /// Texte brut, espaces fusionnées et bords rognés. Vide si rien n'est lisible.
    static func plain(_ raw: String) -> String {
        let withoutTags = strippingTags(raw)
        let decoded = decodingEntities(withoutTags)
        return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Comme `plain(_:)`, `nil` si le résultat est vide.
    static func plainOrNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = plain(raw)
        return text.isEmpty ? nil : text
    }

    // MARK: - Balises

    private static func strippingTags(_ raw: String) -> String {
        guard raw.contains("<") else { return raw }
        var output = ""
        var index = raw.startIndex
        var skippingUntilClose: String?
        while index < raw.endIndex {
            let character = raw[index]
            guard character == "<", let close = raw[index...].firstIndex(of: ">") else {
                if skippingUntilClose == nil { output.append(character) }
                index = raw.index(after: index)
                continue
            }
            let name = tagName(in: raw[raw.index(after: index)..<close])
            if let skipped = skippingUntilClose {
                if name == "/" + skipped { skippingUntilClose = nil }
            } else if invisibleTags.contains(name) {
                skippingUntilClose = name
            } else if blockTags.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
                output.append(" ")
            }
            index = raw.index(after: close)
        }
        return output
    }

    /// Nom de balise en minuscules, avec son « / » d'ouverture pour une balise fermante.
    private static func tagName(in inside: Substring) -> String {
        let trimmed = inside.drop { $0 == " " }
        let isClosing = trimmed.first == "/"
        let name = trimmed.drop { $0 == "/" }
            .prefix { $0.isLetter || $0.isNumber }
            .lowercased()
        return isClosing ? "/" + name : name
    }

    // MARK: - Entités

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
                  let decoded = decodedEntity(text[text.index(after: index)..<semicolon])
            else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            output.append(decoded)
            index = text.index(after: semicolon)
        }
        return output
    }

    private static func decodedEntity(_ body: Substring) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[String(body)]
    }
}
