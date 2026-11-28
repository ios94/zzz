//
//  AppStoreScreenshotCard.swift
//  AshteMobile
//
//  Screenshots section of the app page: every screenshot gets its own size from its
//  aspect ratio (tall phone shots or wide landscape shots), rounded corners, no grey frame.
//

import SwiftUI
import NukeUI
import Nuke

// MARK: - Heading ("Screenshots" with the gradient accent bar)
struct AppStoreScreenshotsHeader: View {
	let title: String

	var body: some View {
		HStack(spacing: 10) {
			Capsule()
				.fill(
					LinearGradient(
						colors: [Color(red: 0.55, green: 0.42, blue: 0.97), Color(red: 0.97, green: 0.40, blue: 0.62)],
						startPoint: .top,
						endPoint: .bottom
					)
				)
				.frame(width: 5, height: 28)

			Text(title)
				.font(.title2.bold())
				.foregroundStyle(.primary)
		}
	}
}

// MARK: - One screenshot
struct AppStoreScreenshotCard: View {
	let url: URL
	var portraitHeight: CGFloat = 420

	private var _maxWidth: CGFloat { UIScreen.main.bounds.width - 36 }

	var body: some View {
		LazyImage(url: url) { state in
			if let container = state.imageContainer {
				let size = _cardSize(for: container.image.size)
				Image(uiImage: container.image)
					.resizable()
					.scaledToFill()
					.frame(width: size.width, height: size.height)
					.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
					.overlay(
						RoundedRectangle(cornerRadius: 22, style: .continuous)
							.stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
					)
			} else if state.error != nil {
				AppStoreScreenshotPlaceholder(showsProgress: false)
			} else {
				AppStoreScreenshotPlaceholder(showsProgress: true)
			}
		}
		.processors([.resize(size: CGSize(width: 1000, height: 1000))])
	}

	/// Tall screenshots keep a fixed height; wide ones take the full width.
	private func _cardSize(for imageSize: CGSize) -> CGSize {
		guard imageSize.width > 0, imageSize.height > 0 else {
			return CGSize(width: portraitHeight * 0.5, height: portraitHeight)
		}
		let ratio = imageSize.width / imageSize.height

		if ratio >= 1 {
			let r = min(ratio, 2.4)
			let width = _maxWidth
			return CGSize(width: width, height: width / r)
		} else {
			let r = max(ratio, 0.3)
			let width = min(portraitHeight * r, _maxWidth)
			return CGSize(width: width, height: width / r)
		}
	}
}

// MARK: - Placeholder while loading
struct AppStoreScreenshotPlaceholder: View {
	var showsProgress: Bool

	var body: some View {
		RoundedRectangle(cornerRadius: 22, style: .continuous)
			.fill(Color.primary.opacity(0.06))
			.frame(width: 210, height: 420)
			.overlay {
				if showsProgress {
					ProgressView()
				} else {
					Image(systemName: "photo")
						.font(.largeTitle)
						.foregroundStyle(.tertiary)
				}
			}
	}
}

// MARK: - Warm the image cache so screenshots are already on disk when an app page opens
@MainActor
enum AppStoreScreenshotPrefetch {
	private static var prefetcher: ImagePrefetcher?
	private static var lastKey = ""

	static func warm(_ items: [AppStoreAppItem], apps: Int = 6, perApp: Int = 3) {
		let urls = items.prefix(apps).flatMap { $0.screenshots.prefix(perApp) }
		let key = urls.map(\.absoluteString).joined(separator: "|")
		guard !urls.isEmpty, key != lastKey else { return }
		lastKey = key
		prefetcher?.stopPrefetching()
		let next = ImagePrefetcher(pipeline: ImagePipeline.shared, destination: .diskCache, maxConcurrentRequestCount: 3)
		next.priority = .low
		next.startPrefetching(with: Array(urls))
		prefetcher = next
	}
}
