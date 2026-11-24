//
//  SettingsView.swift
//  AshteMobile
//

import SwiftUI
import NimbleViews
import UIKit

// MARK: - View
struct SettingsView: View {
	/// `true` when pushed inside an existing NavigationStack (back button + inline title).
	var embedded: Bool = false

	@AppStorage(AshteL10n.storageKey) private var _language: String = AshteL10n.defaultCode

	// MARK: Body
	var body: some View {
		Group {
			if embedded {
				_content()
					.navigationTitle(AshteL10n.t("Settings"))
					.navigationBarTitleDisplayMode(.inline)
					.toolbar(.visible, for: .navigationBar)
			} else {
				NBNavigationView(AshteL10n.t("Settings")) {
					_content()
				}
			}
		}
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
	}

	@ViewBuilder
	private func _content() -> some View {
		Form {
			_channelSection()
			_featuresSection()
			_resetSection()
		}
	}
}

// MARK: - Modern row icon
private struct SettingsTile: View {
	let systemImage: String
	let color: Color
	
	var body: some View {
		Image(systemName: systemImage)
			.font(.system(size: 15, weight: .semibold))
			.foregroundStyle(.white)
			.frame(width: 30, height: 30)
			.background(
				LinearGradient(
					colors: [color, color.opacity(0.72)],
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				),
				in: RoundedRectangle(cornerRadius: 8, style: .continuous)
			)
	}
}

// MARK: - Sections
extension SettingsView {
	@ViewBuilder
	private func _tile(_ title: String, _ systemImage: String, _ color: Color) -> some View {
		Label {
			Text(title).foregroundStyle(.primary)
		} icon: {
			SettingsTile(systemImage: systemImage, color: color)
		}
	}
	
	@ViewBuilder
	private func _linkRow(_ title: String, _ systemImage: String, _ color: Color) -> some View {
		HStack {
			_tile(title, systemImage, color)
			Spacer()
			Image(systemName: AshteL10n.isRightToLeft ? "chevron.left" : "chevron.right")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.tertiary)
		}
	}
	
	@ViewBuilder
	private func _channelSection() -> some View {
		Section {
			// Channel / logo
			Button {
				_open(AshteBranding.telegramURL)
			} label: {
				HStack(spacing: 14) {
					_logo(size: 56)
						.shadow(color: .black.opacity(0.15), radius: 6, y: 3)
					VStack(alignment: .leading, spacing: 3) {
						Text(AshteBranding.appName)
							.font(.title3.weight(.bold))
							.foregroundStyle(.primary)
						Text(AshteL10n.t("Official App Channel"))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
					Spacer()
					Image(systemName: AshteL10n.isRightToLeft ? "chevron.left" : "chevron.right")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.tertiary)
				}
				.padding(.vertical, 6)
			}
		}
		
		Section {
			NavigationLink {
				CertificatesView()
					.navigationTitle(AshteL10n.t("Certificates"))
			} label: {
				_tile(AshteL10n.t("Certificates"), "checkmark.seal.fill", .green)
			}

			Button {
				if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
					UIApplication.shared.open(url)
				}
			} label: {
				_linkRow(AshteL10n.t("Notifications"), "bell.badge.fill", .red)
			}

			NavigationLink {
				AppearanceView()
			} label: {
				_tile(AshteL10n.t("Appearance"), "paintbrush.fill", .indigo)
			}

			NavigationLink {
				LanguageView()
			} label: {
				_tile(AshteL10n.t("Translation"), "globe", .blue)
			}
		}
		
		Section {
			if let youtube = AshteBranding.youtubeURL {
				Button { _open(youtube) } label: { _linkRow("YouTube", "play.rectangle.fill", .red) }
			}

			if AshteBranding.telegramURL != nil {
				Button { _open(AshteBranding.telegramURL) } label: { _linkRow("Telegram", "paperplane.fill", .cyan) }
			}

			Button { _open(AshteBranding.instagramURL) } label: { _linkRow("Instagram", "camera.fill", .pink) }

			NavigationLink {
				AboutView()
			} label: {
				_tile(AshteL10n.t("Developer"), "chevron.left.forwardslash.chevron.right", .gray)
			}
		}
	}

	@ViewBuilder
	private func _featuresSection() -> some View {
		NBSection(AshteL10n.t("Features")) {
			NavigationLink(destination: AshteMySourcesView()) {
				_tile(AshteL10n.t("My Sources"), "shippingbox.fill", .orange)
			}
			NavigationLink(destination: ConfigurationView()) {
				_tile(AshteL10n.t("Signing Options"), "signature", .purple)
			}
			NavigationLink(destination: ArchiveView()) {
				_tile(AshteL10n.t("Archive & Compression"), "archivebox.fill", .brown)
			}
			NavigationLink(destination: InstallationView()) {
				_tile(AshteL10n.t("Installation"), "arrow.down.circle.fill", .teal)
			}
		}
	}

	@ViewBuilder
	private func _resetSection() -> some View {
		Section {
			NavigationLink(destination: ResetView()) {
				_tile(AshteL10n.t("Reset"), "trash.fill", .red)
			}
		} footer: {
			Text(AshteL10n.t("Reset the applications sources, certificates, apps, and general contents."))
		}
	}

	// MARK: Helpers
	@ViewBuilder
	private func _logo(size: CGFloat) -> some View {
		AsyncImage(url: AshteBranding.logoURL) { image in
			image.resizable().scaledToFill()
		} placeholder: {
			Image("AshteLogo")
				.resizable()
				.scaledToFill()
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
	}

	private func _open(_ url: URL?) {
		guard let url else { return }
		UIApplication.shared.open(url)
	}
}
