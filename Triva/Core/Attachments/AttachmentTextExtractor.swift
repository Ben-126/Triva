//
//  AttachmentTextExtractor.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Nature d'une pièce jointe ACCEPTÉE. Tout ce qui n'a pas de cas ici est
/// refusé explicitement (`AttachmentExtractionError.unsupportedFileType`),
/// jamais « tenté pour voir ».
///
/// DIVERGENCE assumée avec le web (`src/lib/uploads/manager.ts`), qui accepte
/// PDF, DOCX et texte brut : ici DOCX est refusé. Côté serveur, Vane s'appuie
/// sur `officeparser` (npm) ; côté Apple, aucun framework natif ne lit un
/// `.docx` sur iOS (`NSAttributedString` ne sait l'ouvrir que sur macOS), et
/// la règle "zéro dépendance" interdit d'embarquer un parseur tiers. En
/// échange, Markdown, CSV et JSON sont acceptés : ce sont du texte, lu par le
/// même chemin que le `.txt`.
nonisolated enum AttachmentKind: String, Sendable, Equatable, CaseIterable {
    case pdf
    case plainText
    case markdown
    case csv
    case json

    /// Identifiant système du Markdown. Pas de constante `UTType.markdown`
    /// dans le SDK : on passe par l'identifiant, déclaré par le système
    /// (vérifié sur macOS 27 : `md` et `markdown` y sont rattachés).
    private static let markdownType = UTType("net.daringfireball.markdown")

    /// Filet de sécurité si l'identifiant Markdown n'était pas déclaré sur un
    /// OS : l'extension suffit alors à le reconnaître, au lieu de refuser un
    /// fichier texte parfaitement lisible.
    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Résolution par l'extension, via `UTType` plutôt qu'une liste
    /// d'extensions écrite à la main : le système connaît les variantes
    /// (`.text`, `.log`, `.swift`…) et la casse ne compte pas.
    ///
    /// L'ORDRE DES TESTS EST PORTEUR : Markdown, CSV et TSV sont tous
    /// conformes à `public.plain-text` (vérifié sur macOS 27, et dans les
    /// déclarations `MobileCoreTypes` du runtime iOS 27 : mêmes extensions,
    /// mêmes conformances), ils doivent donc être reconnus AVANT le cas
    /// générique. JSON, lui, n'est PAS
    /// conforme à `public.plain-text` (seulement à `public.text`) : sans son
    /// test dédié, il serait refusé. À l'inverse, RTF, HTML et XML ne sont
    /// conformes qu'à `public.text` et restent refusés — leur texte brut est
    /// du balisage, pas du contenu.
    ///
    /// Fichier sans extension : refusé. Le sélecteur de documents conserve
    /// l'extension d'origine, et deviner le type au contenu reviendrait à
    /// traiter comme texte n'importe quel binaire sans extension.
    init?(fileName: String) {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else {
            return nil
        }

        if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .json) {
            self = .json
        } else if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) {
            self = .csv
        } else if Self.markdownExtensions.contains(fileExtension) || Self.markdownType.map(type.conforms(to:)) == true {
            self = .markdown
        } else if type.conforms(to: .plainText) {
            self = .plainText
        } else {
            return nil
        }
    }
}

/// Échec de lecture d'une pièce jointe. Motifs FERMÉS, sans texte libre :
/// aucun cas ne transporte de contenu issu du fichier, donc rien de ce que
/// contient un document ne peut ressortir tel quel dans un message d'erreur
/// affiché (même principe que `SearchWidgetFailure`).
///
/// Le seul libre-texte, `fileExtension`, vient du NOM choisi par
/// l'utilisateur, pas du contenu ; il sert au diagnostic et aux tests, et
/// n'est volontairement pas repris dans `userFacingMessage`.
nonisolated enum AttachmentExtractionError: Error, Sendable, Equatable {
    /// Type hors liste (`AttachmentKind`) : DOCX, image, HTML, archive…
    case unsupportedFileType(fileExtension: String)
    /// Fichier introuvable, illisible, accès refusé par le bac à sable, ou
    /// coordination de fichier en échec (voir `extract(from:characterLimit:)`).
    case fileUnreadable
    /// Fichier texte au-delà de `maxTextFileByteCount`.
    case fileTooLarge(byteCount: Int, maximumByteCount: Int)
    /// Zéro octet, ou uniquement des blancs une fois décodé.
    case emptyFile
    /// Fichier « texte » qui contient en réalité du binaire (image renommée
    /// en `.txt`, par exemple).
    case binaryContent
    /// Aucun décodage n'a abouti. En pratique inatteignable sans marque
    /// d'ordre des octets (le repli Latin-1 accepte toute suite d'octets),
    /// mais une marque UTF-8/UTF-16/UTF-32 suivie d'octets invalides y mène.
    case undecodableText
    /// `PDFKit` refuse le document : fichier corrompu, tronqué, ou pas un PDF.
    case invalidPDF
    /// PDF chiffré avec mot de passe d'ouverture.
    case passwordProtectedPDF
    /// PDF lisible mais sans couche texte : document scanné, ou pages
    /// composées uniquement d'images.
    case noExtractableText(pageCount: Int)

    /// Message court en français, tutoiement, sans jargon, prêt pour l'UI.
    /// Aucune interpolation de donnée issue du fichier (seule la limite de
    /// taille, une constante de l'app, est affichée).
    var userFacingMessage: String {
        switch self {
        case .unsupportedFileType:
            return "Ce type de fichier n'est pas pris en charge. Joins un PDF ou un fichier texte (TXT, Markdown, CSV, JSON)."
        case .fileUnreadable:
            return "Impossible d'ouvrir ce fichier. Vérifie qu'il est disponible sur l'appareil, puis réessaie."
        case let .fileTooLarge(_, maximumByteCount):
            let megabytes = max(1, maximumByteCount / (1_024 * 1_024))
            return "Ce fichier est trop volumineux : \(megabytes) Mo maximum pour un fichier texte."
        case .emptyFile:
            return "Ce fichier est vide."
        case .binaryContent:
            return "Ce fichier ne contient pas de texte lisible."
        case .undecodableText:
            return "Impossible de décoder le texte de ce fichier."
        case .invalidPDF:
            return "Ce PDF est illisible ou endommagé."
        case .passwordProtectedPDF:
            return "Ce PDF est protégé par un mot de passe. Retire la protection, puis joins-le à nouveau."
        case .noExtractableText:
            return "Ce PDF ne contient aucun texte sélectionnable. C'est sans doute un document scanné."
        }
    }
}

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

/// Un morceau de texte extrait, avec sa page d'origine quand elle existe.
/// Unité de provenance transmise au découpage (`AttachmentChunker`), qui la
/// reporte sur chaque fragment.
nonisolated struct ExtractedTextSection: Sendable, Equatable {
    /// Numéro de page à partir de 1 (convention d'affichage « p. 3 »), `nil`
    /// pour un fichier texte, qui n'a pas de pagination.
    let pageNumber: Int?
    let text: String
}

/// Résultat d'une extraction réussie : jamais vide (au moins une section non
/// blanche, sinon l'extracteur lève une erreur).
nonisolated struct ExtractedAttachment: Sendable, Equatable {
    let fileName: String
    let kind: AttachmentKind
    /// Une section par page non vide pour un PDF, une seule pour un texte.
    let sections: [ExtractedTextSection]
    /// Nombre TOTAL de pages du PDF (pas seulement celles lues) ; `nil` hors PDF.
    let pageCount: Int?
    /// Vrai quand une borne (caractères ou pages) a interrompu la lecture :
    /// seul le DÉBUT du document est disponible. À signaler à l'utilisateur.
    let isTruncated: Bool
    /// PDF dont l'auteur interdit la copie du contenu. Lu malgré tout (voir
    /// `AttachmentTextExtractor.extractPDF`) : c'est un signal exposé pour
    /// que le produit décide, pas une décision prise ici. Toujours `false`
    /// hors PDF.
    let isCopyRestricted: Bool
    /// Encodage détecté pour un fichier texte ; `nil` pour un PDF.
    let textEncoding: AttachmentTextEncoding?

    var characterCount: Int {
        sections.reduce(0) { $0 + $1.text.count }
    }
}

/// Lecture locale du texte d'une pièce jointe — port de
/// `UploadManager.extractContentAndEmbed` (`src/lib/uploads/manager.ts`,
/// web), avec les frameworks Apple uniquement.
///
/// DIVERGENCE STRUCTURELLE : le web reçoit le fichier par HTTP, en écrit une
/// copie sur le disque du serveur (`data/uploads/`), puis un second fichier
/// `.content.json` avec les fragments et leurs vecteurs. Triva n'a pas de
/// serveur et ne recopie RIEN : le fichier de l'utilisateur est lu sur place,
/// le temps de l'extraction, puis relâché (voir `AttachmentStore` pour la
/// justification complète). L'extracteur ne fait qu'une chose — produire du
/// texte — et laisse le découpage à `AttachmentChunker`, là où le web mêle
/// extraction, découpage et vectorisation dans une même fonction.
///
/// `nonisolated` + `Sendable` : aucun état d'interface. Mais sous
/// `NonisolatedNonsendingByDefault` (activé par le réglage
/// `SWIFT_APPROACHABLE_CONCURRENCY` du projet), une fonction `nonisolated
/// async` s'exécute sur l'acteur de SON APPELANT : appelée depuis un store
/// `@MainActor`, elle tournerait sur le thread principal. D'où le
/// `@concurrent` explicite de `extract(from:characterLimit:)` — c'est lui,
/// pas `nonisolated`, qui garantit que l'analyse d'un PDF de 500 pages ne
/// gèle pas l'interface.
nonisolated struct AttachmentTextExtractor: Sendable {
    /// 12 500 caractères ≈ 5 pages de texte dense PAR FICHIER (mesuré sur
    /// macOS 27 : 2 457 caractères par page de cours générée) — limite choisie
    /// par Ben le 2026-10-04 (5 pages par fichier, 75 pages au total : voir
    /// `AttachmentStore.defaultTotalCharacterBudget`). Ce n'est PAS une limite
    /// de lecture mais de RECHERCHE : `TextSimilarityScoring` n'expose pas de
    /// vecteur réutilisable, chaque question ré-embarque donc tout le texte
    /// indexé, au coût mesuré par `NaturalLanguageSimilarityScorer` de
    /// ~0,043 ms par caractère (42,9 ms pour 1 000 caractères). Extrapolé de
    /// cette mesure (pas mesuré de bout en bout) : 80 000 caractères,
    /// recouvrement des fragments compris (≈ +19 %), coûtent ~4 s par requête
    /// sur Mac, sans doute davantage sur iPhone — au-delà, attendre la
    /// réponse d'un chat devient déraisonnable. Le dépassement n'est pas
    /// silencieux : `isTruncated`.
    static let defaultMaxCharacterCount = 12_500

    /// 500 pages. Mesuré sur macOS 27 : `PDFPage.string` coûte ~2,1 ms par
    /// page (500 pages de 2 457 caractères lues en 1,05 s). Pour un PDF texte,
    /// la borne de caractères s'arrête bien avant (≈ 5 pages) ; cette borne
    /// protège le cas qui, lui, ne s'arrête jamais tout seul : un scan de
    /// plusieurs milliers de pages sans aucun texte, qu'il faudrait
    /// parcourir entièrement avant de conclure qu'il n'y a rien à lire.
    static let defaultMaxPDFPageCount = 500

    /// 10 Mo ≈ 10 millions de caractères, cent fois la borne d'indexation :
    /// lire davantage ne servirait à rien, puisque tout serait tronqué. Borne
    /// appliquée AVANT de charger le fichier en mémoire. Pas d'équivalent
    /// pour le PDF : `PDFKit` le lit paresseusement page par page, et un gros
    /// PDF l'est presque toujours par ses images, jamais décodées ici.
    static let defaultMaxTextFileByteCount = 10 * 1_024 * 1_024

    /// Échantillon inspecté pour reconnaître un binaire déguisé : 8 000
    /// octets, la même heuristique que Git (`buffer_is_binary`). Un fichier
    /// texte n'a pas d'octet nul ; une image, un PDF ou une archive en ont
    /// dès leurs premiers octets.
    static let binarySniffingByteCount = 8_000

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

    let maxCharacterCount: Int
    let maxPDFPageCount: Int
    let maxTextFileByteCount: Int

    /// Bornes ramenées à au moins 1 : une borne nulle ou négative est une
    /// erreur de configuration, pas une entrée utilisateur — on la neutralise
    /// plutôt que de planter ou de tout refuser.
    init(
        maxCharacterCount: Int = AttachmentTextExtractor.defaultMaxCharacterCount,
        maxPDFPageCount: Int = AttachmentTextExtractor.defaultMaxPDFPageCount,
        maxTextFileByteCount: Int = AttachmentTextExtractor.defaultMaxTextFileByteCount
    ) {
        self.maxCharacterCount = max(1, maxCharacterCount)
        self.maxPDFPageCount = max(1, maxPDFPageCount)
        self.maxTextFileByteCount = max(1, maxTextFileByteCount)
    }

    // MARK: - Points d'entrée

    /// Lit un fichier choisi par l'utilisateur (sélecteur de documents,
    /// glisser-déposer). Lève `AttachmentExtractionError`, ou
    /// `CancellationError` si la tâche est annulée en cours de lecture —
    /// relayée telle quelle, jamais maquillée en « fichier illisible ».
    ///
    /// ACCÈS SECURITY-SCOPED — piège classique : une URL renvoyée par le
    /// sélecteur de documents (ou `.fileImporter`) pointe HORS du bac à
    /// sable de l'app ; la lire exige `startAccessingSecurityScopedResource()`
    /// avant, et `stopAccessingSecurityScopedResource()` après. Le simulateur
    /// n'applique pas le bac à sable avec la même rigueur : sans cet appel, la
    /// lecture y RÉUSSIT puis échoue sur iPhone réel — et sur Mac, puisque
    /// l'app est sandboxée (`ENABLE_USER_SELECTED_FILES = readonly`). Le
    /// `stop` n'est appelé que si le `start` a renvoyé `true` (appels
    /// appariés, exigence d'Apple), via `defer` pour couvrir toutes les
    /// sorties, erreurs comprises. Un `false` n'est pas une erreur en soi :
    /// c'est la réponse normale pour un fichier déjà dans le bac à sable
    /// (dossier temporaire, tests) ; si l'accès manque vraiment, c'est la
    /// lecture qui échoue, en `fileUnreadable`.
    ///
    /// COORDINATION DE FICHIER : la lecture passe par `NSFileCoordinator`,
    /// qui, d'après la documentation d'Apple, fait matérialiser un document
    /// iCloud Drive ou d'un fournisseur tiers pas encore téléchargé, et
    /// attend qu'une autre app ait fini d'écrire le fichier. Sans elle, on
    /// lirait un fichier fantôme ou à moitié écrit. Ni ce point ni l'accès
    /// security-scoped ne sont vérifiables sur simulateur : à valider sur
    /// appareil réel. L'appel est bloquant, ce qui est acceptable ici : on
    /// est sur l'exécuteur global (`@concurrent`), et l'attente éventuelle
    /// porte sur un téléchargement mené par le système, pas sur une tâche de
    /// notre pool coopératif.
    ///
    /// - Parameter characterLimit: borne plus basse que `maxCharacterCount`,
    ///   pour qu'un appelant partage un budget entre plusieurs pièces jointes
    ///   (voir `AttachmentStore`). Jamais plus haute : `maxCharacterCount`
    ///   reste un plafond.
    @concurrent
    func extract(from url: URL, characterLimit: Int? = nil) async throws -> ExtractedAttachment {
        let fileName = url.lastPathComponent
        // Type vérifié AVANT de toucher au fichier : un refus de type ne
        // doit coûter ni accès disque ni téléchargement iCloud.
        guard let kind = AttachmentKind(fileName: fileName) else {
            throw AttachmentExtractionError.unsupportedFileType(fileExtension: url.pathExtension.lowercased())
        }
        let limit = effectiveCharacterLimit(characterLimit)

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try Self.readCoordinated(url) { readableURL in
            try extractContents(of: readableURL, fileName: fileName, kind: kind, characterLimit: limit)
        }
    }

    /// Même extraction, depuis des octets déjà en mémoire (tests, données
    /// d'un glisser-déposer). SYNCHRONE : pour un gros PDF, l'appeler hors du
    /// main actor — `extract(from:characterLimit:)` le fait d'office.
    func extract(data: Data, fileName: String, characterLimit: Int? = nil) throws -> ExtractedAttachment {
        guard let kind = AttachmentKind(fileName: fileName) else {
            throw AttachmentExtractionError.unsupportedFileType(fileExtension: (fileName as NSString).pathExtension.lowercased())
        }
        let limit = effectiveCharacterLimit(characterLimit)
        guard !data.isEmpty else { throw AttachmentExtractionError.emptyFile }

        switch kind {
        case .pdf:
            guard let document = PDFDocument(data: data) else { throw AttachmentExtractionError.invalidPDF }
            return try extractPDF(document, fileName: fileName, characterLimit: limit)
        case .plainText, .markdown, .csv, .json:
            return try extractText(data, fileName: fileName, kind: kind, characterLimit: limit)
        }
    }

    // MARK: - Lecture du fichier

    private func effectiveCharacterLimit(_ requested: Int?) -> Int {
        max(1, min(requested ?? maxCharacterCount, maxCharacterCount))
    }

    /// Exécute `body` sous coordination de lecture. L'accesseur est appelé
    /// de façon synchrone, avant le retour de `coordinate` ; s'il ne l'a pas
    /// été, la coordination a échoué (l'erreur d'origine, système, n'apporte
    /// rien de plus à l'utilisateur que `fileUnreadable`).
    private static func readCoordinated(
        _ url: URL,
        _ body: (URL) throws -> ExtractedAttachment
    ) throws -> ExtractedAttachment {
        var coordinationError: NSError?
        var outcome: Result<ExtractedAttachment, any Error>?

        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            outcome = Result { try body(readableURL) }
        }

        guard let outcome else { throw AttachmentExtractionError.fileUnreadable }
        return try outcome.get()
    }

    private func extractContents(
        of url: URL,
        fileName: String,
        kind: AttachmentKind,
        characterLimit: Int
    ) throws -> ExtractedAttachment {
        let byteCount = try Self.fileSize(of: url)
        guard byteCount > 0 else { throw AttachmentExtractionError.emptyFile }

        switch kind {
        case .pdf:
            // `PDFDocument(url:)` plutôt que des octets chargés d'un bloc :
            // PDFKit lit paresseusement, un PDF de 80 Mo d'images n'est
            // jamais monté en mémoire en entier.
            guard let document = PDFDocument(url: url) else { throw AttachmentExtractionError.invalidPDF }
            return try extractPDF(document, fileName: fileName, characterLimit: characterLimit)
        case .plainText, .markdown, .csv, .json:
            guard byteCount <= maxTextFileByteCount else {
                throw AttachmentExtractionError.fileTooLarge(byteCount: byteCount, maximumByteCount: maxTextFileByteCount)
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw AttachmentExtractionError.fileUnreadable
            }
            return try extractText(data, fileName: fileName, kind: kind, characterLimit: characterLimit)
        }
    }

    /// Taille lue dans les métadonnées, sans ouvrir le fichier. `nil` (un
    /// dossier, un paquet) est traité comme illisible : ce n'est pas un
    /// document qu'on sait lire.
    private static func fileSize(of url: URL) throws -> Int {
        let size: Int?
        do {
            size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } catch {
            throw AttachmentExtractionError.fileUnreadable
        }
        guard let size else { throw AttachmentExtractionError.fileUnreadable }
        return size
    }

    // MARK: - PDF

    /// Texte page par page. `PDFDocument` n'est pas `Sendable` : il est créé
    /// par l'appelant, utilisé ici et relâché dans la même portée
    /// synchrone, sans traverser de frontière d'isolation.
    ///
    /// - Mot de passe d'ouverture (`isLocked`) : refus explicite. Proposer de
    ///   saisir le mot de passe serait une évolution, pas un correctif.
    /// - Restriction de copie (`allowsCopying == false`) : mesuré sur
    ///   macOS 27, un tel PDF n'est PAS verrouillé et `PDFPage.string` rend
    ///   son texte normalement. On le lit donc, et on expose
    ///   `isCopyRestricted`. Refuser ces documents — ou les réserver aux
    ///   moteurs sur l'appareil, pour que leur texte ne parte pas chez un
    ///   fournisseur cloud — est un ARBITRAGE PRODUIT réservé à Ben, pas un
    ///   choix technique à glisser ici.
    /// - Page sans texte : `PDFPage.string` renvoie `nil` (pas `""`), aussi
    ///   bien pour une page blanche que pour une page scannée (vérifié) ; les
    ///   deux sont simplement sautées. Si AUCUNE page lue n'a de texte, c'est
    ///   un scan : erreur dédiée plutôt qu'un document « vide » trompeur.
    ///   Limite : au-delà de `maxPDFPageCount`, les pages ne sont pas
    ///   examinées — un document de 600 pages scannées dont seules les
    ///   dernières porteraient du texte serait déclaré sans texte.
    /// - Annulation vérifiée à chaque page : un PDF de 500 pages ne doit pas
    ///   continuer à tourner une fois l'utilisateur passé à autre chose.
    private func extractPDF(_ document: PDFDocument, fileName: String, characterLimit: Int) throws -> ExtractedAttachment {
        guard !document.isLocked else { throw AttachmentExtractionError.passwordProtectedPDF }

        let pageCount = document.pageCount
        guard pageCount > 0 else { throw AttachmentExtractionError.invalidPDF }

        let pagesToRead = min(pageCount, maxPDFPageCount)
        var sections: [ExtractedTextSection] = []
        var remainingCharacters = characterLimit
        var reachedCharacterLimit = false

        for pageIndex in 0..<pagesToRead {
            try Task.checkCancellation()

            guard let rawText = document.page(at: pageIndex)?.string else { continue }
            let text = Self.normalizedPDFText(rawText)
            guard !text.isEmpty else { continue }

            let bounded = Self.truncatedAtWordBoundary(text, maxCharacterCount: remainingCharacters)
            sections.append(ExtractedTextSection(pageNumber: pageIndex + 1, text: bounded.text))
            if bounded.wasTruncated {
                reachedCharacterLimit = true
                break
            }
            remainingCharacters -= bounded.text.count
            if remainingCharacters <= 0 {
                // Budget épuisé pile en fin de page : les pages suivantes ne
                // sont pas lues, le document est donc bien tronqué s'il en reste.
                reachedCharacterLimit = pageIndex + 1 < pageCount
                break
            }
        }

        guard !sections.isEmpty else { throw AttachmentExtractionError.noExtractableText(pageCount: pageCount) }

        return ExtractedAttachment(
            fileName: fileName,
            kind: .pdf,
            sections: sections,
            pageCount: pageCount,
            isTruncated: reachedCharacterLimit || pagesToRead < pageCount,
            isCopyRestricted: !document.allowsCopying,
            textEncoding: nil
        )
    }

    // MARK: - Texte

    private func extractText(
        _ data: Data,
        fileName: String,
        kind: AttachmentKind,
        characterLimit: Int
    ) throws -> ExtractedAttachment {
        guard !data.isEmpty else { throw AttachmentExtractionError.emptyFile }
        guard data.count <= maxTextFileByteCount else {
            throw AttachmentExtractionError.fileTooLarge(byteCount: data.count, maximumByteCount: maxTextFileByteCount)
        }

        let decoded = try Self.decodeText(data)
        let text = Self.normalizedText(decoded.text)
        guard !text.isEmpty else { throw AttachmentExtractionError.emptyFile }

        // Troncature APRÈS décodage, en caractères : voir `truncatedAtWordBoundary`.
        let bounded = Self.truncatedAtWordBoundary(text, maxCharacterCount: characterLimit)
        return ExtractedAttachment(
            fileName: fileName,
            kind: kind,
            sections: [ExtractedTextSection(pageNumber: nil, text: bounded.text)],
            pageCount: nil,
            isTruncated: bounded.wasTruncated,
            isCopyRestricted: false,
            textEncoding: decoded.encoding
        )
    }

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
