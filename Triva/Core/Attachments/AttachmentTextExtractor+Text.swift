//
//  AttachmentTextExtractor+Text.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation

// Décodage, normalisation et troncature du texte d'une pièce jointe. Rangé à part de `AttachmentTextExtractor.swift`
// (rangement W4-R, code déplacé à l'identique) ; `AttachmentTextEncoding` suit ici : son `foundationEncoding` est
// `fileprivate`, utilisé seulement par `decodeText`.

/// Encodage effectivement retenu pour un fichier texte. Type dédié plutôt
/// que `String.Encoding` : il documente la chaîne de repli de
/// `AttachmentTextExtractor.decodeText(_:)` et reste trivialement `Sendable`.
nonisolated enum AttachmentTextEncoding: String, Sendable, Equatable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case utf32LittleEndian
    case utf32BigEndian
    case windowsCP1252
    case isoLatin1

    fileprivate var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .utf32LittleEndian: return .utf32LittleEndian
        case .utf32BigEndian: return .utf32BigEndian
        case .windowsCP1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        }
    }
}

nonisolated extension AttachmentTextExtractor {
    /// Octets de contrôle tolérés dans un vrai texte : tabulation, fins de
    /// ligne, tabulation verticale, saut de page, et ESC (séquences de
    /// couleur des journaux de terminal).
    private static let tolerableControlBytes: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1B]

    /// Ligatures typographiques latines (U+FB00 à U+FB06). Selon sa table
    /// ToUnicode, un PDF peut rendre « fi » sous la forme d'UN caractère
    /// ligaturé : « ﬁchier » ne correspondrait alors jamais à « fichier »
    /// pour le repli lexical de la recherche, ni pour le tokenizer. Correctif
    /// ciblé plutôt qu'une normalisation NFKC complète, qui réécrirait aussi
    /// « m² » en « m2 » ou « ½ » en « 1⁄2 ». Non mesuré sur un corpus de PDF
    /// réels : filet peu coûteux, appliqué au seul texte des PDF.
    private static let typographicLigatures: [(ligature: String, expansion: String)] = [
        ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"),
        ("\u{FB04}", "ffl"), ("\u{FB05}", "st"), ("\u{FB06}", "st"),
    ]

    /// Décodage d'un fichier texte. Chaîne STRICTE, chaque étape vérifiée
    /// sur macOS 27 :
    /// 1. Marque d'ordre des octets (BOM) UTF-32, UTF-8 ou UTF-16 : elle fait
    ///    foi. Testée AVANT la détection de binaire, puisque l'UTF-16 contient
    ///    des octets nuls pour chaque caractère ASCII.
    /// 2. Binaire déguisé : refus (voir `looksBinary`).
    /// 3. UTF-8 strict (`String(validating:as:)` rejette toute séquence
    ///    invalide) — l'encodage de l'écrasante majorité des fichiers actuels.
    /// 4. Windows-1252 : l'encodage « ANSI » historique de Windows (Bloc-notes,
    ///    exports CSV d'Excel), de loin le plus courant pour du texte français
    ///    ancien. Un texte Windows-1252 accentué n'est quasiment jamais de
    ///    l'UTF-8 valide (« é » y vaut l'octet 0xE9, qui annonce une séquence
    ///    UTF-8 de trois octets que la suite ne complète pas), donc l'étape 3
    ///    ne l'avale pas par erreur.
    /// 5. ISO Latin-1 : Windows-1252 ÉCHOUE sur chacun de ses cinq octets non
    ///    définis (0x81, 0x8D, 0x8F, 0x90, 0x9D — vérifié octet par octet),
    ///    alors que Latin-1 accepte tout octet.
    ///
    /// PAS d'étape « UTF-8 avec caractères de remplacement » avant
    /// Windows-1252, et c'est délibéré : tout seuil de tolérance laisserait
    /// passer un texte Windows-1252 dont seuls quelques pour cent des octets
    /// sont accentués, et remplacerait chaque accent par « � ». Pas non plus
    /// de réparation d'une séquence UTF-8 incomplète en fin de fichier, à la
    /// manière de `ScrapeService` : là-bas, la troncature par octets vient du
    /// code lui-même, qui SAIT qu'il a coupé ; ici le fichier est lu en
    /// entier, et retirer ses derniers octets ferait perdre le « é » final
    /// d'un fichier Windows-1252 dont c'est le seul accent. Un fichier
    /// réellement corrompu donne au pire du texte mal accentué, jamais un
    /// plantage.
    static func decodeText(_ data: Data) throws -> (text: String, encoding: AttachmentTextEncoding) {
        if let mark = byteOrderMark(of: data) {
            guard let text = String(data: data.dropFirst(mark.length), encoding: mark.encoding.foundationEncoding) else {
                throw AttachmentExtractionError.undecodableText
            }
            return (text, mark.encoding)
        }

        guard !looksBinary(data) else { throw AttachmentExtractionError.binaryContent }

        if let text = String(validating: data, as: UTF8.self) {
            return (text, .utf8)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return (text, .windowsCP1252)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, .isoLatin1)
        }
        throw AttachmentExtractionError.undecodableText
    }

    /// UTF-32 testé avant UTF-16 : la marque UTF-32 petit-boutiste
    /// (FF FE 00 00) commence par la marque UTF-16 petit-boutiste (FF FE).
    private static func byteOrderMark(of data: Data) -> (length: Int, encoding: AttachmentTextEncoding)? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (4, .utf32LittleEndian) }
        if head.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (4, .utf32BigEndian) }
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return (3, .utf8) }
        if head.starts(with: [0xFF, 0xFE]) { return (2, .utf16LittleEndian) }
        if head.starts(with: [0xFE, 0xFF]) { return (2, .utf16BigEndian) }
        return nil
    }

    /// Binaire si l'échantillon contient un octet nul, ou plus de 10 %
    /// d'octets de contrôle hors tabulations et fins de ligne. Le second
    /// critère attrape les rares binaires sans octet nul ; 10 % laisse une
    /// large marge à un journal de terminal truffé de séquences de couleur.
    /// Limite assumée : un fichier UTF-16 SANS marque d'ordre des octets est
    /// pris pour du binaire (ses caractères ASCII contiennent un octet nul).
    /// Cas rare : le Bloc-notes de Windows écrit toujours la marque.
    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(binarySniffingByteCount)
        guard !sample.isEmpty else { return false }

        var controlByteCount = 0
        for byte in sample {
            if byte == 0x00 { return true }
            if byte == 0x7F || (byte < 0x20 && !tolerableControlBytes.contains(byte)) {
                controlByteCount += 1
            }
        }
        return controlByteCount * 10 > sample.count
    }

    // MARK: - Normalisation et troncature

    /// Fins de ligne unifiées en `\n` : `\r\n` (Windows) et `\r` seul (ancien
    /// Mac OS) deviennent `\n`, ce qui laisse au découpage une seule
    /// convention de paragraphe. Retire aussi une marque d'ordre des octets
    /// résiduelle (U+FEFF) et les blancs de bord.
    static func normalizedText(_ text: String) -> String {
        let withoutMark = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return withoutMark
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalisation du texte d'une page PDF : celle du texte brut, plus le
    /// développement des ligatures typographiques (voir
    /// `typographicLigatures`). Pas de recollage des mots coupés en fin de
    /// ligne (« infor-\nmation ») : impossible de distinguer une césure d'un
    /// vrai trait d'union (« porte-\nmonnaie ») sans dictionnaire.
    static func normalizedPDFText(_ text: String) -> String {
        let expanded = typographicLigatures.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.ligature, with: pair.expansion)
        }
        return normalizedText(expanded)
    }

    /// Garde au plus `maxCharacterCount` caractères, en reculant jusqu'au
    /// dernier blanc pour ne jamais couper un mot — sauf si la partie gardée
    /// n'en contient aucun (un unique « mot » géant), auquel cas la coupe est
    /// franche, mais toujours sur une frontière de caractère.
    ///
    /// LEÇON DE `ScrapeService` : le projet a déjà corrompu du texte en
    /// tronquant des OCTETS avant décodage (une séquence UTF-8 coupée en deux,
    /// relue en Latin-1, donnait du charabia). Ici, la troncature n'opère
    /// JAMAIS sur des octets : elle s'applique après décodage, sur des
    /// `Character` Swift, qui sont des graphèmes complets. Un « é » décomposé
    /// (e + accent combinant), un drapeau ou un emoji famille ne peuvent donc
    /// pas être coupés en deux, par construction.
    ///
    /// Compte en O(limite), pas en O(longueur) : `index(_:offsetBy:limitedBy:)`
    /// s'arrête à la borne, même sur un fichier de 10 millions de caractères.
    static func truncatedAtWordBoundary(_ text: String, maxCharacterCount: Int) -> (text: String, wasTruncated: Bool) {
        guard let cut = text.index(text.startIndex, offsetBy: max(0, maxCharacterCount), limitedBy: text.endIndex),
              cut < text.endIndex else {
            return (text, false)
        }

        let head = text[..<cut]
        // Le premier caractère écarté est un blanc : la tête finit déjà sur
        // une frontière de mot, reculer ferait perdre un mot entier pour rien.
        let endsOnWordBoundary = text[cut].isWhitespace
        let keptEnd = endsOnWordBoundary ? cut : head.lastIndex(where: \.isWhitespace)
        guard let keptEnd else {
            return (String(head), true)
        }

        let wordAligned = text[..<keptEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return (wordAligned.isEmpty ? String(head) : wordAligned, true)
    }
}
