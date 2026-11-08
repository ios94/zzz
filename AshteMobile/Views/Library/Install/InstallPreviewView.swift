//
//  InstallPreview.swift
//  AshteMobile
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import IDeviceSwift
import OSLog

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("AshteMobile.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@AppStorage("AshteMobile.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("AshteMobile.serverMethod") private var _serverMethod: Int = 0
	@State private var _isWebviewPresenting = false
	@State private var progressTask: Task<Void, Never>?
    @State private var installRequestWatchdog: Task<Void, Never>?
    @State private var didRequestInstallation = false
    @State private var didStartPreparation = false
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	/// Store apps (Get button): delete the signed copy from the Library after installation.
	var removeAfterInstall: Bool = false
	
	init(app: AppInfoPresentable, isSharing: Bool = false, removeAfterInstall: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		self.removeAfterInstall = removeAfterInstall
		let viewModel = InstallerStatusViewModel(isIdevice: UserDefaults.standard.integer(forKey: "AshteMobile.installationMethod") == 1)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 0) {
			Spacer(minLength: 12)
			InstallProgressView(app: app, viewModel: viewModel)
			Spacer(minLength: 12)
			_button()
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(
			LinearGradient(
				colors: [Color.accentColor.opacity(0.18), Color(UIColor.systemBackground)],
				startPoint: .top,
				endPoint: .center
			)
			.background(Color(UIColor.systemBackground))
			.ignoresSafeArea()
		)
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.onReceive(viewModel.$status) { newStatus in
			if _installationMethod == 0 {
				if case .ready = newStatus, !didRequestInstallation {
					didRequestInstallation = true
					_launchOTAInstall()
				}
				
				if case .sendingManifest = newStatus {
					installRequestWatchdog?.cancel()
					installRequestWatchdog = nil
				}

				if case .sendingPayload = newStatus {
					installRequestWatchdog?.cancel()
					installRequestWatchdog = nil
					_isWebviewPresenting = false
				}
				
				if case .installing = newStatus {
					if progressTask == nil, let bundleID = app.identifier, !bundleID.isEmpty {
						progressTask = startInstallProgressPolling(
							bundleID: bundleID,
							viewModel: viewModel
						)
					}
				}
				
				switch newStatus {
				case .completed, .broken(_):
					progressTask?.cancel()
					progressTask = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
		}
		#endif
		
        .onDisappear {
            installRequestWatchdog?.cancel()
            installRequestWatchdog = nil
            progressTask?.cancel()
			progressTask = nil
			
			if removeAfterInstall, let uuid = app.uuid {
				switch viewModel.status {
				case .completed, .broken(_):
					AutoSignPipelineManager.shared.cleanupAfterInstall(uuid: uuid)
				default:
					break
				}
			}
			
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					Text(AshteL10n.t("Open"))
						.font(.headline)
						.foregroundStyle(.white)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 14)
						.background(Color.accentColor, in: Capsule())
				}
				.buttonStyle(.plain)
				.padding(.horizontal, 32)
				.compatTransition()
			}
		}
		.frame(height: 52)
		.padding(.bottom, 24)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
        guard !didStartPreparation else { return }
        if !isSharing && (app.identifier ?? "").isEmpty {
            viewModel.status = .broken(NSError(domain: "XSign.Installation", code: 2, userInfo: [NSLocalizedDescriptionKey: AshteL10n.t("معرّف التطبيق مفقود. راجع معلومات التطبيق ثم أعد توقيعه.")]))
            return
        }
        didStartPreparation = true
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier || _installationMethod == 1 else {
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			)
			return
		}
				
        let sharing = isSharing
        let method = _installationMethod
        let useShareSheet = _useShareSheet
        let currentBundleID = Bundle.main.bundleIdentifier ?? ""
        Task.detached(priority: .userInitiated) {
            do {
                let handler = await ArchiveHandler(app: app, viewModel: viewModel)
                try await handler.move()
                let packageURL = try await handler.archive(forLocalInstallation: !sharing && method == 0)
                if !sharing {
                    if method == 0 {
                        // IPA is streamed directly from this device; no upload/re-download round trip.
                        try installer.start()
                        await MainActor.run {
                            installer.packageUrl = packageURL
                            viewModel.status = .ready
                        }
                        // The .installing status publisher owns progress polling.
                        // Starting a second poller here races that publisher.
                    } else if method == 1 {
                        let proxy = await InstallationProxy(viewModel: viewModel)
                        try await proxy.install(at: packageURL, suspend: app.identifier == currentBundleID)
                    }
                } else {
                    let package = try await handler.moveToArchive(packageURL, shouldOpen: !useShareSheet)
                    await MainActor.run {
                        dismiss()
                        if useShareSheet, let package {
                            UIActivityViewController.show(activityItems: [package])
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    progressTask?.cancel()
                    progressTask = nil
                    UIAlertController.showAlertWithOk(
                        title: .localized("Install"), message: String(describing: error), action: {
                            HeartbeatManager.shared.start(true)
                            dismiss()
                        }
                    )
                }
            }
        }

	}
	
	private func _launchOTAInstall() {
		guard let url = URL(string: installer.iTunesLinkExternal) else {
			viewModel.status = .broken(NSError(
				domain: "AshteMobile.Install", code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Unable to create the AshteMobile installation link."]
			))
			return
		}

		UIApplication.shared.open(url) { opened in
			guard opened else {
				viewModel.status = .broken(NSError(
					domain: "AshteMobile.Install", code: 2,
					userInfo: [NSLocalizedDescriptionKey: "iOS could not open the AshteMobile installation link. Please retry."]
				))
				return
			}

			installRequestWatchdog?.cancel()
			installRequestWatchdog = Task { @MainActor in
				try? await Task.sleep(nanoseconds: 12_000_000_000)
				guard !Task.isCancelled else { return }
				if case .ready = viewModel.status {
					viewModel.status = .broken(NSError(
						domain: "AshteMobile.Install", code: 3,
						userInfo: [NSLocalizedDescriptionKey: "iOS did not request the installation. Keep AshteMobile open and retry."]
					))
				}
			}
		}
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = hasStarted
					? Self._normalizeInstallProgress(rawProgress)
					: 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(Void()))
					}
					break
				}

				do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break } // 2 polls/s; no busy loop
			}
		}
	}

	private nonisolated static func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}
