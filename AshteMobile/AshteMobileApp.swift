//
//  AshteMobileApp.swift
//  AshteMobile
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import Nuke
import IDeviceSwift
import OSLog
import WebKit
import Combine
import SystemConfiguration
import Network

// MARK: - نماذج إعدادات اللوحة (متوافقة مع Sendable في Xcode 26.3)
struct XSignRemoteRoot: Codable, Equatable, Sendable {
	let name: String?
    let subtitle: String?
    let iconURL: String?
    let categories: [XSignPanelCategory]?
	let tintColor: String?
	let repo_revision_id: Int?
	let xsign_config: XSignRemoteConfig?
}

struct XSignPanelCategory: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isGame: Bool?
}

struct XSignRemoteConfig: Codable, Equatable, Sendable {
	let splash_screen: XSignSplashConfig?
	let theme: XSignThemeColors?
	let maintenance: XSignMaintenance?
	let force_update: XSignForceUpdate?
	let security_locks: XSignSecurityLocks?
	let app_control: XSignAppControl?
}

struct XSignSplashConfig: Codable, Equatable, Hashable, Sendable {
	let engine: String?
	let animation_style: String?
	let show_sign_feather: Bool?
	let duration_seconds: Double?
	let custom_code: String?
    let size_px: Double?
    let stroke_width: Double?
    let glow_radius: Double?
    let subtitle: String?
}

struct XSignThemeColors: Codable, Equatable, Sendable {
	let app_tint_hex: String?
	let splash_bg_top_hex: String?
	let splash_bg_bottom_hex: String?
	let splash_logo_hex: String?
}

struct XSignMaintenance: Codable, Equatable, Sendable {
	let enabled: Bool?
	let title: String?
	let message: String?
	let button_url: String?
}

struct XSignForceUpdate: Codable, Equatable, Sendable {
	let enabled: Bool?
	let min_version: String?
	let update_url: String?
	let message: String?
}

struct XSignSecurityLocks: Codable, Equatable, Sendable {
	let allow_app_metadata_editing: Bool?
	let lock_bundle_rename: Bool?
	let lock_icon_change: Bool?
	let lock_dylib_injection: Bool?
	let anti_vpn_proxy: Bool?
	let require_online_handshake: Bool?
	let vpn_warning_message: String?

    var allowsAppMetadataEditing: Bool {
        XSignAppMetadata.editingAllowed(allow_app_metadata_editing)
    }
}

struct XSignCoreSourceItem: Codable, Equatable, Sendable {
	let name: String
	let id: String
	let url: String
}

struct XSignAppControl: Codable, Equatable, Sendable {
	let top_banner_enabled: Bool?
	let top_banner_text: String?
	let top_banner_url: String?
	let cache_flush_id: Int?
	let purge_sources_id: Int?
	let core_sources: [XSignCoreSourceItem]?
}

// MARK: - مدقق الحماية والأمان (بدون أي مؤقتات تسبب لاك أثناء البحث)
@MainActor
final class XSignSecurityEnforcer: ObservableObject {
	static let shared = XSignSecurityEnforcer()
	
	private let locksStorageKey = "ashtemobile.persistedSecurityLocks_v1"
	private let pathMonitor = NWPathMonitor()
	private let monitorQueue = DispatchQueue(label: "com.ashtemobile.netguard", qos: .utility)
	
	// AshteMobile ships without remote locks: signing, renaming, icon changes and dylib injection are all allowed.
	@Published var locks: XSignSecurityLocks = XSignSecurityLocks(
		allow_app_metadata_editing: true,
		lock_bundle_rename: false,
		lock_icon_change: false,
		lock_dylib_injection: false,
		anti_vpn_proxy: false,
		require_online_handshake: false,
		vpn_warning_message: "VPN / Proxy"
	)
	@Published var isVPNOrProxyDetected: Bool = false
	@Published var didCompleteOnlineHandshake: Bool = false
	
	init() {
		// Decide synchronously so no request can leave before the first check finishes.
		self.isVPNOrProxyDetected = Self.isVPNOrProxyActiveOnDevice()
		if let data = UserDefaults.standard.data(forKey: locksStorageKey),
		   let saved = try? JSONDecoder().decode(XSignSecurityLocks.self, from: data) {
			self.locks = saved
		}
		evaluateNetworkSecurity()
		startEventDrivenNetworkMonitor()
	}
	
	func updateLocks(_ newLocks: XSignSecurityLocks?, verifiedOnline: Bool = false) {
		guard let newLocks = newLocks else { return }
		if self.locks != newLocks {
			self.locks = newLocks
		}
		self.didCompleteOnlineHandshake = verifiedOnline
		if let encoded = try? JSONEncoder().encode(newLocks) {
			UserDefaults.standard.set(encoded, forKey: locksStorageKey)
		}
		evaluateNetworkSecurity()
	}
	
	private func startEventDrivenNetworkMonitor() {
		pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
			let detected = Self.isVPNOrProxyActiveOnDevice()
			Task { @MainActor [weak self] in
				guard let self = self else { return }
				if !connected { self.didCompleteOnlineHandshake = false }
                let shouldBlock = detected
				if self.isVPNOrProxyDetected != shouldBlock {
					self.isVPNOrProxyDetected = shouldBlock
                    NotificationCenter.default.post(name: .xsignPolicyChanged, object: nil)
				}
			}
		}
		pathMonitor.start(queue: monitorQueue)
	}
	
	func evaluateNetworkSecurity() {
		let antiVPNEnabled = true
		DispatchQueue.global(qos: .utility).async { [weak self] in
			let detected = antiVPNEnabled ? Self.isVPNOrProxyActiveOnDevice() : false
			DispatchQueue.main.async {
				guard let self = self else { return }
				if self.isVPNOrProxyDetected != detected {
					self.isVPNOrProxyDetected = detected
				}
			}
		}
	}
	
	nonisolated static func isVPNOrProxyActiveOnDevice() -> Bool {
		guard let cfSettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
			return false
		}
		guard let cfDict = cfSettings as NSDictionary as? [String: Any] else {
			return false
		}
		
		let proxyKeys = [
			"HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable",
			"HTTPProxy", "HTTPSProxy", "SOCKSProxy"
		]
		for key in proxyKeys {
			if let val = cfDict[key] as? Int, val == 1 { return true }
			if let str = cfDict[key] as? String, !str.isEmpty { return true }
		}
		
		if let scoped = cfDict["__SCOPED__"] as? [String: Any] {
			let vpnPrefixes = ["tap", "tun", "utun", "ppp", "ipsec", "wg", "pptp", "l2tp"]
			for iface in scoped.keys {
				let lower = iface.lowercased()
				if vpnPrefixes.contains(where: { lower.contains($0) }) {
					return true
				}
			}
		}
		return false
	}
	
	func validateSigningPermissions(
		originalName: String,
		newName: String,
		originalBundleID: String,
		newBundleID: String,
		didModifyIcon: Bool,
		injectedDylibCount: Int
	) -> (allowed: Bool, errorMessage: String?) {
		if (locks.require_online_handshake ?? false) && !didCompleteOnlineHandshake {
			return (false, AshteL10n.t("يجب الاتصال بالإنترنت للتحقق من صلاحيات التوقيع والأمان."))
		}
		if isVPNOrProxyDetected {
			return (false, locks.vpn_warning_message ?? AshteL10n.t("يرجى إيقاف الـ VPN أو مراقب الشبكة أولاً."))
		}
		if !locks.allowsAppMetadataEditing && (originalName != newName || originalBundleID != newBundleID) {
			return (false, AshteL10n.t("غير مسموح بتعديل اسم التطبيق أو معرف الحزمة (Bundle ID)."))
		}
		if (locks.lock_icon_change ?? false) && didModifyIcon {
			return (false, AshteL10n.t("غير مسموح بتغيير أو استبدال أيقونة التطبيق الأصلية."))
		}
		if (locks.lock_dylib_injection ?? false) && injectedDylibCount > 0 {
			return (false, AshteL10n.t("غير مسموح بحقن أدوات خارجية (.dylib / .deb) داخل التطبيق."))
		}
		return (true, nil)
	}
}

// MARK: - Remote panel transport
@MainActor
final class XSignRemoteManager: ObservableObject {
    static let shared = XSignRemoteManager()
    private let cacheKey = "xsign.cachedRemoteRoot_v7"
    @Published private(set) var config: XSignRemoteConfig?
    @Published private(set) var currentRevisionID = 0
    @Published private(set) var sourceName = "AshteMobile"
    private var lastCatalogRefresh = Date.distantPast

    init() {
        // No cached remote panel: AshteMobile has no remote control server.
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: "xsign.cachedRemoteConfig_v6")
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    var isMaintenanceActive: Bool { config?.maintenance?.enabled == true }
    var isForceUpdateRequired: Bool {
        guard let update = config?.force_update, update.enabled == true,
              let required = update.min_version else { return false }
        return Self.versionIsOlder(currentVersion, than: required)
    }
    nonisolated static func versionIsOlder(_ current: String, than required: String) -> Bool {
        let lhs = current.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = required.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b { return a < b }
        }
        return false
    }
    var blockingReason: String? {
        if isMaintenanceActive { return config?.maintenance?.message ?? AshteL10n.t("التطبيق قيد الصيانة.") }
        if isForceUpdateRequired { return config?.force_update?.message ?? AshteL10n.t("يرجى تحديث التطبيق أولاً.") }
        let security = XSignSecurityEnforcer.shared
        if security.isVPNOrProxyDetected { return security.locks.vpn_warning_message ?? AshteL10n.t("يرجى إيقاف VPN أو Proxy.") }
        return nil
    }

    func prepareProtectedOperation() async -> String? {
        await fetchRemoteConfig()
        let security = XSignSecurityEnforcer.shared
        // Evaluate synchronously at the operation boundary as well as on path changes.
        security.isVPNOrProxyDetected = XSignSecurityEnforcer.isVPNOrProxyActiveOnDevice()
        if let reason = blockingReason { return reason }
        return nil
    }

    func fetchRemoteConfig(storeCache: AppStoreCacheManager? = nil, sourcesViewModel: SourcesViewModel? = nil) async {
        // There is no remote panel anymore: nothing can lock, block or reconfigure the app.
        // This call only keeps the AshteMobile catalog fresh.
        XSignSecurityEnforcer.shared.didCompleteOnlineHandshake = true
        let cache = storeCache ?? AppStoreCacheManager.shared
        let sourcesVM = sourcesViewModel ?? SourcesViewModel.shared
        if !cache.hasLoadedCatalog || Date().timeIntervalSince(lastCatalogRefresh) >= 60 {
            lastCatalogRefresh = Date()
            let sources = Storage.shared.getSources()
            Task { @MainActor in await cache.forceRefresh(sources: sources, viewModel: sourcesVM) }
        }
    }

    nonisolated static func validHex(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
}

extension Notification.Name {
    static let xsignPolicyChanged = Notification.Name("xsign.policyChanged")
}

// Only user-initiated links use these schemes; custom HTML cannot navigate the app.
func xsignSafeURL(_ text: String?) -> URL? {
    guard let text, let url = URL(string: text),
          ["https", "http", "tg"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
}

// MARK: - Isolated custom splash renderer
final class XSignSplashScriptCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var lastHTML: String?
    var onAnimationCompleted: (() -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "xsignSplash", message.frameInfo.isMainFrame,
              (message.body as? String) == "finished" else { return }
        onAnimationCompleted?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
}
struct XSignCustomCSSSplashWebView: UIViewRepresentable {
    let htmlCode: String
    var onFinishedFromJS: (() -> Void)? = nil
    func makeCoordinator() -> XSignSplashScriptCoordinator { XSignSplashScriptCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "xsignSplash")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onAnimationCompleted = onFinishedFromJS
        guard context.coordinator.lastHTML != htmlCode else { return }
        context.coordinator.lastHTML = htmlCode
        let document = "<!DOCTYPE html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:\"></head><body>\(htmlCode)</body></html>"
        view.loadHTMLString(document, baseURL: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: XSignSplashScriptCoordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "xsignSplash")
        coordinator.onAnimationCompleted = nil
    }
}

@main
struct AshteMobileApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@Environment(\.scenePhase) private var scenePhase
	
	let heartbeat = HeartbeatManager.shared
	
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject private var storeCache = AppStoreCacheManager.shared
    @StateObject private var autoSign = AutoSignPipelineManager.shared
	@StateObject private var sourcesViewModel = SourcesViewModel.shared
	@StateObject private var remoteManager = XSignRemoteManager.shared
	@StateObject private var securityEnforcer = XSignSecurityEnforcer.shared
	@StateObject private var storage = Storage.shared
	
	@AppStorage(AshteL10n.storageKey) private var _language: String = AshteL10n.defaultCode
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
    @AppStorage("AshteMobile.userInterfaceStyle")
    private var userInterfaceStyle: Int = UIUserInterfaceStyle.unspecified.rawValue
	@State private var _showSplash = true
	
	init() {
		// Installation type picker was removed from Settings: always install from the server.
		UserDefaults.standard.set(0, forKey: "AshteMobile.installationMethod")
		// Route every `.localized(...)` string through the in-app language.
		AshteL10n.install()
		// Block every http(s) request while a proxy / traffic-capture tool is active.
		NetworkShield.install()
	}
	
	private var activeTintColor: Color {
		Color(hex: userTintHex)
	}

    private var preferredAppColorScheme: ColorScheme? {
        switch UIUserInterfaceStyle(rawValue: userInterfaceStyle) ?? .unspecified {
        case .light: return .light
        case .dark: return .dark
        default: return nil
        }
    }

    private func applyAppearanceToWindows() {
        let style = UIUserInterfaceStyle(rawValue: userInterfaceStyle) ?? .unspecified
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                window.tintColor = UIColor(activeTintColor)
            }
        }
    }
	
	var body: some Scene {
		WindowGroup {
            Group {
                if !storage.isStoreLoaded { XSignStorageLoadView(storage: storage) }
                else {
			ZStack {
				VStack(spacing: 0) {
					if remoteManager.config?.app_control?.top_banner_enabled == true,
					   let text = remoteManager.config?.app_control?.top_banner_text, !text.isEmpty {
						Button {
							if let uStr = remoteManager.config?.app_control?.top_banner_url,
							   let u = xsignSafeURL(uStr) {
								UIApplication.shared.open(u)
							}
						} label: {
							HStack(spacing: 8) {
								Image(systemName: "bell.badge.fill")
									.font(.caption.bold())
								Text(text)
									.font(.caption.bold())
									.lineLimit(1)
								Spacer()
								Image(systemName: "chevron.left")
									.font(.caption2)
							}
							.foregroundColor(AppStoreTheme.contrastingText(forHex: userTintHex))
							.padding(.horizontal, 14)
							.padding(.vertical, 9)
							.background(activeTintColor)
						}
					}
					
					DownloadHeaderView(downloadManager: downloadManager)
						.transition(.move(edge: .top).combined(with: .opacity))
					VariedTabbarView()
						.environment(\.managedObjectContext, storage.context)
						.onOpenURL(perform: _handleURL)
						.transition(.move(edge: .top).combined(with: .opacity))
				}
				.tint(activeTintColor)
				.accentColor(activeTintColor)
				.animation(.smooth, value: downloadManager.manualDownloads.description)
				

				XSignDownloadBanner(pipeline: autoSign)
					.zIndex(500)

				if _showSplash {
					XSignPhotoIdenticalSplashView(
						cache: storeCache,
						sourcesViewModel: sourcesViewModel,
						remoteManager: remoteManager
					) {
						withAnimation(.easeInOut(duration: 0.45)) {
							_showSplash = false
						}
					}
					.transition(.opacity)
					.zIndex(999)
				}

				if !_showSplash && (remoteManager.isMaintenanceActive || remoteManager.isForceUpdateRequired) {
					XSignRemoteGateOverlayView(remoteManager: remoteManager, tintColor: activeTintColor)
						.transition(.opacity)
						.zIndex(1000)
				}
				
				if securityEnforcer.isVPNOrProxyDetected {
					ProxyDetectionView {
						securityEnforcer.evaluateNetworkSecurity()
					}
					.transition(.opacity)
					.zIndex(2000)
				}
			}
            .tint(activeTintColor)
            .accentColor(activeTintColor)
			.preferredColorScheme(preferredAppColorScheme)
			.environment(\.locale, Locale(identifier: _language))
            .sheet(item: $autoSign.readyToInstallApp, onDismiss: {
                autoSign.presentNextReadyApp()
            }) { signedApp in
                InstallPreviewView(app: signedApp.base, isSharing: signedApp.archive, removeAfterInstall: true)
                    .presentationDetents([.height(470)])
                    .presentationDragIndicator(.visible)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await remoteManager.fetchRemoteConfig(storeCache: storeCache, sourcesViewModel: sourcesViewModel)
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await storeCache.runAutomaticUpdates(sources: { storage.getSources() }, viewModel: sourcesViewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: .xsignPolicyChanged)) { _ in
                autoSign.applyRemotePolicy()
                if remoteManager.blockingReason != nil {
                    for download in downloadManager.downloads where download.task != nil { downloadManager.cancelDownload(download) }
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { securityEnforcer.evaluateNetworkSecurity() }
            }
            .onChange(of: userTintHex) { _ in
                applyAppearanceToWindows()
            }
            .onChange(of: userInterfaceStyle) { _ in
                applyAppearanceToWindows()
            }
			.onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(
						title: "InvalidHostID",
						message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
					)
				}
			}
			.onAppear {
				if UserDefaults.standard.string(forKey: "AshteMobile.userTintColor") == nil {
					UserDefaults.standard.set("#005BBB", forKey: "AshteMobile.userTintColor")
				}
                applyAppearanceToWindows()
			}
                }
            }
		}
	}
	
	private func _handleURL(_ url: URL) {
		XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
		if XSignSecurityEnforcer.shared.isVPNOrProxyDetected {
			UIAlertController.showAlertWithOk(
				title: AshteL10n.t("تنبيه أمني"),
				message: XSignSecurityEnforcer.shared.locks.vpn_warning_message ?? AshteL10n.t("يرجى إيقاف الـ VPN أو مراقب الشبكة أولاً.")
			)
			return
		}
		
		if url.scheme == "feather" {
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}
				
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}
				
				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}
				
				let generator = UINotificationFeedbackGenerator()
				generator.prepare()
				
				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					return
				}
				
				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password
				) { error in
					if let error = error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					} else {
						generator.notificationOccurred(.success)
					}
				}
				
				return
			}
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}
				
				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
				
				FR.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				UIAlertController.showAlertWithCancel(
					title: .localized("Install"),
					message: .localized("Do you want to download and install this file?") + "\n\n\(downloadURL)",
					actions: [
						UIAlertAction(title: .localized("Install"), style: .default) { _ in
							guard !XSignSecurityEnforcer.shared.isVPNOrProxyDetected else { return }
							_ = DownloadManager.shared.startDownload(from: downloadURL)
						}
					]
				)
			}
		} else {
			if url.pathExtension == "ipa" || url.pathExtension == "tipa" {
				Task.detached(priority: .high) {
					autoreleasepool {
						if FileManager.default.isFileFromFileProvider(at: url) {
							guard url.startAccessingSecurityScopedResource() else { return }
							defer { url.stopAccessingSecurityScopedResource() }
							FR.handlePackageFile(url) { _ in }
						} else {
							FR.handlePackageFile(url) { _ in }
						}
					}
				}
				return
			}
		}
	}
}

// MARK: - شاشة الحظر عند اكتشاف VPN أو مراقب شبكة
struct XSignVPNBlockedOverlayView: View {
	let message: String
	var onRetry: () -> Void
	
	var body: some View {
		ZStack {
			AppStoreTheme.background.ignoresSafeArea()
			
			VStack(spacing: 18) {
				Image(systemName: "network.badge.shield.half.filled")
					.font(.system(size: 58))
					.foregroundColor(.red)
				
				Text(AshteL10n.t("تم إيقاف الاتصال لحماية التطبيق"))
					.font(.title3.bold())
					.foregroundColor(.primary)
				
				Text(message)
					.font(.subheadline)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 28)
				
				Button(action: onRetry) {
					Text(AshteL10n.t("إعادة الفحص بعد إيقاف الـ VPN"))
						.font(.headline.bold())
						.foregroundColor(.white)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 14)
						.background(Color.red)
						.cornerRadius(14)
				}
				.padding(.horizontal, 40)
				.padding(.top, 8)
			}
			.padding(24)
		}
	}
}

// MARK: - شاشة الصيانة والتحديث الإجباري
struct XSignRemoteGateOverlayView: View {
	@ObservedObject var remoteManager: XSignRemoteManager
	let tintColor: Color
    @AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	
	var body: some View {
		ZStack {
			AppStoreTheme.background.ignoresSafeArea()
			
			VStack(spacing: 20) {
				Image(systemName: remoteManager.isMaintenanceActive ? "wrench.and.screwdriver.fill" : "arrow.down.circle.fill")
					.font(.system(size: 56))
					.foregroundColor(tintColor)
				
				Text(remoteManager.isMaintenanceActive
					 ? (remoteManager.config?.maintenance?.title ?? AshteL10n.t("التطبيق قيد الصيانة"))
					 : AshteL10n.t("تحديث إجباري مطلوب"))
					.font(.title2.bold())
					.foregroundColor(.primary)
					.multilineTextAlignment(.center)
				
				Text(remoteManager.isMaintenanceActive
					 ? (remoteManager.config?.maintenance?.message ?? AshteL10n.t("يرجى المحاولة لاحقاً."))
					 : (remoteManager.config?.force_update?.message ?? AshteL10n.t("يرجى تحديث التطبيق لأحدث إصدار.")))
					.font(.subheadline)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 24)
				
				Button {
					let target = remoteManager.isMaintenanceActive
						? (remoteManager.config?.maintenance?.button_url ?? "")
						: (remoteManager.config?.force_update?.update_url ?? "")
					if let url = URL(string: target) {
						UIApplication.shared.open(url)
					}
				} label: {
					Text(remoteManager.isMaintenanceActive ? AshteL10n.t("متابعة قناة التيليجرام") : AshteL10n.t("تحديث التطبيق الآن"))
						.font(.headline.bold())
						.foregroundColor(AppStoreTheme.contrastingText(forHex: userTintHex))
						.frame(maxWidth: .infinity)
						.padding(.vertical, 14)
						.background(tintColor)
						.cornerRadius(14)
				}
				.padding(.horizontal, 36)
			}
			.padding(24)
		}
	}
}

// MARK: - المسارات الهندسية المطابقة 100% لصورة X Sign
struct ExactImageXLeftRibbon: Shape {
	func path(in rect: CGRect) -> Path {
		let w = rect.width, h = rect.height
		func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
		
		var path = Path()
		path.move(to: pt(0.3157, 0.1961))
		path.addLine(to: pt(0.4431, 0.1961))
		path.addLine(to: pt(0.4863, 0.2725))
		path.addLine(to: pt(0.6373, 0.0569))
		path.addLine(to: pt(0.4863, 0.3176))
		path.addLine(to: pt(0.4275, 0.2196))
		path.addLine(to: pt(0.3529, 0.2196))
		path.addLine(to: pt(0.4373, 0.3824))
		path.addLine(to: pt(0.2549, 0.6941))
		path.addLine(to: pt(0.4157, 0.3824))
		path.closeSubpath()
		return path
	}
}

struct ExactImageXRightRibbon: Shape {
	func path(in rect: CGRect) -> Path {
		let w = rect.width, h = rect.height
		func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
		
		var path = Path()
		path.move(to: pt(0.7451, 0.0569))
		path.addLine(to: pt(0.5765, 0.3961))
		path.addLine(to: pt(0.6745, 0.5745))
		path.addLine(to: pt(0.5353, 0.5745))
		path.addLine(to: pt(0.5000, 0.5020))
		path.addLine(to: pt(0.3588, 0.6980))
		path.addLine(to: pt(0.5020, 0.4549))
		path.addLine(to: pt(0.5529, 0.5471))
		path.addLine(to: pt(0.6353, 0.5471))
		path.addLine(to: pt(0.5471, 0.3961))
		path.closeSubpath()
		return path
	}
}

struct ExactImageSignAshteMobileWing: Shape {
	func path(in rect: CGRect) -> Path {
		let w = rect.width, h = rect.height
		func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
		
		var path = Path()
		path.move(to: pt(0.604, 0.812))
		path.addCurve(to: pt(0.725, 0.760), control1: pt(0.625, 0.782), control2: pt(0.665, 0.785))
		path.addCurve(to: pt(0.668, 0.770), control1: pt(0.702, 0.770), control2: pt(0.686, 0.772))
		path.addCurve(to: pt(0.746, 0.672), control1: pt(0.708, 0.752), control2: pt(0.738, 0.725))
		path.addCurve(to: pt(0.646, 0.745), control1: pt(0.722, 0.715), control2: pt(0.688, 0.732))
		path.addCurve(to: pt(0.704, 0.692), control1: pt(0.672, 0.728), control2: pt(0.695, 0.712))
		path.addCurve(to: pt(0.622, 0.752), control1: pt(0.674, 0.718), control2: pt(0.642, 0.726))
		path.addCurve(to: pt(0.594, 0.816), control1: pt(0.612, 0.765), control2: pt(0.602, 0.795))
		path.closeSubpath()
		return path
	}
}

struct PhotoIdenticalXVectorView: View {
	let progress: CGFloat
	let fillAlpha: Double
	let glow: Double
	var logoColor: Color = .white
	var showSignAndAshteMobile: Bool = true
	var leftOffset: CGSize = .zero
	var rightOffset: CGSize = .zero
    var strokeWidth: CGFloat = 2.8
    var glowRadius: CGFloat = 18
	
	var body: some View {
		ZStack {
			ZStack {
				ExactImageXLeftRibbon()
					.fill(logoColor.opacity(fillAlpha))
				ExactImageXLeftRibbon()
					.trim(from: 0, to: progress)
					.stroke(logoColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .miter, miterLimit: 18))
			}
			.offset(leftOffset)
			
			ZStack {
				ExactImageXRightRibbon()
					.fill(logoColor.opacity(fillAlpha))
				ExactImageXRightRibbon()
					.trim(from: 0, to: progress)
					.stroke(logoColor, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .miter, miterLimit: 18))
			}
			.offset(rightOffset)
			
			if showSignAndAshteMobile {
				ZStack {
					Text("Sign")
						.font(.custom("Georgia-Italic", size: 52))
						.foregroundColor(logoColor)
						.position(x: 146, y: 262)
					
					ExactImageSignAshteMobileWing()
						.fill(logoColor)
				}
				.opacity(fillAlpha)
			}
		}
		.frame(width: 320, height: 320)
		.shadow(color: logoColor.opacity(0.65 * glow), radius: glowRadius, x: 0, y: 0)
	}
}

struct XSignPhotoIdenticalSplashView: View {
    @ObservedObject var cache: AppStoreCacheManager
    @ObservedObject var sourcesViewModel: SourcesViewModel
    @ObservedObject var remoteManager: XSignRemoteManager
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beganAt = Date()
    @State private var appeared = false
    @State private var pulse = false
    @State private var dismissed = false

    private let minimumDuration: Double = 2.6

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#02060F"), Color(hex: "#06173A"), Color(hex: "#02060F")],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            RadialGradient(
                colors: [Color(hex: "#2F6BFF").opacity(0.5), .clear],
                center: .center, startRadius: 10, endRadius: 300
            )
            .scaleEffect(pulse ? 1.12 : 0.92)
            .opacity(appeared ? 1 : 0)
            .ignoresSafeArea()

            VStack(spacing: 30) {
                ZStack {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color(hex: "#6FB1FF"), Color(hex: "#7A4DFF"), Color(hex: "#6FB1FF")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 252, height: 252)
                        .scaleEffect(pulse ? 1.07 : 0.97)
                        .opacity(pulse ? 0.25 : 0.75)

                    Image("AshteLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 214, height: 214)
                        .shadow(color: Color(hex: "#3D7BFF").opacity(0.7), radius: 30)
                }
                .scaleEffect(appeared ? 1 : 0.55)
                .opacity(appeared ? 1 : 0)

                Text(AshteBranding.appName)
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color(hex: "#9CC4FF")], startPoint: .leading, endPoint: .trailing)
                    )
                    .shadow(color: Color(hex: "#3D7BFF").opacity(0.55), radius: 12)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(0.35), value: appeared)
            }
        }
        .task {
            await Task.yield()
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.72)) { appeared = true }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = true }
            }
            let remaining = max(0, minimumDuration - Date().timeIntervalSince(beganAt))
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            guard !dismissed else { return }
            dismissed = true
            onFinished()
        }
    }
}

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    private var storeReadySubscription: AnyCancellable?
    private var didPrepareStorage = false
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		_createLowMemoryPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
        storeReadySubscription = Storage.shared.$isStoreLoaded.filter { $0 }.first()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, !self.didPrepareStorage else { return }
                self.didPrepareStorage = true
                self._configureProtectedCoreSources()
                self._addDefaultCertificates()
            }
		return true
	}
	
	func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
		ImagePipeline.shared.cache.removeAll()
		URLCache.shared.removeAllCachedResponses()
	}
	
	// إعداد كاش صور ذكي يحمل أيقونات GitHub المستخرجة فوراً ولا يخزن أخطاء 404
	private func _createLowMemoryPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0
		DataLoader.sharedUrlCache.memoryCapacity = 0
		
		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				config.requestCachePolicy = .useProtocolCachePolicy
				config.httpMaximumConnectionsPerHost = 4
				return DataLoader(configuration: NetworkShield.protect(config))
			}()
			let dataCache = try? DataCache(name: "thewonderofyou.AshteMobile.datacache")
			let imageCache = Nuke.ImageCache()
			dataCache?.sizeLimit = 300 * 1024 * 1024
			imageCache.costLimit = 32 * 1024 * 1024
			imageCache.countLimit = 120
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .storeAll
			$0.isStoringPreviewsInMemoryCache = false
			$0.isDecompressionEnabled = true
		}
		
		ImagePipeline.shared = pipeline
	}
	
	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]
		
		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}
	
	private func _configureProtectedCoreSources() {
		let context = Storage.shared.context
		context.perform {
			let request = NSFetchRequest<AltSource>(entityName: "AltSource")
			let existingSources = (try? context.fetch(request)) ?? []
			
            // Remove only the retired catalog records. Certificates and imported/signed apps are separate entities.
            for source in existingSources where ProtectedSourcesVault.isRetiredSource(source.sourceURL, identifier: source.identifier) {
                context.delete(source)
            }

			let coreRepos: [(name: String, id: String, url: String)] = [
				(ProtectedSourcesVault.primaryName, ProtectedSourcesVault.primaryIdentifier, ProtectedSourcesVault.primaryURLString)
			]
			
			let updatedExisting = (try? context.fetch(request)) ?? []
			for repo in coreRepos {
				guard let repoURL = URL(string: repo.url) else { continue }
				let alreadyExists = updatedExisting.contains {
					$0.sourceURL.map { XSignCatalogIO.canonicalURL($0) == XSignCatalogIO.canonicalURL(repoURL) } == true ||
					$0.identifier == repo.id
				}
				if !alreadyExists {
					let newSource = AltSource(context: context)
					newSource.name = repo.name
					newSource.identifier = repo.id
					newSource.sourceURL = repoURL
					newSource.date = Date()
				}
			}
			
			try? context.save()
		}
	}
	
	private func _addDefaultCertificates() {
		guard
			UserDefaults.standard.bool(forKey: "feather.didImportDefaultCertificates") == false,
			let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
		else {
			return
		}
		
		do {
			let folderContents = try FileManager.default.contentsOfDirectory(
				at: signingAssetsURL,
				includingPropertiesForKeys: nil,
				options: .skipsHiddenFiles
			)
			
			for folderURL in folderContents {
				guard folderURL.hasDirectoryPath else { continue }
				
				let certName = folderURL.lastPathComponent
				
				let p12URL = folderURL.appendingPathComponent("cert.p12")
				let provisionURL = folderURL.appendingPathComponent("cert.mobileprovision")
				let passwordURL = folderURL.appendingPathComponent("cert.txt")
				
				guard
					FileManager.default.fileExists(atPath: p12URL.path),
					FileManager.default.fileExists(atPath: provisionURL.path),
					FileManager.default.fileExists(atPath: passwordURL.path)
				else {
					Logger.misc.warning("Skipping \(certName): missing required files")
					continue
				}
				
				let password = try String(contentsOf: passwordURL, encoding: .utf8)
				
				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password,
					certificateName: certName,
					isDefault: true
				) { _ in
					
				}
			}
			UserDefaults.standard.set(true, forKey: "feather.didImportDefaultCertificates")
		} catch {
			Logger.misc.error("Failed to list signing-assets: \(error)")
		}
	}
}

private struct XSignStorageLoadView: View {
    @ObservedObject var storage: Storage
    var body: some View {
        VStack(spacing: 16) {
            if storage.storeLoadError != nil {
                Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                Text(AshteL10n.t("تعذّر فتح البيانات المحفوظة")).font(.headline)
                Text(AshteL10n.t("أعد المحاولة لفتح مكتبتك.")).foregroundStyle(.secondary)
                Button(AshteL10n.t("إعادة المحاولة")) { storage.retryLoadingStore() }
            } else { Color.clear.frame(width: 1, height: 1) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, AshteL10n.layoutDirection)
    }
}
