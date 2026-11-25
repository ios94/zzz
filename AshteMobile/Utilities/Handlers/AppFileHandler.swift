//
//  IPAHandler.swift
//  AshteMobile
//
//  Created by samara on 11.04.2025.
//

import Foundation
import Zip
import SwiftUI

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	var resultUUID: String { _uuid }
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	private let _install: Bool
	private let _download: Download?
	private let _sourceProvenance: SourceAppProvenance?
	private let _consumeTemporaryFile: Bool

	/// Import progress from 0 to 1. Always delivered on the main queue.
	var onProgress: ((Double) -> Void)?

	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		consumeTemporaryFile: Bool = false
	) {
		self._ipa = ipa
		self._install = install
		self._download = download
		self._sourceProvenance = sourceProvenance ?? download?.sourceProvenance
		self._consumeTemporaryFile = consumeTemporaryFile
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("AshteMobileImport_\(_uuid)", isDirectory: true)

		super.init()
	}

	/// Sends a progress value to `onProgress` on the main queue.
	private func _report(_ fraction: Double) {
		guard let onProgress else { return }
		let value = min(1, max(0, fraction))
		DispatchQueue.main.async { onProgress(value) }
	}

	/// Copies the file in chunks so the copy stage can report real progress (copyItem gives none).
	private func _copyWithProgress(from source: URL, to destination: URL) throws {
		_ = _fileManager.createFile(atPath: destination.path, contents: nil)
		let total = (try _fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
		let reader = try FileHandle(forReadingFrom: source)
		let writer = try FileHandle(forWritingTo: destination)
		defer {
			try? reader.close()
			try? writer.close()
		}
		var copied: Int64 = 0
		while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
			try writer.write(contentsOf: chunk)
			copied += Int64(chunk.count)
			if total > 0 {
				// Copy stage covers 0% to 30%.
				_report(0.3 * Double(copied) / Double(total))
			}
		}
	}

	func copy() async throws {
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)

		let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

		try _fileManager.removeFileIfNeeded(at: destinationURL)

		if _consumeTemporaryFile {
			let temporary = _fileManager.temporaryDirectory.resolvingSymlinksInPath().path + "/"
			guard _ipa.resolvingSymlinksInPath().path.hasPrefix(temporary) else {
				throw CocoaError(.fileWriteNoPermission)
			}
			// The caller owns this temporary download. Rename instead of copying the whole IPA.
			try _fileManager.moveItem(at: _ipa, to: destinationURL)
			_report(0.3)
		} else {
			try _copyWithProgress(from: _ipa, to: destinationURL)
		}
		_ipa = destinationURL
	}

	func extract() async throws {
		if _ipa.pathExtension == "ipa" {
			Zip.addCustomFileExtension("ipa")
		}
		if _ipa.pathExtension == "tipa" {
			Zip.addCustomFileExtension("tipa")
		}

		let download = self._download
		let progressGate = XSignDownloadProgressGate()
		let importGate = XSignDownloadProgressGate()

		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .utility).async {
				do {
					try Zip.unzipFile(
						self._ipa,
						destination: self._uniqueWorkDir,
						overwrite: true,
						password: nil,
						progress: { progress in
							guard progress.isFinite else { return }
							let clamped = max(0, min(1, progress))
							// Unzip stage covers 30% to 90%.
							if importGate.shouldPublish(Int(clamped * 100)) {
								self._report(0.3 + 0.6 * clamped)
							}
							if let download = download, progressGate.shouldPublish(Int(clamped * 100)) {
								DispatchQueue.main.async {
									download.unpackageProgress = progress

									#if !targetEnvironment(macCatalyst)
									if #available(iOS 26.0, *) {
										BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
									}
									#endif
								}
							}
						}
					)

					self.uniqueWorkDirPayload = self._uniqueWorkDir.appendingPathComponent("Payload")
					if download?.requireUnencryptedBinary == true, let payload = self.uniqueWorkDirPayload {
						try XSignMachOEncryption.verifyPayload(at: payload)
					}
					self._report(0.9)
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	func move() async throws {
		guard let payloadURL = uniqueWorkDirPayload else {
			throw ImportedFileHandlerError.payloadNotFound
		}

		let destinationURL = try await _directory()

		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			throw ImportedFileHandlerError.payloadNotFound
		}

		try _fileManager.moveItem(at: payloadURL, to: destinationURL)

		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}

	@MainActor
	func addToDatabase() async throws {
		let app = try await _directory()

		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			throw ImportedFileHandlerError.payloadNotFound
		}

		let bundle = Bundle(url: appUrl)

		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Storage.shared.addImported(
				uuid: _uuid,
				source: _sourceProvenance?.sourceRepositoryURL,
				appName: bundle?.name,
				appIdentifier: bundle?.bundleIdentifier,
				appVersion: bundle?.version,
				appIcon: bundle?.iconFileName
			) { error in
				if let error { continuation.resume(throwing: error) }
				else { continuation.resume() }
			}
		}

		if let sourceProvenance = _sourceProvenance {
			Storage.shared.addSourceMetadata(
				for: _uuid,
				kind: .imported,
				provenance: sourceProvenance
			)
		}
	}

	private func _directory() async throws -> URL {
		// Documents/AshteMobile/Unsigned/\(UUID)
		_fileManager.unsigned(_uuid)
	}

	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
}

private enum ImportedFileHandlerError: Error {
	case payloadNotFound
}
