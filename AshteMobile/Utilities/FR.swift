//
//  FR.swift
//  AshteMobile
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import ZsignC
import NimbleJSON
import AltSourceKit
import IDeviceSwift

// MARK: - Serial package work gate
private actor FRPackageWorkGate {
    static let shared = FRPackageWorkGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

enum FR {
    static func handlePackageFile(
        _ ipa: URL,
        download: Download? = nil,
        sourceProvenance: SourceAppProvenance? = nil,
        consumeTemporaryFile: Bool = false,
        completion: @escaping (Error?) -> Void
    ) {
        importPackageFile(ipa, download: download, sourceProvenance: sourceProvenance, consumeTemporaryFile: consumeTemporaryFile) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    static func importPackageFile(
        _ ipa: URL,
        download: Download? = nil,
        sourceProvenance: SourceAppProvenance? = nil,
        consumeTemporaryFile: Bool = false,
        onProgress: ((Double) -> Void)? = nil,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        Task.detached {
            await FRPackageWorkGate.shared.acquire()
            let handler = AppFileHandler(file: ipa, download: download, sourceProvenance: sourceProvenance, consumeTemporaryFile: consumeTemporaryFile)
            handler.onProgress = onProgress
            do {
                try await handler.copy()
                try await handler.extract()
                try await handler.move()
                try await handler.addToDatabase()
                try? await handler.clean()
                let uuid = handler.resultUUID
                await FRPackageWorkGate.shared.release()
                await MainActor.run {
                    onProgress?(1)
                    completion(.success(uuid))
                }
            } catch {
                try? await handler.clean()
                try? FileManager.default.removeItem(at: FileManager.default.unsigned(handler.resultUUID))
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    static func signPackageFile(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        completion: @escaping (Error?) -> Void
    ) {
        signPackageFileWithResult(app, using: options, icon: icon, certificate: certificate) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    static func signPackageFileWithResult(
        _ app: AppInfoPresentable,
        using options: Options,
        icon: UIImage?,
        certificate: CertificatePair?,
        preserveBundleForBatch: Bool = false,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        Task.detached {
            await FRPackageWorkGate.shared.acquire()
            if let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.failure(NSError(domain: "XSign.Policy", code: 403,
                    userInfo: [NSLocalizedDescriptionKey: reason]))) }
                return
            }
            let locks = await MainActor.run { XSignSecurityEnforcer.shared.locks }
            var permittedOptions = options
            if !locks.allowsAppMetadataEditing {
                permittedOptions.appName = nil
                permittedOptions.appIdentifier = nil
                permittedOptions.matchCertificateAppID = false
                permittedOptions.appVersion = nil
                permittedOptions.identifiers = [:]
                permittedOptions.displayNames = [:]
                permittedOptions.ppqProtection = false
                permittedOptions.dynamicProtection = false
                permittedOptions.changeLanguageFilesForCustomDisplayName = false
            }
            permittedOptions.appName = permittedOptions.appName?.trimmingCharacters(in: .whitespacesAndNewlines)
            permittedOptions.appIdentifier = permittedOptions.appIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            permittedOptions.appVersion = permittedOptions.appVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
            if locks.lock_dylib_injection ?? true {
                permittedOptions.injectionFiles = []
                permittedOptions.experiment_replaceSubstrateWithEllekit = false
            }
            if permittedOptions.signingOption == .default && permittedOptions.matchCertificateAppID == true {
                do {
                    let input = try await MainActor.run { () throws -> (URL, String) in
                        guard let certificate, let url = Storage.shared.getFile(.provision, from: certificate) else {
                            throw SigningFileHandlerError.missingCertifcate
                        }
                        return (url, app.identifier ?? "")
                    }
                    let profile = try XSignProvisioningProfile.read(at: input.0)
                    let current = permittedOptions.appIdentifier ?? input.1
                    permittedOptions.appIdentifier = try profile.identifier(for: current, matchExactID: !preserveBundleForBatch)
                    if !profile.isWildcard {
                        permittedOptions.ppqProtection = false
                        permittedOptions.dynamicProtection = false
                    }
                } catch {
                    await FRPackageWorkGate.shared.release()
                    await MainActor.run { completion(.failure(error)) }
                    return
                }
            }
            let handler = SigningHandler(app: app, options: permittedOptions)
            handler.appCertificate = certificate
            handler.appIcon = (locks.lock_icon_change ?? true) ? nil : icon
            do {
                try await handler.copy()
                try await handler.modify()
                try? await handler.clean()
                let uuid = handler.resultUUID
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.success(uuid)) }
            } catch {
                try? await handler.clean()
                try? FileManager.default.removeItem(at: FileManager.default.signed(handler.resultUUID))
                await FRPackageWorkGate.shared.release()
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName,
				isDefault: isDefault
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
                await handler.cleanAfterFailure()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_free(provision.path)
		}
		
		password_check_fix(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		
		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		
		NBFetchService().fetch(from: urlString) { (result: Result<ServerView.ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					try FileManager.forceWrite(content: pack.key, to: "server.pem")
					try FileManager.forceWrite(content: pack.cert, to: "server.crt")
					try FileManager.forceWrite(content: pack.info.domains.commonName, to: "commonName.txt")
					generator.notificationOccurred(.success)
					completion(true)
				} catch {
					completion(false)
				}
			case .failure(_):
				completion(false)
			}
		}
	}
	
    static func handleSource(_ urlString: String, onFailure: ((Error) -> Void)? = nil, competion: @escaping () -> Void) {
        guard let input = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(input.scheme?.lowercased() ?? ""), input.host != nil else {
            onFailure?(XSignCatalogError.invalidURL)
            return
        }
        let url = XSignCatalogIO.canonicalURL(input)
        Task { @MainActor in
            do {
                let record = try await XSignCatalogIO.shared.fetch(url)
                let identifier = record.repository.id ?? url.absoluteString
                let finish: (Error?) -> Void = { error in
                    if let error {
                        onFailure?(error)
                        UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
                        return
                    }
                    let sources = Storage.shared.getSources()
                    if let source = sources.first(where: { source in
                        source.sourceURL.map { XSignCatalogIO.canonicalURL($0) == url } == true || source.identifier == identifier
                    }) {
                        SourcesViewModel.shared.seed(record, for: source)
                    }
                    AppStoreCacheManager.shared.acceptRepository(record, from: url)
                    AppStoreCacheManager.shared.rebuildCacheIfNeeded(sources: sources, repositoriesMap: SourcesViewModel.shared.sources)
                    competion()
                    Task { @MainActor in
                        await AppStoreCacheManager.shared.ensureFetched(sources: sources, viewModel: .shared)
                    }
                }
                if Storage.shared.sourceExists(identifier) { finish(nil) }
                else { Storage.shared.addSource(url, repository: record.repository, id: identifier, completion: finish) }
            } catch {
                onFailure?(error)
                UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
            }
        }
    }

	static func exportCertificateAndOpenUrl(using template: String) {
		// Helper that performs the export for a given certificate
		func performExport(for certificate: CertificatePair) {
			guard
				let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
				let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile)
			else {
				return
			}
			
			let base64encodedCert = certificateKeyFileData.base64EncodedString()
			
			var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
			allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
			
			guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
				return
			}
			
			let urlStr = template
				.replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
				.replacingOccurrences(of: "$(PASSWORD)", with: certificate.password ?? "")
			
			guard let callbackUrl = URL(string: urlStr) else {
				return
			}
			
			UIApplication.shared.open(callbackUrl)
		}
		
		let certificates = Storage.shared.getAllCertificates()
		guard !certificates.isEmpty else { return }
		
		DispatchQueue.main.async {
			var selectionActions: [UIAlertAction] = []
			
			for cert in certificates {
				var title: String
				let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
				
				title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "🐞 \(title)"
				}
				
				let selectAction = UIAlertAction(title: title, style: .default) { _ in
					performExport(for: cert)
				}
				selectionActions.append(selectAction)
			}
			
			UIAlertController.showAlertWithCancel(
				title: .localized("Export Certificate"),
				message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
				style: .alert,
				actions: selectionActions
			)
		}
	}
}
