//
//  ShareComposerView.swift
//  TrivaShare
//
//  Chantier 2.1 (mission E) : la feuille « Rechercher avec Triva ». Composants système seulement (DESIGN.md : pas de
//  fond forcé, couleurs sémantiques, grille d'espacement, aucun emoji, SF Symbols), pas d'aperçu décodé d'une image :
//  une extension a très peu de mémoire.
//

import SwiftUI

struct ShareComposerView: View {
    @Bindable var model: ShareComposerModel
    let onCancel: () -> Void
    let onDone: () -> Void

    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("Rechercher avec Triva")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task { await model.load() }
    }

    // MARK: Contenu

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading, .saving:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            // Très grande taille de texte : la feuille défile au lieu d'être coupée.
            ScrollView { composer }
        case .done(let message):
            ScrollView { ShareMessageView(systemImage: "checkmark.circle", message: message) }
        case .failed(let message):
            ScrollView { ShareMessageView(systemImage: "exclamationmark.circle", message: message) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let file = model.file {
                ShareFileRow(file: file)
            }
            TextField(
                model.file == nil ? "Ta question" : "Ta question (facultatif)",
                text: $model.question,
                axis: .vertical
            )
            .lineLimit(3...8)
            .focused($isQuestionFocused)
            .textFieldStyle(.roundedBorder)
            if model.file != nil {
                Text("Rien n'est envoyé : le fichier sera joint dans Triva, à toi de valider.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 16)
        .onAppear { isQuestionFocused = model.file == nil }
    }

    // MARK: Barre d'outils

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.phase {
        case .done, .failed:
            ToolbarItem(placement: .confirmationAction) {
                Button("Terminé", action: onDone)
            }
        default:
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuler", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Envoyer à Triva") { Task { await model.send() } }
                    .disabled(!model.canSend)
            }
        }
    }
}

/// Message de confirmation ou d'erreur : un symbole et une phrase, sans décor.
private struct ShareMessageView: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.body)
        }
        .padding(.top, 24)
    }
}

/// Le fichier partagé : son nom, son type et sa taille. Aucun aperçu (mémoire de l'extension).
private struct ShareFileRow: View {
    let file: StagedShareFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.type.isImage ? "photo" : "doc")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.body)
                    .lineLimit(2)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let size = file.byteCount.formatted(.byteCount(style: .file))
        return "\(file.type.isImage ? "Image" : "PDF") · \(size)"
    }
}
