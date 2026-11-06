//
//  SearchKeysView.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import SwiftUI

/// Écran « Clés de recherche » (mission RI2, Réglages > Recherche) : les clés personnelles Brave et
/// Tavily, facultatives, qui passent avant les instances SearXNG publiques (`WebSearchChain`). On
/// y arrive aussi depuis le chat, quand toutes les sources ont échoué (`SearchKeyInvitationView`).
///
/// Toute la logique vit dans `SearchKeysViewModel` ; cette vue ne fait qu'afficher et relayer.
/// Composants système (`Form`) et non du verre, comme `SearXNGInstancesView` : les réglages sont
/// l'écran où l'app doit ressembler au reste du système (DESIGN.md). Tous les libellés sont écrits
/// en clair : sans localisation française dans le projet, ceux du système sortiraient en anglais.
///
/// Poussée dans la pile des Réglages : pas de `NavigationStack` ici (une pile imbriquée dans une
/// autre donne une double barre et des liens cassés).
struct SearchKeysView: View {
    @State private var viewModel: SearchKeysViewModel

    /// La valeur par défaut est réévaluée à chaque rendu du parent, sans coût : l'init de
    /// `SearchKeysViewModel` ne lit pas le trousseau, et seule la première instance est gardée.
    init(viewModel: SearchKeysViewModel = SearchKeysViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                Text("Une clé Brave ou Tavily fait passer tes recherches d'abord par ce service : des résultats plus fiables que les instances publiques, quel que soit ton moteur IA.")
            } footer: {
                Text("Facultatif. Ta clé reste dans le Trousseau de cet appareil et ne part que vers ce service. Chaque test consomme une requête de ton quota.")
            }
            // Ordre d'essai de la chaîne : l'écran montre d'abord la clé qui sert d'abord.
            ForEach(BYOKSearchSource.preferenceOrder, id: \.self) { source in
                SearchKeySection(source: source, viewModel: viewModel)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clés de recherche")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            viewModel.reload()
        }
    }
}

// MARK: - Section d'une source

/// Une source : le champ et le lien d'obtention tant qu'aucune clé n'est enregistrée, puis l'état
/// et les actions sur la clé. Le résultat de la dernière action est dans le pied de section.
///
/// La saisie reste ici, dans le `@State` du champ, jamais dans le modèle : c'est la seule copie en
/// clair de la clé hors du trousseau, vidée dès qu'elle est enregistrée. Une clé enregistrée n'est
/// jamais réaffichée, pas même masquée : pour la changer, on la supprime et on en saisit une autre.
private struct SearchKeySection: View {
    let source: BYOKSearchSource
    let viewModel: SearchKeysViewModel

    @State private var draft = ""
    @State private var isConfirmingDeletion = false

    var body: some View {
        let entry = viewModel.entry(for: source)
        Section {
            if entry.hasStoredKey {
                storedKeyRows(entry)
            } else {
                draftRows(entry)
            }
        } header: {
            Text(verbatim: source.displayName)
        } footer: {
            if let feedback = entry.feedback {
                SearchKeyFeedbackLabel(feedback: feedback)
            }
        }
    }

    // MARK: Lignes

    @ViewBuilder
    private func draftRows(_ entry: SearchKeyEntry) -> some View {
        SecureField("Clé \(source.displayName)", text: $draft, prompt: Text("Colle ta clé"))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .disabled(entry.isTesting)
            .onSubmit(submitDraft)
            .accessibilityIdentifier("searchKeys.field.\(source.rawValue)")

        Button(action: submitDraft) {
            SearchKeyTestLabel(title: "Tester et enregistrer", isTesting: entry.isTesting)
        }
        .disabled(!entry.canSubmit(draft: draft))
        .accessibilityIdentifier("searchKeys.save.\(source.rawValue)")

        if let keyPageURL = source.keyPageURL {
            Link(destination: keyPageURL) {
                Label("Obtenir une clé \(source.displayName)", systemImage: "arrow.up.forward.square")
            }
            .accessibilityIdentifier("searchKeys.link.\(source.rawValue)")
        }
    }

    /// La confirmation de suppression est attachée à son bouton : sur iPad et Mac, elle s'ouvre
    /// depuis lui. Elle existe parce que la clé n'est plus lisible nulle part dans l'app, et que
    /// plusieurs services ne la montrent qu'à sa création.
    @ViewBuilder
    private func storedKeyRows(_ entry: SearchKeyEntry) -> some View {
        Label("Clé enregistrée", systemImage: "key")
            // La copie en clair de la saisie ne survit pas à l'enregistrement, quel qu'en soit le
            // chemin : ce champ, ou une autre fenêtre vue à la relecture du trousseau.
            .onAppear { draft = "" }

        Button {
            Task {
                await viewModel.testStoredKey(for: source)
                announceResult()
            }
        } label: {
            SearchKeyTestLabel(title: "Tester la clé", isTesting: entry.isTesting)
        }
        .disabled(entry.isTesting)

        Button("Supprimer la clé", role: .destructive) {
            isConfirmingDeletion = true
        }
        .disabled(entry.isTesting)
        .confirmationDialog(
            "Supprimer la clé \(source.displayName)\u{00A0}?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Supprimer la clé", role: .destructive) {
                viewModel.deleteKey(for: source)
                announceResult()
            }
            // Explicite : celui du système sortirait en anglais.
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Triva ne l'utilisera plus. Pour la retrouver, il faudra la saisir à nouveau.")
        }
    }

    // MARK: Actions

    /// Tâche non structurée volontairement : quitter l'écran pendant le test ne l'annule pas, la clé
    /// est enregistrée si elle est valide. C'est ce que l'utilisateur vient de demander.
    private func submitDraft() {
        guard viewModel.entry(for: source).canSubmit(draft: draft) else { return }
        let rawKey = draft
        Task {
            await viewModel.testAndSave(rawKey: rawKey, for: source)
            announceResult()
        }
    }

    /// Sans annonce, un utilisateur VoiceOver ne saurait pas que le test vient de se terminer : le
    /// pied de section ne prend pas le focus (même principe que `SearXNGInstancesView`).
    ///
    /// À la fin de l'action et non dans un `.onChange` sur la `Section` : un modificateur posé sur
    /// une section de `Form` peut se répartir sur ses lignes, et ces lignes changent au moment même
    /// où l'état bascule. L'annonce pourrait se répéter, ou se perdre.
    private func announceResult() {
        guard let feedback = viewModel.entry(for: source).feedback else { return }
        let prefix = feedback.isPositive ? "" : "Erreur : "
        AccessibilityNotification.Announcement("\(source.displayName), \(prefix)\(feedback.message)").post()
    }
}

// MARK: - Composants

/// Titre d'un bouton de test, remplacé par un indicateur pendant le test.
private struct SearchKeyTestLabel: View {
    let title: String
    let isTesting: Bool

    var body: some View {
        if isTesting {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Test en cours…")
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(verbatim: title)
        }
    }
}

/// Résultat de la dernière action. Seul le succès prend la couleur d'accent : même convention que
/// le test d'une instance dans `SearXNGInstancesView`.
private struct SearchKeyFeedbackLabel: View {
    let feedback: SearchKeyFeedback

    var body: some View {
        Label {
            Text(verbatim: feedback.message)
        } icon: {
            if feedback.isPositive {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Aperçus

/// Trousseau factice : jamais le vrai trousseau de l'appareil dans un aperçu.
private final class PreviewSearchKeychain: APIKeyStoring, @unchecked Sendable {
    private var items: [String: String]

    init(items: [String: String] = [:]) {
        self.items = items
    }

    func apiKey(account: String) throws -> String? { items[account] }
    func save(apiKey: String, account: String) throws { items[account] = apiKey }
    func deleteAPIKey(account: String) throws { items[account] = nil }
}

/// Test de clé factice : jamais de vrai réseau dans un aperçu. La clé « refusee » est refusée.
private struct PreviewKeyValidator: SearchKeyValidating {
    let credentials: SearchKeyCredentials

    func validateKey() async throws -> SearchKeyValidationOutcome {
        try await Task.sleep(for: .seconds(1))
        if credentials.apiKey.value == "refusee" { throw WebSearchError.unauthorized }
        return .valid
    }
}

private func previewViewModel(storedKeys: [BYOKSearchSource]) -> SearchKeysViewModel {
    let items = Dictionary(uniqueKeysWithValues: storedKeys.map { ($0.keyAccount, "cle-apercu") })
    return SearchKeysViewModel(
        store: SearchKeyStore(keyStore: PreviewSearchKeychain(items: items)),
        makeValidator: { PreviewKeyValidator(credentials: $0) }
    )
}

#Preview("Aucune clé") {
    NavigationStack {
        SearchKeysView(viewModel: previewViewModel(storedKeys: []))
    }
}

#Preview("Clé Brave enregistrée — sombre") {
    NavigationStack {
        SearchKeysView(viewModel: previewViewModel(storedKeys: [.brave]))
    }
    .preferredColorScheme(.dark)
}
