//
//  AttachmentTextExtractor.swift
//  Triva
//
//  Created by ben podrojsky on 29/09/2026.
//

import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Lecture locale du texte d'une pièce jointe — port de
/// `UploadManager.extractContentAndEmbed` de la version web d'origine,
/// avec les frameworks Apple uniquement.
///
/// DIVERGENCE STRUCTURELLE : la version web d'origine reçoit le fichier par HTTP, en écrit une
/// copie sur le disque du serveur (`data/uploads/`), puis un second fichier
/// `.content.json` avec les fragments et leurs vecteurs. Triva n'a pas de
/// serveur et ne recopie RIEN : le fichier de l'utilisateur est lu sur place,
/// le temps de l'extraction, puis relâché (voir `AttachmentStore` pour la
/// justification complète). L'extracteur ne fait qu'une chose — produire du
/// texte — et laisse le découpage à `AttachmentChunker`, là où la version web d'origine mêle
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

    /// 50 Mo : une photo de 48 millions de pixels en HEIC en pèse ~10, une capture Retina en PNG ~15. Au-delà, ce
    /// n'est plus une capture mais un fichier à ne pas charger en mémoire pour y chercher du texte.
    static let defaultMaxImageByteCount = 50 * 1_024 * 1_024

    /// 100 millions de pixels (10 000 × 10 000) : au-delà de tout appareil photo courant (48 à 50 millions de pixels)
    /// et d'une capture d'écran, même panoramique. Décoder davantage coûterait plusieurs centaines de Mo de mémoire.
    static let defaultMaxImagePixelCount = 100_000_000

    let maxCharacterCount: Int
    let maxPDFPageCount: Int
    let maxTextFileByteCount: Int
    let maxImageByteCount: Int
    let maxImagePixelCount: Int
    /// Lecture du texte des images (Vision par défaut ; un faux dans les tests).
    let imageRecognizer: any ImageTextRecognizing
    /// Lecture des documents Word (plafonds réglables dans les tests).
    let docxReader: DocxTextReader

    /// Bornes ramenées à au moins 1 : une borne nulle ou négative est une
    /// erreur de configuration, pas une entrée utilisateur — on la neutralise
    /// plutôt que de planter ou de tout refuser.
    init(
        maxCharacterCount: Int = AttachmentTextExtractor.defaultMaxCharacterCount,
        maxPDFPageCount: Int = AttachmentTextExtractor.defaultMaxPDFPageCount,
        maxTextFileByteCount: Int = AttachmentTextExtractor.defaultMaxTextFileByteCount,
        maxImageByteCount: Int = AttachmentTextExtractor.defaultMaxImageByteCount,
        maxImagePixelCount: Int = AttachmentTextExtractor.defaultMaxImagePixelCount,
        imageRecognizer: any ImageTextRecognizing = VisionImageTextRecognizer(),
        docxReader: DocxTextReader = DocxTextReader()
    ) {
        self.maxCharacterCount = max(1, maxCharacterCount)
        self.maxPDFPageCount = max(1, maxPDFPageCount)
        self.maxTextFileByteCount = max(1, maxTextFileByteCount)
        self.maxImageByteCount = max(1, maxImageByteCount)
        self.maxImagePixelCount = max(1, maxImagePixelCount)
        self.imageRecognizer = imageRecognizer
        self.docxReader = docxReader
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

        if kind == .image {
            // Octets lus sous coordination (comme tout fichier), puis reconnaissance hors du main actor.
            let data = try Self.readCoordinated(url) { try imageData(at: $0) }
            return try await extractImage(data: data, fileName: fileName, characterLimit: limit)
        }
        return try Self.readCoordinated(url) { readableURL in
            try extractContents(of: readableURL, fileName: fileName, kind: kind, characterLimit: limit)
        }
    }

    /// Texte d'une image déjà en mémoire, reconnu EN LOCAL (Vision). Une seule section, sans page. Lève
    /// `noTextInImage` si rien de lisible, `invalidImage` si les octets ne sont pas une image.
    @concurrent
    func extractImage(data: Data, fileName: String, characterLimit: Int? = nil) async throws -> ExtractedAttachment {
        guard !data.isEmpty else { throw AttachmentExtractionError.emptyFile }
        guard data.count <= maxImageByteCount else {
            throw AttachmentExtractionError.imageTooLarge(byteCount: data.count, maximumByteCount: maxImageByteCount)
        }
        // Dimensions lues dans l'en-tête, sans décoder l'image : une petite image peut cacher des milliards de pixels.
        if let pixelCount = Self.pixelCount(ofImageData: data), pixelCount > maxImagePixelCount {
            throw AttachmentExtractionError.imageDimensionsTooLarge
        }
        let recognized = try await imageRecognizer.recognizeText(inImageData: data)
        let text = Self.normalizedText(recognized)
        guard !text.isEmpty else { throw AttachmentExtractionError.noTextInImage }

        let bounded = Self.truncatedAtWordBoundary(text, maxCharacterCount: effectiveCharacterLimit(characterLimit))
        return ExtractedAttachment(
            fileName: fileName,
            kind: .image,
            sections: [ExtractedTextSection(pageNumber: nil, text: bounded.text)],
            pageCount: nil,
            isTruncated: bounded.wasTruncated,
            isCopyRestricted: false,
            textEncoding: nil
        )
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
        case .docx:
            return try extractDocx(data: data, fileName: fileName, characterLimit: limit)
        case .plainText, .markdown, .csv, .json:
            return try extractText(data, fileName: fileName, kind: kind, characterLimit: limit)
        case .image:
            // La reconnaissance est asynchrone : voir `extractImage(data:fileName:characterLimit:)`.
            throw AttachmentExtractionError.unsupportedFileType(fileExtension: (fileName as NSString).pathExtension.lowercased())
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
    private static func readCoordinated<Output>(
        _ url: URL,
        _ body: (URL) throws -> Output
    ) throws -> Output {
        var coordinationError: NSError?
        var outcome: Result<Output, any Error>?

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
        case .docx:
            // Lu par morceaux, jamais chargé en mémoire ; le plafond de taille est celui de `docxReader`.
            return try extractDocx(fileAt: url, fileName: fileName, characterLimit: characterLimit)
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
        case .image:
            // Inatteignable : `extract(from:)` traite les images avant (la reconnaissance est asynchrone).
            throw AttachmentExtractionError.unsupportedFileType(fileExtension: url.pathExtension.lowercased())
        }
    }

    /// Largeur × hauteur d'après l'en-tête de l'image (ImageIO ne décode pas les pixels), ou `nil` si les octets ne
    /// sont pas une image reconnue : la reconnaissance rendra alors son propre verdict (`invalidImage`).
    static func pixelCount(ofImageData data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : product
    }

    /// Octets d'une image, après contrôle de la taille dans les métadonnées (jamais chargée si trop grosse).
    private func imageData(at url: URL) throws -> Data {
        let byteCount = try Self.fileSize(of: url)
        guard byteCount > 0 else { throw AttachmentExtractionError.emptyFile }
        guard byteCount <= maxImageByteCount else {
            throw AttachmentExtractionError.imageTooLarge(byteCount: byteCount, maximumByteCount: maxImageByteCount)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AttachmentExtractionError.fileUnreadable
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
    ///   son texte normalement. Décision FINALE de Ben (2026-11-17), voir
    ///   `PDFCopyPolicy` : lu seulement si `allowsContentAccessibility`, sinon
    ///   refusé (`copyProtectedPDF`), quel que soit le moteur.
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
        // Décision de Ben (2026-11-17) : un PDF qui interdit la copie n'est lu que s'il autorise
        // l'extraction pour l'accessibilité ; sinon son texte n'est extrait avec aucun moteur.
        guard PDFCopyPolicy.allowsReading(
            allowsCopying: document.allowsCopying,
            allowsContentAccessibility: document.allowsContentAccessibility
        ) else { throw AttachmentExtractionError.copyProtectedPDF }

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
}
