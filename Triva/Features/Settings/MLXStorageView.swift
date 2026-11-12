//
//  MLXStorageView.swift
//  Triva
//
//  Created by ben podrojsky on 04/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Données

/// Un modèle MLX présent sur le disque : un sous-dossier de la racine des
/// modèles (voir `MLXModelStorage.rootDirectory`).
nonisolated struct MLXStoredModel: Sendable, Equatable, Identifiable {
    /// Nom du sous-dossier, c'est-à-dire `MLXModelCatalogEntry.id` pour un
    /// modèle du catalogue (`MLXProvider.modelStorageDirectory(for:)` range un
    /// modèle sous son identifiant).
    let id: String
    /// Espace réellement occupé sur le disque (blocs alloués), liens
    /// symboliques exclus — voir `MLXModelStorage.allocatedSize(ofDirectory:)`.
    let allocatedBytes: UInt64
}

nonisolated enum MLXModelStorageError: Error, Sendable, Equatable {
    /// La racine existe mais n'a pas pu être listée.
    case scanFailed
    /// Identifiant qui ne désigne pas un sous-dossier direct de la racine
    /// (vide, « . », « .. », ou contenant « / ») : rien n'est supprimé.
    case invalidModelID
    /// Modèle utilisé par le moteur actif (voir `MLXStorageView.isInUse`).
    case modelInUse
    case deletionFailed

    /// Textes fixes : aucune description d'erreur système n'est affichée.
    var userFacingMessage: String {
        switch self {
        case .scanFailed:
            "Le dossier des modèles n'a pas pu être lu."
        case .invalidModelID:
            "Ce dossier ne peut pas être supprimé d'ici."
        case .modelInUse:
            "Ce modèle est en service : choisis-en un autre ou change de moteur avant de le supprimer."
        case .deletionFailed:
            "La suppression a échoué. Réessaie."
        }
    }
}

// MARK: - Accès disque

/// Lecture et suppression des modèles MLX téléchargés.
///
/// OÙ SONT LES MODÈLES : la seule source de vérité est
/// `MLXProvider.modelStorageDirectory(for:)` — `Application Support/MLXModels/
/// <id du modèle>/`, un sous-dossier par modèle, dans lequel `MLXProvider`
/// fixe le cache Hugging Face (`HubCache(location: .fixed(...))`) pour le
/// téléchargement comme pour le chargement. La racine est donc dérivée de
/// cette fonction plutôt que réécrite ici : si `MLXProvider` change
/// d'emplacement, cet écran suit. Rien n'est supposé sur le contenu d'un
/// dossier (structure interne du cache, téléchargement complet ou partiel) :
/// on mesure et on supprime le dossier entier, c'est tout.
///
/// CONCURRENCE : les points d'entrée `async` sont `@concurrent` — avec
/// `NonisolatedNonsendingByDefault`, une fonction `nonisolated async`
/// tournerait sur l'acteur de l'appelant, ici le main actor. Le parcours
/// récursif reste dans des fonctions SYNCHRONES : Swift 6 interdit d'itérer
/// un `FileManager.DirectoryEnumerator` (`makeIterator`) dans un contexte
/// asynchrone, et c'est aussi ce qui permet de tester ce parcours sans
/// `await` sur un dossier temporaire.
nonisolated enum MLXModelStorage {
    /// Identifiant fictif servant uniquement à remonter au dossier parent.
    private static let rootProbeID = "_"

    /// `Application Support/MLXModels/`, dérivé de `MLXProvider`.
    static var rootDirectory: URL {
        MLXProvider.modelStorageDirectory(for: rootProbeID).deletingLastPathComponent()
    }

    @concurrent
    static func scan(rootDirectory: URL) async throws -> [MLXStoredModel] {
        try scanSynchronously(rootDirectory: rootDirectory)
    }

    @concurrent
    static func delete(modelID: String, rootDirectory: URL) async throws {
        try deleteSynchronously(modelID: modelID, rootDirectory: rootDirectory)
    }

    /// Sous-dossiers directs de la racine, du plus lourd au plus léger (à
    /// taille égale, par identifiant, pour un ordre stable d'un affichage à
    /// l'autre). Racine absente : aucun modèle n'a jamais été téléchargé, ce
    /// n'est pas une erreur. Un dossier qui n'appartient plus au catalogue
    /// (modèle retiré d'une version ultérieure) est listé quand même : sans ça,
    /// sa place serait perdue pour toujours, faute d'écran pour la libérer.
    static func scanSynchronously(rootDirectory: URL) throws -> [MLXStoredModel] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootDirectory.path(percentEncoded: false)) else { return [] }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw MLXModelStorageError.scanFailed
        }
        return children
            .filter { isRealDirectory($0) }
            .map { MLXStoredModel(id: $0.lastPathComponent, allocatedBytes: allocatedSize(ofDirectory: $0)) }
            .sorted { lhs, rhs in
                lhs.allocatedBytes != rhs.allocatedBytes ? lhs.allocatedBytes > rhs.allocatedBytes : lhs.id < rhs.id
            }
    }

    /// Supprime le dossier entier d'un modèle — exactement celui que
    /// `MLXProvider` utilise pour cet identifiant. L'identifiant doit désigner
    /// un sous-dossier DIRECT de la racine : jamais de suppression hors du
    /// dossier des modèles, même avec un identifiant malformé.
    static func deleteSynchronously(modelID: String, rootDirectory: URL) throws {
        guard isSafeModelID(modelID) else { throw MLXModelStorageError.invalidModelID }
        let directory = rootDirectory.appendingPathComponent(modelID, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw MLXModelStorageError.deletionFailed
        }
    }

    /// Un seul composant de chemin, sans remontée possible.
    static func isSafeModelID(_ modelID: String) -> Bool {
        !modelID.isEmpty && modelID != "." && modelID != ".." && !modelID.contains("/")
    }

    /// Somme des blocs alloués des fichiers ORDINAIRES du dossier, en
    /// profondeur. Les liens symboliques sont ignorés et jamais suivis : le
    /// cache Hugging Face relie `snapshots/` à `blobs/` par des liens, les
    /// suivre compterait chaque poids deux fois. Taille ALLOUÉE plutôt que
    /// logique : c'est la place réellement libérée par une suppression. Un
    /// fichier illisible est sauté (taille sous-estimée) plutôt que de faire
    /// échouer toute la mesure.
    static func allocatedSize(ofDirectory directory: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: UInt64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            total += regularFileSize(at: fileURL, keys: keys)
        }
        return total
    }

    private static func regularFileSize(at fileURL: URL, keys: Set<URLResourceKey>) -> UInt64 {
        guard let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            return 0
        }
        let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
        return UInt64(max(size, 0))
    }

    /// Un lien symbolique vers un dossier n'est pas un modèle : le supprimer
    /// ne libérerait rien, et le mesurer reviendrait à suivre le lien.
    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

// MARK: - Écran

/// Écran « Modèles MLX » des Réglages (1.15) : espace occupé par chaque
/// modèle téléchargé, et suppression pour libérer de la place.
///
/// RÈGLE DU MODÈLE EN SERVICE : le modèle sélectionné (`MLXModelSelectionStore`)
/// n'est pas supprimable tant que le moteur actif est MLX local (ou inconnu,
/// par prudence, tant que l'intégration ne fournit pas `activeEngine`). La
/// session de recherche garde ce modèle chargé et validé en cache
/// (`SearchSession.validatedMLXModel`, `preparedProvider`) : effacer ses
/// fichiers déclencherait au prochain `prepare()` un nouveau téléchargement de
/// plusieurs Go, sans que l'utilisateur l'ait demandé. Avec un autre moteur
/// actif, la suppression est permise ET efface la sélection MLX : revenir
/// plus tard sur MLX redemandera un modèle au lieu d'en retélécharger un en
/// silence.
///
/// Poussé dans la pile des Réglages : pas de `NavigationStack` ici.
struct MLXStorageView: View {
    let mlxSelectionStore: MLXModelSelectionStore
    let activeEngine: AIEngineOption?
    private let rootDirectory: URL

    @State private var phase: MLXStoragePhase = .loading
    @State private var displayNames: [String: String] = [:]
    @State private var pendingDeletion: MLXStoredModel?
    @State private var deletingModelID: String?
    @State private var deletionError: MLXModelStorageError?
    /// Chaque incrément relance la lecture du disque (`.task(id:)`).
    @State private var reloadToken = 0

    /// `rootDirectory` n'est injectable que pour les tests et les previews ;
    /// l'app utilise toujours la racine dérivée de `MLXProvider`.
    init(
        mlxSelectionStore: MLXModelSelectionStore,
        activeEngine: AIEngineOption?,
        rootDirectory: URL = MLXModelStorage.rootDirectory
    ) {
        self.mlxSelectionStore = mlxSelectionStore
        self.activeEngine = activeEngine
        self.rootDirectory = rootDirectory
    }

    var body: some View {
        MLXStorageContent(
            display: display,
            onRequestDeletion: { requestDeletion(id: $0) },
            onRetry: { retry() }
        )
        .navigationTitle("Modèles MLX")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: reloadToken) {
            await reload()
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { model in
            Button("Supprimer", role: .destructive) {
                Task { await delete(model) }
            }
            // Explicite : celui du système sortirait en anglais.
            Button("Annuler", role: .cancel) {}
        } message: { model in
            Text(verbatim: deletionMessage(for: model))
        }
        .alert(deletionError?.userFacingMessage ?? "", isPresented: isShowingDeletionError) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Le modèle `modelID` est-il en service ? Voir la règle dans le
    /// commentaire de tête. Logique pure, exposée pour être testable.
    static func isInUse(modelID: String, selectedModelID: String?, activeEngine: AIEngineOption?) -> Bool {
        guard modelID == selectedModelID else { return false }
        switch activeEngine {
        case .appleIntelligence?, .cloudBYOK?:
            return false
        case .mlxLocal?, nil:
            return true
        }
    }

    // MARK: Affichage

    private var display: MLXStorageDisplay {
        switch phase {
        case .loading:
            return .loading
        case .failed:
            return .failed
        case .loaded(let models):
            let total = models.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
            return .loaded(rows: models.map { row(for: $0) }, totalSize: Self.formattedSize(total))
        }
    }

    private func row(for model: MLXStoredModel) -> MLXStorageRow {
        MLXStorageRow(
            id: model.id,
            name: displayName(for: model),
            sizeText: Self.formattedSize(model.allocatedBytes),
            isInUse: isInUse(model),
            isDeleting: deletingModelID == model.id
        )
    }

    /// Nom du catalogue, ou à défaut l'identifiant du dossier (modèle retiré
    /// du catalogue, ou catalogue illisible).
    private func displayName(for model: MLXStoredModel) -> String {
        displayNames[model.id] ?? model.id
    }

    private func isInUse(_ model: MLXStoredModel) -> Bool {
        Self.isInUse(modelID: model.id, selectedModelID: mlxSelectionStore.selectedModelID, activeEngine: activeEngine)
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "" }
        return "Supprimer \(displayName(for: pendingDeletion))\u{00A0}?"
    }

    private func deletionMessage(for model: MLXStoredModel) -> String {
        "\(Self.formattedSize(model.allocatedBytes)) seront libérés. Il faudra le retélécharger pour l'utiliser à nouveau."
    }

    /// Même format que la taille de téléchargement affichée au choix du
    /// modèle (`MLXModelSelectionView.formattedSize`).
    private static func formattedSize(_ bytes: UInt64) -> String {
        ByteCountText.string(forByteCount: bytes)
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingDeletion = nil }
            }
        )
    }

    private var isShowingDeletionError: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { isPresented in
                if !isPresented { deletionError = nil }
            }
        )
    }

    // MARK: Actions

    /// Une suppression à la fois : `deletingModelID` ne suit qu'un modèle, une
    /// seconde suppression effacerait l'indicateur de la première.
    private func requestDeletion(id: String) {
        guard deletingModelID == nil else { return }
        guard case .loaded(let models) = phase, let model = models.first(where: { $0.id == id }) else { return }
        guard !isInUse(model) else {
            deletionError = .modelInUse
            return
        }
        pendingDeletion = model
    }

    private func retry() {
        phase = .loading
        reloadToken += 1
    }

    /// Les noms du catalogue sont lus une fois ; le catalogue n'est qu'une
    /// source de libellés ici, son échec de lecture n'empêche rien (repli sur
    /// l'identifiant, voir `displayName(for:)`). Après une suppression, la
    /// liste reste affichée pendant la relecture : pas de clignotement.
    private func reload() async {
        if displayNames.isEmpty {
            displayNames = Self.catalogDisplayNames()
        }
        do {
            let models = try await MLXModelStorage.scan(rootDirectory: rootDirectory)
            phase = .loaded(models)
        } catch {
            phase = .failed
        }
    }

    /// La règle du modèle en service est revérifiée ici : la sélection a pu
    /// changer entre la demande et la confirmation.
    private func delete(_ model: MLXStoredModel) async {
        guard !isInUse(model) else {
            deletionError = .modelInUse
            return
        }
        deletingModelID = model.id
        do {
            try await MLXModelStorage.delete(modelID: model.id, rootDirectory: rootDirectory)
            removeFromDisplayedList(modelID: model.id)
            if mlxSelectionStore.selectedModelID == model.id {
                mlxSelectionStore.selectedModelID = nil
            }
        } catch {
            deletionError = (error as? MLXModelStorageError) ?? .deletionFailed
        }
        deletingModelID = nil
        reloadToken += 1
    }

    /// Retire la ligne dès la fin de la suppression, sans attendre la
    /// relecture du disque : entre les deux, la ligne réapparaîtrait un
    /// instant avec son bouton « Supprimer » actif. La relecture qui suit
    /// reste la source de vérité (et montre ce qui reste après un échec
    /// partiel, qui ne passe pas par ici).
    private func removeFromDisplayedList(modelID: String) {
        guard case .loaded(let models) = phase else { return }
        phase = .loaded(models.filter { $0.id != modelID })
    }

    private static func catalogDisplayNames() -> [String: String] {
        guard let catalog = try? MLXModelCatalog.load() else { return [:] }
        return Dictionary(catalog.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Présentation

private nonisolated enum MLXStoragePhase: Equatable, Sendable {
    case loading
    case loaded([MLXStoredModel])
    case failed
}

/// Ce qu'une ligne affiche, déjà formaté.
private nonisolated struct MLXStorageRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sizeText: String
    let isInUse: Bool
    let isDeleting: Bool
}

private nonisolated enum MLXStorageDisplay: Equatable, Sendable {
    case loading
    case failed
    case loaded(rows: [MLXStorageRow], totalSize: String)
}

/// Mise en page seule, sans accès au disque : c'est ce qui permet des
/// previews de chaque état avec des données factices.
private struct MLXStorageContent: View {
    let display: MLXStorageDisplay
    let onRequestDeletion: (String) -> Void
    let onRetry: () -> Void

    var body: some View {
        Form {
            if case .loaded(let rows, let totalSize) = display, !rows.isEmpty {
                Section {
                    ForEach(rows) { row in
                        MLXStorageRowView(row: row) { onRequestDeletion(row.id) }
                    }
                } footer: {
                    footer(rows: rows, totalSize: totalSize)
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            overlay
        }
    }

    private func footer(rows: [MLXStorageRow], totalSize: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(totalSize) au total.")
            if rows.contains(where: \.isInUse) {
                Text("Le modèle en service ne peut pas être supprimé : choisis-en un autre ou change de moteur d'abord.")
            }
        }
    }

    /// Chargement : rien plutôt qu'un indicateur — une lecture locale de
    /// quelques dossiers ne ferait que le faire clignoter (même choix que
    /// `FavoritesView`).
    @ViewBuilder
    private var overlay: some View {
        switch display {
        case .loading:
            EmptyView()
        case .failed:
            ContentUnavailableView {
                Label("Lecture impossible", systemImage: "exclamationmark.triangle")
            } description: {
                Text(MLXModelStorageError.scanFailed.userFacingMessage)
            } actions: {
                // Seule action de l'écran dans cet état : action principale
                // (DESIGN.md), comme dans Découvrir et Favoris.
                Button("Réessayer", action: onRetry)
                    .buttonStyle(.glassProminent)
            }
        case .loaded(let rows, _) where rows.isEmpty:
            ContentUnavailableView(
                "Aucun modèle téléchargé",
                systemImage: "internaldrive",
                description: Text("Les modèles MLX que tu télécharges apparaissent ici, avec la place qu'ils occupent.")
            )
        case .loaded:
            EmptyView()
        }
    }
}

/// Une ligne : nom (et « En service »), taille, bouton de suppression visible
/// — c'est l'action principale de l'écran, elle ne doit pas dépendre d'un
/// geste caché. Balayage et menu contextuel en plus, pour les habitudes de
/// chaque plateforme.
private struct MLXStorageRowView: View {
    let row: MLXStorageRow
    let onRequestDeletion: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        layout {
            details
            deletionControl
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            deleteAction
        }
        .contextMenu {
            deleteAction
        }
    }

    /// Verticale aux tailles de texte d'accessibilité : sur une seule ligne,
    /// nom, taille et bouton se disputeraient une largeur trop étroite.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    }

    private var details: some View {
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.name)
                if row.isInUse {
                    Text("En service")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.sizeText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var deletionControl: some View {
        if row.isDeleting {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Suppression de \(row.name) en cours")
        } else if !row.isInUse {
            Button(role: .destructive, action: onRequestDeletion) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Supprimer \(row.name)")
        }
    }

    @ViewBuilder
    private var deleteAction: some View {
        if !row.isInUse && !row.isDeleting {
            Button(role: .destructive, action: onRequestDeletion) {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }
}

// MARK: - Previews

#Preview("Deux modèles, dont un en service") {
    NavigationStack {
        MLXStorageContent(
            display: .loaded(
                rows: [
                    MLXStorageRow(id: "qwen3-4b-4bit", name: "Qwen3 4B", sizeText: "2,3 Go", isInUse: true, isDeleting: false),
                    MLXStorageRow(id: "qwen3-0_6b-4bit", name: "Qwen3 0.6B", sizeText: "430 Mo", isInUse: false, isDeleting: false),
                ],
                totalSize: "2,7 Go"
            ),
            onRequestDeletion: { _ in },
            onRetry: {}
        )
        .navigationTitle("Modèles MLX")
    }
}

#Preview("Aucun modèle") {
    NavigationStack {
        MLXStorageContent(display: .loaded(rows: [], totalSize: "0 octet"), onRequestDeletion: { _ in }, onRetry: {})
            .navigationTitle("Modèles MLX")
    }
}

#Preview("Lecture impossible") {
    NavigationStack {
        MLXStorageContent(display: .failed, onRequestDeletion: { _ in }, onRetry: {})
            .navigationTitle("Modèles MLX")
    }
}

#Preview("Écran réel") {
    NavigationStack {
        MLXStorageView(
            mlxSelectionStore: MLXModelSelectionStore(userDefaults: UserDefaults(suiteName: "preview.mlxStorage") ?? .standard),
            activeEngine: .appleIntelligence
        )
    }
}
