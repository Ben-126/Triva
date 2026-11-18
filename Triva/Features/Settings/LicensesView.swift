//
//  LicensesView.swift
//  Triva
//
//  Mission C3 (audit légal, constats 25 et 26 ; M5).
//

import SwiftUI

/// Écran « Licences et attributions » : liste groupée (logiciels libres, modèles d'IA, sources de
/// données, flux de Découvrir), recherche, et pour chaque ligne le texte complet de la licence et
/// le NOTICE. Poussé dans la pile des Réglages (pas de `NavigationStack` ici).
struct LicensesView: View {
    private enum Phase {
        case loading
        case loaded(LicenseCatalog)
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var query = ""

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                // Validé par Ben le 2026-11-18 (texte légal)
                ContentUnavailableView(
                    "Licences indisponibles",
                    systemImage: "doc.text",
                    description: Text("Impossible de lire la liste des licences. Elle est aussi publiée sur la page Licences du site de Triva.")
                )
            case .loaded(let catalog):
                list(catalog)
            }
        }
        .navigationTitle(AboutText.licensesTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard case .loading = phase else { return }
            phase = (try? LicenseCatalog.load()).map(Phase.loaded) ?? .failed
        }
    }

    private func list(_ catalog: LicenseCatalog) -> some View {
        let sections = catalog.filtered(by: query)
        return List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        // Destination dans le lien (et non `navigationDestination(for:)`) : la valeur
                        // déclarée sur la liste, créée après le chargement du catalogue, ne poussait
                        // rien sur iPhone (constaté au simulateur, mission V3).
                        NavigationLink {
                            LicenseDetailView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                if !entry.summary.isEmpty {
                                    Text(entry.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } header: {
                    Text(section.kind.title)
                } footer: {
                    if let footer = section.kind.footer { Text(footer) }
                }
            }
        }
        .searchable(text: $query, prompt: "Rechercher")
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .accessibilityIdentifier("settings.licenses.list")
    }
}

/// Détail d'une ligne : droit d'auteur, remarques, liens, NOTICE puis texte complet de la licence.
struct LicenseDetailView: View {
    let entry: LicenseCatalog.Entry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .foregroundStyle(.secondary)
                    }
                    if let copyright = entry.copyright {
                        Text(copyright)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(entry.notes, id: \.self) { note in
                    Text(note)
                }

                if !entry.links.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entry.links, id: \.url) { link in
                            Link(link.label, destination: link.url)
                        }
                    }
                }

                if let notice = entry.notice {
                    block(title: "Avis (NOTICE)", text: notice)
                }
                if let text = entry.licenseText {
                    block(title: "Texte de la licence", text: text)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(entry.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("settings.licenses.detail")
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            // Texte intégral, tel que publié par les auteurs : pas de mise en forme, sélectionnable.
            Text(text)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }
}
