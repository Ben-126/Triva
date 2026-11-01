//
//  LibraryView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import SwiftUI

// MARK: - Regroupement par période

/// Les trois périodes de la Bibliothèque, dans l'ordre d'affichage.
nonisolated enum LibraryPeriod: CaseIterable, Identifiable, Hashable, Sendable {
    case today
    case thisWeek
    case older

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Aujourd'hui"
        case .thisWeek: "Cette semaine"
        case .older: "Plus ancien"
        }
    }

    /// Période de `date`, vue depuis `now`.
    ///
    /// « Cette semaine » est la semaine CALENDAIRE de l'utilisateur (lundi en
    /// France, via `calendar.firstWeekday`), pas « les 7 derniers jours » : le
    /// libellé dit « cette semaine », il doit donc dire vrai. Conséquence
    /// assumée : un lundi, la section ne contient rien d'autre que ce
    /// qu'affiche déjà « Aujourd'hui », et elle disparaît.
    ///
    /// Une date future (horloge reculée) est rangée avec aujourd'hui plutôt
    /// que de créer une section absurde.
    static func of(_ date: Date, now: Date, calendar: Calendar) -> LibraryPeriod {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        // `dateInterval(of:for:)` ne renvoie `nil` que pour un calendrier qui
        // ignore la notion de semaine : on se rabat alors sur deux périodes.
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        return date >= startOfWeek ? .thisWeek : .older
    }
}

/// Une ligne de la Bibliothèque : une COPIE en valeur, jamais un
/// `StoredConversation`.
///
/// C'est la parade au piège documenté sur `ChatHistoryStore` : après
/// `delete(_:)`, la référence supprimée reste lisible (`isDeleted` ne le
/// signale pas) et la toucher sur un store sur disque peut être brutal. Une
/// vue qui ne garde que des valeurs n'a jamais de conversation fantôme à
/// afficher, quel que soit le moment où la suppression a eu lieu.
nonisolated struct LibraryConversationSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    /// Critère de tri du store ET de regroupement : regrouper sur `createdAt`
    /// ferait tomber une vieille conversation relancée aujourd'hui (en tête de
    /// liste) dans « Plus ancien », et les sections s'entrelaceraient.
    let updatedAt: Date
    /// Aperçu de la dernière réponse, `nil` si aucune réponse n'a été
    /// enregistrée (génération interrompue avant le premier mot).
    let preview: String?
}

nonisolated struct LibrarySection: Identifiable, Hashable, Sendable {
    let period: LibraryPeriod
    let conversations: [LibraryConversationSummary]

    var id: LibraryPeriod { period }
}

nonisolated enum LibraryGrouping {
    /// Sections non vides, dans l'ordre de `LibraryPeriod.allCases`.
    /// `Dictionary(grouping:by:)` conserve l'ordre d'entrée dans chaque groupe,
    /// donc l'ordre du store (activité la plus récente d'abord) est préservé.
    static func sections(
        for conversations: [LibraryConversationSummary],
        now: Date,
        calendar: Calendar
    ) -> [LibrarySection] {
        let grouped = Dictionary(grouping: conversations) { conversation in
            LibraryPeriod.of(conversation.updatedAt, now: now, calendar: calendar)
        }
        return LibraryPeriod.allCases.compactMap { period in
            guard let members = grouped[period], !members.isEmpty else { return nil }
            return LibrarySection(period: period, conversations: members)
        }
    }

    /// Copie des sections sans la conversation `id` ; une section vidée
    /// disparaît (jamais d'en-tête « Aujourd'hui » au-dessus de rien).
    static func removing(_ id: UUID, from sections: [LibrarySection]) -> [LibrarySection] {
        sections.compactMap { section in
            let remaining = section.conversations.filter { $0.id != id }
            return remaining.isEmpty ? nil : LibrarySection(period: section.period, conversations: remaining)
        }
    }
}

// MARK: - État de l'écran

/// Résultat d'un chargement : les sections et l'instant auquel elles ont été
/// calculées (référence commune des sections et des libellés de date).
private struct LibrarySnapshot: Equatable {
    let sections: [LibrarySection]
    let referenceDate: Date

    var isEmpty: Bool { sections.isEmpty }

    func removing(_ id: UUID) -> LibrarySnapshot {
        LibrarySnapshot(sections: LibraryGrouping.removing(id, from: sections), referenceDate: referenceDate)
    }
}

private enum LibraryPhase: Equatable {
    case loading
    case loaded(LibrarySnapshot)
    case failed(message: String)
}

/// Tout ce qui doit relancer un chargement : la requête, chaque écriture
/// réussie du store (`revision`) et le bouton « Réessayer ».
private struct LibraryLoadKey: Equatable {
    let query: String
    let revision: Int
    let retry: Int
}

// MARK: - Écran

/// Bibliothèque : l'historique local des conversations (1.9).
///
/// Portage de `src/app/library/page.tsx` (web) : titre, date relative, puis
/// suppression. Écarts assumés : aperçu de la dernière réponse (le web n'en a
/// pas, mais une liste de titres seuls est difficile à parcourir), recherche
/// dans les titres ET le contenu (`ChatHistoryStore.conversations(matching:)`),
/// regroupement par période, et pas de compteur « 12 chats » (DESIGN.md : pas
/// de chiffre qui ne sert à rien).
///
/// ## Données
/// L'écran ne lit SwiftData qu'à travers `ChatHistoryStore` et ne garde que
/// des copies en valeur (`LibraryConversationSummary`). Il se recharge quand
/// la requête change et à chaque écriture réussie du store (`revision`) : la
/// Bibliothèque reste juste même affichée à côté du chat.
///
/// ## Intégration (étape suivante)
/// - Passer l'INSTANCE UNIQUE de `ChatHistoryStore` de l'app : `revision` est
///   propre à chaque instance, donc une instance distincte de celle du chat ne
///   verrait jamais ses écritures en direct.
/// - `onOpenConversation` reçoit l'`id` métier, à résoudre par
///   `ChatHistoryStore.conversation(with:)`. Sans closure, les lignes ne sont
///   pas tapables plutôt que de faire semblant de l'être.
/// - `onConversationDeleted` prévient après une suppression réussie : si
///   c'était la conversation ouverte dans le chat, celui-ci doit repartir à
///   neuf, sinon il écrirait dans un objet supprimé.
struct LibraryView: View {
    @State private var store: ChatHistoryStore
    private let isStorageVolatile: Bool
    private let onOpenConversation: (@MainActor (UUID) -> Void)?
    private let onConversationDeleted: @MainActor (UUID) -> Void

    @State private var query = ""
    @State private var phase: LibraryPhase = .loading
    @State private var retryCount = 0
    @State private var excerptCache = AnswerExcerptCache()
    @State private var pendingDeletion: LibraryConversationSummary?
    @State private var deletionErrorMessage: String?

    @Environment(\.calendar) private var calendar

    /// Délai de frappe avant de lancer une recherche. `conversations(matching:)`
    /// normalise le texte de TOUS les messages de l'historique sur le main
    /// actor : une fois par pause de frappe, pas une fois par caractère.
    private static let searchDebounce: Duration = .milliseconds(250)

    /// Les valeurs par défaut existent pour que `TrivaRootView` compile avant
    /// l'intégration (elle appelle encore `LibraryView()`). Elles créent une
    /// instance de store DISTINCTE de celle du chat — voir « Intégration ». Un
    /// aperçu doit toujours passer un store en mémoire et une valeur explicite
    /// pour `isStorageVolatile` : les défauts ouvrent la vraie base sur disque.
    init(
        store: ChatHistoryStore = ChatHistoryStore(container: TrivaModelContainer.shared),
        isStorageVolatile: Bool = TrivaModelContainer.isUsingVolatileFallback,
        onOpenConversation: (@MainActor (UUID) -> Void)? = nil,
        onConversationDeleted: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        _store = State(initialValue: store)
        self.isStorageVolatile = isStorageVolatile
        self.onOpenConversation = onOpenConversation
        self.onConversationDeleted = onConversationDeleted
    }

    var body: some View {
        NavigationStack {
            LibraryContentView(
                phase: phase,
                query: query,
                isStorageVolatile: isStorageVolatile,
                onOpen: onOpenConversation,
                onRequestDeletion: { pendingDeletion = $0 },
                onRetry: { retryCount += 1 }
            )
            .navigationTitle("Bibliothèque")
            .searchable(text: $query, prompt: Text("Rechercher dans l'historique"))
            .task(id: LibraryLoadKey(query: query, revision: store.revision, retry: retryCount)) {
                await reload()
            }
            .confirmationDialog(
                "Supprimer cette conversation ?",
                isPresented: isConfirmingDeletion,
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { summary in
                Button("Supprimer", role: .destructive) { delete(summary) }
                // Fourni explicitement : celui que le système ajouterait de
                // lui-même sortirait en anglais (aucune localisation fr).
                Button("Annuler", role: .cancel) {}
            } message: { _ in
                Text("Elle sera effacée de cet appareil. Ses réponses mises en favori restent dans Favoris.")
            }
            .alert(deletionErrorMessage ?? "", isPresented: isShowingDeletionError) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    // MARK: Chargement

    /// Recharge la liste. Synchrone une fois le délai passé : aucune
    /// suspension entre la lecture du store et l'affectation de `phase`, donc
    /// pas d'état intermédiaire à gérer.
    private func reload() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            do {
                try await Task.sleep(for: Self.searchDebounce)
            } catch {
                // Annulée par `.task(id:)` : une frappe plus récente a pris le
                // relais. Surtout ne pas lancer la lecture d'une requête périmée.
                return
            }
        }

        let now = Date.now
        do {
            let summaries = try store.conversations(matching: trimmedQuery).map(summary(of:))
            if trimmedQuery.isEmpty {
                excerptCache.retainOnly(Set(summaries.map(\.id)))
            }
            let sections = LibraryGrouping.sections(for: summaries, now: now, calendar: calendar)
            phase = .loaded(LibrarySnapshot(sections: sections, referenceDate: now))
        } catch let error as ChatHistoryStoreError {
            phase = .failed(message: error.userFacingMessage)
        } catch {
            phase = .failed(message: "Impossible de lire l'historique.")
        }
    }

    private func summary(of conversation: StoredConversation) -> LibraryConversationSummary {
        let preview = excerptCache.excerpt(for: conversation.id, version: conversation.updatedAt) {
            Self.latestAnswerText(in: conversation).flatMap { AnswerExcerpt.make(from: $0) }
        }
        return LibraryConversationSummary(
            id: conversation.id,
            title: conversation.title,
            updatedAt: conversation.updatedAt,
            preview: preview
        )
    }

    /// Dernière réponse par `order` (et non par date, voir
    /// `StoredMessage.order`). Le maximum en un passage plutôt que
    /// `orderedMessages.last` : inutile de trier toute la conversation pour un
    /// seul message.
    private static func latestAnswerText(in conversation: StoredConversation) -> String? {
        conversation.messages
            .filter { $0.role == .assistant }
            .max { $0.order < $1.order }?
            .text
    }

    // MARK: Suppression

    /// La conversation est relue par son `id` juste avant d'être supprimée :
    /// aucune référence de modèle ne vit dans l'état de la vue. Une
    /// conversation déjà absente (supprimée ailleurs entre-temps) n'est pas
    /// une erreur : le résultat voulu est atteint.
    private func delete(_ summary: LibraryConversationSummary) {
        do {
            if let conversation = try store.conversation(with: summary.id) {
                try store.delete(conversation)
            }
        } catch {
            // Message fixe, jamais `diagnosticDescription` : le détail
            // technique n'a rien à faire à l'écran.
            deletionErrorMessage = "Impossible de supprimer cette conversation."
            return
        }
        // Retrait immédiat, sans attendre le rechargement déclenché par
        // `revision` : la ligne balayée ne doit pas réapparaître un instant.
        if case .loaded(let snapshot) = phase {
            withAnimation { phase = .loaded(snapshot.removing(summary.id)) }
        }
        onConversationDeleted(summary.id)
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
            get: { deletionErrorMessage != nil },
            set: { isPresented in
                if !isPresented { deletionErrorMessage = nil }
            }
        )
    }
}

// MARK: - Contenu (présentation pure)

/// La liste et ses états, sans aucun accès aux données : c'est ce que les
/// aperçus alimentent avec des valeurs factices (0, 1 et 500 lignes, erreur,
/// stockage volatil).
///
/// `List` et non `ScrollView` + `VStack` : elle est paresseuse (500 lignes sans
/// effort) et c'est elle qui porte le balayage. Pas de verre sur les lignes :
/// c'est du texte statique, et 500 calques de verre coûteraient cher.
///
/// Les états « vide », « aucun résultat » et « erreur » sont en `overlay` : la
/// `List` reste en place, et avec elle le champ de recherche et le titre.
private struct LibraryContentView: View {
    let phase: LibraryPhase
    let query: String
    let isStorageVolatile: Bool
    let onOpen: (@MainActor (UUID) -> Void)?
    let onRequestDeletion: @MainActor (LibraryConversationSummary) -> Void
    let onRetry: @MainActor () -> Void

    private static let volatileNotice =
        "L'historique ne peut pas être enregistré sur cet appareil. Il sera perdu à la fermeture de Triva."

    var body: some View {
        List {
            if let snapshot {
                if isStorageVolatile, !snapshot.isEmpty {
                    StorageVolatilityNotice(text: Self.volatileNotice)
                }
                ForEach(snapshot.sections) { section in
                    Section {
                        ForEach(section.conversations) { conversation in
                            row(for: conversation, referenceDate: snapshot.referenceDate)
                        }
                    } header: {
                        HistorySectionHeader(title: section.period.title)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { overlay }
    }

    private var snapshot: LibrarySnapshot? {
        if case .loaded(let snapshot) = phase { snapshot } else { nil }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Lignes

    /// Balayage ET menu contextuel sur les deux plateformes : le balayage est
    /// le geste attendu sur iOS, le clic droit celui du Mac, et chacun existe
    /// aussi sur l'autre (appui long sur iOS, balayage au trackpad sur Mac).
    private func row(for conversation: LibraryConversationSummary, referenceDate: Date) -> some View {
        rowContent(for: conversation, referenceDate: referenceDate)
            .listRowInsets(HistoryListLayout.rowInsets)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteButton(for: conversation)
            }
            .contextMenu {
                deleteButton(for: conversation)
            }
    }

    @ViewBuilder
    private func rowContent(for conversation: LibraryConversationSummary, referenceDate: Date) -> some View {
        let label = LibraryRowLabel(conversation: conversation, referenceDate: referenceDate)
        if let onOpen {
            Button {
                onOpen(conversation.id)
            } label: {
                label
            }
            // Sur Mac, le style par défaut dessinerait un bouton à bordure dans
            // la ligne ; sur iOS, il donne la surbrillance de ligne attendue.
            #if os(macOS)
            .buttonStyle(.plain)
            #endif
            .accessibilityHint("Ouvre la conversation")
        } else {
            label
        }
    }

    /// Rôle destructif : rouge système et annonce VoiceOver adaptée, sans
    /// couleur écrite en dur. La suppression elle-même attend la confirmation.
    private func deleteButton(for conversation: LibraryConversationSummary) -> some View {
        Button(role: .destructive) {
            onRequestDeletion(conversation)
        } label: {
            Label("Supprimer", systemImage: "trash")
        }
    }

    // MARK: États

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .loading:
            // Lecture locale quasi instantanée : un indicateur ne ferait que
            // clignoter pendant une image.
            EmptyView()
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } actions: {
                // Seule action de l'écran dans cet état : action principale
                // (DESIGN.md), comme dans Découvrir et les Favoris.
                Button("Réessayer", action: onRetry)
                    .buttonStyle(.glassProminent)
            }
        case .loaded(let snapshot) where snapshot.isEmpty:
            if trimmedQuery.isEmpty {
                ContentUnavailableView {
                    Label("Aucune conversation", systemImage: "clock")
                } description: {
                    Text(verbatim: isStorageVolatile ? Self.volatileNotice : "Tes conversations apparaîtront ici.")
                }
            } else {
                // Pas `ContentUnavailableView.search` : son texte vient du
                // système et sortirait en anglais (aucune localisation fr).
                ContentUnavailableView {
                    Label("Aucun résultat", systemImage: "magnifyingglass")
                } description: {
                    Text(verbatim: "Aucune conversation ne correspond à «\u{00A0}\(trimmedQuery)\u{00A0}».")
                }
            }
        case .loaded:
            EmptyView()
        }
    }
}

/// Titre, aperçu, date : empilés plutôt qu'en ligne, pour que rien ne se
/// dispute la largeur, même en Dynamic Type d'accessibilité.
private struct LibraryRowLabel: View {
    let conversation: LibraryConversationSummary
    let referenceDate: Date

    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: conversation.title)
                .font(.headline)
                // Explicite : dans une `List` iOS, un `Button` teinte son
                // libellé à l'accent.
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let preview = conversation.preview {
                Text(verbatim: preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Aucune réponse enregistrée")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            Text(verbatim: RelativeDateLabel.text(for: conversation.updatedAt, relativeTo: referenceDate, calendar: calendar))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Toute la ligne est cliquable sur Mac (style `.plain`), pas seulement
        // les glyphes.
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Aperçus

/// Données factices. Le store en mémoire ne sert qu'à l'aperçu de l'écran
/// complet ; tous les autres états passent par `LibraryContentView` avec des
/// valeurs pures (500 lignes s'affichent sans rien écrire en base).
private enum LibraryPreviewData {
    static let referenceDate = Date.now

    private static let titles = [
        "Comment fonctionne la photosynthèse ?",
        "Quelle est la hauteur de la tour Eiffel ?",
        "Comparer SwiftData et Core Data pour une app locale",
        "Recette de la pâte à crêpes",
        "Pourquoi le ciel est-il bleu ?",
    ]

    private static let previews: [String?] = [
        "La photosynthèse convertit l'énergie lumineuse en énergie chimique, dans les chloroplastes des cellules végétales.",
        "330 mètres avec ses antennes.",
        "SwiftData s'appuie sur Core Data et propose une API déclarative avec la macro @Model.",
        nil,
        "La lumière bleue est davantage diffusée par les molécules de l'air : c'est la diffusion Rayleigh.",
    ]

    /// Une conversation toutes les 18 heures en remontant le temps : 500
    /// lignes couvrent environ un an, donc les trois sections.
    static func snapshot(count: Int) -> LibrarySnapshot {
        let summaries = (0..<count).map { index in
            LibraryConversationSummary(
                id: UUID(),
                title: titles[index % titles.count],
                updatedAt: referenceDate.addingTimeInterval(-Double(index) * 18 * 3_600),
                preview: previews[index % previews.count]
            )
        }
        let sections = LibraryGrouping.sections(for: summaries, now: referenceDate, calendar: .current)
        return LibrarySnapshot(sections: sections, referenceDate: referenceDate)
    }

    /// Store en mémoire avec quelques conversations réelles, dont une réponse
    /// avec `<think>` et citations, et une question restée sans réponse.
    static func seededStore() -> ChatHistoryStore {
        let samples: [(question: String, answer: String?, hoursAgo: Double)] = [
            ("Comment fonctionne la photosynthèse ?",
             "## En bref\nLa **photosynthèse** convertit l'énergie lumineuse en énergie chimique[1]. Elle a lieu dans les chloroplastes[2].", 1),
            ("Quelle est la hauteur de la tour Eiffel ?",
             "<think>L'utilisateur veut la hauteur actuelle.</think>La tour Eiffel mesure 330 mètres avec ses antennes[1].", 30),
            ("Résume l'actualité tech de la semaine", nil, 54),
            ("Comparer SwiftData et Core Data",
             "- SwiftData s'appuie sur Core Data\n- API déclarative avec `@Model`", 24 * 12),
        ]
        do {
            let store = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory())
            for sample in samples {
                let date = referenceDate.addingTimeInterval(-sample.hoursAgo * 3_600)
                let conversation = try store.createConversation(firstQuestion: sample.question, now: date)
                try store.appendUserMessage(to: conversation, text: sample.question, now: date)
                if let answer = sample.answer {
                    try store.appendAssistantMessage(to: conversation, text: answer, now: date)
                }
            }
            return store
        } catch {
            // Même politique que `TrivaModelContainer` : un conteneur en
            // mémoire qui échoue trahit un schéma invalide, donc un bug de
            // développement — jamais une donnée utilisateur.
            preconditionFailure("Aperçu de la Bibliothèque impossible : \(error)")
        }
    }
}

private struct LibraryContentPreview: View {
    let phase: LibraryPhase
    var query = ""
    var isStorageVolatile = false

    var body: some View {
        NavigationStack {
            LibraryContentView(
                phase: phase,
                query: query,
                isStorageVolatile: isStorageVolatile,
                onOpen: { _ in },
                onRequestDeletion: { _ in },
                onRetry: {}
            )
            .navigationTitle("Bibliothèque")
        }
    }
}

#Preview("Écran complet — store en mémoire") {
    LibraryView(
        store: LibraryPreviewData.seededStore(),
        isStorageVolatile: false,
        onOpenConversation: { _ in }
    )
}

#Preview("500 conversations") {
    LibraryContentPreview(phase: .loaded(LibraryPreviewData.snapshot(count: 500)))
}

#Preview("Une conversation") {
    LibraryContentPreview(phase: .loaded(LibraryPreviewData.snapshot(count: 1)))
}

#Preview("Vide") {
    LibraryContentPreview(phase: .loaded(LibraryPreviewData.snapshot(count: 0)))
}

#Preview("Aucun résultat") {
    LibraryContentPreview(phase: .loaded(LibraryPreviewData.snapshot(count: 0)), query: "fusion froide")
}

#Preview("Erreur de lecture") {
    LibraryContentPreview(phase: .failed(message: "Impossible de lire l'historique."))
}

#Preview("Stockage volatil — sombre") {
    LibraryContentPreview(phase: .loaded(LibraryPreviewData.snapshot(count: 3)), isStorageVolatile: true)
        .preferredColorScheme(.dark)
}
