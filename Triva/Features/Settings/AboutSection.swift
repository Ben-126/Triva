//
//  AboutSection.swift
//  Triva
//
//  Mission C3 (audit légal, constats 1, 5, 25 ; M3).
//

import SwiftUI

/// Dernière section des Réglages, « À propos et mentions légales » (`textes/ecrans.md`, section E).
///
/// Les pages web (confidentialité, conditions, mentions, assistance) s'ouvrent par l'`openURL` de
/// l'environnement, donc dans le navigateur intégré (`opensLinksInApp`). « Signaler un problème »
/// prépare un e-mail si l'adresse de support est définie, sinon ouvre la page d'assistance
/// (`LegalLinks.reportDestination`). « Licences et attributions » pousse l'écran natif.
struct AboutSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            webRow(AboutText.privacyTitle, AboutText.privacySubtitle, page: .privacy, id: "settings.about.privacy")
            webRow(AboutText.termsTitle, AboutText.termsSubtitle, page: .terms, id: "settings.about.terms")
            webRow(AboutText.legalNoticeTitle, AboutText.legalNoticeSubtitle, page: .legalNotice, id: "settings.about.legal")
            NavigationLink(value: SettingsRoute.licenses) {
                RowLabel(title: AboutText.licensesTitle, subtitle: AboutText.licensesSubtitle)
            }
            .accessibilityIdentifier("settings.about.licenses")
            webRow(AboutText.supportTitle, AboutText.supportSubtitle, page: .support, id: "settings.about.support")
            Button {
                openURL(LegalLinks.reportDestination())
            } label: {
                RowLabel(title: AboutText.reportTitle, subtitle: AboutText.reportSubtitle, opensExternally: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.about.report")
        } header: {
            Text(AboutText.header)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(AboutText.versionLine())
                    .accessibilityIdentifier("settings.about.version")
                // Validé par Ben le 2026-11-18 (texte légal)
                Text(AboutText.footer)
            }
        }
    }

    private func webRow(_ title: String, _ subtitle: String, page: LegalLinks.Page, id: String) -> some View {
        Button {
            openURL(LegalLinks.url(for: page))
        } label: {
            RowLabel(title: title, subtitle: subtitle, opensExternally: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// Titre et sous-titre d'une ligne. Les lignes qui ouvrent une page web portent la flèche
    /// « sortie » du système ; VoiceOver lit le titre puis le sous-titre, et annonce un bouton.
    private struct RowLabel: View {
        let title: String
        let subtitle: String
        var opensExternally = false

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if opensExternally {
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }
}
