//
//  SigningView.swift
//  AshteMobile
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - Custom X Logo Shape
struct XSignLogoShape: Shape {
	func path(in rect: CGRect) -> Path {
		var path = Path()
		let w = rect.width
		let h = rect.height
		
		// الجزء الأيسر العلوي الممتد للشوكة العلوية والسفلية
		path.move(to: CGPoint(x: w * 0.67, y: h * 0.04))
		path.addLine(to: CGPoint(x: w * 0.47, y: h * 0.36))
		path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.22))
		path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.22))
		path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.54))
		path.addLine(to: CGPoint(x: w * 0.10, y: h * 0.96))
		path.addLine(to: CGPoint(x: w * 0.44, y: h * 0.54))
		path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.28))
		path.addLine(to: CGPoint(x: w * 0.35, y: h * 0.28))
		path.addLine(to: CGPoint(x: w * 0.47, y: h * 0.46))
		path.closeSubpath()
		
		// الجزء الأيمن السفلي الممتد للشوكة العلوية والسفلية
		path.move(to: CGPoint(x: w * 0.25, y: h * 0.96))
		path.addLine(to: CGPoint(x: w * 0.49, y: h * 0.63))
		path.addLine(to: CGPoint(x: w * 0.57, y: h * 0.76))
		path.addLine(to: CGPoint(x: w * 0.77, y: h * 0.76))
		path.addLine(to: CGPoint(x: w * 0.59, y: h * 0.47))
		path.addLine(to: CGPoint(x: w * 0.86, y: h * 0.04))
		path.addLine(to: CGPoint(x: w * 0.53, y: h * 0.47))
		path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.70))
		path.addLine(to: CGPoint(x: w * 0.60, y: h * 0.70))
		path.addLine(to: CGPoint(x: w * 0.49, y: h * 0.53))
		path.closeSubpath()
		
		return path
	}
}

struct XSignHeaderLogo: View {
	var body: some View {
		Image("AshteHeaderLogo")
			.resizable()
			.scaledToFit()
			.frame(width: 36, height: 36)
	}
}

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@ObservedObject private var policy = XSignSecurityEnforcer.shared
    @StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State var appIcon: UIImage?
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_cert()
				_customizationProperties(for: app)
				
				// horrible
				Rectangle()
					.foregroundStyle(.clear)
					.frame(height: 30)
					.listRowBackground(EmptyView())
			}
			.overlay {
				VStack(spacing: 0) {
					Spacer()
					NBVariableBlurView()
						.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
						.rotationEffect(.degrees(180))
						.overlay {
							Button {
								_start()
							} label: {
								NBSheetButton(title: .localized("Start Signing"), style: .prominent)
									.padding()
							}
							.buttonStyle(.plain)
							.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
						}
				}
				.ignoresSafeArea(edges: .bottom)
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					XSignHeaderLogo()
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
		}
		.onAppear {
			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					FRAppIconView(app: app, size: 56)
				}
            }.disabled(policy.locks.lock_icon_change ?? true)

            _infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName,
                    field: .name, originalValue: app.name
                )
            }.disabled(!policy.locks.allowsAppMetadataEditing)
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier,
                    field: .bundleIdentifier, originalValue: app.identifier
                )
            }.disabled(!policy.locks.allowsAppMetadataEditing)
			
			_cloneRow(for: app).disabled(!policy.locks.allowsAppMetadataEditing)
			
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion,
                    field: .version, originalValue: app.version
				)
			}.disabled(!policy.locks.allowsAppMetadataEditing)
		}
	}
	
	@ViewBuilder
	private func _cloneRow(for app: AppInfoPresentable) -> some View {
		let baseID = app.identifier ?? ""
		let currentID = _temporaryOptions.appIdentifier ?? baseID
		let canRemoveClone = currentID.hasSuffix("1") && currentID.count > baseID.count
		
		HStack(spacing: 12) {
			Label {
				VStack(alignment: .leading, spacing: 2) {
					Text(AshteL10n.t("الاستنساخ"))
						.font(.body)
					Text(AshteL10n.t("إضافة أو إزالة (1) من البندل لتكرار التطبيق"))
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			} icon: {
				Image(systemName: "plus.square.on.square.fill")
					.foregroundStyle(Color.accentColor)
					.font(.system(size: 18, weight: .semibold))
			}
			
			Spacer()
			
			HStack(spacing: 0) {
				// زر الناقص (-) لعكس العملية
				Button {
					guard canRemoveClone else { return }
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
					withAnimation(.snappy) {
						var updated = currentID
						updated.removeLast()
						_temporaryOptions.appIdentifier = updated
					}
				} label: {
					Image(systemName: "minus")
						.font(.system(size: 14, weight: .bold))
						.frame(width: 38, height: 32)
						.foregroundStyle(canRemoveClone ? Color.primary : Color.secondary.opacity(0.35))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(!canRemoveClone)
				
				Divider()
					.frame(height: 18)
				
				// زر الزائد (+) لإضافة 1 إلى البندل
				Button {
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
					withAnimation(.snappy) {
						_temporaryOptions.appIdentifier = currentID + "1"
					}
				} label: {
					Image(systemName: "plus")
						.font(.system(size: 14, weight: .bold))
						.frame(width: 38, height: 32)
						.foregroundStyle(Color.accentColor)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
			.background(
				RoundedRectangle(cornerRadius: 9, style: .continuous)
					.fill(Color(UIColor.secondarySystemFill))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 9, style: .continuous)
					.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
			)
		}
		.padding(.vertical, 2)
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
			
				NavigationLink(.localized("Entitlements") + " (BETA)") {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}
				
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
                    )
                }.disabled(policy.locks.lock_dylib_injection ?? true)
			}
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.navigationTitle(.localized("Properties"))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
        if policy.locks.allowsAppMetadataEditing {
            do {
                _ = try XSignAppMetadata.validated(_temporaryOptions.appName, field: .name, original: app.name)
                _ = try XSignAppMetadata.validated(_temporaryOptions.appIdentifier, field: .bundleIdentifier, original: app.identifier)
                _ = try XSignAppMetadata.validated(_temporaryOptions.appVersion, field: .version, original: app.version)
            } catch {
                UIAlertController.showAlertWithOk(title: AshteL10n.t("معلومات التطبيق"), message: error.localizedDescription)
                return
            }
        }
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isSigning = true
		
		FR.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert()
		) { error in
			if let error {
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					dismiss()
				}
				
				UIAlertController.showAlert(
					title: "Error",
					message: error.localizedDescription,
					actions: [ok]
				)
			} else {
				if
					_temporaryOptions.post_deleteAppAfterSigned,
					!app.isSigned
				{
					Storage.shared.deleteApp(for: app)
				}
				
				if _temporaryOptions.post_installAppAfterSigned {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
						NotificationCenter.default.post(name: Notification.Name("AshteMobile.installApp"), object: nil)
					}
				}
				dismiss()
			}
		}
	}
}
