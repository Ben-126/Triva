//
//  SearXNGInstancesView.swift
//  Triva
//
//  Created by ben podrojsky on 04/10/2026.
//

import SwiftUI

/// Écran « Instances SearXNG » (1.15, Réglages > Recherche > Avancé) : voir
/// et éditer la liste d'instances que la recherche essaie, dans l'ordre.
///
/// Toute la logique vit dans `CustomInstanceStore` (validation, surcouche
/// persistée, sondes) ; cette vue ne fait qu'afficher et relayer. Composants
/// système (`Form`, swipe, menu contextuel) et non du verre : les réglages
/// sont l'écran où l'app doit ressembler au reste du système (DESIGN.md :
/// le verre est réservé aux barres, badges et cartes interactives).
///
/// Poussée dans la pile des Réglages : pas de `NavigationStack` ici (une pile
/// imbriquée dans une autre donne une double barre et des liens cassés).
///
/// Chaque action a deux chemins — balayage sur iPhone/iPad, menu contextuel
/// partout (le Mac n'a pas de balayage) — plus le bouton « Tester » visible.
/// Tous les libellés sont écrits en clair : sans localisation française dans
/// le projet, ceux fournis par le système (`onDelete`, bouton « Annuler »
/// implicite d'une boîte de dialogue) sortiraient en anglais.
struct SearXNGInstancesView: View {
    let store: CustomInstanceStore

    @State private var newAddress = ""
    @State private var inputError: CustomInstanceError?
    /// Adresse locale validée, en attente de confirmation explicite.
    @State private var pendingLocalCandidate: SearXNGInstanceCandidate?
    @State private var isConfirmingReset = false
    @State private var actionError: CustomInstanceError?

    var body: some View {
        Form {
            if store.defaultListLoadFailed {
                Section {
                    Label("La liste par défaut n'a pas pu être chargée.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            addSection
            if !store.customInstances.isEmpty {
                Section("Tes instances") {
                    instanceRows(store.customInstances)
                }
            }
            if !store.defaultSectionInstances.isEmpty || store.hiddenDefaultCount > 0 {
                defaultsSection
            }
            automaticSection
            actionsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Instances SearXNG")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(actionError?.userFacingMessage ?? "", isPresented: isShowingActionError) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Sections

    /// La confirmation d'adresse locale est attachée au bouton « Ajouter » (et
    /// non à la liste) : sur iPad et Mac, elle s'ouvre depuis lui, comme dans
    /// `FavoritesView`. Un seul `confirmationDialog` par vue, de surcroît.
    private var addSection: some View {
        Section {
            TextField("Adresse", text: $newAddress, prompt: Text(verbatim: "https://searx.exemple.org"))
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(submit)
            Button("Ajouter", action: submit)
                .disabled(isAddressEmpty)
                .confirmationDialog(
                    "Adresse locale",
                    isPresented: isConfirmingLocalAddress,
                    titleVisibility: .visible,
                    presenting: pendingLocalCandidate
                ) { candidate in
                    Button("Ajouter quand même") { commit(candidate) }
                    // Explicite : celui du système sortirait en anglais.
                    Button("Annuler", role: .cancel) {}
                } message: { _ in
                    Text("Cette instance ne répondra que depuis ton réseau local ou ton VPN.")
                }
        } header: {
            Text("Ajouter une instance")
        } footer: {
            addFooter
        }
        .onChange(of: newAddress) { _, _ in
            inputError = nil
        }
    }

    @ViewBuilder
    private var addFooter: some View {
        if let inputError {
            Label(inputError.userFacingMessage, systemImage: "exclamationmark.triangle")
        } else {
            Text("L'instance doit accepter le format JSON. Tes instances sont essayées avant celles par défaut.")
        }
    }

    private var defaultsSection: some View {
        Section {
            instanceRows(store.defaultSectionInstances)
        } header: {
            Text("Par défaut")
        } footer: {
            if store.hiddenDefaultCount > 0 {
                Text(verbatim: hiddenCountText)
            }
        }
    }

    /// Toujours présente, même vide : c'est le seul endroit qui dit que Triva
    /// complète la liste tout seul, et pourquoi elle ne le fait pas en ce moment.
    private var automaticSection: some View {
        Section {
            let instances = store.automaticInstances
            if instances.isEmpty {
                Text(verbatim: automaticEmptyText)
                    .foregroundStyle(.secondary)
            } else {
                instanceRows(instances, rowIdentifier: "searxng.row.automatic")
            }
        } header: {
            Text("Ajoutées automatiquement")
        } footer: {
            Text(verbatim: automaticFooterText)
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Tester toutes les instances") {
                Task { await store.testAllConnectivity() }
            }
            .disabled(isTestingEveryInstance)
            if store.isCustomized {
                Button("Revenir à la liste par défaut", role: .destructive) {
                    isConfirmingReset = true
                }
                .accessibilityIdentifier("searxng.reset")
                .confirmationDialog(
                    "Revenir à la liste par défaut\u{00A0}?",
                    isPresented: $isConfirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Rétablir la liste", role: .destructive) { store.resetToDefaults() }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Tes instances seront retirées et les instances masquées reviendront.")
                }
            }
        } footer: {
            Text("Si une instance ne répond pas, Triva passe à la suivante.")
        }
    }

    private func instanceRows(_ instances: [URL], rowIdentifier: String = "searxng.row") -> some View {
        ForEach(instances, id: \.self) { instance in
            SearXNGInstanceRow(
                address: SearXNGInstanceAddress.displayAddress(for: instance),
                isLocalOrPrivate: SearXNGInstanceAddress.isLocalOrPrivate(url: instance),
                connectivity: store.connectivity(for: instance),
                onTest: { test(instance) }
            )
            .accessibilityIdentifier(rowIdentifier)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                removeButton(for: instance)
            }
            .contextMenu {
                Button("Tester", systemImage: "network") { test(instance) }
                removeButton(for: instance)
            }
        }
    }

    /// Absent quand il ne reste qu'une instance : proposer une action vouée à
    /// échouer (`cannotRemoveLastInstance`) serait pire que de ne rien
    /// proposer. « Retirer » plutôt que « Supprimer » : pour une instance par
    /// défaut, c'est un masquage réversible (« Revenir à la liste par défaut »).
    @ViewBuilder
    private func removeButton(for instance: URL) -> some View {
        if store.canRemove(instance) {
            Button(role: .destructive) {
                remove(instance)
            } label: {
                Label("Retirer", systemImage: "minus.circle")
            }
        }
    }

    // MARK: États dérivés

    private var isAddressEmpty: Bool {
        newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isTestingEveryInstance: Bool {
        store.testableInstances.allSatisfy { store.connectivity(for: $0) == .testing }
    }

    private var hiddenCountText: String {
        store.hiddenDefaultCount == 1
            ? "1 instance par défaut masquée."
            : "\(store.hiddenDefaultCount) instances par défaut masquées."
    }

    private var automaticEmptyText: String {
        store.overrides.hidesEveryDefault(of: store.defaultInstances)
            ? "Aucune : tu as retiré toutes les instances par défaut, Triva n'en ajoute donc pas."
            : "Aucune pour le moment."
    }

    private var automaticFooterText: String {
        let source = "Instances publiques vérifiées, tirées de l'annuaire searx.space. Elles sont essayées après les autres."
        switch store.hiddenAutomaticCount {
        case 0: return source
        case 1: return source + " 1 instance masquée."
        case let count: return source + " \(count) instances masquées."
        }
    }

    private var isConfirmingLocalAddress: Binding<Bool> {
        Binding(
            get: { pendingLocalCandidate != nil },
            set: { isPresented in
                if !isPresented { pendingLocalCandidate = nil }
            }
        )
    }

    private var isShowingActionError: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { isPresented in
                if !isPresented { actionError = nil }
            }
        )
    }

    // MARK: Actions

    /// Validation d'abord, ajout ensuite : une adresse locale ou privée passe
    /// par une confirmation (elle ne répondra pas hors du réseau local),
    /// les autres sont ajoutées tout de suite.
    private func submit() {
        guard !isAddressEmpty else { return }
        do {
            let candidate = try store.candidate(from: newAddress)
            if candidate.isLocalOrPrivate {
                pendingLocalCandidate = candidate
            } else {
                commit(candidate)
            }
        } catch {
            report(inputError: error)
        }
    }

    /// Ajoute puis teste aussitôt : savoir tout de suite si l'instance répond
    /// en JSON est la seule information qui compte après un ajout.
    private func commit(_ candidate: SearXNGInstanceCandidate) {
        do {
            let added = try store.add(candidate)
            newAddress = ""
            test(added)
        } catch {
            report(inputError: error)
        }
    }

    /// Message affiché sous le champ ET annoncé à VoiceOver : sans annonce, un
    /// utilisateur VoiceOver ne saurait pas que l'ajout a échoué (même principe
    /// que `ProviderAPIKeyEntryView.announce(error:)`).
    private func report(inputError error: any Error) {
        let instanceError = (error as? CustomInstanceError) ?? .invalidAddress
        inputError = instanceError
        AccessibilityNotification.Announcement("Erreur : \(instanceError.userFacingMessage)").post()
    }

    private func remove(_ instance: URL) {
        do {
            try store.remove(instance)
        } catch {
            actionError = (error as? CustomInstanceError) ?? .notInList
        }
    }

    /// Tâche non structurée volontairement : le store survit à l'écran, un
    /// test lancé puis quitté se termine et son résultat est là au retour.
    private func test(_ instance: URL) {
        Task { await store.testConnectivity(of: instance) }
    }
}

// MARK: - Ligne

/// Une instance : adresse, mention « réseau local » éventuelle, résultat du
/// dernier test, bouton « Tester » (ou indicateur pendant le test).
///
/// Disposition verticale aux tailles de texte d'accessibilité : sur une
/// ligne, l'adresse et le bouton se disputeraient une largeur trop étroite.
private struct SearXNGInstanceRow: View {
    let address: String
    let isLocalOrPrivate: Bool
    let connectivity: SearXNGInstanceConnectivity?
    let onTest: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            details
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingControl
        }
        .padding(.vertical, 4)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: address)
                .foregroundStyle(.primary)
            if isLocalOrPrivate {
                Text("Réseau local uniquement")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let connectivity, let summary = connectivity.summary {
                statusLabel(summary, isReachable: Self.isReachable(connectivity))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Seul le succès prend la couleur d'accent : un coup d'œil suffit pour
    /// repérer les instances qui marchent, sans code couleur supplémentaire.
    private func statusLabel(_ summary: String, isReachable: Bool) -> some View {
        Label {
            Text(verbatim: summary)
        } icon: {
            if isReachable {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if connectivity == .testing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Test de \(address) en cours")
        } else {
            Button("Tester", action: onTest)
                .buttonStyle(.borderless)
                .accessibilityLabel("Tester \(address)")
        }
    }

    private static func isReachable(_ connectivity: SearXNGInstanceConnectivity) -> Bool {
        if case .reachable = connectivity {
            return true
        }
        return false
    }
}

// MARK: - Previews

/// Client SearXNG factice : jamais de vrai réseau dans une préview. Un
/// `actor`, comme `PreviewSearXNGClient` dans `ChatView.swift` (requis par
/// `SearXNGSearching: Sendable`). Répond tout de suite, sauf pour les
/// adresses contenant « opnxng », qui échouent, pour montrer les deux états.
private actor InstancesPreviewClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        if instance.absoluteString.contains("opnxng") {
            throw URLError(.timedOut)
        }
        let result = SearXNGSearchResult(
            title: "Exemple", url: "https://exemple.org",
            content: nil, imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
        return SearXNGSearchResponse(results: [result], suggestions: [])
    }
}

private func previewInstanceStore(
    suiteName: String,
    defaults: [URL],
    loadFailed: Bool = false,
    directory: [String] = []
) -> CustomInstanceStore {
    let directoryStore = SearXNGDirectoryStore()
    directoryStore.save(SearXNGDirectorySnapshot(instances: directory))
    return CustomInstanceStore(
        defaultInstances: defaults,
        defaultListLoadFailed: loadFailed,
        userDefaults: UserDefaults(suiteName: suiteName) ?? .standard,
        client: InstancesPreviewClient(),
        directory: directoryStore
    )
}

private func previewDefaultInstances() -> [URL] {
    ["https://search.mectov.my.id", "https://baresearch.org", "https://opnxng.com", "https://priv.au"]
        .compactMap { URL(string: $0) }
}

#Preview("Liste par défaut, testée") {
    let store = previewInstanceStore(suiteName: "preview.searxngInstances.defaults", defaults: previewDefaultInstances())
    return NavigationStack {
        SearXNGInstancesView(store: store)
    }
    .task { await store.testAllConnectivity() }
}

#Preview("Avec des instances de l'annuaire") {
    NavigationStack {
        SearXNGInstancesView(
            store: previewInstanceStore(
                suiteName: "preview.searxngInstances.directory",
                defaults: previewDefaultInstances(),
                directory: ["https://annuaire-un.example", "https://annuaire-deux.example"]
            )
        )
    }
}

#Preview("Personnalisée") {
    let store = previewInstanceStore(suiteName: "preview.searxngInstances.custom", defaults: previewDefaultInstances())
    if let candidate = try? store.candidate(from: "searx.maison.local") {
        _ = try? store.add(candidate)
    }
    return NavigationStack {
        SearXNGInstancesView(store: store)
    }
}

#Preview("Liste par défaut illisible") {
    NavigationStack {
        SearXNGInstancesView(
            store: previewInstanceStore(suiteName: "preview.searxngInstances.failed", defaults: [], loadFailed: true)
        )
    }
}
