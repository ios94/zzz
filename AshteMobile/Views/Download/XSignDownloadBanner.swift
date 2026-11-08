//
//  XSignDownloadBanner.swift
//  AshteMobile
//
//  Floating banner at the top of the screen while a store app is downloading:
//  app icon, name, percentage and a ring with a stop button.
//

import SwiftUI

struct XSignDownloadBanner: View {
	@ObservedObject var pipeline: AutoSignPipelineManager

	private var activeKey: String? {
		pipeline.activeStates.first(where: { $0.value == .downloading })?.key
			?? pipeline.activeStates.first(where: { $0.value == .paused })?.key
	}

	var body: some View {
		VStack(spacing: 0) {
			if let key = activeKey {
				banner(
					name: pipeline.bannerInfo[key]?.name ?? AshteBranding.appName,
					iconURL: pipeline.bannerInfo[key]?.iconURL,
					percent: pipeline.downloadProgress[key] ?? 0,
					isPaused: pipeline.activeStates[key] == .paused,
					toggle: {
						if pipeline.activeStates[key] == .paused { pipeline.resumeDownload(key: key) }
						else { pipeline.pauseActiveDownload(key: key) }
					},
					cancel: { pipeline.cancelDownload(key: key) }
				)
				.padding(.horizontal, 40)
				.padding(.top, 2)
				.transition(.move(edge: .top).combined(with: .opacity))
			}
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.animation(.spring(response: 0.45, dampingFraction: 0.82), value: activeKey)
		.environment(\.layoutDirection, .leftToRight)
	}

	private func banner(name: String, iconURL: URL?, percent: Int, isPaused: Bool, toggle: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
		HStack(spacing: 10) {
			AppStoreIconView(url: iconURL, appName: name, size: 38)

			VStack(alignment: .leading, spacing: 0) {
				Text(name)
					.font(.system(size: 15, weight: .semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				Text(verbatim: isPaused ? "Paused · \(percent)%" : "\(percent)%")
					.font(.system(size: 13, weight: .regular))
					.monospacedDigit()
					.foregroundStyle(.primary.opacity(0.9))
					.contentTransition(.numericText())
			}

			Spacer(minLength: 8)

			Button(action: cancel) {
				Image(systemName: "xmark")
					.font(.system(size: 12, weight: .bold))
					.foregroundStyle(.secondary)
					.frame(width: 28, height: 28)
					.background(Color.primary.opacity(0.08), in: Circle())
			}
			.buttonStyle(.plain)

			Button(action: toggle) {
				ZStack {
					Circle()
						.stroke(Color.primary.opacity(0.18), lineWidth: 4)
					Circle()
						.trim(from: 0, to: max(0.03, CGFloat(percent) / 100))
						.stroke(Color.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(.easeOut(duration: 0.25), value: percent)
					Image(systemName: isPaused ? "play.fill" : "pause.fill")
						.font(.system(size: 14, weight: .bold))
						.foregroundStyle(Color.primary)
				}
				.frame(width: 38, height: 38)
				.contentShape(Circle())
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
		)
		.shadow(color: .black.opacity(0.14), radius: 10, y: 4)
	}
}
