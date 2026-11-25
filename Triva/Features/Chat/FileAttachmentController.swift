//
//  FileAttachmentController.swift
//  Triva
//
//  Découpé de FileAttachmentPicker.swift (K2, 25/11/2026) : déplacement pur, sans changement de code.
//

import Foundation
import Observation
import SwiftUI

/// Entrée de la file de lecture : l'URL n'est gardée que jusqu'à la lecture
/// (comme `AttachmentStore`, qui ne conserve aucun accès au fichier).
nonisolated private struct QueuedFile: Sendable {
    let id = UUID()
    let url: URL
    /// Fichier reçu par glisser-déposer, déjà copié dans les dépôts du coffre (déplacé, pas recopié).
    var isDeposit = false
    var fileName: String { url.lastPathComponent }
}

// MARK: - Contrôleur

/// État d'interface partagé par `FileAttachmentPicker` (bouton) et
/// `FileAttachmentTray` (capsules) : file des lectures et messages. Les pièces
/// jointes restent dans `AttachmentStore`, seule source de vérité, lu sans
/// copie : un `store.remove(id:)` fait ailleurs ne laisse aucune capsule fantôme.
///
/// - **Lecture SÉQUENTIELLE, obligatoire.** `AttachmentStore.attach(fileAt:)`
///   réserve `min(12 500, budget restant)` caractères dès le début d'une
///   lecture. En parallèle, le premier de trois petits fichiers réserverait
///   tout le budget et les deux autres échoueraient en « limite atteinte »,
///   alors qu'il n'en consommera que 2 000. Une seule tâche vide donc la file :
///   chaque réservation est libérée avant la lecture suivante.
/// - **Retirer un fichier pas encore joint** : sa capsule disparaît aussitôt.
///   En file, il n'est jamais lu ; en lecture, la lecture de CE fichier est
///   annulée (W4-V : la première lecture d'une image peut durer ~40 s ; Vision
///   s'arrête aussitôt) et, si elle va tout de même à son terme (un PDF), son
///   résultat est écarté dans le même tour du main actor que son ajout, sans
///   jamais s'afficher. Seule la tâche de LECTURE est annulée, jamais l'unique
///   tâche qui vide la file : l'annuler ferait échouer la suite.
/// - **Nouvelle conversation : `removeAll()`, jamais `store.removeAll()`
///   seul.** La génération du store écarte la lecture EN COURS, pas les
///   fichiers EN FILE, qui s'attacheraient sinon à la nouvelle conversation.
/// - **Durée de vie** : reçoit le store de la conversation sans le créer ; à
///   posséder à côté du ViewModel, jamais dans le `@State` d'une vue recréable.
/// - **Annonces VoiceOver** postées ici, au moment exact de l'événement : la
///   rangée n'existe pas tant qu'elle est vide, et `onChange` ignore la valeur
///   présente à l'apparition.
@Observable
final class FileAttachmentController {
    let store: AttachmentStore
    let maxAttachmentCount: Int
    /// Préparation de la lecture d'image (W4-V) : `nil` sous les tests unitaires. Lue par la rangée de capsules pour dire
    /// qu'une image attend cette préparation.
    let imageReadiness: ImageRecognitionReadiness?
    private(set) var pendingAttachments: [PendingFileAttachment] = []
    private(set) var notices: [FileAttachmentNotice] = []
    /// Sélecteur de fichiers présenté : posé par le bouton trombone ET par le menu Fichier > « Joindre des
    /// fichiers… » (⇧⌘A), qui passent tous deux par `requestPicker()`. Ici et non dans la vue : le menu n'a
    /// aucune vue sous la main.
    var isPickerPresented = false
    /// Photothèque présentée (iPhone, iPad, iPhone Duo) : posé par l'entrée « Photothèque… » du menu du trombone.
    var isPhotoPickerPresented = false
    /// Copies conservées par le coffre, par pièce jointe : de quoi proposer le Coup d'œil (chantier 2.2, M5).
    /// Absent pour un fichier trop gros ou dont la copie a échoué.
    private(set) var storedFileURLs: [UUID: URL] = [:]

    @ObservationIgnored private let vault: AttachmentFileVault
    @ObservationIgnored private var purgeObservation: AttachmentVaultPurgeObservation?
    @ObservationIgnored private var queue: [QueuedFile] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Lecture EN COURS, annulable pour de vrai (W4-V) : retirer une image dont la première lecture dure ~40 s doit
    /// libérer la file aussitôt, pas à la fin du calcul. Seule cette tâche est annulée, jamais `worker`.
    @ObservationIgnored private var currentReadTask: Task<IndexedAttachment, any Error>?
    @ObservationIgnored private var currentFileID: UUID?
    @ObservationIgnored private var discardsCurrentResult = false

    init(
        store: AttachmentStore,
        maxAttachmentCount: Int = FileAttachmentRules.maxAttachmentCount,
        vault: AttachmentFileVault = AttachmentFileVault(),
        purgeSignalCenter: NotificationCenter = .default,
        imageReadiness: ImageRecognitionReadiness? = ImageRecognitionReadiness.forCurrentProcess
    ) {
        self.store = store
        self.imageReadiness = imageReadiness
        self.maxAttachmentCount = max(1, maxAttachmentCount)
        self.vault = vault
        purgeObservation = AttachmentVaultPurgeObservation(center: purgeSignalCenter) { [weak self] root in
            self?.forgetPurgedCopies(inVaultAt: root)
        }
    }

    /// « Tout effacer » va supprimer TOUTES les copies du coffre (`AttachmentVaultPurgeSignal`), y compris les
    /// nôtres : on les oublie (plus de Coup d'œil proposé sur un fichier disparu ; le texte déjà lu reste joint), et
    /// les dépôts encore en file, dont la copie disparaît avant d'être lue, sont retirés. Un fichier choisi dans le
    /// sélecteur n'est pas une copie du coffre : il reste en file.
    private func forgetPurgedCopies(inVaultAt root: URL?) {
        // Un autre coffre que le nôtre : nos copies ne sont pas touchées.
        guard root?.path == vault.rootDirectory.standardizedFileURL.path else { return }
        storedFileURLs = [:]
        let lostIDs = Set(queue.filter(\.isDeposit).map(\.id))
        guard !lostIDs.isEmpty else { return }
        queue.removeAll { lostIDs.contains($0.id) }
        pendingAttachments.removeAll { lostIDs.contains($0.id) }
    }

    /// Fenêtre fermée : les copies de documents de l'utilisateur ne doivent pas lui survivre, y compris les dépôts
    /// encore en file, jamais lus.
    deinit {
        Self.discardDeposits(in: queue, rootDirectory: vault.rootDirectory)
        vault.removeAll()
    }

    var attachments: [IndexedAttachment] { store.attachments }
    var remainingSlots: Int { max(0, maxAttachmentCount - store.attachments.count - pendingAttachments.count) }
    /// Budget des fichiers DÉJÀ joints, sans les réservations des lectures en
    /// cours : sinon le bouton paraîtrait bloqué pendant chaque lecture.
    var isCharacterBudgetExhausted: Bool { store.indexedCharacterCount >= store.totalCharacterBudget }
    var canAttachMore: Bool { remainingSlots > 0 && !isCharacterBudgetExhausted }
    var isEmpty: Bool { store.attachments.isEmpty && pendingAttachments.isEmpty && notices.isEmpty }

    // MARK: Actions

    /// Bouton touché alors que `canAttachMore` est faux : explique pourquoi,
    /// plutôt que d'ouvrir un sélecteur dont aucun choix n'aboutirait.
    func explainAttachmentLimit() {
        let message = remainingSlots == 0
            ? FileAttachmentPresentation.countLimitReachedMessage(limit: maxAttachmentCount)
            : AttachmentStoreError.characterBudgetExhausted.userFacingMessage
        notices = []
        show(FileAttachmentNotice(fileNames: [], message: message))
    }

    /// Ouvre le sélecteur, ou explique pourquoi on ne peut plus rien joindre (même règle pour le bouton et le menu).
    func requestPicker() {
        if canAttachMore {
            isPickerPresented = true
        } else {
            explainAttachmentLimit()
        }
    }

    /// Ouvre la photothèque, ou explique pourquoi on ne peut plus rien joindre (même règle que `requestPicker()`).
    func requestPhotoPicker() {
        if canAttachMore {
            isPhotoPickerPresented = true
        } else {
            explainAttachmentLimit()
        }
    }

    /// Résultat brut de `.fileImporter`.
    func handlePickerResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            enqueue(urls)
        case .failure(let error):
            guard !FileAttachmentPresentation.isUserCancellation(error) else { return }
            notices = []
            show(FileAttachmentNotice(fileNames: [], message: FileAttachmentPresentation.pickerFailureMessage))
        }
    }

    /// Met des fichiers en file ; les messages précédents, caducs, sont effacés.
    /// - Parameter areDeposits : `true` pour des fichiers reçus par glisser-déposer, déjà copiés dans les dépôts du
    ///   coffre : ceux qui ne sont pas retenus (doublon, excédent) y sont effacés.
    func enqueue(_ urls: [URL], areDeposits: Bool = false) {
        guard !urls.isEmpty else { return }
        let existingNames = store.attachments.map(\.fileName) + pendingAttachments.map(\.fileName)
        let plan = FileAttachmentRules.plan(for: urls, existingFileNames: existingNames, availableSlots: remainingSlots)
        let files = plan.accepted.map { QueuedFile(url: $0, isDeposit: areDeposits) }
        if areDeposits {
            urls.filter { !plan.accepted.contains($0) }.forEach { AttachmentFileVault.discardDeposit($0, rootDirectory: vault.rootDirectory) }
        }
        notices = []
        if !plan.duplicateFileNames.isEmpty {
            show(FileAttachmentNotice(fileNames: plan.duplicateFileNames, message: FileAttachmentPresentation.alreadyAttachedMessage))
        }
        if !plan.overflowFileNames.isEmpty {
            show(FileAttachmentNotice(fileNames: plan.overflowFileNames, message: FileAttachmentPresentation.tooManyFilesMessage(limit: maxAttachmentCount)))
        }
        pendingAttachments += files.map { PendingFileAttachment(id: $0.id, fileName: $0.fileName) }
        queue += files
        // Une image qui arrive : la préparation de la lecture part tout de suite (ou continue), et la capsule le dit.
        if files.contains(where: { AttachmentKind(fileName: $0.fileName) == .image }) {
            imageReadiness?.prepareForUserRequest()
        }
        startWorkerIfNeeded()
    }

    func removeAttachment(id: UUID) {
        store.remove(id: id)
        vault.remove(storedURL: storedFileURLs.removeValue(forKey: id))
    }

    /// Information discrète sous les capsules (texte externe coupé) : même rangée que les refus, sans l'icône d'alerte.
    func reportInformation(_ message: String) {
        show(FileAttachmentNotice(fileNames: [], message: message, style: .information))
    }

    func reportTruncatedText() {
        reportInformation(FileAttachmentPresentation.truncatedTextMessage(limit: ExternalQuerySanitizer.maxLength))
    }

    /// Message sous les capsules pour un dépôt refusé (type inconnu, trop gros…). Texte fermé, sans nom de fichier.
    func reportRefusal(_ message: String) {
        show(FileAttachmentNotice(fileNames: [], message: message))
    }

    /// Copie à montrer au Coup d'œil, tant qu'elle existe encore sur le disque (le système peut vider le
    /// dossier temporaire d'une app restée longtemps ouverte).
    func previewURL(for attachmentID: UUID) -> URL? {
        guard let url = storedFileURLs[attachmentID],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func dismissNotice(id: UUID) { notices.removeAll { $0.id == id } }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        Self.discardDeposits(in: queue.filter { $0.id == id }, rootDirectory: vault.rootDirectory)
        queue.removeAll { $0.id == id }
        if currentFileID == id {
            discardsCurrentResult = true
            currentReadTask?.cancel()
        }
        releaseImageWaitIfNoImageLeft()
    }

    /// À l'envoi d'une question, par exemple : ces messages sont caducs.
    func dismissAllNotices() { notices = [] }

    /// « Nouvelle conversation » : file vidée AVANT le store, pour qu'aucun
    /// fichier en attente ne démarre après coup. La lecture en cours échoue en
    /// `CancellationError` (génération du store), sans message.
    func removeAll() {
        Self.discardDeposits(in: queue, rootDirectory: vault.rootDirectory)
        queue.removeAll()
        pendingAttachments.removeAll()
        notices = []
        if currentFileID != nil {
            discardsCurrentResult = true
            currentReadTask?.cancel()
        }
        store.removeAll()
        storedFileURLs = [:]
        vault.removeAll()
        releaseImageWaitIfNoImageLeft()
    }

    /// Plus aucune image en file ni en lecture : la préparation de la lecture d'image n'est plus attendue par personne.
    private func releaseImageWaitIfNoImageLeft() {
        guard !pendingAttachments.contains(where: { AttachmentKind(fileName: $0.fileName) == .image }) else { return }
        imageReadiness?.userRequestDidEnd()
    }

    /// Efface les copies des dépôts qui ne seront jamais lus (retirés, file vidée, budget épuisé, fenêtre fermée) :
    /// des documents de l'utilisateur ne doivent pas attendre le prochain lancement dans `tmp`.
    nonisolated private static func discardDeposits(in files: [QueuedFile], rootDirectory: URL) {
        for file in files where file.isDeposit {
            AttachmentFileVault.discardDeposit(file.url, rootDirectory: rootDirectory)
        }
    }

    // MARK: File de lecture

    /// Tâche créée sur le main actor, dont elle hérite : les appels au store
    /// (isolé au main actor) se font sans saut d'acteur ; le travail lourd
    /// quitte le main actor dans `AttachmentPreparer` (`@concurrent`).
    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    /// Aucune suspension entre la fin de la boucle et `worker = nil` : une
    /// sélection ne peut pas s'intercaler et rester sans tâche pour la lire.
    private func drainQueue() async {
        while !queue.isEmpty {
            let file = queue.removeFirst()
            await read(file)
        }
        worker = nil
    }

    private func read(_ file: QueuedFile) async {
        currentFileID = file.id
        discardsCurrentResult = false
        defer { currentFileID = nil }
        // La lecture se fait sur la copie du coffre (hors du main actor) : le fichier d'origine n'est ouvert qu'une fois.
        let placement = await vault.place(file.url, isDeposit: file.isDeposit)
        do {
            let readTask = Task { try await store.attach(fileAt: placement.readURL) }
            currentReadTask = readTask
            defer { currentReadTask = nil }
            let attachment = try await readTask.value
            pendingAttachments.removeAll { $0.id == file.id }
            if discardsCurrentResult {
                store.remove(id: attachment.id)
                vault.remove(storedURL: placement.storedURL)
            } else {
                if let storedURL = placement.storedURL { storedFileURLs[attachment.id] = storedURL }
                announce(FileAttachmentPresentation.attachedAnnouncement(for: attachment))
            }
        } catch {
            pendingAttachments.removeAll { $0.id == file.id }
            vault.remove(storedURL: placement.storedURL)
            handleFailure(error, for: file)
        }
        releaseImageWaitIfNoImageLeft()
        // Dépôt que le coffre n'a pas pu adopter : lu en place, puis effacé (jamais laissé dans les dépôts).
        if file.isDeposit, placement.storedURL == nil { AttachmentFileVault.discardDeposit(file.url, rootDirectory: vault.rootDirectory) }
    }

    /// Fichier retiré pendant sa lecture, ou conversation vidée : son échec ne
    /// concerne plus personne. Budget épuisé : les fichiers encore en file
    /// échoueraient tous à l'identique (rien ne s'exécute entre deux lectures),
    /// ils sont donc abandonnés d'un coup, sous UN seul message.
    private func handleFailure(_ error: any Error, for file: QueuedFile) {
        guard !discardsCurrentResult else { return }
        if let storeError = error as? AttachmentStoreError, storeError == .characterBudgetExhausted {
            let abandoned = queue
            let abandonedIDs = Set(abandoned.map(\.id))
            Self.discardDeposits(in: abandoned, rootDirectory: vault.rootDirectory)
            queue.removeAll()
            pendingAttachments.removeAll { abandonedIDs.contains($0.id) }
            show(FileAttachmentNotice(fileNames: [file.fileName] + abandoned.map(\.fileName), message: storeError.userFacingMessage))
        } else if let message = FileAttachmentPresentation.failureMessage(for: error) {
            show(FileAttachmentNotice(fileNames: [file.fileName], message: message))
        }
    }

    private func show(_ notice: FileAttachmentNotice) {
        notices.append(notice)
        announce(FileAttachmentPresentation.announcement(for: notice))
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
