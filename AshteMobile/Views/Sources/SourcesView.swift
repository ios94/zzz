//
//  SourcesView.swift
//  AshteMobile
//
//  Created by samara on 10.04.2025.
//

import Foundation
import CryptoKit
import CoreData
import AltSourceKit
import SwiftUI
import Combine
import NaturalLanguage
import NimbleViews
import NukeUI
import Nuke
import UIKit

// MARK: - Appearance-aware application colors
enum AppStoreTheme {
    nonisolated static let oceanBlue = Color.accentColor
    nonisolated static let deepOcean = Color(red: 0.02, green: 0.16, blue: 0.36)
    nonisolated static let background = Color(uiColor: .systemGroupedBackground)
    nonisolated static let pureBlack = background
    nonisolated static let cardSurface = Color(uiColor: .secondarySystemGroupedBackground)
    nonisolated static let controlSurface = Color(uiColor: .tertiarySystemFill)

    nonisolated static var dynamicAccent: Color { Color.accentColor }

    // Keep labels readable even when the wheel selects a very bright color.
    nonisolated static func contrastingText(forHex hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return .white
        }
        func channel(_ shift: Int) -> Double {
            let component = Double((value >> shift) & 0xFF) / 255.0
            return component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return luminance > 0.179 ? .black : .white
    }
}

// MARK: - Protected Sources Vault (AshteMobile primary source)
enum ProtectedSourcesVault {
	nonisolated static let primaryURLString = "https://raw.githubusercontent.com/ios94/ashtejson/main/ashtemobile94.json"
	nonisolated static let primaryIdentifier = "ashtemobile.core"
	nonisolated static let primaryName = "AshteMobile"

	nonisolated static let coreURLs: [String] = [
		primaryURLString
	]

	// Old built-in catalogs (IPA BLACK, Soon, IPAOMTK, reference, store-api) are retired for good.
	nonisolated static func isRetiredSource(_ sourceURL: URL?, identifier: String? = nil) -> Bool {
		if let id = identifier?.lowercased(), id.hasPrefix("xsign.core.") { return true }
		guard let sourceURL else { return false }
		let url = XSignCatalogIO.canonicalURL(sourceURL)
		guard let host = url.host?.lowercased() else { return false }
		if host == "appiraq.com" || host.hasSuffix(".appiraq.com") { return true }
		guard ["github.com", "raw.githubusercontent.com"].contains(host) else { return false }
		return url.path.lowercased().split(separator: "/").first == "ipa-black"
	}

	nonisolated static func isPrimarySource(_ sourceURL: URL?, identifier: String? = nil) -> Bool {
		if identifier?.lowercased() == primaryIdentifier { return true }
		guard let sourceURL, let primary = URL(string: primaryURLString) else { return false }
		return XSignCatalogIO.canonicalURL(sourceURL) == XSignCatalogIO.canonicalURL(primary)
	}

	nonisolated static func isHiddenCoreSource(_ source: AltSource) -> Bool {
		isPrimarySource(source.sourceURL, identifier: source.identifier)
	}
}

// MARK: - Rich Apple App Store Metadata Model (Skips Deleted Apps Automatically)
struct AppleStoreRichMetadata: Codable, Sendable {
	let screenshots: [URL]
	let artworkURL: URL?
	let description: String?
	let releaseNotes: String?
	let sellerName: String?
	let genre: String?
	let contentRating: String?
	let rating: Double?
	let fileSizeBytes: Int64?
}

actor AppStoreLiveMetadataBridge {
	static let shared = AppStoreLiveMetadataBridge()
	
	private var memoryCache: [String: AppleStoreRichMetadata] = [:]
    private var metadataOrder: [String] = []
	private var negativeCache: Set<String> = []
	private var inFlightTasks: [String: Task<AppleStoreRichMetadata?, Never>] = [:]
	
	private nonisolated static var diskCacheDir: URL {
		let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("XSignAppleMetadataCache_SA_v5", isDirectory: true)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}
	
    private var metadataGeneration = 0

    func invalidateCache() {
        metadataGeneration += 1
        metadataOrder.removeAll()
        for task in inFlightTasks.values { task.cancel() }
        inFlightTasks.removeAll()
        memoryCache.removeAll()
        negativeCache.removeAll()
        try? FileManager.default.removeItem(at: Self.diskCacheDir)
    }

	// إذا كانت الأيقونة مستخرجة من ملفات التطبيق ومرفوعة على GitHub، فالتطبيق محذوف من متجر أبل ولا نطلب أي صور من أبل
	nonisolated static func hasExtractedGitHubIcon(_ iconURL: URL?) -> Bool {
		guard let str = iconURL?.absoluteString.lowercased() else { return false }
		return str.contains("/assets/icons/")
	}
	
	func fetchMetadata(bundleID: String?, appName: String, iconURL: URL? = nil, skipLookup: Bool = false) async -> AppleStoreRichMetadata? {
		// تخطي متجر أبل نهائياً إذا كان التطبيق يستخدم أيقونة مستخرجة من ملفاته على GitHub
		if skipLookup || Self.hasExtractedGitHubIcon(iconURL) {
			return nil
		}
		
		let cacheKey = "\(bundleID ?? "")_\(appName)".lowercased()
			.replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
		
		if negativeCache.contains(cacheKey) {
			return nil
		}
		
		if let cached = memoryCache[cacheKey] {
			return cached
		}
		
		let diskFile = Self.diskCacheDir.appendingPathComponent("\(cacheKey).json")
		if let data = try? Data(contentsOf: diskFile),
		   let decoded = try? JSONDecoder().decode(AppleStoreRichMetadata.self, from: data) {
			storeMetadata(decoded, for: cacheKey)
			return decoded
		}
		
		if let existingTask = inFlightTasks[cacheKey] {
			return await existingTask.value
		}
		
        guard !Task.isCancelled, inFlightTasks.count < 4 else { return nil }
		let generation = metadataGeneration
        let task = Task<AppleStoreRichMetadata?, Never> {
			// الفحص يتم حصرياً عبر الـ Bundle ID؛ إذا كان التطبيق محذوفاً من المتجر نتوقف فوراً ولا نجلب صوراً عشوائية بالاسم
			guard let bID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
				  bID.contains("."),
				  !bID.hasPrefix("games."),
				  bID != "com.ipablack.app",
				  let encodedID = bID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
			else {
				return nil
			}
			
			if let found = await Self.queryiTunes(
				urlString: "https://itunes.apple.com/lookup?bundleId=\(encodedID)&country=SA"
			) {
				return found
			}
			
			if let foundUS = await Self.queryiTunes(
				urlString: "https://itunes.apple.com/lookup?bundleId=\(encodedID)&country=US"
			) {
				return foundUS
			}
			
			// التطبيق محذوف من متجر أبل -> لا نجلب أي صور من أبل
			return nil
		}
		
		inFlightTasks[cacheKey] = task
		let result = await task.value
        guard metadataGeneration == generation else { return nil }
		inFlightTasks.removeValue(forKey: cacheKey)
		
		if let result {
			storeMetadata(result, for: cacheKey)
			if let encodedData = try? JSONEncoder().encode(result) {
				try? encodedData.write(to: diskFile, options: .atomic)
			}
		} else {
            if negativeCache.count >= 256 { negativeCache.removeAll(keepingCapacity: true) }
			negativeCache.insert(cacheKey)
		}
		return result
	}
	
    private func storeMetadata(_ metadata: AppleStoreRichMetadata, for key: String) {
        if memoryCache[key] == nil {
            if metadataOrder.count >= 128 {
                memoryCache.removeValue(forKey: metadataOrder.removeFirst())
            }
            metadataOrder.append(key)
        }
        memoryCache[key] = metadata
    }

	private nonisolated static func queryiTunes(urlString: String) async -> AppleStoreRichMetadata? {
		guard let url = URL(string: urlString) else { return nil }
		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 6
			request.setValue("ar-SA,ar;q=0.9", forHTTPHeaderField: "Accept-Language")
			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse,
			      (200..<300).contains(http.statusCode) else { return nil }
			guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				  let results = json["results"] as? [[String: Any]],
				  let first = results.first else {
				return nil
			}
			
			var screenshots = (first["screenshotUrls"] as? [String])?.compactMap { URL(string: $0) } ?? []
			if screenshots.isEmpty {
				screenshots = (first["ipadScreenshotUrls"] as? [String])?.compactMap { URL(string: $0) } ?? []
			}
			
			let artString = (first["artworkUrl512"] as? String) ?? (first["artworkUrl100"] as? String)
			let artworkURL = artString.flatMap { URL(string: $0) }
			let description = first["description"] as? String
			let releaseNotes = first["releaseNotes"] as? String
			let sellerName = first["sellerName"] as? String
			let genre = first["primaryGenreName"] as? String
			let contentRating = first["trackContentRating"] as? String
			let rating = first["averageUserRating"] as? Double
			
			var parsedBytes: Int64? = nil
			if let sizeStr = first["fileSizeBytes"] as? String, let b = Int64(sizeStr) {
				parsedBytes = b
			} else if let sizeNum = first["fileSizeBytes"] as? NSNumber {
				parsedBytes = sizeNum.int64Value
			}
			
			return AppleStoreRichMetadata(
				screenshots: screenshots,
				artworkURL: artworkURL,
				description: description,
				releaseNotes: releaseNotes,
				sellerName: sellerName,
				genre: genre,
				contentRating: contentRating,
				rating: rating,
				fileSizeBytes: parsedBytes
			)
		} catch {
			return nil
		}
	}
}

// MARK: - Zero-Lag Bilingual Search & Clean Localization Engine
enum AppStoreBilingualEngine {
	nonisolated static let rawSynonymGroups: [[String]] = [
		["instagram", "insta", "ig", "rocket", "plus", "bhinsta", "انستقرام", "انستا", "انستجرام", "إنستجرام", "انستغرام", "إنستغرام"],
		["whatsapp", "watusi", "wa", "واتساب", "واتس", "واتس اب", "وتساب"],
		["tiktok", "tik tok", "lrd", "bh", "dl", "تيك توك", "تيكتوك", "تك توك"],
		["snapchat", "snap", "wicked", "shadow", "سناب", "سناب شات", "سنابشات"],
		["youtube", "uplus", "uyou", "cercube", "yt", "يوتيوب", "يتوب", "فيديو"],
		["telegram", "swiftgram", "nicegram", "tele", "تليجرام", "تلغرام", "تلكرام", "تيليجرام"],
		["twitter", "x", "bhx", "twt", "تويتر", "اكس", "إكس"],
		["facebook", "fb", "wolf", "فيسبوك", "فيس بوك", "فيس"],
		["messenger", "مسنجر", "ماسنجر"],
		["discord", "enmity", "vendetta", "ديسكورد", "دسكورد"],
		["reddit", "ريديت"],
		["threads", "ثريدز"],
		["spotify", "eevee", "spotilife", "سبوتيفاي", "سبوتفاي", "موسيقى", "اغاني", "أغاني"],
		["soundcloud", "ساوند كلاود", "ساوندكلاود"],
		["shahid", "شاهد", "مسلسلات"],
		["netflix", "نتفلكس", "نتفليكس", "افلام", "أفلام"],
		["osn", "ostora", "اسطورة", "الأسطورة", "مباريات", "بث", "تلفزيون", "iptv", "tv", "movie", "anime", "انمي", "أنمي"],
		["capcut", "كاب كات", "كابكات", "مونتاج", "تعديل فيديو"],
		["picsart", "بيكس ارت", "بيكس آرت", "تعديل صور"],
		["lightroom", "لايت روم", "لايتروم", "فلاتر"],
		["inshot", "انشوت", "إنشوت"],
		["videostar", "video star", "فيديو ستار", "فيديوستار"],
		["alight", "alight motion", "الايت موشن", "ألايت موشن"],
		["canva", "كانفا", "تصميم"],
		["photoshop", "فوتوشوب"],
		["remini", "ريميني", "توضيح الصور"],
		["pubg", "ببجي", "بوبجي", "شدات"],
		["8ball", "pool", "8 ball", "بلياردو", "بول", "بليارد"],
		["roblox", "روبلوكس", "روبلكس"],
		["minecraft", "ماين كرافت", "ماينكرافت"],
		["subway", "صب واي", "سابوي", "ركض"],
		["gta", "san andreas", "قراند", "جاتا", "حرامي السيارات"],
		["cod", "call of duty", "كود", "كول اوف ديوتي"],
		["freefire", "free fire", "فري فاير"],
		["clash", "brawl", "كلاش", "براول ستارز"],
		["fifa", "fc", "pes", "efootball", "فيفا", "بيس", "كرة قدم"],
		["ludo", "yalla", "لودو", "يلا لودو"],
		["chess", "شطرنج"],
		["car", "racing", "drift", "سيارات", "سباق", "هجولة", "تفحيط"],
		["filza", "فيلزا", "مدير ملفات", "ملفات"],
		["esign", "feather", "scarlet", "gbox", "ksign", "x-sign", "vsign", "توقيع", "شهادات", "متجر", "اي ساين", "فيذر"],
		["troll", "trollstore", "ترول ستور", "ترول"],
		["vpn", "adblock", "dns", "في بي ان", "كاسر بروكسي", "حجب اعلانات", "مانع اعلانات"],
		["ai", "chatgpt", "gemini", "claude", "ذكاء اصطناعي", "شات جي بي تي", "جيميناي"]
	]
	
	// تجهيز المرادفات مسبقاً لمرة واحدة في الذاكرة لمنع أي لاك أثناء الكتابة في البحث
	nonisolated static let preNormalizedSynonymGroups: [[String]] = {
		rawSynonymGroups.map { group in
			group.map { normalize($0) }
		}
	}()
	
    nonisolated static let preparedAliasIndex = XSignSearchAliasIndex(groups: preNormalizedSynonymGroups)

    nonisolated static func normalize(_ text: String) -> String {
        XSignSearchDocument.normalize(text)
    }

    nonisolated static func buildFastSearchTokens(for app: ASRepository.App, category: AppStore2026Category) -> String {
        let document = XSignSearchDocument(name: app.currentName, bundleID: app.id ?? "", aliasIndex: preparedAliasIndex)
        return ([document.name, document.bundle, normalize(category.rawValue)] + document.aliases).joined(separator: " ")
    }

	nonisolated static func matchesQuery(tokens: String, normalizedQuery: String) -> Bool {
		guard !normalizedQuery.isEmpty else { return true }
		return tokens.contains(normalizedQuery)
	}
	
	nonisolated static func isInternalSourceNote(_ text: String?) -> Bool {
		guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
			return true
		}
		let lower = text.lowercased()
		return lower.hasPrefix("sources:") ||
			lower.contains("flekstore") ||
			lower.contains("unkeyapp") ||
			lower.contains("khoipa") ||
			lower.contains(" | ")
	}
	
	nonisolated static func localizedSubtitle(for app: ASRepository.App, category: AppStore2026Category) -> String {
		if let customDesc = app.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !customDesc.isEmpty,
		   !isInternalSourceNote(customDesc),
		   customDesc.count <= 65 {
			return customDesc
		}
		
		let nameAndID = "\(app.name ?? "") \(app.id ?? "")".lowercased()
		
		if nameAndID.contains("instagram") || nameAndID.contains("insta") || nameAndID.contains("rocket") {
			return AshteL10n.t("تواصل، شارك الصور والريلز بميزات إضافية")
		}
		if nameAndID.contains("whatsapp") || nameAndID.contains("watusi") {
			return AshteL10n.t("مراسلة فورية مع مزايا الخصوصية والتحميل")
		}
		if nameAndID.contains("tiktok") || nameAndID.contains("lrd") {
			return AshteL10n.t("فيديوهات قصيرة وحفظ بدون علامة مائية")
		}
		if nameAndID.contains("snapchat") || nameAndID.contains("wicked") || nameAndID.contains("shadow") {
			return AshteL10n.t("شارك اللحظات مع أدوات الحفظ المتقدمة")
		}
		if nameAndID.contains("youtube") || nameAndID.contains("uyou") || nameAndID.contains("uplus") {
			return AshteL10n.t("مشاهدة بدون إعلانات وتشغيل في الخلفية")
		}
		if nameAndID.contains("telegram") || nameAndID.contains("swiftgram") || nameAndID.contains("nicegram") {
			return AshteL10n.t("مراسلة سحابية سريعة وآمنة بلا حدود")
		}
		if nameAndID.contains("twitter") || nameAndID.contains("bhx") {
			return AshteL10n.t("أحدث الأخبار والتغريدات مع تحميل الوسائط")
		}
		if nameAndID.contains("spotify") || nameAndID.contains("eevee") {
			return AshteL10n.t("استمع للموسيقى والبودكاست بجودة عالية")
		}
		if nameAndID.contains("capcut") || nameAndID.contains("videostar") || nameAndID.contains("alight") || nameAndID.contains("inshot") {
			return AshteL10n.t("تحرير ومونتاج الفيديو باحترافية عالية")
		}
		if nameAndID.contains("picsart") || nameAndID.contains("lightroom") || nameAndID.contains("photoshop") || nameAndID.contains("remini") {
			return AshteL10n.t("تعديل الصور والفلاتر الاحترافية")
		}
		if nameAndID.contains("canva") {
			return AshteL10n.t("تصميم الجرافيك والشعارات بسهولة")
		}
		if nameAndID.contains("pubg") {
			return AshteL10n.t("معارك باتل رويال جماعية مشوقة")
		}
		if nameAndID.contains("pool") || nameAndID.contains("8ball") {
			return AshteL10n.t("لعبة البلياردو العالمية رقم 1")
		}
		if nameAndID.contains("roblox") {
			return AshteL10n.t("استمتع بلعب ملايين الألعاب والعوالم")
		}
		if nameAndID.contains("minecraft") {
			return AshteL10n.t("ابنِ عالمك واستكشف بلا حدود")
		}
		if nameAndID.contains("subway") || nameAndID.contains("minion") || nameAndID.contains("temple") || nameAndID.contains("sonic") {
			return AshteL10n.t("انضم إلى مرح دائم من الركض والقفز!")
		}
		if nameAndID.contains("filza") {
			return AshteL10n.t("مدير ملفات متكامل لنظام iOS")
		}
		if nameAndID.contains("esign") || nameAndID.contains("feather") || nameAndID.contains("scarlet") || nameAndID.contains("sign") {
			return AshteL10n.t("توقيع وتثبيت تطبيقات IPA بسهولة")
		}
		
		return category.defaultArabicSubtitle
	}
}

struct AppStoreAppItem: Identifiable, Hashable, Sendable {
	let id: String
	let sourceURL: URL?
    let sourceName: String
    let sourceCategories: [ASRepository.CatalogCategory]
	let app: ASRepository.App
	let category: AppStore2026Category
	let isGame: Bool
	let arabicSubtitle: String
	let searchIndexTokens: String
    let searchDocument: XSignSearchDocument
	let screenshots: [URL]
	
	init(id: String, sourceURL: URL?, repository: ASRepository, app: ASRepository.App) {
		self.id = id
		self.sourceURL = sourceURL
        self.sourceName = repository.name ?? "المصدر"
        self.sourceCategories = repository.categories ?? []
		self.app = app
		
		let inferred = AppStore2026Category.strictlyClassify(app: app)
        // AshteMobile rows are split explicitly: category "games" -> Games tab, "apps" -> Apps tab.
        let rawCategory = (app.category ?? "").lowercased()
        let declaredGame: Bool? = rawCategory == "games" ? true
            : rawCategory == "apps" ? false
            : repository.categories?.first(where: { $0.id == app.category })?.isGame
        let classified: AppStore2026Category = declaredGame == true && !inferred.isGameCategory ? .casualGames
            : declaredGame == false && inferred.isGameCategory ? .productivity : inferred
		self.category = classified
		self.isGame = declaredGame ?? classified.isGameCategory
		self.arabicSubtitle = AppStoreBilingualEngine.localizedSubtitle(for: app, category: classified)
        self.searchDocument = XSignSearchDocument(name: app.currentName, bundleID: app.id ?? "", aliasIndex: AppStoreBilingualEngine.preparedAliasIndex)
        self.searchIndexTokens = ([searchDocument.name, searchDocument.bundle] + searchDocument.aliases).joined(separator: " ")
		
		if let urls = app.screenshotURLs, !urls.isEmpty {
			self.screenshots = urls
		} else if let iphone = app.screenshots?.iPhone, !iphone.isEmpty {
			self.screenshots = iphone
		} else {
			self.screenshots = []
		}
	}
	
	nonisolated func matchesNormalizedQuery(_ normalizedQuery: String) -> Bool {
		searchDocument.score(for: normalizedQuery) != nil
	}
	
	static func == (lhs: AppStoreAppItem, rhs: AppStoreAppItem) -> Bool {
		lhs.id == rhs.id
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}

// MARK: - Editorial Instruction Model
enum XSignSearchEngine {
    nonisolated static func search(_ items: [AppStoreAppItem], query: String) -> [AppStoreAppItem]? {
        let query = XSignSearchDocument.normalize(query)
        guard !query.isEmpty else { return [] }
        var matches: [(score: Int, position: Int)] = []
        for (position, item) in items.enumerated() {
            if position.isMultiple(of: 64), Task.isCancelled { return nil }
            if let score = item.searchDocument.score(for: query) { matches.append((score, position)) }
        }
        matches.sort { $0.score == $1.score ? $0.position < $1.position : $0.score < $1.score }
        guard !Task.isCancelled else { return nil }
        return matches.map { items[$0.position] }
    }
}

@MainActor
final class XSignSearchResults: ObservableObject {
    @Published private(set) var visible: [AppStoreAppItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var total = 0
    private var ranked: [AppStoreAppItem] = []
    private var task: Task<Void, Never>?
    private var worker: Task<[AppStoreAppItem]?, Never>?
    private var generation: UInt64 = 0

    func update(query: String, items: [AppStoreAppItem]) {
        cancel()
        let current = generation
        let normalized = XSignSearchDocument.normalize(query)
        guard !normalized.isEmpty else {
            visible = []; ranked = []; total = 0; isSearching = false; return
        }
        isSearching = true
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self, self.generation == current, !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { XSignSearchEngine.search(items, query: normalized) }
            self.worker = work
            guard let result = await work.value, !Task.isCancelled, self.generation == current else { return }
            self.ranked = result
            self.total = result.count
            self.visible = Array(result.prefix(40))
            self.isSearching = false
            self.worker = nil
        }
    }

    func showMore() { visible = Array(ranked.prefix(visible.count + 40)) }
    func cancel() {
        generation &+= 1
        task?.cancel(); worker?.cancel(); task = nil; worker = nil
        isSearching = false
    }
}

struct TodayEditorialInstruction: Identifiable, Sendable {
	let id: String
	let badge: String
	let title: String
	let caption: String
	let imageURL: URL?
	let tintColor: Color
	let associatedApp: AppStoreAppItem?
    let targetURL: URL?
}

enum AppStore2026Category: String, CaseIterable, Identifiable, Sendable {
	case topApps = "مختارات التطبيقات"
	case topGames = "مختارات الألعاب"
	case bestSellingApps = "اكتشف تطبيقات أخرى"
	case bestSellingGames = "اكتشف ألعابًا أخرى"
	case puzzleGames = "ألعاب ألغاز"
	case simulationGames = "ألعاب محاكاة"
	case social = "التواصل الاجتماعي"
	case casualGames = "ألعاب تسالي"
	case timePass = "تمضية وقت"
	case mediaReaders = "قارئات الوسائط"
	case productivity = "إنتاجية"
	case strategyGames = "ألعاب إستراتيجية"
	case pvpGames = "لاعب ضد لاعب"
	case devTools = "تطبيقات أدوات التطوير"
	case visualArts = "فنون بصرية"
	case photoVideo = "صور وفيديو"
	
	var id: String { rawValue }
	
	/// Localized display name (rawValue stays the stable Arabic identifier).
	nonisolated var title: String { AshteL10n.t(rawValue) }
	
	nonisolated var isGameCategory: Bool {
		switch self {
		case .topGames, .bestSellingGames, .puzzleGames, .simulationGames, .casualGames, .timePass, .strategyGames, .pvpGames:
			return true
		case .topApps, .bestSellingApps, .social, .mediaReaders, .productivity, .devTools, .visualArts, .photoVideo:
			return false
		}
	}
	
	nonisolated var defaultArabicSubtitle: String {
		switch self {
		case .topApps, .bestSellingApps: return AshteL10n.t("تطبيق مميز للآيفون")
		case .topGames, .bestSellingGames: return AshteL10n.t("لعبة رائجة ومختارة")
		case .puzzleGames: return AshteL10n.t("ألغاز وتحديات ذكاء ممتعة")
		case .simulationGames: return AshteL10n.t("محاكاة واقعية وبناء عوالم")
		case .social: return AshteL10n.t("تواصل اجتماعي ومراسلة فورية")
		case .casualGames: return AshteL10n.t("ألعاب تسالي سريعة وممتعة")
		case .timePass: return AshteL10n.t("ترفيه وتسلية في كل وقت")
		case .mediaReaders: return AshteL10n.t("مشاهدة الفيديو والموسيقى")
		case .productivity: return AshteL10n.t("إنتاجية وأدوات ذكية يومية")
		case .strategyGames: return AshteL10n.t("تخطيط، معارك، وإستراتيجية")
		case .pvpGames: return AshteL10n.t("منافسات جماعية لاعب ضد لاعب")
		case .devTools: return AshteL10n.t("أدوات النظام والتوقيع والمطورين")
		case .visualArts: return AshteL10n.t("تصميم جرافيك وفنون رقمية")
		case .photoVideo: return AshteL10n.t("تصوير ومونتاج وتحرير احترافي")
		}
	}
	
	var sfSymbol: String {
		switch self {
		case .topApps:          return "star.fill"
		case .topGames:         return "trophy.fill"
		case .bestSellingApps:  return "crown.fill"
		case .bestSellingGames: return "medal.fill"
		case .puzzleGames:      return "puzzlepiece.fill"
		case .simulationGames:  return "house.and.flag.fill"
		case .social:           return "bubble.left.and.bubble.right.fill"
		case .casualGames:      return "airplane.departure"
		case .timePass:         return "sparkles"
		case .mediaReaders:     return "book.pages.fill"
		case .productivity:     return "paperplane.fill"
		case .strategyGames:    return "flag.2.crossed.fill"
		case .pvpGames:         return "gamecontroller.fill"
		case .devTools:         return "wrench.and.screwdriver.fill"
		case .visualArts:       return "paintpalette.fill"
		case .photoVideo:       return "camera.fill"
		}
	}
	
	var gradientColors: [Color] {
		switch self {
		case .topApps:
			return [Color(red: 0.04, green: 0.45, blue: 0.85), Color(red: 0.02, green: 0.25, blue: 0.58)]
		case .topGames:
			return [Color(red: 0.96, green: 0.69, blue: 0.45), Color(red: 0.92, green: 0.53, blue: 0.31)]
		case .bestSellingApps:
			return [Color(red: 0.52, green: 0.85, blue: 0.49), Color(red: 0.35, green: 0.75, blue: 0.38)]
		case .bestSellingGames:
			return [Color(red: 0.69, green: 0.62, blue: 0.98), Color(red: 0.56, green: 0.47, blue: 0.94)]
		case .puzzleGames:
			return [Color(red: 0.53, green: 0.84, blue: 0.96), Color(red: 0.38, green: 0.72, blue: 0.88)]
		case .simulationGames:
			return [Color(red: 0.55, green: 0.84, blue: 0.68), Color(red: 0.40, green: 0.72, blue: 0.54)]
		case .social:
			return [Color(red: 0.08, green: 0.52, blue: 0.92), Color(red: 0.04, green: 0.32, blue: 0.68)]
		case .casualGames:
			return [Color(red: 0.55, green: 0.82, blue: 0.95), Color(red: 0.42, green: 0.72, blue: 0.89)]
		case .timePass:
			return [Color(red: 0.54, green: 0.84, blue: 0.96), Color(red: 0.42, green: 0.75, blue: 0.90)]
		case .mediaReaders:
			return [Color(red: 0.96, green: 0.71, blue: 0.42), Color(red: 0.91, green: 0.58, blue: 0.27)]
		case .productivity:
			return [Color(red: 0.12, green: 0.48, blue: 0.84), Color(red: 0.05, green: 0.28, blue: 0.56)]
		case .strategyGames:
			return [Color(red: 0.54, green: 0.82, blue: 0.48), Color(red: 0.42, green: 0.72, blue: 0.38)]
		case .pvpGames:
			return [Color(red: 0.79, green: 0.56, blue: 0.98), Color(red: 0.68, green: 0.40, blue: 0.93)]
		case .devTools:
			return [Color(red: 0.06, green: 0.42, blue: 0.78), Color(red: 0.02, green: 0.22, blue: 0.48)]
		case .visualArts:
			return [Color(red: 0.55, green: 0.85, blue: 0.96), Color(red: 0.42, green: 0.75, blue: 0.90)]
		case .photoVideo:
			return [Color(red: 0.94, green: 0.79, blue: 0.48), Color(red: 0.88, green: 0.68, blue: 0.34)]
		}
	}
	
	nonisolated static func strictlyClassify(app: ASRepository.App) -> AppStore2026Category {
		let catRaw = (app.category ?? "").lowercased()
		if catRaw == "games" {
			// Only look at the game sub-genres; never let app keywords (e.g. "dl" in "Idle") turn a game into a tool.
			let gameText = "\(app.name ?? "") \(app.id ?? "")".lowercased()
			let genres: [(AppStore2026Category, [String])] = [
				(.pvpGames, ["pubg", "8ball", "pool", "freefire", "brawl", "fortnite", "fifa", "efootball", "mobilelegends", "wildrift", "standoff", "pvp", "multiplayer", "ببجي", "بلياردو", "فري فاير", "فيفا"]),
				(.strategyGames, ["clash", "royale", "clans", "strategy", "chess", "tower", "defense", "empire", "civilization", "boombeach", "كلاش", "شطرنج", "استراتيجيه"]),
				(.simulationGames, ["roblox", "minecraft", "sims", "simcity", "gta", "sanandreas", "parking", "simulator", "truck", "flight", "farm", "hayday", "township", "روبلوكس", "محاكاة", "مزرعه"]),
				(.puzzleGames, ["puzzle", "candy", "crush", "match", "brain", "sudoku", "word", "gardenscapes", "homescapes", "royalmatch", "2048", "trivia", "sort", "merge", "block", "الغاز", "ألغاز"])
			]
			for (genre, words) in genres where words.contains(where: { gameText.contains($0) }) { return genre }
			return .casualGames
		}
		if catRaw == "social" { return .social }
		if catRaw == "media" { return .photoVideo }
		if catRaw == "tools" { return .devTools }
		
		let nameAndBundle = "\(app.name ?? "") \(app.id ?? "") \(catRaw)".lowercased()
		let desc = (app.localizedDescription ?? app.subtitle ?? "").lowercased()
		let combined = "\(nameAndBundle) \(desc)"
		
		let socialApps = ["instagram", "whatsapp", "tiktok", "snapchat", "twitter", "telegram", "facebook", "discord", "messenger", "reddit", "threads", "watusi", "bhinsta", "uplus", "rocket", "swiftgram", "nicegram", "wicked", "انستقرام", "واتس", "تيك توك", "سناب", "تليجرام", "تويتر", "فيسبوك", "ديسكورد"]
		if socialApps.contains(where: { nameAndBundle.contains($0) }) { return .social }
		
		let mediaApps = ["youtube", "uyou", "cercube", "spotify", "eevee", "soundcloud", "shahid", "netflix", "ostora", "iptv", "movie", "anime", "music", "podcast", "player", "infuse", "vlc", "يوتيوب", "سبوتيفاي", "شاهد", "نتفلكس", "افلام", "مسلسلات", "انمي", "موسيقى", "اسطورة"]
		if mediaApps.contains(where: { nameAndBundle.contains($0) }) { return .mediaReaders }
		
		let photoVideoApps = ["capcut", "lightroom", "picsart", "inshot", "videostar", "alight", "photoshop", "remini", "vn", "camera", "dazz", "lensa", "b612", "snow", "vsco", "snapseed", "كاب كات", "بيكس ارت", "لايت روم", "فيديو ستار", "مونتاج", "فوتوشوب"]
		if photoVideoApps.contains(where: { nameAndBundle.contains($0) }) { return .photoVideo }
		
		let visualArtApps = ["canva", "procreate", "ibis", "sketch", "pixelmator", "vector", "font", "logo", "كانفا", "رسم", "خطوط"]
		if visualArtApps.contains(where: { nameAndBundle.contains($0) }) { return .visualArts }
		
		let devToolApps = ["filza", "esign", "feather", "scarlet", "troll", "gbox", "ksign", "x-sign", "vsign", "vpn", "adblock", "adguard", "dns", "flex", "igamegod", "dl", "terminal", "ssh", "cert", "ipa", "sideload", "altstore", "فيلزا", "توقيع", "شهادات", "ترول"]
		if devToolApps.contains(where: { nameAndBundle.contains($0) }) { return .devTools }
		
		let pvpKeywords = ["pubg", "8ball", "pool", "cod", "callofduty", "freefire", "brawl", "fortnite", "fifa", "efootball", "pes", "mobilelegends", "wildrift", "standoff", "bullet", "pvp", "multiplayer", "ark", "ببجي", "بلياردو", "فري فاير", "كود", "فيفا", "بيس"]
		if pvpKeywords.contains(where: { combined.contains($0) }) { return .pvpGames }
		
		let strategyKeywords = ["clash", "royale", "clans", "strategy", "chess", "tower", "defense", "war", "stick war", "empire", "civilization", "boombeach", "plantsvs", "كلاش", "شطرنج", "حرب", "استراتيجيه"]
		if strategyKeywords.contains(where: { combined.contains($0) }) { return .strategyGames }
		
		let simulationKeywords = ["roblox", "minecraft", "sims", "simcity", "gta", "rockstar", "sanandreas", "parking", "simulator", "bus", "truck", "flight", "farm", "hayday", "township", "روبلوكس", "ماين كرافت", "قراند", "محاكاة", "مزرعه"]
		if simulationKeywords.contains(where: { combined.contains($0) }) { return .simulationGames }
		
		let puzzleKeywords = ["puzzle", "candy", "crush", "match", "brain", "sudoku", "word", "gardenscapes", "homescapes", "royalmatch", "angrybirds", "cuttherope", "2048", "trivia", "الغاز", "ألغاز", "ذكاء", "كلمات"]
		if puzzleKeywords.contains(where: { combined.contains($0) }) { return .puzzleGames }
		
		let casualGameKeywords = [
			"game", "games", "gaming", "arcade", "subway", "surfers", "minion", "temple", "run", "sonic",
			"talking", "tom", "flappy", "jump", "racing", "race", "asphalt", "carx", "drift", "hillclimb",
			"ludo", "yalla", "uno", "monopoly", "fruitninja", "jetpack", "pacman", "mario", "pokemon",
			"zelda", "ppsspp", "delta", "retroarch", "emulator", "hack", "playdead", "gameloft", "supercell",
			"zynga", "rovio", "ketchapp", "voodoo", "miniclip", "ubisoft", "activision", "konami", "sega",
			"لعبة", "لعبه", "العاب", "ألعاب"
		]
		if casualGameKeywords.contains(where: { combined.contains($0) }) { return .casualGames }
		
		return .productivity
	}
}

// MARK: - Cached catalog shown before background refresh
private struct XSignCatalogSnapshot: Sendable {
    var primaryItems: [AppStoreAppItem] = []
    var primaryEditorialNews: [TodayEditorialInstruction] = []
    var allCombinedItems: [AppStoreAppItem] = []
    var pureAppsOnly: [AppStoreAppItem] = []
    var pureGamesOnly: [AppStoreAppItem] = []
    var itemsByCategory: [AppStore2026Category: [AppStoreAppItem]] = [:]
    var includesPrimary = false
    var sourceName = "AshteMobile"
    var sourceSubtitle = ""
    var sourceIconURL: URL? = nil
    var sourceCategories: [ASRepository.CatalogCategory] = []
    var skippedLookupBundleIDs: Set<String> = []
}

@MainActor
final class AppStoreCacheManager: ObservableObject {
    static let shared = AppStoreCacheManager()

    @Published private var catalog = XSignCatalogSnapshot()
    var primaryItems: [AppStoreAppItem] { catalog.primaryItems }
    var primaryEditorialNews: [TodayEditorialInstruction] { catalog.primaryEditorialNews }
    var allCombinedItems: [AppStoreAppItem] { catalog.allCombinedItems }
    var pureAppsOnly: [AppStoreAppItem] { catalog.pureAppsOnly }
    var pureGamesOnly: [AppStoreAppItem] { catalog.pureGamesOnly }
    var itemsByCategory: [AppStore2026Category: [AppStoreAppItem]] { catalog.itemsByCategory }

    var sourceName: String { catalog.sourceName }
    var sourceSubtitle: String { catalog.sourceSubtitle }
    var sourceIconURL: URL? { catalog.sourceIconURL }
    var sourceCategories: [ASRepository.CatalogCategory] { catalog.sourceCategories }
    var hasLoadedCatalog: Bool { !catalog.allCombinedItems.isEmpty || finishedInitialLoad }
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPreparing = false
    @Published private(set) var catalogErrorMessage: String? = nil
    @Published private(set) var catalogRevision: UInt64 = 0
    private var finishedInitialLoad = false
    private var publicationTask: Task<Void, Never>?
    private var sourceSubscription: AnyCancellable?
    private var requestedSources: [AltSource] = []
    private var customFingerprints: [String: Data] = [:]
    private let catalogIO: XSignCatalogIO
    private let bundledResources: URL?

    func shouldSkipStoreLookup(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return catalog.skippedLookupBundleIDs.contains(bundleID)
    }

    private var directLoadedRepos: [String: ASRepository] = [:]
    private var repoFingerprints: [String: Data] = [:]
    private var customSnapshot: [(URL?, String?, ASRepository)] = []
    private var diskSnapshotTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var nextRefreshAllowed = Date.distantPast
    private var indexGeneration: UInt64 = 0
    private var indexTask: Task<XSignCatalogSnapshot?, Never>?

    private nonisolated static let defaultCoreTargets: [(urlStr: String, id: String, file: String, seed: String)] = [
        (ProtectedSourcesVault.primaryURLString, ProtectedSourcesVault.primaryIdentifier, "ashtemobile_cache.json", "XSignLaunchAshteMobile")
    ]

    // The AshteMobile catalog is built in. Extra managed sources may be added, but cannot remove it.
    nonisolated static func resolvedManagedSources(_ configured: [XSignCoreSourceItem]?) -> [XSignCoreSourceItem] {
        var sources = defaultCoreTargets.map {
            XSignCoreSourceItem(name: ProtectedSourcesVault.primaryName, id: $0.id, url: $0.urlStr)
        }
        var seenURLs = Set(sources.compactMap { URL(string: $0.url) }.map { XSignCatalogIO.canonicalURL($0).absoluteString })
        var seenIDs = Set(sources.map { $0.id })
        for source in configured ?? [] {
            guard !ProtectedSourcesVault.isRetiredSource(URL(string: source.url), identifier: source.id) else { continue }
            guard let url = URL(string: source.url), url.scheme?.lowercased() == "https", url.host != nil,
                  !source.id.isEmpty else { continue }
            let key = XSignCatalogIO.canonicalURL(url).absoluteString
            guard !seenURLs.contains(key), !seenIDs.contains(source.id) else { continue }
            sources.append(XSignCoreSourceItem(name: source.name, id: source.id, url: key))
            seenURLs.insert(key); seenIDs.insert(source.id)
        }
        return sources
    }

    private nonisolated static var coreTargets: [(urlStr: String, id: String, file: String, seed: String)] {
        let configured = UserDefaults.standard.data(forKey: "xsign.managedSources")
            .flatMap { try? JSONDecoder().decode([XSignCoreSourceItem].self, from: $0) }
        return resolvedManagedSources(configured).map { source in
            let known = defaultCoreTargets.first { $0.id == source.id }
            let file = known?.file ?? "managed_" + SHA256.hash(data: Data(source.url.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".json"
            return (source.url, source.id, file, known?.seed ?? "")
        }
    }

    @discardableResult
    func configureManagedSources(_ sources: [XSignCoreSourceItem]?) -> Bool {
        let valid = Self.resolvedManagedSources(sources)
        guard let encoded = try? JSONEncoder().encode(valid) else { return false }
        let prior = UserDefaults.standard.data(forKey: "xsign.managedSources")
        if let prior, (try? JSONDecoder().decode([XSignCoreSourceItem].self, from: prior)) == valid { return false }
        UserDefaults.standard.set(encoded, forKey: "xsign.managedSources")
        let allowed = Set(valid.map { $0.url })
        directLoadedRepos = directLoadedRepos.filter { allowed.contains($0.key) }
        repoFingerprints = repoFingerprints.filter { allowed.contains($0.key) }
        nextRefreshAllowed = .distantPast
        restoreBoundedLaunchPreviews()
        scheduleSnapshot(priority: .userInitiated)
        loadInstantDiskSnapshot()
        return true
    }

    func invalidateNetworkCache() {
        repoFingerprints.removeAll()
        nextRefreshAllowed = .distantPast
        for target in Self.coreTargets { UserDefaults.standard.removeObject(forKey: "XSign.catalog.etag." + target.file) }
        // Keep the visible snapshot and last good disk catalog until a valid response replaces them.
        Task { await AppStoreLiveMetadataBridge.shared.invalidateCache() }
    }

    private nonisolated static var diskCacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignInstantStoreCache_v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func restoreBoundedLaunchPreviews() {
        for target in Self.coreTargets where directLoadedRepos[target.urlStr] == nil {
            let disk = Self.diskCacheDirectory.appendingPathComponent("preview_" + target.file)
            let bundle = bundledResources?.appendingPathComponent(target.seed + ".json") ?? Bundle.main.url(forResource: target.seed, withExtension: "json")
            for path in [Optional(disk), bundle].compactMap({ $0 }) {
                guard let size = (try? path.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      size <= 131_072, let data = try? Data(contentsOf: path),
                      let record = try? XSignCatalogIO.decode(data), record.repository.apps.count <= 24 else { continue }
                directLoadedRepos[target.urlStr] = record.repository
                break
            }
        }
    }

    // Only a small first screen is prepared synchronously. The full bundled catalog is decoded off-main.
    init(catalogIO: XSignCatalogIO = .shared, bundledResources: URL? = nil) {
        self.catalogIO = catalogIO
        self.bundledResources = bundledResources
        restoreBoundedLaunchPreviews()
        let preview = Self.coreTargets.compactMap { target -> (URL?, String?, ASRepository)? in
            guard let repo = directLoadedRepos[target.urlStr] else { return nil }
            return (URL(string: target.urlStr).map(XSignCatalogIO.canonicalURL), target.id, repo)
        }
        if let snapshot = Self.buildSnapshot(snapshot: preview, previousItems: []) { catalog = snapshot }
        loadInstantDiskSnapshot()
    }

    private func loadInstantDiskSnapshot() {
        diskSnapshotTask?.cancel()
        let targets = Self.coreTargets
        diskSnapshotTask = Task { @MainActor [weak self] in
            for target in targets {
                guard !Task.isCancelled, let url = URL(string: target.urlStr),
                      let self, let record = await self.catalogIO.cached(url) else { continue }
                guard !Task.isCancelled, Self.coreTargets.contains(where: { $0.urlStr == target.urlStr }) else { continue }
                self.acceptRepository(record, from: url)
            }
            guard !Task.isCancelled, let self else { return }
            await self.publicationTask?.value
        }
    }

    func acceptRepository(_ record: XSignRepositoryRecord, from input: URL) {
        let key = XSignCatalogIO.canonicalURL(input).absoluteString
        guard let target = Self.coreTargets.first(where: {
            URL(string: $0.urlStr).map { XSignCatalogIO.canonicalURL($0).absoluteString } == key
        }), repoFingerprints[target.urlStr] != record.fingerprint else { return }
        directLoadedRepos[target.urlStr] = record.repository
        repoFingerprints[target.urlStr] = record.fingerprint
        scheduleSnapshot(priority: .userInitiated)
        let repo = record.repository
        let path = Self.diskCacheDirectory.appendingPathComponent("preview_" + target.file)
        Task.detached(priority: .utility) {
            if let preview = Self.makeLaunchPreview(repo) { try? preview.write(to: path, options: .atomic) }
        }
    }

    private func customSources(_ sources: [AltSource]) -> [AltSource] {
        let managed = Set(Self.coreTargets.compactMap { URL(string: $0.urlStr) }.map { XSignCatalogIO.canonicalURL($0).absoluteString })
        // A manually added core URL must still load when it is absent from the dashboard list.
        return sources.filter { source in
            guard let url = source.sourceURL else { return false }
            guard !ProtectedSourcesVault.isRetiredSource(url, identifier: source.identifier) else { return false }
            return !managed.contains(XSignCatalogIO.canonicalURL(url).absoluteString)
        }
    }

    func ensureFetched<S: Collection>(sources: S, viewModel: SourcesViewModel) async where S.Element == AltSource {
        await refresh(sources: Array(sources), viewModel: viewModel, force: false)
    }

    func runAutomaticUpdates(sources: @escaping @MainActor () -> [AltSource], viewModel: SourcesViewModel) async {
        while !Task.isCancelled {
            await ensureFetched(sources: sources(), viewModel: viewModel)
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        }
    }

    func waitForInitialCatalog() async {
        await diskSnapshotTask?.value
        await publicationTask?.value
    }

    func forceRefresh<S: Collection>(sources: S, viewModel: SourcesViewModel) async where S.Element == AltSource {
        await refresh(sources: Array(sources), viewModel: viewModel, force: true)
    }

    private func refresh(sources: [AltSource], viewModel: SourcesViewModel, force: Bool) async {
        requestedSources = sources
        if sourceSubscription == nil {
            sourceSubscription = viewModel.$sources.sink { [weak self, weak viewModel] repositories in
                guard let self, let viewModel else { return }
                self.rebuildCustomSnapshot(sources: self.requestedSources, repositories: repositories, viewModel: viewModel)
            }
        }
        if let running = refreshTask {
            if force { refreshAgain = true }
            await running.value
            // A source added during an existing refresh must not get lost.
            if customSources(requestedSources).contains(where: { viewModel.sources[$0] == nil && viewModel.errors[$0] == nil }) {
                await refresh(sources: requestedSources, viewModel: viewModel, force: false)
            }
            return
        }
        let custom = customSources(sources)
        let hasNewSources = custom.contains { viewModel.sources[$0] == nil && viewModel.errors[$0] == nil }
        guard force || hasNewSources || Date() >= nextRefreshAllowed else {
            rebuildCacheIfNeeded(sources: sources, repositoriesMap: viewModel.sources)
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer { self.refreshTask = nil; self.isRefreshing = false; self.finishedInitialLoad = true }
            await self.diskSnapshotTask?.value
            repeat {
                self.refreshAgain = false
                let custom = self.customSources(self.requestedSources)
                async let coreSucceeded = self.fetchCoreRepositories()
                // This path already passed the refresh deadline. Refresh custom URLs too,
                // even when a previous response is visible; otherwise they never update automatically.
                await viewModel.fetchSources(custom, refresh: true, batchSize: 1)
                let succeeded = await coreSucceeded
                self.rebuildCacheIfNeeded(sources: self.requestedSources, repositoriesMap: viewModel.sources)
                await self.publicationTask?.value
                if self.catalogErrorMessage == nil, !viewModel.errors.isEmpty {
                    self.catalogErrorMessage = AshteL10n.t("تعذّر تحديث أحد المصادر. البيانات المحفوظة ما زالت متاحة؛ اسحب لأسفل للمحاولة مجددًا.")
                }
                self.nextRefreshAllowed = Date().addingTimeInterval(succeeded ? 300 : 15)
            } while self.refreshAgain && !Task.isCancelled
        }
        refreshTask = task
        await task.value
    }

    private func fetchCoreRepositories() async -> Bool {
        let targets = Self.coreTargets
        var failures = 0
        var successes = 0
        // Neither built-in source waits behind another source's network timeout.
        await withTaskGroup(of: (URL, XSignRepositoryRecord?).self) { group in
            for target in targets {
                guard let url = URL(string: target.urlStr) else { failures += 1; continue }
                let io = catalogIO
                group.addTask { (url, try? await io.fetch(url)) }
            }
            for await (url, record) in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let record { acceptRepository(record, from: url); successes += 1 }
                else { failures += 1 }
            }
        }
        catalogErrorMessage = failures > 0 ? AshteL10n.t("تعذّر تحديث أحد المصادر. سنعيد المحاولة تلقائيًا؛ المحتوى المحفوظ متاح.") : nil
        return successes > 0 && failures == 0
    }

    func rebuildCacheIfNeeded<S: Collection>(sources: S, repositoriesMap: [AltSource: ASRepository]) where S.Element == AltSource {
        requestedSources = Array(sources)
        rebuildCustomSnapshot(sources: requestedSources, repositories: repositoriesMap, viewModel: .shared)
    }

    private func rebuildCustomSnapshot(sources: [AltSource], repositories: [AltSource: ASRepository], viewModel: SourcesViewModel) {
        var signatures: [String: Data] = [:]
        var seen = Set<String>()
        let next: [(URL?, String?, ASRepository)] = customSources(sources).compactMap { source in
            guard let input = source.sourceURL, let repo = repositories[source] else { return nil }
            let url = XSignCatalogIO.canonicalURL(input)
            guard seen.insert(url.absoluteString).inserted else { return nil }
            signatures[url.absoluteString] = viewModel.fingerprint(for: source) ?? Data()
            return (url, source.identifier, repo)
        }
        guard signatures != customFingerprints else { return }
        customFingerprints = signatures
        customSnapshot = next
        scheduleSnapshot(priority: .userInitiated)
    }

    private func scheduleSnapshot(priority: TaskPriority) {
        var entries = customSnapshot
        for target in Self.coreTargets {
            if let repo = directLoadedRepos[target.urlStr] {
                entries.append((URL(string: target.urlStr).map(XSignCatalogIO.canonicalURL), target.id, repo))
            }
        }
        indexGeneration &+= 1
        let generation = indexGeneration
        indexTask?.cancel()
        publicationTask?.cancel()
        guard !entries.isEmpty else {
            catalog = XSignCatalogSnapshot(); indexTask = nil; isPreparing = false
            catalogRevision &+= 1
            return
        }
        let input = entries
        let previous = allCombinedItems
        isPreparing = true
        let worker = Task.detached(priority: priority) {
            Self.buildSnapshot(snapshot: input, previousItems: previous)
        }
        indexTask = worker
        publicationTask = Task { @MainActor [weak self] in
            guard let next = await worker.value, !Task.isCancelled, let self, self.indexGeneration == generation else { return }
            self.catalog = next
            self.catalogRevision &+= 1
            self.isPreparing = false
            self.indexTask = nil
        }
    }

    private nonisolated static func makeLaunchPreview(_ repo: ASRepository) -> Data? {
        var games: [ASRepository.App] = []
        var apps: [ASRepository.App] = []
        for app in repo.apps {
            if AppStore2026Category.strictlyClassify(app: app).isGameCategory {
                if games.count < 12 { games.append(app) }
            } else if apps.count < 12 { apps.append(app) }
            if apps.count == 12 && games.count == 12 { break }
        }
        var selected = apps + games
        if selected.count < 24 {
            let used = Set(selected.map { $0.stableCatalogIdentifier })
            selected += repo.apps.lazy.filter { !used.contains($0.stableCatalogIdentifier) }.prefix(24 - selected.count)
        }
        let page = selected.map { app -> [String: Any] in
            var item: [String: Any] = ["name": app.currentName]
            item["bundleIdentifier"] = app.id
            item["catalogID"] = app.catalogID
            item["downloadURL"] = app.currentDownloadUrl?.absoluteString
            item["iconURL"] = app.iconURL?.absoluteString
            item["version"] = app.currentVersion
            item["size"] = app.size
            item["category"] = app.category
            item["skipAppStoreLookup"] = app.skipAppStoreLookup
            item["developerName"] = app.developer
            item["subtitle"] = app.subtitle.map { String($0.prefix(200)) }
            item["localizedDescription"] = app.localizedDescription.map { String($0.prefix(800)) }
            return item
        }
        var root: [String: Any] = ["apps": page]
        root["name"] = repo.name
        root["identifier"] = repo.id
        root["subtitle"] = repo.subtitle
        root["iconURL"] = repo.iconURL?.absoluteString
        guard let data = try? JSONSerialization.data(withJSONObject: root), data.count <= 131_072 else { return nil }
        return data
    }

    private nonisolated static func sameAppContent(_ first: ASRepository.App, _ second: ASRepository.App) -> Bool {
        var comparable = second
        comparable.uuid = first.uuid
        return first == comparable
    }

    private nonisolated static func buildSnapshot(snapshot: [(URL?, String?, ASRepository)], previousItems: [AppStoreAppItem]) -> XSignCatalogSnapshot? {
		if Task.isCancelled { return nil }
        let previousByID = Dictionary(previousItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		let totalCount = snapshot.reduce(0) { $0 + $1.2.apps.count }
		var allItems: [AppStoreAppItem] = []
		var primaryOnly: [AppStoreAppItem] = []
		var primaryNews: [TodayEditorialInstruction] = []
		var didIncludePrimaryRepo = false
		
		allItems.reserveCapacity(totalCount)
		var seenKeys = Set<String>()
        var seenBundleNames = Set<String>()
        var seenDownloadURLs = Set<String>()
		
		for (sourceURL, sourceID, repo) in snapshot {
			let isPrimary = ProtectedSourcesVault.isPrimarySource(sourceURL, identifier: sourceID)
			if isPrimary {
				didIncludePrimaryRepo = true
			}
			let sourceURLString = sourceURL?.absoluteString ?? ""
			
			var currentRepoItems: [AppStoreAppItem] = []
			currentRepoItems.reserveCapacity(repo.apps.count)
			
			for (index, app) in repo.apps.enumerated() {
                if index.isMultiple(of: 64) && Task.isCancelled { return nil }
				let bundleName = (app.id ?? "").lowercased() + "\u{1F}" + app.currentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let download = app.currentDownloadUrl?.absoluteString
                seenBundleNames.insert(bundleName)
                if let download { seenDownloadURLs.insert(download) }
                let uniqueKey = "\(app.stableCatalogIdentifier)_\(sourceURLString)"
				let item: AppStoreAppItem
                if let existing = previousByID[uniqueKey], Self.sameAppContent(existing.app, app),
                   existing.sourceName == (repo.name ?? "المصدر"), existing.sourceCategories == (repo.categories ?? []) {
                    item = existing
                } else {
                    item = AppStoreAppItem(
					id: uniqueKey,
					sourceURL: sourceURL,
					repository: repo,
					app: app
				)
                }
				if isPrimary {
					currentRepoItems.append(item)
				}
				if seenKeys.insert(uniqueKey).inserted {
					allItems.append(item)
				}
			}
			
			if isPrimary {
				primaryOnly.append(contentsOf: currentRepoItems)
				
				if let newsList = repo.news {
					for newsItem in newsList {
						let matchedApp = currentRepoItems.first {
							$0.app.id == newsItem.appID
						}
						
						primaryNews.append(
							TodayEditorialInstruction(
								id: newsItem.id,
								badge: newsItem.notify ? AshteL10n.t("تنبيه") : AshteL10n.t("يحدث الآن"),
								title: newsItem.title,
								caption: newsItem.caption,
								imageURL: newsItem.imageURL,
								tintColor: newsItem.tintColor ?? AppStoreTheme.oceanBlue,
								associatedApp: matchedApp,
                                targetURL: xsignSafeURL(newsItem.url?.absoluteString)
							)
						)
					}
				}
			}
		}
		
		let onlyApps = allItems.filter { !$0.isGame }
		let onlyGames = allItems.filter { $0.isGame }
		
		let grouped = Dictionary(grouping: allItems, by: { $0.category })
		var categoryDict: [AppStore2026Category: [AppStoreAppItem]] = [:]
		for category in AppStore2026Category.allCases {
			switch category {
			case .topApps:
				categoryDict[category] = onlyApps
			case .bestSellingApps:
				categoryDict[category] = Array(onlyApps.reversed())
			case .topGames:
				categoryDict[category] = onlyGames
			case .bestSellingGames:
				categoryDict[category] = Array(onlyGames.reversed())
			case .timePass:
				let casual = onlyGames.filter { $0.category == .casualGames || $0.category == .puzzleGames }
				categoryDict[category] = casual
			default:
				let exactMatches = grouped[category] ?? []
				if !exactMatches.isEmpty {
					categoryDict[category] = exactMatches
                } else {
                    categoryDict[category] = []
                }
			}
		}
		
		// حصر صفحة اليوم بسورس AshteMobile فقط وعدم خلطها مع السورسات الأخرى
		let finalPrimary = primaryOnly
		let finalPrimaryNews = primaryNews
		let finalAll = allItems
		let finalApps = onlyApps
		let finalGames = onlyGames
		let finalCats = categoryDict
		let shouldUpdatePrimary = didIncludePrimaryRepo
		
        if Task.isCancelled { return nil }
        return XSignCatalogSnapshot(
            primaryItems: finalPrimary,
            primaryEditorialNews: finalPrimaryNews,
            allCombinedItems: finalAll,
            pureAppsOnly: finalApps,
            pureGamesOnly: finalGames,
            itemsByCategory: finalCats,
            includesPrimary: shouldUpdatePrimary,
            sourceName: ProtectedSourcesVault.primaryName,
            sourceSubtitle: snapshot.first(where: { ProtectedSourcesVault.isPrimarySource($0.0, identifier: $0.1) })?.2.subtitle ?? "",
            sourceIconURL: snapshot.first(where: { ProtectedSourcesVault.isPrimarySource($0.0, identifier: $0.1) })?.2.iconURL,
            sourceCategories: snapshot.first(where: { ProtectedSourcesVault.isPrimarySource($0.0, identifier: $0.1) })?.2.categories ?? [],
            skippedLookupBundleIDs: Set(finalAll.filter { $0.app.skipAppStoreLookup == true }.compactMap { $0.app.id })
        )
    }
}

// MARK: - Serial FIFO download queue
struct XSignSerialQueue<Element> {
    struct Entry {
        let key: String
        let value: Element
    }
    private var waiting: [Entry?] = []
    private var head = 0
    private var registered: Set<String> = []
    private(set) var active: Entry? = nil
    var pendingCount: Int { waiting.count - head }

    init() {}

    mutating func enqueue(key: String, value: Element) -> Bool {
        guard registered.insert(key).inserted else { return false }
        waiting.append(Entry(key: key, value: value))
        return true
    }

    mutating func next() -> Entry? {
        guard case nil = active else { return nil }
        guard head < waiting.count, let entry = waiting[head] else { return nil }
        waiting[head] = nil
        head += 1
        if head == waiting.count {
            waiting.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 && head >= waiting.count / 2 {
            waiting.removeFirst(head)
            head = 0
        }
        active = entry
        return entry
    }

    @discardableResult
    mutating func finish(key: String) -> Bool {
        guard active?.key == key else { return false }
        registered.remove(key)
        active = nil
        return true
    }
}

// MARK: - Bounded download and signing pipeline
// The network may download the next IPA while the previous IPA is processed.
// Only one network stream and one file on deck are allowed; payloads stay on disk.
struct XSignBoundedPipeline<Job, File> {
    struct Prepared {
        let key: String
        let job: Job
        let file: File
    }
    private var downloads = XSignSerialQueue<Job>()
    private var registered: Set<String> = []
    private(set) var staged: Prepared? = nil
    private(set) var processing: Prepared? = nil
    var activeDownload: XSignSerialQueue<Job>.Entry? { downloads.active }
    var pendingCount: Int { downloads.pendingCount }
    var canStartDownload: Bool {
        if case nil = activeDownload, case nil = staged { return pendingCount > 0 }
        return false
    }
    var inFlightCount: Int {
        (activeDownload.map { _ in 1 } ?? 0) + (staged.map { _ in 1 } ?? 0) + (processing.map { _ in 1 } ?? 0)
    }
    mutating func enqueue(key: String, job: Job) -> Bool {
        guard registered.insert(key).inserted else { return false }
        guard downloads.enqueue(key: key, value: job) else {
            registered.remove(key)
            return false
        }
        return true
    }
    mutating func takeDownload() -> XSignSerialQueue<Job>.Entry? {
        guard canStartDownload else { return nil }
        return downloads.next()
    }
    mutating func completeDownload(key: String, file: File) -> Bool {
        guard let entry = activeDownload, entry.key == key, case nil = staged,
              downloads.finish(key: key) else { return false }
        staged = Prepared(key: key, job: entry.value, file: file)
        return true
    }
    mutating func failDownload(key: String) -> Bool {
        guard downloads.finish(key: key) else { return false }
        registered.remove(key)
        return true
    }
    mutating func takeProcessing() -> Prepared? {
        guard case nil = processing, let next = staged else { return nil }
        staged = nil
        processing = next
        return next
    }
    mutating func finishProcessing(key: String) -> Bool {
        guard processing?.key == key else { return false }
        processing = nil
        registered.remove(key)
        return true
    }
}

// Collapse byte-level KVO callbacks before they enqueue work on the UI actor.
final class XSignDownloadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var greatest = -1
    func shouldPublish(_ percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent > greatest else { return false }
        greatest = percent
        return true
    }
}

// MARK: - Universal Payload Extractor + Instant ZSign
@MainActor
final class AutoSignPipelineManager: ObservableObject {
	static let shared = AutoSignPipelineManager()
	
	@Published var activeStates: [String: Stage] = [:]
	@Published var downloadProgress: [String: Int] = [:]
	@Published var readyToInstallApp: AnyApp? = nil
	struct DownloadBannerInfo: Equatable {
		let name: String
		let iconURL: URL?
	}
	/// Name + icon shown in the top download banner, keyed like `activeStates`.
	@Published var bannerInfo: [String: DownloadBannerInfo] = [:]
	private var userCancelledKeys: Set<String> = []
	// Pause / resume (App Store style)
	private var pausingKeys: Set<String> = []
	private var pausedApps: [String: ASRepository.App] = [:]
	private var resumeDataByKey: [String: Data] = [:]
    private var packagePipeline = XSignBoundedPipeline<ASRepository.App, URL>()
    private var pendingInstallApps: [AnyApp] = []
    private var activeNetworkTask: URLSessionDownloadTask?
    private var isCheckingDownloadPolicy = false
    private var downloadPreflightBlocked = false
	
	enum Stage: Equatable {
        case queued
        case failed(String)
        case preparing
		case downloading
		case paused
		case signing
		case ready
	}
	
	private var cachedCertificate: CertificatePair? = nil
	private var progressObservations: [String: NSKeyValueObservation] = [:]
	
	private lazy var turboSession: URLSession = {
		let config = URLSessionConfiguration.default
		config.networkServiceType = .default
		config.httpMaximumConnectionsPerHost = 1
		config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
		config.requestCachePolicy = .reloadIgnoringLocalCacheData
		config.urlCache = nil
		return URLSession(configuration: NetworkShield.protect(config))
	}()
	
	init() {
		refreshCertificateCache()
	}
	
	func refreshCertificateCache() {
		cachedCertificate = Self.fetchActiveCertificate()
	}
	
	nonisolated static func prewarmInfoPlist(for app: Imported) {
		prewarmAndNormalizePayload(for: app)
	}
	
	nonisolated static func prewarmAndNormalizePayload(for app: Imported) {
		guard let uuid = app.uuid else { return }
		let unsignedDir = FileManager.default.unsigned.appendingPathComponent(uuid)
		
		guard let enumerator = FileManager.default.enumerator(
			at: unsignedDir,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		) else { return }
		
		for case let fileURL as URL in enumerator {
			if fileURL.pathExtension == "app" {
				let infoPlistURL = fileURL.appendingPathComponent("Info.plist")
				if let plist = NSDictionary(contentsOf: infoPlistURL) {
					_ = plist["CFBundleExecutable"]
					_ = plist["CFBundleIdentifier"]
				}
				break
			}
		}
	}
	
    func downloadAndAutoSign(app: ASRepository.App) {
        if let reason = XSignRemoteManager.shared.blockingReason {
            UIAlertController.showAlertWithOk(title: AshteL10n.t("تنبيه"), message: reason)
            return
        }
        downloadPreflightBlocked = false
        let key = app.stableCatalogIdentifier
        if let state = activeStates[key] {
            switch state {
            case .failed: activeStates.removeValue(forKey: key)
            case .paused:
                resumeDownload(key: key)
                return
            default: return
            }
        }
        // Ready-to-install link in the JSON (itms-services:// or a manifest .plist):
        // let iOS install it directly - no download, no signing, nothing kept in the Library.
        if let rawURL = app.currentDownloadUrl ?? app.versions?.first?.downloadURL,
           let direct = Self.directInstallURL(from: rawURL) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIApplication.shared.open(direct)
            return
        }
        guard let url = app.currentDownloadUrl ?? app.versions?.first?.downloadURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            activeStates[key] = .failed(AshteL10n.t("رابط التنزيل غير صالح."))
            return
        }
        bannerInfo[key] = DownloadBannerInfo(name: app.currentName, iconURL: app.iconURL)
        guard packagePipeline.enqueue(key: key, job: app) else { return }
        activeStates[key] = .queued
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        startNextDownload()
    }

    /// Returns an itms-services install URL when the JSON link is already installable.
    nonisolated static func directInstallURL(from url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "itms-services" { return url }
        if scheme == "https", url.pathExtension.lowercased() == "plist" {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return URL(string: "itms-services://?action=download-manifest&url=\(encoded)")
        }
        return nil
    }

    /// Stop button of the top download banner.
    func cancelActiveDownload(key: String) {
        guard activeStates[key] == .downloading, packagePipeline.activeDownload?.key == key else { return }
        userCancelledKeys.insert(key)
        activeNetworkTask?.cancel()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Pause the running download (like the App Store). It can be resumed later.
    func pauseActiveDownload(key: String) {
        guard activeStates[key] == .downloading,
              let entry = packagePipeline.activeDownload, entry.key == key,
              let task = activeNetworkTask else { return }
        pausingKeys.insert(key)
        pausedApps[key] = entry.value
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self, let data, self.pausingKeys.contains(key) || self.activeStates[key] == .paused else { return }
                self.resumeDataByKey[key] = data
            }
        })
    }

    /// Continue a paused download from where it stopped (or restart it if iOS gave no resume data).
    func resumeDownload(key: String) {
        guard activeStates[key] == .paused, let app = pausedApps[key] else { return }
        if let reason = XSignRemoteManager.shared.blockingReason {
            UIAlertController.showAlertWithOk(title: AshteL10n.t("تنبيه"), message: reason)
            return
        }
        guard packagePipeline.enqueue(key: key, job: app) else { return }
        activeStates[key] = .queued
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        startNextDownload()
    }

    /// Cancel a running or paused download and forget it.
    func cancelDownload(key: String) {
        switch activeStates[key] {
        case .downloading:
            cancelActiveDownload(key: key)
        case .paused:
            pausedApps.removeValue(forKey: key)
            resumeDataByKey.removeValue(forKey: key)
            downloadProgress.removeValue(forKey: key)
            bannerInfo.removeValue(forKey: key)
            activeStates.removeValue(forKey: key)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        default:
            break
        }
    }

    func applyRemotePolicy() {
        if XSignRemoteManager.shared.blockingReason != nil {
            activeNetworkTask?.cancel()
        } else {
            downloadPreflightBlocked = false
            startNextProcessing()
            startNextDownload()
        }
    }

    private func startNextDownload() {
        guard packagePipeline.canStartDownload, !isCheckingDownloadPolicy, !downloadPreflightBlocked,
              XSignRemoteManager.shared.blockingReason == nil else { return }
        isCheckingDownloadPolicy = true
        Task { @MainActor in
            let reason = await XSignRemoteManager.shared.prepareProtectedOperation()
            isCheckingDownloadPolicy = false
            if let reason {
                downloadPreflightBlocked = true
                if let entry = packagePipeline.takeDownload() { failNetworkDownload(key: entry.key, message: reason) }
                return
            }
            beginNextDownload()
        }
    }

    private func beginNextDownload() {
        guard XSignRemoteManager.shared.blockingReason == nil,
              let entry = packagePipeline.takeDownload() else { return }
        let app = entry.value
        let key = entry.key
        guard let url = app.currentDownloadUrl ?? app.versions?.first?.downloadURL else {
            failNetworkDownload(key: key, message: AshteL10n.t("رابط التنزيل غير صالح."))
            return
        }
        let resumeData = resumeDataByKey.removeValue(forKey: key)
        pausedApps.removeValue(forKey: key)
        activeStates[key] = .downloading
        if resumeData == nil { downloadProgress[key] = 0 }
        var request = URLRequest(url: url)
        request.setValue("AshteMobile/2.0", forHTTPHeaderField: "User-Agent")
        let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { [weak self] location, response, error in
            guard let self else { return }
            guard error == nil, let location,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                Task { @MainActor in
                    if let resume, self.pausingKeys.contains(key) { self.resumeDataByKey[key] = resume }
                    self.failNetworkDownload(key: key, message: error?.localizedDescription ?? AshteL10n.t("تعذّر تنزيل التطبيق من الخادم."))
                }
                return
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("XSignQueue_\(UUID().uuidString).ipa")
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
                guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                    throw NSError(domain: "XSign.Download", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: AshteL10n.t("الملف الذي نزله الخادم فارغ.")])
                }
                try FileManager.default.moveItem(at: location, to: file)
            } catch {
                try? FileManager.default.removeItem(at: file)
                Task { @MainActor in self.failNetworkDownload(key: key, message: error.localizedDescription) }
                return
            }
            Task { @MainActor in self.receivedPackage(file, key: key) }
        }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = turboSession.downloadTask(withResumeData: resumeData, completionHandler: completion)
        } else {
            task = turboSession.downloadTask(with: request, completionHandler: completion)
        }
        let progressGate = XSignDownloadProgressGate()
        progressObservations[key] = task.progress.observe(\Progress.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            guard fraction.isFinite else { return }
            let percent = Int(max(0, min(99, fraction * 100)))
            guard progressGate.shouldPublish(percent) else { return }
            Task { @MainActor in
                guard let self, self.activeStates[key] == .downloading else { return }
                // At most 100 progress publications per download, regardless of chunk count.
                if self.downloadProgress[key] != percent { self.downloadProgress[key] = percent }
            }
        }
        activeNetworkTask = task
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    private func receivedPackage(_ file: URL, key: String) {
        guard packagePipeline.activeDownload?.key == key else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if let reason = XSignRemoteManager.shared.blockingReason {
            try? FileManager.default.removeItem(at: file)
            failNetworkDownload(key: key, message: reason)
            return
        }
        guard packagePipeline.completeDownload(key: key, file: file) else {
            try? FileManager.default.removeItem(at: file)
            failNetworkDownload(key: key, message: AshteL10n.t("تعذّر إدراج الملف في طابور التجهيز."))
            return
        }
        activeNetworkTask = nil
        progressObservations.removeValue(forKey: key)
        downloadProgress.removeValue(forKey: key)
        activeStates[key] = .preparing
        // These two lanes overlap without opening a second simultaneous download.
        startNextProcessing()
        startNextDownload()
    }

    private func startNextProcessing() {
        guard XSignRemoteManager.shared.blockingReason == nil,
              let entry = packagePipeline.takeProcessing() else { return }
        let key = entry.key
        let file = entry.file
        activeStates[key] = .preparing
        refreshCertificateCache()
        FR.importPackageFile(file, consumeTemporaryFile: true) { [weak self] result in
            try? FileManager.default.removeItem(at: file)
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishDownload(key: key, error: error.localizedDescription)
            case .success(let uuid):
                let request = NSFetchRequest<Imported>(entityName: "Imported")
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "uuid == %@", uuid)
                guard let imported = (try? Storage.shared.context.fetch(request))?.first else {
                    self.finishDownload(key: key, error: AshteL10n.t("تعذّر العثور على التطبيق المستورد."))
                    return
                }
                self.triggerInstantZSign(for: imported, appKey: key)
            }
        }
    }

    private func failNetworkDownload(key: String, message: String) {
        guard packagePipeline.failDownload(key: key) else { return }
        activeNetworkTask = nil
        progressObservations.removeValue(forKey: key)
        if pausingKeys.remove(key) != nil {
            // Paused by the user: keep progress, app and resume data so it can continue.
            activeStates[key] = .paused
        } else {
            downloadProgress.removeValue(forKey: key)
            pausedApps.removeValue(forKey: key)
            resumeDataByKey.removeValue(forKey: key)
            if userCancelledKeys.remove(key) != nil {
                activeStates.removeValue(forKey: key)
                bannerInfo.removeValue(forKey: key)
            } else {
                activeStates[key] = .failed(message)
            }
        }
        startNextProcessing()
        startNextDownload()
    }

    private func finishDownload(key: String, error: String?) {
        guard packagePipeline.finishProcessing(key: key) else { return }
        if let error { activeStates[key] = .failed(error) }
        startNextProcessing()
        startNextDownload()
    }

    func triggerInstantZSign(for importedApp: Imported, appKey: String) {
        guard let cert = cachedCertificate ?? Self.fetchActiveCertificate() else {
            finishDownload(key: appKey, error: AshteL10n.t("تم الاستيراد. أضف شهادة من الإعدادات للتوقيع."))
            return
        }
        activeStates[appKey] = .signing
        let options = OptionsManager.shared.options
        FR.signPackageFileWithResult(importedApp, using: options, icon: nil, certificate: cert) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishDownload(key: appKey, error: error.localizedDescription)
            case .success(let uuid):
                let request = NSFetchRequest<Signed>(entityName: "Signed")
                request.fetchLimit = 1
                request.predicate = NSPredicate(format: "uuid == %@", uuid)
                guard let signed = (try? Storage.shared.context.fetch(request))?.first else {
                    self.finishDownload(key: appKey, error: AshteL10n.t("تعذّر العثور على التطبيق الموقّع."))
                    return
                }
                // The unsigned copy is not needed any more: keep nothing extra in the Library.
                Storage.shared.deleteApp(for: importedApp)
                self.activeStates[appKey] = .ready
                self.enqueueInstallation(signed)
                self.finishDownload(key: appKey, error: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    if self?.activeStates[appKey] == .ready { self?.activeStates[appKey] = nil }
                }
            }
        }
    }

    /// Removes the signed copy of a store app after it was installed (or failed) so it never stays in the Library.
    func cleanupAfterInstall(uuid: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let request = NSFetchRequest<Signed>(entityName: "Signed")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "uuid == %@", uuid)
            if let signed = (try? Storage.shared.context.fetch(request))?.first {
                Storage.shared.deleteApp(for: signed)
            }
        }
    }

    private func enqueueInstallation(_ app: Signed) {
        guard readyToInstallApp?.base.uuid != app.uuid,
              !pendingInstallApps.contains(where: { $0.base.uuid == app.uuid }) else { return }
        pendingInstallApps.append(AnyApp(base: app))
        presentNextReadyApp()
    }

    func presentNextReadyApp() {
        guard case nil = readyToInstallApp, !pendingInstallApps.isEmpty else { return }
        if let root = UIApplication.topViewController()?.view.window?.rootViewController,
           root.presentedViewController != nil { return }
        readyToInstallApp = pendingInstallApps.removeFirst()
    }

	nonisolated static func fetchImportedApps() -> [Imported] {
		let request = NSFetchRequest<Imported>(entityName: "Imported")
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
		request.fetchLimit = 5
		return (try? Storage.shared.context.fetch(request)) ?? []
	}
	
	nonisolated static func fetchSignedApps() -> [Signed] {
		let request = NSFetchRequest<Signed>(entityName: "Signed")
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		request.fetchLimit = 2
		return (try? Storage.shared.context.fetch(request)) ?? []
	}
	
	nonisolated static func fetchActiveCertificate() -> CertificatePair? {
		let request = NSFetchRequest<CertificatePair>(entityName: "CertificatePair")
		request.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		guard let certs = try? Storage.shared.context.fetch(request), !certs.isEmpty else {
			return nil
		}
		let index = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		return certs.indices.contains(index) ? certs[index] : certs.first
	}
}

// MARK: - Authentic App Store 2026 Detail View (Hides Screenshots if App is Removed from App Store)
struct AppStore2026DetailView: View {
	let item: AppStoreAppItem
	@State private var appleMetadata: AppleStoreRichMetadata? = nil
	@State private var isLoadingMetadata = true
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	
	private var accentColor: Color {
		Color(hex: userTintHex)
	}
	
	private var displayScreenshots: [URL] {
		if let screenshots = appleMetadata?.screenshots, !screenshots.isEmpty {
			return screenshots
		}
		return item.screenshots
	}
	
	private var displayDescription: String {
		if let original = item.app.currentDescription,
		   !AppStoreBilingualEngine.isInternalSourceNote(original) {
			return original
		}
		if let appleDesc = appleMetadata?.description, !appleDesc.isEmpty {
			return appleDesc
		}
		return AshteL10n.t("نسخة معدلة ومحدثة جاهزة للتثبيت الفوري عبر AshteMobile.")
	}
	
	private var displayReleaseNotes: String {
		if let versionDesc = item.app.versions?.first?.localizedDescription,
		   !AppStoreBilingualEngine.isInternalSourceNote(versionDesc) {
			return versionDesc
		}
		if let appleNotes = appleMetadata?.releaseNotes, !appleNotes.isEmpty {
			return appleNotes
		}
		return AshteL10n.t("نسخة معدلة ومحدثة.")
	}
	
	private var displayDeveloper: String {
		if let seller = appleMetadata?.sellerName, !seller.isEmpty {
			return seller
		}
		if let dev = item.app.developer, !dev.isEmpty {
			return dev
		}
		return item.sourceName
	}
	
	private var formattedSize: String {
		let versionSize = (item.app.currentAppVersion?.size).flatMap { Int64(exactly: $0) }
		let repoSize: Int64 = item.app.size ?? versionSize ?? 0
		let bytes: Int64 = repoSize > 0 ? repoSize : (appleMetadata?.fileSizeBytes ?? 0)
		guard bytes > 0 else { return "IPA" }
		let formatter = ByteCountFormatter()
		formatter.allowedUnits = [.useMB, .useGB]
		formatter.countStyle = .file
		return formatter.string(fromByteCount: bytes)
	}
	
	var body: some View {
		ScrollView(.vertical, showsIndicators: false) {
			VStack(alignment: .leading, spacing: 24) {
				HStack(alignment: .top, spacing: 16) {
					AppStoreIconView(
						url: item.app.iconURL,
						bundleID: item.app.id,
						appName: item.app.currentName,
						size: 112
					)
					.shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
					
					VStack(alignment: .leading, spacing: 6) {
						Text(item.app.currentName)
							.font(.title2.bold())
							.foregroundStyle(.primary)
							.lineLimit(2)
						
						Text(item.arabicSubtitle)
							.font(.system(size: 14, weight: .medium))
							.foregroundStyle(.secondary)
							.lineLimit(1)
						
						Spacer(minLength: 8)
						
						HStack {
							AppStore2026DownloadButton(app: item.app)
							Spacer()
						}
					}
				}
				.padding(.horizontal, 18)
				.padding(.top, 10)
				
				Divider().background(Color.primary.opacity(0.1)).padding(.horizontal, 18)
				
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 0) {
						AppStoreStatBadge(
							topTitle: AshteL10n.t("تقييم App Store"),
							mainValue: appleMetadata?.rating.map { String(format: "%.1f", $0) } ?? "—",
							bottomText: appleMetadata?.rating == nil ? AshteL10n.t("غير متوفر") : "App Store"
						)
						
						Divider().frame(height: 36).background(Color.primary.opacity(0.12))
						
						AppStoreStatBadge(
							topTitle: AshteL10n.t("العمر"),
							mainValue: appleMetadata?.contentRating ?? "—",
							bottomText: AshteL10n.t("سنة")
						)
						
						Divider().frame(height: 36).background(Color.primary.opacity(0.12))
						
						AppStoreStatBadge(
							topTitle: AshteL10n.t("الفئة"),
							mainValue: item.category.title,
							bottomText: AshteL10n.t("التصنيف")
						)
						
						Divider().frame(height: 36).background(Color.primary.opacity(0.12))
						
						AppStoreStatBadge(
							topTitle: AshteL10n.t("الحجم"),
							mainValue: formattedSize,
							bottomText: "iOS"
						)
					}
					.padding(.horizontal, 18)
				}
				
				// لا يظهر قسم لقطات الشاشة إذا كان التطبيق محذوفاً من متجر أبل ولا يملك لقطات شاشة
				if !displayScreenshots.isEmpty || isLoadingMetadata {
					Divider().background(Color.primary.opacity(0.1)).padding(.horizontal, 18)
					
					VStack(alignment: .leading, spacing: 14) {
						AppStoreScreenshotsHeader(title: AshteL10n.t("Screenshots"))
							.padding(.horizontal, 18)

						if !displayScreenshots.isEmpty {
							ScrollView(.horizontal, showsIndicators: false) {
								HStack(alignment: .top, spacing: 12) {
									ForEach(displayScreenshots, id: \.self) { screenURL in
										AppStoreScreenshotCard(url: screenURL)
									}
								}
								.padding(.horizontal, 18)
							}
						} else if isLoadingMetadata {
							ScrollView(.horizontal, showsIndicators: false) {
								HStack(alignment: .top, spacing: 12) {
									ForEach(0..<2, id: \.self) { _ in
										AppStoreScreenshotPlaceholder(showsProgress: true)
									}
								}
								.padding(.horizontal, 18)
							}
						}
					}
				}
				
				Divider().background(Color.primary.opacity(0.1)).padding(.horizontal, 18)
				
				VStack(alignment: .leading, spacing: 10) {
					HStack {
						Text(AshteL10n.t("ما الجديد"))
							.font(.title2.bold())
							.foregroundStyle(.primary)
						Spacer()
						Text(AshteL10n.t("الإصدار %@", (item.app.currentVersion ?? "—")))
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
					
					Text(displayReleaseNotes)
						.font(.system(size: 15))
						.foregroundStyle(Color.primary.opacity(0.9))
						.lineSpacing(4)
						.lineLimit(4)
				}
				.padding(.horizontal, 18)
				
				Divider().background(Color.primary.opacity(0.1)).padding(.horizontal, 18)
				
				XSignTranslatableDescription(text: displayDescription, accentColor: accentColor)
				.padding(.horizontal, 18)
				
				Divider().background(Color.primary.opacity(0.1)).padding(.horizontal, 18)
				
				VStack(alignment: .leading, spacing: 14) {
					Text(AshteL10n.t("المعلومات"))
						.font(.title2.bold())
						.foregroundStyle(.primary)
					
					AppStoreInfoRow(label: AshteL10n.t("المصدر"), value: item.sourceName)
					AppStoreInfoRow(label: AshteL10n.t("المطور"), value: displayDeveloper)
					AppStoreInfoRow(label: AshteL10n.t("الحجم"), value: formattedSize)
					AppStoreInfoRow(label: AshteL10n.t("الفئة"), value: item.category.title)
					AppStoreInfoRow(label: AshteL10n.t("الإصدار"), value: item.app.currentVersion ?? "—")
				}
				.padding(.horizontal, 18)
				.padding(.bottom, 36)
			}
		}
		.background(AppStoreTheme.background.ignoresSafeArea())
		.navigationBarTitleDisplayMode(.inline)
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
		.task {
			if AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(item.app.iconURL) {
				isLoadingMetadata = false
				return
			}
			appleMetadata = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
				bundleID: item.app.id,
				appName: item.app.currentName,
				iconURL: item.app.iconURL,
                skipLookup: item.app.skipAppStoreLookup == true
			)
			isLoadingMetadata = false
		}
	}
}

struct AppStoreStatBadge: View {
	let topTitle: String
	let mainValue: String
	let bottomText: String
	
	var body: some View {
		VStack(spacing: 4) {
			Text(topTitle)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(.secondary)
			Text(mainValue)
				.font(.system(size: 20, weight: .heavy, design: .rounded))
				.foregroundStyle(Color.primary.opacity(0.9))
			Text(bottomText)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.frame(width: 92)
	}
}

struct AppStoreInfoRow: View {
	let label: String
	let value: String
	
	var body: some View {
		VStack(spacing: 10) {
			HStack {
				Text(label)
					.font(.system(size: 14))
					.foregroundStyle(.secondary)
				Spacer()
				Text(value)
					.font(.system(size: 14, weight: .medium))
					.foregroundStyle(.primary)
					.lineLimit(1)
			}
			Divider().background(Color.primary.opacity(0.08))
		}
	}
}

// MARK: - 1. TODAY VIEW (Exclusively from the AshteMobile Source)
struct AppStoreTodayView: View {
    @StateObject private var viewModel = SourcesViewModel.shared
    @StateObject private var cache = AppStoreCacheManager.shared
    @State private var showSettingsSheet = false
    @FetchRequest(entity: AltSource.entity(), sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)])
    private var sources: FetchedResults<AltSource>

    private var todayApps: [AppStoreAppItem] { cache.primaryItems }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(AshteL10n.t("Today")).font(.largeTitle.bold())
                        }
                        Spacer()
                        AppStoreAccountAppIconButton { showSettingsSheet = true }
                    }.padding(.top, 12).zIndex(10)

                    ForEach(cache.primaryEditorialNews) { instruction in
                        XSignAnnouncementCard(instruction: instruction)
                    }
                    if let featured = todayApps.first {
                        XSignTodayFeatureCard(item: featured, sourceName: cache.sourceName)
                        let compact = Array(todayApps.dropFirst().prefix(2))
                        if !compact.isEmpty {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(compact) { item in
                                    NavigationLink { AppStore2026DetailView(item: item) } label: {
                                        XSignTodaySmallCard(item: item)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        let remaining = Array(todayApps.dropFirst(3).prefix(8))
                        if !remaining.isEmpty {
                            TodayFourAppsListCard(outerTitle: nil, outerSubtitle: nil,
                                innerCaption: AshteL10n.t("More from %@", cache.sourceName), innerTitle: AshteL10n.t("Discover your next app"), items: remaining)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
                            Text(cache.sourceName).font(.footnote.weight(.semibold))
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 4)
                    } else {
                        AppStore2026EmptyState(isLoading: cache.isRefreshing || cache.isPreparing,
                            emptyMessage: cache.catalogErrorMessage ?? AshteL10n.t("لا توجد تطبيقات في المصدر حتى الآن."),
                            retry: { Task { await cache.forceRefresh(sources: sources, viewModel: viewModel) } })
                    }
                }.padding(.horizontal, 20).padding(.bottom, 110)
            }
            .background(AppStoreTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await cache.forceRefresh(sources: sources, viewModel: viewModel) }
            .navigationDestination(isPresented: $showSettingsSheet) {
                SettingsView(embedded: true)
            }
        }
        .environment(\.layoutDirection, AshteL10n.layoutDirection)
        .task(id: sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: sources, viewModel: viewModel)
        }
    }
}

struct XSignTodayFeatureCard: View {
    let item: AppStoreAppItem
    let sourceName: String
    var body: some View {
        VStack(spacing: 0) {
            NavigationLink { AppStore2026DetailView(item: item) } label: {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.init(red: 0.01, green: 0.10, blue: 0.25), .init(red: 0.02, green: 0.28, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let artwork = item.screenshots.first {
                        LazyImage(url: artwork) { state in
                            if let image = state.image { image.resizable().scaledToFill().opacity(0.5) }
                        }.processors([.resize(size: CGSize(width: 700, height: 700))])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .allowsHitTesting(false)
                    } else {
                        VStack {
                            Spacer(minLength: 16)
                            AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: 132)
                                .rotationEffect(.degrees(-9)).shadow(color: .black.opacity(0.3), radius: 18, y: 12)
                            Spacer(minLength: 120)
                        }.frame(maxWidth: .infinity)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AshteL10n.t("AshteMobile Pick")).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.white.opacity(0.8))
                        Text(item.app.currentName).font(.system(.largeTitle, design: .rounded).bold()).lineLimit(2)
                        Text(item.arabicSubtitle).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.white.opacity(0.85))
                    }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.frame(height: 350).clipped().contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                NavigationLink { AppStore2026DetailView(item: item) } label: {
                    HStack(spacing: 12) {
                        AppStoreIconView(url: item.app.iconURL, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.app.currentName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                AppStore2026DownloadButton(app: item.app)
            }.padding(16).background(AppStoreTheme.cardSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
    }
}

struct XSignTodaySmallCard: View {
    let item: AppStoreAppItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AppStoreIconView(url: item.app.iconURL, size: 64)
                Spacer(minLength: 0)
            }
            Text(item.category.title).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).lineLimit(1)
            Text(item.app.currentName).font(.headline).foregroundStyle(.primary).lineLimit(2)
            Text(item.arabicSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .padding(16).background(AppStoreTheme.cardSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - 2. APPS VIEW
struct SourcesView: View {
	@StateObject var viewModel = SourcesViewModel.shared
	@StateObject private var cache = AppStoreCacheManager.shared
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	@State private var _isSettingsPresenting = false
	@State private var _selectedAppCategory: AppStore2026Category? = nil
    @State private var visibleAppCount = 60
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>
	
	private let appOnlyCategories: [AppStore2026Category] = [
		.social,
		.photoVideo,
		.mediaReaders,
		.devTools,
		.visualArts,
		.productivity
	]
	
	private var filteredPureApps: [AppStoreAppItem] {
		guard let selected = _selectedAppCategory else {
			return cache.pureAppsOnly
		}
		return cache.itemsByCategory[selected] ?? []
	}
	
	private var accentColor: Color {
		Color(hex: userTintHex)
	}
	
	var body: some View {
		NavigationStack {
			ScrollView(.vertical, showsIndicators: false) {
				LazyVStack(alignment: .leading, spacing: 24) {
					AppStore2026TopHeader(
						title: AshteL10n.t("التطبيقات"),
						onSettingsTap: { _isSettingsPresenting = true }
					)
					
					if cache.pureAppsOnly.isEmpty {
                        AppStore2026EmptyState(isLoading: cache.isRefreshing || cache.isPreparing,
                            emptyMessage: cache.catalogErrorMessage ?? AshteL10n.t("لا توجد تطبيقات في المصادر المفعّلة."),
                            retry: { Task { await cache.forceRefresh(sources: _sources, viewModel: viewModel) } })
							.padding(.horizontal, 18)
							.padding(.top, 30)
					} else {
						ScrollView(.horizontal, showsIndicators: false) {
							HStack(spacing: 10) {
								Button {
									_selectedAppCategory = nil
								} label: {
									Text(AshteL10n.t("الكل"))
										.font(.subheadline.weight(.bold))
										.foregroundStyle(_selectedAppCategory == nil ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 18)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(_selectedAppCategory == nil ? accentColor : AppStoreTheme.controlSurface)
										)
								}
								.buttonStyle(.plain)
								
								ForEach(appOnlyCategories.filter { !(cache.itemsByCategory[$0] ?? []).isEmpty }) { cat in
									Button {
										_selectedAppCategory = cat
									} label: {
										HStack(spacing: 6) {
											Image(systemName: cat.sfSymbol)
												.font(.caption)
											Text(cat.title)
												.font(.subheadline.weight(.bold))
										}
										.foregroundStyle(_selectedAppCategory == cat ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 16)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(_selectedAppCategory == cat ? accentColor : AppStoreTheme.controlSurface)
										)
									}
									.buttonStyle(.plain)
								}
							}
							.padding(.horizontal, 18)
						}
						
						if _selectedAppCategory == nil {
							ScrollView(.horizontal, showsIndicators: false) {
								LazyHStack(spacing: 16) {
									ForEach(Array(cache.pureAppsOnly.prefix(6))) { item in
										NavigationLink {
											AppStore2026DetailView(item: item)
										} label: {
											AppStore2026FeaturedBanner(item: item)
										}
										.buttonStyle(.plain)
									}
								}
								.padding(.horizontal, 18)
							}
							
							AppStore2026ThreeRowSection(
								title: AshteL10n.t("مختارات التطبيقات"),
								subtitle: AshteL10n.t("أفضل التطبيقات المختارة لك"),
								items: Array(cache.pureAppsOnly.prefix(18))
							)
						}
						
						HStack {
							Text(_selectedAppCategory?.title ?? AshteL10n.t("جميع التطبيقات"))
								.font(.system(size: 22, weight: .bold))
								.foregroundStyle(.primary)
							Spacer()
						}
						.padding(.horizontal, 18)
						.padding(.top, 4)
						
						ForEach(Array(filteredPureApps.prefix(visibleAppCount).enumerated()), id: \.element.id) { index, item in
							NavigationLink {
								AppStore2026DetailView(item: item)
							} label: {
								VStack(spacing: 0) {
									AppStore2026AppRow(item: item)
										.padding(.horizontal, 18)
										.padding(.vertical, 8)
									
									Divider()
										.background(Color.primary.opacity(0.08))
										.padding(.leading, 82)
										.padding(.trailing, 18)
								}
							}
							.buttonStyle(.plain)
                            .onAppear {
                                if index >= visibleAppCount - 12 && visibleAppCount < filteredPureApps.count {
                                    visibleAppCount = min(visibleAppCount + 60, filteredPureApps.count)
                                }
                            }
						}
					}
				}
				.padding(.bottom, 100)
			}
			.background(AppStoreTheme.background.ignoresSafeArea())
			.toolbar(.hidden, for: .navigationBar)
			.refreshable {
				await cache.forceRefresh(sources: _sources, viewModel: viewModel)
			}
			.navigationDestination(isPresented: $_isSettingsPresenting) {
				SettingsView(embedded: true)
			}
		}
        .onChange(of: _selectedAppCategory) { _ in visibleAppCount = 60 }
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
        .task(id: _sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: _sources, viewModel: viewModel)
        }
	}
}

// MARK: - 3. GAMES VIEW
struct AppStoreGamesView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@StateObject private var cache = AppStoreCacheManager.shared
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	@State private var showSettingsSheet = false
	@State private var selectedGameCategory: AppStore2026Category? = nil
    @State private var visibleGameCount = 60
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>
	
	private let gameOnlyCategories: [AppStore2026Category] = [
		.pvpGames,
		.simulationGames,
		.strategyGames,
		.puzzleGames,
		.casualGames
	]
	
	private var displayedGames: [AppStoreAppItem] {
		guard let selected = selectedGameCategory else {
			return cache.pureGamesOnly
		}
		return cache.itemsByCategory[selected] ?? []
	}
	
	private var accentColor: Color {
		Color(hex: userTintHex)
	}
	
	var body: some View {
		NavigationStack {
			ScrollView(.vertical, showsIndicators: false) {
				LazyVStack(alignment: .leading, spacing: 24) {
					AppStore2026TopHeader(
						title: AshteL10n.t("الألعاب"),
						onSettingsTap: { showSettingsSheet = true }
					)
					
					if cache.pureGamesOnly.isEmpty {
                        AppStore2026EmptyState(isLoading: cache.isRefreshing || cache.isPreparing,
                            emptyMessage: cache.catalogErrorMessage ?? AshteL10n.t("لا توجد تطبيقات في المصادر المفعّلة."),
                            retry: { Task { await cache.forceRefresh(sources: _sources, viewModel: viewModel) } })
							.padding(.horizontal, 18)
							.padding(.top, 20)
					} else {
						ScrollView(.horizontal, showsIndicators: false) {
							HStack(spacing: 10) {
								Button {
									selectedGameCategory = nil
								} label: {
									Text(AshteL10n.t("كل الألعاب"))
										.font(.subheadline.weight(.bold))
										.foregroundStyle(selectedGameCategory == nil ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 18)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(selectedGameCategory == nil ? accentColor : AppStoreTheme.controlSurface)
										)
								}
								.buttonStyle(.plain)
								
								ForEach(gameOnlyCategories.filter { !(cache.itemsByCategory[$0] ?? []).isEmpty }) { cat in
									Button {
										selectedGameCategory = cat
									} label: {
										HStack(spacing: 6) {
											Image(systemName: cat.sfSymbol)
												.font(.caption)
											Text(cat.title)
												.font(.subheadline.weight(.bold))
										}
										.foregroundStyle(selectedGameCategory == cat ? AppStoreTheme.contrastingText(forHex: userTintHex) : Color.primary)
										.padding(.horizontal, 16)
										.padding(.vertical, 9)
										.background(
											Capsule(style: .continuous)
												.fill(selectedGameCategory == cat ? accentColor : AppStoreTheme.controlSurface)
										)
									}
									.buttonStyle(.plain)
								}
							}
							.padding(.horizontal, 18)
						}
						
						if selectedGameCategory == nil {
							if let heroGame = cache.pureGamesOnly.first {
								NavigationLink {
									AppStore2026DetailView(item: heroGame)
								} label: {
									TodayLiveEventHeroCard(
										outerTitle: nil,
										outerSubtitle: nil,
										cornerBadge: AshteL10n.t("يحدث الآن"),
										eventTag: AshteL10n.t("رائج الآن"),
										headline: AshteL10n.t("العب مواجهة %@", heroGame.app.currentName),
										descriptionText: heroGame.arabicSubtitle,
										bannerImageURL: heroGame.screenshots.first,
										cardColor: accentColor,
										item: heroGame
									)
								}
								.buttonStyle(.plain)
								.padding(.horizontal, 18)
							}
							
							AppStore2026ThreeRowSection(
								title: AshteL10n.t("مختارات الألعاب"),
								subtitle: AshteL10n.t("أقوى الألعاب المختارة لك"),
								items: Array(cache.pureGamesOnly.prefix(15))
							)
						}
						
						HStack {
							Text(selectedGameCategory?.title ?? AshteL10n.t("جميع الألعاب"))
								.font(.system(size: 22, weight: .bold))
								.foregroundStyle(.primary)
							Spacer()
						}
						.padding(.horizontal, 18)
						
						ForEach(Array(displayedGames.prefix(visibleGameCount).enumerated()), id: \.element.id) { index, item in
							NavigationLink {
								AppStore2026DetailView(item: item)
							} label: {
								VStack(spacing: 0) {
									AppStore2026AppRow(item: item)
										.padding(.horizontal, 18)
										.padding(.vertical, 8)
									
									Divider()
										.background(Color.primary.opacity(0.08))
										.padding(.leading, 82)
										.padding(.trailing, 18)
								}
							}
							.buttonStyle(.plain)
                            .onAppear {
                                if index >= visibleGameCount - 12 && visibleGameCount < displayedGames.count {
                                    visibleGameCount = min(visibleGameCount + 60, displayedGames.count)
                                }
                            }
						}
					}
				}
				.padding(.bottom, 100)
			}
			.background(AppStoreTheme.background.ignoresSafeArea())
			.toolbar(.hidden, for: .navigationBar)
			.refreshable {
				await cache.forceRefresh(sources: _sources, viewModel: viewModel)
			}
			.navigationDestination(isPresented: $showSettingsSheet) {
                SettingsView(embedded: true)
            }
		}
        .onChange(of: selectedGameCategory) { _ in visibleGameCount = 60 }
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
        .task(id: _sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            await cache.ensureFetched(sources: _sources, viewModel: viewModel)
        }
	}
}

// MARK: - 4. SEARCH VIEW (Background Debounced 120fps Zero-Lag Search)
struct AppStoreSearchView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@StateObject private var cache = AppStoreCacheManager.shared
	@State private var searchText = ""
	@StateObject private var results = XSignSearchResults()
	@State private var showSettingsSheet = false
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>
	
	var body: some View {
		NavigationStack {
			ScrollView(.vertical, showsIndicators: false) {
				LazyVStack(alignment: .leading, spacing: 26) {
					AppStore2026TopHeader(
						title: AshteL10n.t("بحث"),
						onSettingsTap: { showSettingsSheet = true }
					)
					if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        XSignCatalogCategories(cache: cache)
						VStack(alignment: .leading, spacing: 14) {
							HStack(spacing: 6) {
								Text(AshteL10n.t("تصفح"))
									.font(.system(size: 22, weight: .bold))
									.foregroundStyle(.primary)
								Image(systemName: "chevron.left")
									.font(.system(size: 16, weight: .bold))
									.foregroundStyle(.secondary)
								Spacer()
							}
							.padding(.horizontal, 18)
							
							LazyVGrid(
								columns: [
									GridItem(.flexible(), spacing: 12),
									GridItem(.flexible(), spacing: 12)
								],
								spacing: 12
							) {
								ForEach(AppStore2026Category.allCases.filter { !(cache.itemsByCategory[$0] ?? []).isEmpty }) { category in
									let catApps = cache.itemsByCategory[category] ?? []
									NavigationLink {
										AppStore2026CategoryListView(
											category: category,
											items: catApps
										)
									} label: {
										AppStore2026BrowseCategoryTile(
											category: category,
											previewApps: Array(catApps.prefix(2))
										)
									}
									.buttonStyle(.plain)
								}
							}
							.padding(.horizontal, 18)
						}
					} else {
                        HStack {
                            if results.isSearching { ProgressView().controlSize(.small); Text(AshteL10n.t("جاري البحث…")) }
                            else { Text(AshteL10n.t("%ld نتيجة", results.total)) }
                            Spacer()
                        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18)
						LazyVStack(spacing: 14) {
							if results.visible.isEmpty && !results.isSearching {
								VStack(spacing: 12) {
									Image(systemName: "magnifyingglass")
										.font(.system(size: 42))
										.foregroundStyle(.secondary)
									Text(AshteL10n.t("لا توجد نتائج لـ \"%@\"", searchText))
										.font(.headline)
										.foregroundStyle(.primary)
								}
								.frame(maxWidth: .infinity)
								.padding(.top, 60)
							} else {
								ForEach(results.visible) { item in
                                    XSignSearchResultRow(item: item)
								}
							}
                            if results.visible.count < results.total && !results.isSearching {
                                Button(AshteL10n.t("عرض المزيد")) { results.showMore() }.padding(.vertical, 12)
                            }
						}
						.padding(.horizontal, 18)
					}
				}
				.padding(.bottom, 110)
			}
			.background(AppStoreTheme.background.ignoresSafeArea())
			.toolbar(.hidden, for: .navigationBar)
			.searchable(
				text: $searchText,
				placement: .automatic,
				prompt: AshteL10n.t("الألعاب والتطبيقات والمزيد...")
			)
			.onChange(of: searchText) { newQuery in
				triggerBackgroundSearch(query: newQuery)
			}
            .onChange(of: cache.catalogRevision) { _ in triggerBackgroundSearch(query: searchText) }
            .onDisappear { results.cancel() }
			.navigationDestination(isPresented: $showSettingsSheet) {
                SettingsView(embedded: true)
            }
		}
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
        .task(id: _sources.map { $0.sourceURL?.absoluteString ?? "" }.sorted()) {
            triggerBackgroundSearch(query: searchText)
            await cache.ensureFetched(sources: _sources, viewModel: viewModel)
        }
	}
	
    private func triggerBackgroundSearch(query: String) {
        results.update(query: query, items: cache.allCombinedItems)
    }

}

struct XSignSearchResultRow: View {
    let item: AppStoreAppItem
    var body: some View {
        HStack(spacing: 12) {
            NavigationLink { AppStore2026DetailView(item: item) } label: {
                HStack(spacing: 12) {
                    AppStoreIconView(url: item.app.iconURL, size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.app.currentName).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(item.arabicSubtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.sourceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            AppStore2026DownloadButton(app: item.app)
        }.padding(.vertical, 6)
    }
}

// MARK: - Top Header
struct AppStore2026TopHeader: View {
	let title: String
	let onSettingsTap: () -> Void
	
	var body: some View {
		HStack(alignment: .center) {
			Text(title)
				.font(.system(size: 34, weight: .heavy))
				.foregroundStyle(.primary)
			
			Spacer()
			
			AppStoreAccountAppIconButton(action: onSettingsTap)
		}
		.padding(.horizontal, 18)
		.padding(.top, 10)
		.zIndex(10)
	}
}

struct AppStoreAccountAppIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FRAppIconView(size: 38)
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.28), lineWidth: 1.1)
                }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(AshteL10n.t("Settings"))
    }
}

// MARK: - Authentic Apple App Store Today Cards
struct TodayLiveEventHeroCard: View {
	let outerTitle: String?
	let outerSubtitle: String?
	let cornerBadge: String
	let eventTag: String
	let headline: String
	let descriptionText: String
	let bannerImageURL: URL?
	let cardColor: Color
	let item: AppStoreAppItem
	
	@State private var liveScreenshots: [URL] = []
	
	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let outerTitle {
				VStack(alignment: .leading, spacing: 2) {
					Text(outerTitle)
						.font(.system(size: 22, weight: .heavy))
						.foregroundStyle(.primary)
					if let outerSubtitle {
						Text(outerSubtitle)
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, 2)
			}
			
			VStack(spacing: 0) {
				ZStack(alignment: .topLeading) {
					Color.clear
						.frame(maxWidth: .infinity)
						.frame(height: 350)
						.background(
							LinearGradient(
								colors: [
									cardColor,
									cardColor.opacity(0.82),
									Color(red: 0.08, green: 0.08, blue: 0.10)
								],
								startPoint: .top,
								endPoint: .bottom
							)
						)
						.overlay {
							let displayBanner = bannerImageURL ?? liveScreenshots.first
							if let bannerURL = displayBanner {
								LazyImage(url: bannerURL) { state in
									if let image = state.image {
										image
											.resizable()
											.scaledToFill()
											.opacity(0.55)
									}
								}
								.processors([.resize(size: CGSize(width: 500, height: 500))])
								.frame(maxWidth: .infinity, maxHeight: .infinity)
								.clipped()
								.allowsHitTesting(false)
							} else {
								AppStoreIconView(
									url: item.app.iconURL,
									bundleID: item.app.id,
									appName: item.app.currentName,
									size: 138
								)
								.shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
								.offset(y: -38)
							}
						}
						.clipped()
						.overlay(alignment: .bottomLeading) {
							ZStack(alignment: .bottomLeading) {
								LinearGradient(
									colors: [.clear, cardColor.opacity(0.88), cardColor],
									startPoint: .center,
									endPoint: .bottom
								)
								
								VStack(alignment: .leading, spacing: 6) {
									Text(eventTag)
										.font(.system(size: 13, weight: .bold))
										.foregroundStyle(.white.opacity(0.9))
									
									Text(headline)
										.font(.system(size: 26, weight: .heavy))
										.foregroundStyle(.white)
										.lineLimit(2)
										.multilineTextAlignment(.leading)
									
									Text(descriptionText)
										.font(.system(size: 14, weight: .medium))
										.foregroundStyle(.white.opacity(0.88))
										.lineLimit(2)
										.multilineTextAlignment(.leading)
								}
								.frame(maxWidth: .infinity, alignment: .leading)
								.padding(.horizontal, 20)
								.padding(.bottom, 18)
							}
						}
					
					Text(cornerBadge)
						.font(.system(size: 13, weight: .bold))
						.foregroundStyle(.white)
						.padding(.horizontal, 16)
						.padding(.vertical, 8)
						.background(
							UnevenRoundedRectangle(
								topLeadingRadius: 26,
								bottomLeadingRadius: 0,
								bottomTrailingRadius: 16,
								topTrailingRadius: 0,
								style: .continuous
							)
							.fill(Color.black.opacity(0.42))
						)
				}
				
				Divider()
					.background(Color.white.opacity(0.14))
				
				HStack(spacing: 12) {
					AppStoreIconView(
						url: item.app.iconURL,
						bundleID: item.app.id,
						appName: item.app.currentName,
						size: 50
					)
					
					VStack(alignment: .leading, spacing: 2) {
						Text(item.app.currentName)
							.font(.system(size: 16, weight: .bold))
							.foregroundStyle(.white)
							.lineLimit(1)
						Text(item.arabicSubtitle)
							.font(.system(size: 13))
							.foregroundStyle(.white.opacity(0.8))
							.lineLimit(1)
					}
					
					Spacer(minLength: 8)
					
					AppStore2026DownloadButton(app: item.app, isLightPill: true)
				}
				.padding(.horizontal, 18)
				.padding(.vertical, 14)
				.frame(maxWidth: .infinity)
				.background(cardColor.opacity(0.95))
			}
			.frame(maxWidth: .infinity)
			.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 28, style: .continuous)
					.stroke(Color.white.opacity(0.10), lineWidth: 0.7)
			)
			.task {
				if bannerImageURL == nil && liveScreenshots.isEmpty && !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(item.app.iconURL) {
					if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
						bundleID: item.app.id,
						appName: item.app.currentName,
						iconURL: item.app.iconURL,
                skipLookup: item.app.skipAppStoreLookup == true
					) {
						liveScreenshots = meta.screenshots
					}
				}
			}
		}
	}
}

struct TodayTwoRowIconGridCard: View {
	let outerTitle: String?
	let outerSubtitle: String?
	let outerPuzzleIcon: Bool
	let caption: String
	let headline: String
	let descriptionText: String?
	let gradientColors: [Color]
	let items: [AppStoreAppItem]
	let fallbackItem: AppStoreAppItem
	
	private var topRowItems: [AppStoreAppItem] {
		Array(items.prefix(4))
	}
	
	private var bottomRowItems: [AppStoreAppItem] {
		let rest = Array(items.dropFirst(4).prefix(4))
		return rest.isEmpty ? Array(items.reversed().prefix(4)) : rest
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			if let outerTitle {
				VStack(alignment: .leading, spacing: 3) {
					HStack(spacing: 6) {
						if outerPuzzleIcon {
							Image(systemName: "puzzlepiece.extension.fill")
								.font(.system(size: 20))
								.foregroundStyle(AppStoreTheme.dynamicAccent)
						}
						Text(outerTitle)
							.font(.system(size: 22, weight: .heavy))
							.foregroundStyle(.primary)
					}
					if let outerSubtitle {
						Text(outerSubtitle)
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, 2)
			}
			
			Color.clear
				.frame(maxWidth: .infinity)
				.frame(height: 365)
				.background(
					LinearGradient(
						colors: gradientColors,
						startPoint: .top,
						endPoint: .bottom
					)
				)
				.overlay(alignment: .top) {
					VStack(spacing: 16) {
						HStack(spacing: 14) {
							ForEach(topRowItems) { appItem in
								AppStoreIconView(
									url: appItem.app.iconURL,
									bundleID: appItem.app.id,
									appName: appItem.app.currentName,
									size: 80
								)
								.shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 5)
							}
						}
						.offset(x: 12)
						
						HStack(spacing: 14) {
							ForEach(bottomRowItems) { appItem in
								AppStoreIconView(
									url: appItem.app.iconURL,
									bundleID: appItem.app.id,
									appName: appItem.app.currentName,
									size: 80
								)
								.shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 5)
							}
						}
						.offset(x: -12)
					}
					.padding(.top, 26)
				}
				.overlay(alignment: .bottomLeading) {
					ZStack(alignment: .bottomLeading) {
						LinearGradient(
							colors: [.clear, gradientColors.last?.opacity(0.95) ?? .black],
							startPoint: .center,
							endPoint: .bottom
						)
						
						VStack(alignment: .leading, spacing: 6) {
							Text(caption)
								.font(.system(size: 13, weight: .bold))
								.foregroundStyle(.white.opacity(0.88))
							
							Text(headline)
								.font(.system(size: 27, weight: .heavy))
								.foregroundStyle(.white)
								.lineLimit(2)
								.multilineTextAlignment(.leading)
							
							if let descriptionText {
								Text(descriptionText)
									.font(.system(size: 14, weight: .medium))
									.foregroundStyle(.white.opacity(0.90))
									.lineLimit(2)
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(22)
					}
				}
				.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 28, style: .continuous)
						.stroke(Color.white.opacity(0.10), lineWidth: 0.7)
			)
		}
	}
}

struct TodayFourAppsListCard: View {
	let outerTitle: String?
	let outerSubtitle: String?
	let innerCaption: String
	let innerTitle: String
	let items: [AppStoreAppItem]
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			if let outerTitle {
				VStack(alignment: .leading, spacing: 3) {
					Text(outerTitle)
						.font(.system(size: 22, weight: .heavy))
						.foregroundStyle(.primary)
					if let outerSubtitle {
						Text(outerSubtitle)
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
				}
				.padding(.horizontal, 4)
			}
			
			VStack(alignment: .leading, spacing: 18) {
				VStack(alignment: .leading, spacing: 4) {
					Text(innerCaption)
						.font(.system(size: 13, weight: .bold))
						.foregroundStyle(.secondary)
					Text(innerTitle)
						.font(.system(size: 26, weight: .heavy))
						.foregroundStyle(.primary)
						.lineLimit(2)
						.multilineTextAlignment(.leading)
				}
				
				VStack(spacing: 14) {
					ForEach(Array(items.prefix(4).enumerated()), id: \.element.id) { index, item in
						NavigationLink {
							AppStore2026DetailView(item: item)
						} label: {
							AppStore2026AppRow(item: item)
						}
						.buttonStyle(.plain)
						
						if index < min(items.count, 4) - 1 {
							Divider()
								.background(Color.primary.opacity(0.08))
								.padding(.leading, 70)
						}
					}
				}
			}
			.padding(20)
			.frame(maxWidth: .infinity)
			.background(
				RoundedRectangle(cornerRadius: 28, style: .continuous)
					.fill(AppStoreTheme.cardSurface)
			)
			.overlay(
				RoundedRectangle(cornerRadius: 28, style: .continuous)
					.stroke(Color.primary.opacity(0.07), lineWidth: 0.6)
			)
		}
	}
}

struct TodayFullArtworkDockCard: View {
	let categoryTag: String
	let headline: String
	let subtitle: String
	let showPlayBadge: Bool
	let item: AppStoreAppItem
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	
	@State private var liveScreenshots: [URL] = []
	
	private var baseColor: Color {
		item.app.tintColor ?? Color(hex: userTintHex)
	}
	
	var body: some View {
		VStack(spacing: 0) {
			Color.clear
				.frame(maxWidth: .infinity)
				.frame(height: 330)
				.background(
					LinearGradient(
						colors: [
							baseColor.opacity(0.75),
							Color(red: 0.16, green: 0.28, blue: 0.42),
							Color(red: 0.12, green: 0.20, blue: 0.30)
						],
						startPoint: .topTrailing,
						endPoint: .bottomLeading
					)
				)
				.overlay {
					let displayImg = item.screenshots.first ?? liveScreenshots.first
					if let firstScreen = displayImg {
						LazyImage(url: firstScreen) { state in
							if let image = state.image {
								image
									.resizable()
									.scaledToFill()
							}
						}
						.processors([.resize(size: CGSize(width: 500, height: 500))])
								.frame(maxWidth: .infinity, maxHeight: .infinity)
								.clipped()
								.allowsHitTesting(false)
					} else {
						AppStoreIconView(
							url: item.app.iconURL,
							bundleID: item.app.id,
							appName: item.app.currentName,
							size: 128
						)
						.shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
						.offset(y: -35)
					}
				}
				.clipped()
				.overlay {
					if showPlayBadge {
						Circle()
							.fill(.ultraThinMaterial)
							.frame(width: 58, height: 58)
							.overlay {
								Image(systemName: "play.fill")
									.font(.system(size: 22))
									.foregroundStyle(.white)
									.offset(x: 2)
							}
							.offset(y: -30)
					}
				}
				.overlay(alignment: .bottomLeading) {
					ZStack(alignment: .bottomLeading) {
						LinearGradient(
							colors: [.clear, Color.black.opacity(0.82)],
							startPoint: .center,
							endPoint: .bottom
						)
						
						VStack(alignment: .leading, spacing: 5) {
							Text(categoryTag)
								.font(.system(size: 13, weight: .bold))
								.foregroundStyle(.white.opacity(0.88))
							Text(headline)
								.font(.system(size: 26, weight: .heavy))
								.foregroundStyle(.white)
								.lineLimit(2)
							Text(subtitle)
								.font(.system(size: 14, weight: .medium))
								.foregroundStyle(.white.opacity(0.88))
								.lineLimit(2)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal, 20)
						.padding(.bottom, 16)
					}
				}
			
			HStack(spacing: 12) {
				AppStoreIconView(
					url: item.app.iconURL,
					bundleID: item.app.id,
					appName: item.app.currentName,
					size: 50
				)
				
				VStack(alignment: .leading, spacing: 2) {
					Text(item.app.currentName)
						.font(.system(size: 16, weight: .bold))
						.foregroundStyle(.white)
						.lineLimit(1)
					Text(item.category.title)
						.font(.caption)
						.foregroundStyle(.white.opacity(0.75))
						.lineLimit(1)
				}
				
				Spacer(minLength: 8)
				
				AppStore2026DownloadButton(app: item.app, isLightPill: true)
			}
			.padding(.horizontal, 18)
			.padding(.vertical, 14)
			.frame(maxWidth: .infinity)
			.background(Color(red: 0.16, green: 0.22, blue: 0.28))
		}
		.frame(maxWidth: .infinity)
		.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 28, style: .continuous)
				.stroke(Color.white.opacity(0.10), lineWidth: 0.6)
		)
		.task {
			if item.screenshots.isEmpty && liveScreenshots.isEmpty && !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(item.app.iconURL) {
				if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
					bundleID: item.app.id,
					appName: item.app.currentName,
					iconURL: item.app.iconURL,
                skipLookup: item.app.skipAppStoreLookup == true
				) {
					liveScreenshots = meta.screenshots
				}
			}
		}
	}
}

// MARK: - Settings Popup
struct AppStore2026SettingsPopup: View {
	@Environment(\.dismiss) private var dismiss
	let sources: FetchedResults<AltSource>
	@ObservedObject var viewModel: SourcesViewModel
	@State private var isAddingSource = false
	@State private var selectedSection = 0
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	
	private var userAddedSourcesOnly: [AltSource] {
		sources.filter { !ProtectedSourcesVault.isHiddenCoreSource($0) }
	}
	
	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				VStack(spacing: 12) {
					HStack(spacing: 12) {
						ZStack {
							RoundedRectangle(cornerRadius: 12, style: .continuous)
								.fill(
									LinearGradient(
										colors: [Color(hex: userTintHex), AppStoreTheme.deepOcean],
										startPoint: .topLeading,
										endPoint: .bottomTrailing
									)
								)
							FRAppIconView(size: 48)
						}
						.frame(width: 48, height: 48)
						
						VStack(alignment: .leading, spacing: 2) {
							Text("AshteMobile")
								.font(.headline.weight(.bold))
							Text(AshteL10n.t("الإعدادات، الشهادات، والمصادر"))
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						
						Spacer()
						
						Button(AshteL10n.t("تم")) {
							dismiss()
						}
						.font(.body.weight(.bold))
					}
					
					Picker("", selection: $selectedSection) {
						Text(AshteL10n.t("الإعدادات")).tag(0)
						Text(AshteL10n.t("الشهادات")).tag(1)
						Text(AshteL10n.t("مصادري (%ld)", userAddedSourcesOnly.count)).tag(2)
					}
					.pickerStyle(.segmented)
				}
				.padding(.horizontal, 18)
				.padding(.vertical, 12)
				.background(Color(uiColor: .secondarySystemGroupedBackground))
				
				if selectedSection == 0 {
					SettingsView()
				} else if selectedSection == 1 {
					CertificatesView()
				} else {
					List {
						Section {
							Button {
								isAddingSource = true
							} label: {
								Label(AshteL10n.t("إضافة مصدر (سورس) خاص بك"), systemImage: "plus.circle.fill")
									.font(.body.weight(.semibold))
							}
						} footer: {
							Text(AshteL10n.t("جميع المصادر المضافة هنا محمية ولا يمكن تصدير أو نسخ روابطها."))
								.font(.caption2)
						}
						
						if !userAddedSourcesOnly.isEmpty {
							Section(AshteL10n.t("المصادر الإضافية")) {
								ForEach(userAddedSourcesOnly) { source in
									HStack(spacing: 12) {
										Image(systemName: "shippingbox.fill")
											.font(.system(size: 20))
											.foregroundStyle(AppStoreTheme.dynamicAccent)
											.frame(width: 38, height: 38)
											.background(AppStoreTheme.dynamicAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
										
										VStack(alignment: .leading, spacing: 2) {
											Text(source.name ?? AshteL10n.t("مصدر مضاف"))
												.font(.body.weight(.bold))
												.foregroundStyle(.primary)
											Text(AshteL10n.t("مصدر مفعل • الرابط مخفي للحماية"))
												.font(.caption2)
												.foregroundStyle(.secondary)
										}
										Spacer()
									}
									.padding(.vertical, 4)
									.swipeActions(edge: .trailing, allowsFullSwipe: true) {
										Button(role: .destructive) {
											Storage.shared.deleteSource(for: source)
										} label: {
											Label(AshteL10n.t("حذف"), systemImage: "trash")
										}
									}
								}
							}
						}
					}
				}
			}
			.toolbar(.hidden, for: .navigationBar)
			.sheet(isPresented: $isAddingSource) {
				CustomSafeAddSourceSheet()
			}
		}
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
	}
}

struct CustomSafeAddSourceSheet: View {
	@Environment(\.dismiss) private var dismiss
	@State private var sourceURLText = ""
	@State private var isSaving = false
	
	var body: some View {
		NavigationStack {
			Form {
				Section(AshteL10n.t("رابط المصدر (JSON URL)")) {
					TextField("https://example.com/repo.json", text: $sourceURLText)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}
				
				Section {
					Button {
						addSource()
					} label: {
						HStack {
							Spacer()
							if isSaving {
								ProgressView()
							} else {
								Text(AshteL10n.t("إضافة المصدر"))
									.font(.body.weight(.bold))
							}
							Spacer()
						}
					}
					.disabled(sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
				}
			}
			.navigationTitle(AshteL10n.t("إضافة مصدر"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button(AshteL10n.t("إلغاء")) {
						dismiss()
					}
				}
			}
		}
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
	}
	
	private func addSource() {
		let trimmed = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard URL(string: trimmed) != nil else { return }
		isSaving = true
		FR.handleSource(trimmed, onFailure: { _ in isSaving = false }) {
			isSaving = false
			dismiss()
		}
	}
}

// MARK: - Unified Download & Auto-Sign Button
struct AppStore2026DownloadButton: View {
	let app: ASRepository.App
	var isLightPill: Bool = false
	@ObservedObject private var pipeline = AutoSignPipelineManager.shared
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	
	private var accentColor: Color {
		Color(hex: userTintHex)
	}
	
	private var appKey: String {
		app.stableCatalogIdentifier
	}
	
	private var currentStage: AutoSignPipelineManager.Stage? {
		pipeline.activeStates[appKey]
	}
	
	private var progressPercent: Int {
		pipeline.downloadProgress[appKey] ?? 0
	}
	
	var body: some View {
		Button {
			switch currentStage {
			case .downloading: pipeline.pauseActiveDownload(key: appKey)
			case .paused: pipeline.resumeDownload(key: appKey)
			default: pipeline.downloadAndAutoSign(app: app)
			}
		} label: {
			switch currentStage {
            case .queued:
                Label(AshteL10n.t("بالانتظار"), systemImage: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 82, height: 32)
                    .background(AppStoreTheme.controlSurface, in: Capsule())
            case .failed(let message):
                VStack(spacing: 3) {
                    Label(AshteL10n.t("أعد المحاولة"), systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 82, height: 32)
                        .background(AppStoreTheme.controlSurface, in: Capsule())
                    Text(message)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(width: 100)
                }
                .accessibilityHint(message)
			case .downloading, .paused:
				HStack(spacing: 6) {
					ZStack {
						Circle()
							.stroke(accentColor.opacity(0.25), lineWidth: 3)
						Circle()
							.trim(from: 0, to: max(0.03, CGFloat(progressPercent) / 100))
							.stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
							.rotationEffect(.degrees(-90))
						Image(systemName: currentStage == .paused ? "play.fill" : "pause.fill")
							.font(.system(size: 11, weight: .bold))
							.foregroundStyle(accentColor)
					}
					.frame(width: 30, height: 30)
					Text("\(progressPercent)%")
						.font(.system(size: 12, weight: .heavy, design: .rounded))
						.monospacedDigit()
						.foregroundStyle(.secondary)
				}
				.frame(width: 82, height: 32)
				
			case .preparing, .signing:
				HStack(spacing: 4) {
					Image(systemName: "bolt.fill")
						.font(.system(size: 11, weight: .bold))
					Text(currentStage == .preparing ? AshteL10n.t("تجهيز...") : AshteL10n.t("توقيع..."))
						.font(.system(size: 11, weight: .bold))
				}
				.foregroundStyle(AppStoreTheme.contrastingText(forHex: userTintHex))
				.frame(width: 82, height: 32)
				.background(Capsule().fill(accentColor))
				
			case .ready:
				HStack(spacing: 4) {
					Image(systemName: "checkmark")
						.font(.system(size: 11, weight: .bold))
					Text(AshteL10n.t("تثبيت"))
						.font(.system(size: 13, weight: .bold))
				}
				.foregroundStyle(.white)
				.frame(width: 78, height: 32)
				.background(Capsule().fill(Color.green))
				
			case nil:
				VStack(spacing: 3) {
					Text(AshteL10n.t("Get"))
						.font(.system(size: 15, weight: .bold))
						.foregroundStyle(AppStoreTheme.contrastingText(forHex: userTintHex))
						.frame(width: 78, height: 32)
						.background(
							Capsule(style: .continuous)
								.fill(accentColor)
						)
					
					Text(AshteL10n.t("Sign with AshteMobile"))
						.font(.system(size: 7.5, weight: .medium))
						.foregroundStyle(isLightPill ? .white.opacity(0.75) : .secondary)
						.lineLimit(1)
				}
			}
		}
		.buttonStyle(.plain)
		.contextMenu {
			if currentStage == .downloading {
				Button { pipeline.pauseActiveDownload(key: appKey) } label: { Label("Pause Download", systemImage: "pause.circle") }
				Button(role: .destructive) { pipeline.cancelDownload(key: appKey) } label: { Label("Cancel Download", systemImage: "xmark.circle") }
			} else if currentStage == .paused {
				Button { pipeline.resumeDownload(key: appKey) } label: { Label("Resume Download", systemImage: "play.circle") }
				Button(role: .destructive) { pipeline.cancelDownload(key: appKey) } label: { Label("Cancel Download", systemImage: "xmark.circle") }
			}
		}
	}
}

struct AppStore2026AppRow: View {
	let item: AppStoreAppItem
	
	var body: some View {
		HStack(spacing: 12) {
			AppStoreIconView(
				url: item.app.iconURL,
				bundleID: item.app.id,
				appName: item.app.currentName,
				size: 58
			)
			
			VStack(alignment: .leading, spacing: 3) {
				Text(item.app.currentName)
					.font(.system(size: 16, weight: .bold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				Text(item.arabicSubtitle)
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
					.lineLimit(2)
			}
			
			Spacer(minLength: 8)
			
			AppStore2026DownloadButton(app: item.app)
		}
	}
}

struct AppStore2026BrowseCategoryTile: View {
	let category: AppStore2026Category
	let previewApps: [AppStoreAppItem]
	
	var body: some View {
		ZStack {
			LinearGradient(
				colors: category.gradientColors,
				startPoint: .topTrailing,
				endPoint: .bottomLeading
			)
			
			Group {
				if previewApps.count >= 2 {
					ZStack {
						AppStoreIconView(
							url: previewApps[1].app.iconURL,
							bundleID: previewApps[1].app.id,
							appName: previewApps[1].app.currentName,
							size: 40
						)
						.rotationEffect(.degrees(12))
						.offset(x: -14, y: 8)
						
						AppStoreIconView(
							url: previewApps[0].app.iconURL,
							bundleID: previewApps[0].app.id,
							appName: previewApps[0].app.currentName,
							size: 44
						)
						.rotationEffect(.degrees(-10))
						.offset(x: 10, y: -4)
					}
				} else {
					Image(systemName: category.sfSymbol)
						.font(.system(size: 38, weight: .bold))
						.foregroundStyle(.white.opacity(0.75))
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
			.padding(.top, 14)
			.padding(.trailing, 18)
			
			Text(category.title)
				.font(.system(size: 16, weight: .bold))
				.foregroundStyle(.white)
				.multilineTextAlignment(.leading)
				.lineLimit(2)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
				.padding(14)
		}
		.frame(height: 102)
		.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
	}
}

struct AppStore2026ThreeRowSection: View {
	let title: String
	let subtitle: String
	let items: [AppStoreAppItem]
	
	private let rows = [
		GridItem(.fixed(72), spacing: 12),
		GridItem(.fixed(72), spacing: 12),
		GridItem(.fixed(72), spacing: 12)
	]
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.font(.system(size: 21, weight: .bold))
						.foregroundStyle(.primary)
					Text(subtitle)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Image(systemName: "chevron.left")
					.font(.caption.weight(.bold))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 18)
			
			ScrollView(.horizontal, showsIndicators: false) {
				LazyHGrid(rows: rows, spacing: 16) {
					ForEach(items) { item in
						NavigationLink {
							AppStore2026DetailView(item: item)
						} label: {
							AppStore2026AppRow(item: item)
								.frame(width: min(UIScreen.main.bounds.width - 48, 320))
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 18)
			}
		}
	}
}

struct AppStore2026FeaturedBanner: View {
	let item: AppStoreAppItem
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	@State private var liveScreenshots: [URL] = []

	@ViewBuilder private var artwork: some View {
		let shot = item.screenshots.first ?? liveScreenshots.first
		ZStack {
			LinearGradient(
				colors: [bannerColor.opacity(0.88), AppStoreTheme.deepOcean],
				startPoint: .topTrailing,
				endPoint: .bottomLeading
			)
			if let shot {
				LazyImage(url: shot) { state in
					if let image = state.image {
						image.resizable().scaledToFill()
					}
				}
				.processors([.resize(size: CGSize(width: 700, height: 400))])
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.clipped()
				.allowsHitTesting(false)
			} else {
				// No screenshot in the source: blurred icon backdrop + tilted icon.
				AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: 220)
					.blur(radius: 30)
					.opacity(0.55)
					.scaleEffect(1.5)
				AppStoreIconView(url: item.app.iconURL, bundleID: item.app.id, appName: item.app.currentName, size: 92)
					.rotationEffect(.degrees(-8))
					.shadow(color: .black.opacity(0.35), radius: 14, y: 8)
					.offset(y: -28)
			}
			LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .center, endPoint: .bottom)
		}
		.clipped()
		.allowsHitTesting(false)
	}
	
	private var bannerColor: Color {
		item.app.tintColor ?? Color(hex: userTintHex)
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(item.category.title)
				.font(.caption2.weight(.bold))
				.foregroundStyle(Color(hex: userTintHex))
			Text(item.category.defaultArabicSubtitle)
				.font(.title3.weight(.bold))
				.foregroundStyle(.primary)
				.lineLimit(1)
			
			// App Store style: the app icon, name and Get button sit inside the artwork.
			artwork
				.frame(maxWidth: .infinity)
				.frame(height: 175)
				.overlay(alignment: .bottom) {
					HStack(spacing: 12) {
						AppStoreIconView(
							url: item.app.iconURL,
							bundleID: item.app.id,
							appName: item.app.currentName,
							size: 50
						)
						
						VStack(alignment: .leading, spacing: 2) {
							Text(item.app.currentName)
								.font(.subheadline.weight(.bold))
								.foregroundStyle(.white)
								.lineLimit(1)
							Text(item.arabicSubtitle)
								.font(.caption)
								.foregroundStyle(.white.opacity(0.75))
								.lineLimit(1)
						}
						
						Spacer()
						
						AppStore2026DownloadButton(app: item.app, isLightPill: true)
					}
					.padding(14)
					.background(
						LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
					)
				}
				.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
		}
		.frame(width: min(UIScreen.main.bounds.width - 44, 336))
		.task {
			guard item.screenshots.isEmpty, liveScreenshots.isEmpty,
				  !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(item.app.iconURL) else { return }
			if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
				bundleID: item.app.id,
				appName: item.app.currentName,
				iconURL: item.app.iconURL,
				skipLookup: item.app.skipAppStoreLookup == true
			) {
				liveScreenshots = meta.screenshots
			}
		}
	}
}

struct AppStore2026SearchResultCard: View {
	let item: AppStoreAppItem
	@State private var liveScreenshots: [URL] = []
	
	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			AppStore2026AppRow(item: item)
			
			let displayScreenshots = liveScreenshots.isEmpty ? item.screenshots : liveScreenshots
			if !displayScreenshots.isEmpty {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 10) {
						ForEach(Array(displayScreenshots.prefix(3)), id: \.self) { url in
							LazyImage(url: url) { state in
								if let image = state.image {
									image
										.resizable()
										.scaledToFill()
								} else {
									RoundedRectangle(cornerRadius: 12, style: .continuous)
										.fill(AppStoreTheme.controlSurface)
								}
							}
							.processors([.resize(size: CGSize(width: 220, height: 380))])
							.frame(width: 106, height: 188)
							.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
						}
					}
				}
			}
		}
		.padding(16)
		.background(
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.fill(AppStoreTheme.cardSurface)
		)
		.task {
			guard item.screenshots.isEmpty,
				  liveScreenshots.isEmpty,
				  !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(item.app.iconURL) else { return }
			
			try? await Task.sleep(nanoseconds: 250_000_000)
			guard !Task.isCancelled else { return }
			
			if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
				bundleID: item.app.id,
				appName: item.app.currentName,
				iconURL: item.app.iconURL,
                skipLookup: item.app.skipAppStoreLookup == true
			) {
				liveScreenshots = meta.screenshots
			}
		}
	}
}

struct AppStore2026CategoryListView: View {
	let category: AppStore2026Category
	let items: [AppStoreAppItem]
    var customTitle: String? = nil
	
	@State private var visibleCategoryCount = 60

	var body: some View {
		ScrollView(.vertical, showsIndicators: false) {
			LazyVStack(spacing: 12) {
				ForEach(Array(items.prefix(visibleCategoryCount).enumerated()), id: \.element.id) { index, item in
					NavigationLink {
						AppStore2026DetailView(item: item)
					} label: {
						AppStore2026AppRow(item: item)
							.padding(14)
							.background(
								RoundedRectangle(cornerRadius: 20, style: .continuous)
									.fill(AppStoreTheme.cardSurface)
							)
					}
					.buttonStyle(.plain)
                .onAppear {
                    if index >= visibleCategoryCount - 12 && visibleCategoryCount < items.count {
                        visibleCategoryCount = min(visibleCategoryCount + 60, items.count)
                    }
                }
				}
			}
			.padding(18)
		}
		.background(AppStoreTheme.background.ignoresSafeArea())
		.navigationTitle(customTitle ?? category.title)
		.environment(\.layoutDirection, AshteL10n.layoutDirection)
	}
}

struct AppStoreIconView: View {
	let url: URL?
	var bundleID: String? = nil
	var appName: String = ""
	let size: CGFloat
	@State private var appleIconURL: URL? = nil
	
	private var isFallbackGitHubIcon: Bool {
		guard let u = url?.absoluteString.lowercased() else { return true }
		return u.contains("github.com/ipa-black.png") || u.hasSuffix("/assets/icon.png")
	}
	
	var body: some View {
		Group {
			let effectiveURL = url ?? appleIconURL
			if let effectiveURL {
				LazyImage(url: effectiveURL) { state in
					if let image = state.image {
						image
							.resizable()
							.scaledToFill()
					} else {
						placeholder
					}
				}
				.processors([.resize(size: CGSize(width: size * 2, height: size * 2))])
			} else {
				placeholder
			}
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
				.stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
		)
		.task {
			if (url == nil || isFallbackGitHubIcon) && !appName.isEmpty && !AppStoreLiveMetadataBridge.hasExtractedGitHubIcon(url) && !AppStoreCacheManager.shared.shouldSkipStoreLookup(bundleID) {
				if let meta = await AppStoreLiveMetadataBridge.shared.fetchMetadata(
					bundleID: bundleID,
					appName: appName,
					iconURL: url
				) {
					appleIconURL = meta.artworkURL
				}
			}
		}
	}
	
	private var placeholder: some View {
		RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
			.fill(AppStoreTheme.controlSurface)
	}
}

struct AppStore2026EmptyState: View {
    let isLoading: Bool
    var emptyMessage: String = AshteL10n.t("لا توجد تطبيقات في المصادر المفعّلة.")
    var retry: (() -> Void)? = nil
	@AppStorage("AshteMobile.userTintColor") private var userTintHex: String = "#005BBB"
	
	var body: some View {
		VStack(spacing: 16) {
            if isLoading {
                ProgressView().tint(Color(hex: userTintHex)).scaleEffect(1.3)
            } else {
                Image(systemName: "square.stack").font(.largeTitle).foregroundStyle(.secondary)
            }
            Text(isLoading ? AshteL10n.t("جاري تحديث المصادر…") : emptyMessage)
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.primary)
            if !isLoading, let retry { Button(AshteL10n.t("إعادة المحاولة"), action: retry) }
		}
		.frame(maxWidth: .infinity)
		.padding(36)
		.background(
			RoundedRectangle(cornerRadius: 26, style: .continuous)
				.fill(AppStoreTheme.cardSurface)
		)
	}
}

// MARK: - Description (plain text, no translate button)
struct XSignTranslatableDescription: View {
    let text: String
    let accentColor: Color
    @State private var expanded = false

    private var isArabic: Bool {
        NLLanguageRecognizer.dominantLanguage(for: text) == .arabic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AshteL10n.t("الوصف")).font(.title2.bold())

            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(Color.primary.opacity(0.88))
                .lineSpacing(5)
                .lineLimit(expanded ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
                .textSelection(.enabled)

            Button(expanded ? AshteL10n.t("عرض أقل") : AshteL10n.t("المزيد")) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(accentColor)
        }
        .buttonStyle(.plain)
    }
}
// MARK: - End Description

// MARK: - Configured source identity, taxonomy and announcements
private struct XSignSourceIdentity: View {
    @ObservedObject var cache: AppStoreCacheManager
    var body: some View {
        HStack(spacing: 12) {
            AppStoreIconView(url: cache.sourceIconURL, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(cache.sourceName).font(.headline)
                if !cache.sourceSubtitle.isEmpty { Text(cache.sourceSubtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }.padding(.horizontal, 18)
    }
}

private struct XSignCatalogCategories: View {
    @ObservedObject var cache: AppStoreCacheManager
    var body: some View {
        if !cache.sourceCategories.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(AshteL10n.t("تصنيفات %@", cache.sourceName))
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 18)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(cache.sourceCategories) { category in
                            NavigationLink {
                                AppStore2026CategoryListView(category: .topApps,
                                    items: cache.primaryItems.filter { $0.app.category == category.id },
                                    customTitle: category.name)
                            } label: {
                                Text(category.name).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(AppStoreTheme.controlSurface, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 18)
                }
            }
        }
    }
}

private struct XSignAnnouncementCard: View {
    let instruction: TodayEditorialInstruction
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(instruction.badge).font(.caption.bold()).foregroundStyle(Color.accentColor)
            Text(instruction.title).font(.title3.bold())
            Text(instruction.caption).font(.subheadline).foregroundStyle(.secondary)
            if instruction.targetURL != nil { Image(systemName: "arrow.up.left.square").foregroundStyle(Color.accentColor) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(AppStoreTheme.cardSurface, in: RoundedRectangle(cornerRadius: 18))
    }
    var body: some View {
        if let url = instruction.targetURL { Link(destination: url) { content }.buttonStyle(.plain) }
        else if let app = instruction.associatedApp {
            NavigationLink { AppStore2026DetailView(item: app) } label: { content }.buttonStyle(.plain)
        } else { content }
    }
}
