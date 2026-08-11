import AppKit
import Foundation

@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private nonisolated static let lastCheckKey = "lastUpdateCheckDate"
    private nonisolated static let stagedUpdateKey = "yankStagedUpdate"
    private nonisolated static let justUpdatedKey = "yankJustUpdated"
    private nonisolated static let updateTagKey = "yankUpdateTag"
    private nonisolated static let highestInstalledKey = "yankHighestInstalledVersion"
    private nonisolated static let releaseFeedURL =
        URL(string: "https://raw.githubusercontent.com/The-PatientZero/yank/main/releases.json")!
    private let releasesURL: URL
    private var updateState: UpdateLifecycleState = .idle {
        didSet {
            guard updateState != oldValue else { return }
            NotificationCenter.default.post(name: .yankUpdateStateChanged, object: self)
        }
    }
    private var availableCandidate: UpdateCandidate?
    private var retryCandidate: UpdateCandidate?
    private var retryStagedUpdate: StagedUpdate?
    private var downloadTask: Task<Void, Never>?
    private var downloadSessionID: UUID?

    private init() {
        releasesURL = Self.releaseFeedURL
        restoreStagedUpdate()
    }

    var menuPresentation: UpdateMenuPresentation {
        updateState.menuPresentation
    }

    private struct UpdateCandidate: Sendable {
        let version: String
        let tag: String
        let downloadURL: String
        let checksumURL: String
        let releaseNotes: String?
        let releaseURL: String?
    }

    func checkOnLaunchIfNeeded() {
        if let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 86400 {
            return
        }
        checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool) {
        guard updateState.canCheckForUpdates else {
            if !silent {
                NotificationCenter.default.post(name: .yankUpdateStateChanged, object: self)
            }
            return
        }

        availableCandidate = nil
        retryCandidate = nil
        retryStagedUpdate = nil
        updateState = .checking
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        let releasesURL = releasesURL
        Task { [weak self] in
            guard let self else { return }
            do {
                let releases = try await Self.fetchReleases(from: releasesURL)
                handleReleases(releases, silent: silent)
            } catch {
                handleUpdateCheckFailure(error, silent: silent)
            }
        }
    }

    // Fetching the release manifest is not the trust anchor; staged apps still must pass
    // checksum, codesign/team, and Gatekeeper verification before install.
    private nonisolated static func fetchReleases(from url: URL) async throws -> [UpdateRelease] {
        try UpdateSecurityPolicy.validateReleaseFeedURL(url)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await BoundedResponse.load(
            request,
            what: "Release manifest",
            maximumBytes: UpdateSecurityPolicy.maximumReleaseFeedBytes
        )
        try UpdateSecurityPolicy.validateReleaseFeedResponse(response, expectedURL: url)
        let status = (response as? HTTPURLResponse)?.statusCode

        do {
            return try JSONDecoder().decode([UpdateRelease].self, from: data)
        } catch {
            throw UpdateError.releaseManifestDecodeFailed(status: status, byteCount: data.count)
        }
    }

    private func handleReleases(_ releases: [UpdateRelease], silent: Bool) {
        #if arch(arm64)
            let archKeyword = "Silicon"
        #else
            let archKeyword = "Intel"
        #endif

        guard let selected = UpdateReleaseSelection.newestCandidate(from: releases, archKeyword: archKeyword) else {
            updateState = silent ? .idle : .unavailable
            return
        }

        let candidate = UpdateCandidate(
            version: stripTagPrefix(selected.tag),
            tag: selected.tag,
            downloadURL: selected.downloadURL,
            checksumURL: selected.checksumURL,
            releaseNotes: selected.releaseNotes,
            releaseURL: selected.releaseURL
        )

        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

        if UpdateVersion.shouldOfferUpdate(
            candidate: candidate.version, current: current, highestInstalled: updatedInstallFloor(current: current)
        ) {
            availableCandidate = candidate
            updateState = .available(version: candidate.version, tag: candidate.tag)
        } else if !silent {
            updateState = .upToDate(version: current)
        } else {
            updateState = .idle
        }
    }

    private func handleUpdateCheckFailure(_ error: any Error, silent: Bool) {
        Log.update.error("Update check failed: \(error.localizedDescription)")
        guard !silent else {
            updateState = .idle
            return
        }
        retryCandidate = nil
        retryStagedUpdate = nil
        updateState = .failed(UpdateFailureContext(
            title: "Could not check for updates",
            detail: error.localizedDescription,
            version: nil,
            tag: nil
        ))
    }

    /// The highest version ever run on this machine — a monotonic floor that stops a tampered
    /// release manifest from re-offering a signed-but-older build the user already moved past.
    /// Bumped to the running version on every read, so it's a no-op floor in the normal case.
    private func updatedInstallFloor(current: String) -> String {
        let stored = UserDefaults.standard.string(forKey: Self.highestInstalledKey) ?? current
        let floor = UpdateVersion.isNewer(current, than: stored) ? current : stored
        UserDefaults.standard.set(floor, forKey: Self.highestInstalledKey)
        return floor
    }

    private func stripTagPrefix(_ tag: String) -> String {
        var version = tag
        if version.lowercased().hasPrefix("v") {
            version = String(version.dropFirst(1))
        }
        return version
    }

    func checkIfJustUpdated() {
        guard UserDefaults.standard.bool(forKey: Self.justUpdatedKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.justUpdatedKey)
        let staged = persistedStagedUpdate()
        let tag = UserDefaults.standard.string(forKey: Self.updateTagKey) ?? staged?.tag ?? ""
        UserDefaults.standard.removeObject(forKey: Self.updateTagKey)
        clearStagedUpdate()
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        updateState = .installed(
            version: version,
            tag: tag,
            releaseNotes: staged?.releaseNotes,
            releaseURL: staged?.releaseURL
        )
    }

    func handleMenuAction(_ action: UpdateMenuActionID) {
        switch action {
        case .check:
            checkForUpdates(silent: false)
        case .install:
            installAvailableUpdate()
        case .cancel:
            cancelDownload()
        case .retry:
            retryUpdate()
        case .relaunch:
            finishStagedUpdateIfAvailable()
        case .openReleaseNotes:
            openReleaseNotes()
        }
    }

    private func installAvailableUpdate() {
        guard let candidate = availableCandidate else { return }
        startDownloadAndStage(candidate)
    }

    private func retryUpdate() {
        if let staged = retryStagedUpdate {
            retryStagedUpdate = nil
            updateState = .staged(staged)
            finishStagedUpdateIfAvailable()
        } else if let candidate = retryCandidate {
            startDownloadAndStage(candidate)
        } else {
            checkForUpdates(silent: false)
        }
    }

    private func startDownloadAndStage(_ candidate: UpdateCandidate) {
        downloadTask?.cancel()
        availableCandidate = nil
        retryCandidate = candidate
        retryStagedUpdate = nil
        let sessionID = UUID()
        downloadSessionID = sessionID
        updateState = .downloading(version: candidate.version)
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await downloadAndStage(candidate, sessionID: sessionID)
        }
    }

    private func cancelDownload() {
        guard downloadTask != nil || downloadSessionID != nil else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadSessionID = nil
        updateState = .idle
        retryCandidate = nil
        Log.update.info("Update download cancelled by user.")
    }

    private func downloadAndStage(_ candidate: UpdateCandidate, sessionID: UUID) async {
        var downloadedFileURL: URL?
        var stagedForCleanup: StagedUpdate?

        do {
            guard let downloadURL = URL(string: candidate.downloadURL) else {
                throw UpdateError.invalidURL(candidate.downloadURL)
            }
            guard let checksumURL = URL(string: candidate.checksumURL) else {
                throw UpdateError.invalidURL(candidate.checksumURL)
            }
            try UpdateSecurityPolicy.validateReleaseAssetURL(downloadURL)
            try UpdateSecurityPolicy.validateReleaseAssetURL(checksumURL)
            try Task.checkCancellation()
            guard activeDownloadCanComplete(sessionID: sessionID, version: candidate.version) else {
                throw CancellationError()
            }

            async let expectedChecksum = UpdateInstaller.fetchExpectedSHA256(from: checksumURL)
            let (localURL, response) = try await URLSession.shared.download(from: downloadURL)
            downloadedFileURL = localURL
            try Task.checkCancellation()
            guard activeDownloadCanComplete(sessionID: sessionID, version: candidate.version) else {
                throw CancellationError()
            }
            try UpdateSecurityPolicy.validateReleaseAssetResponse(response)
            let expected = try await expectedChecksum
            try Task.checkCancellation()
            let targetAppURL = Bundle.main.bundleURL
            let staged = try await Self.stageUpdate(
                expectedVersion: candidate.version,
                tag: candidate.tag,
                localURL: localURL,
                expectedChecksum: expected,
                targetAppURL: targetAppURL,
                releaseNotes: candidate.releaseNotes,
                releaseURL: candidate.releaseURL
            )
            stagedForCleanup = staged
            try Task.checkCancellation()
            guard activeDownloadCanComplete(sessionID: sessionID, version: candidate.version) else {
                throw CancellationError()
            }

            saveStagedUpdate(staged)
            updateState = .staged(staged)
            finishActiveDownload(sessionID)
            retryCandidate = nil
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        } catch where Self.isCancellation(error) {
            cleanUpDownloadArtifacts(downloadedFileURL: downloadedFileURL, staged: stagedForCleanup)
            finishCancelledDownload(sessionID)
        } catch {
            cleanUpDownloadArtifacts(downloadedFileURL: downloadedFileURL, staged: nil)
            guard downloadSessionID == sessionID else { return }
            downloadTask = nil
            downloadSessionID = nil
            retryCandidate = candidate
            retryStagedUpdate = nil
            Log.update.error("Update failed: \(error.localizedDescription)")
            updateState = .failed(UpdateFailureContext(
                title: "Yank \(candidate.version) could not be installed",
                detail: error.localizedDescription,
                version: candidate.version,
                tag: candidate.tag
            ))
        }
    }

    private func activeDownloadCanComplete(sessionID: UUID, version: String) -> Bool {
        downloadSessionID == sessionID && updateState.canAcceptDownloadedUpdate(version: version)
    }

    private func finishActiveDownload(_ sessionID: UUID) {
        guard downloadSessionID == sessionID else { return }
        downloadTask = nil
        downloadSessionID = nil
    }

    private func finishCancelledDownload(_ sessionID: UUID) {
        guard downloadSessionID == sessionID else { return }
        downloadTask = nil
        downloadSessionID = nil
        updateState = .idle
        retryCandidate = nil
    }

    private func cleanUpDownloadArtifacts(downloadedFileURL: URL?, staged: StagedUpdate?) {
        if let staged {
            UpdateInstaller.removeStagedUpdate(staged)
        }
        if let downloadedFileURL {
            try? FileManager.default.removeItem(at: downloadedFileURL)
        }
    }

    private nonisolated static func stageUpdate(
        expectedVersion: String,
        tag: String,
        localURL: URL,
        expectedChecksum: String,
        targetAppURL: URL,
        releaseNotes: String?,
        releaseURL: String?
    ) async throws -> StagedUpdate {
        let stageTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let staged = try UpdateInstaller.stageInstall(
                expectedVersion: expectedVersion,
                tag: tag,
                localURL: localURL,
                expectedChecksum: expectedChecksum,
                targetAppURL: targetAppURL,
                releaseNotes: releaseNotes,
                releaseURL: releaseURL
            )
            do {
                try Task.checkCancellation()
            } catch {
                UpdateInstaller.removeStagedUpdate(staged)
                throw error
            }
            return staged
        }

        return try await withTaskCancellationHandler {
            try await stageTask.value
        } onCancel: {
            stageTask.cancel()
        }
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func openReleaseNotes() {
        guard case let .installed(_, _, _, releaseURL) = updateState,
              let url = UpdateSecurityPolicy.trustedReleasePageURL(
                from: releaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
              ) else {
            checkForUpdates(silent: false)
            return
        }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func finishStagedUpdateIfAvailable() -> Bool {
        guard let staged = updateState.stagedUpdate else { return false }

        do {
            retryStagedUpdate = nil
            try UpdateInstaller.launchStagedInstall(staged)
            UserDefaults.standard.set(true, forKey: Self.justUpdatedKey)
            UserDefaults.standard.set(staged.tag, forKey: Self.updateTagKey)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                NSApplication.shared.terminate(nil)
            }
        } catch {
            Log.update.error("Staged update failed: \(error.localizedDescription)")
            retryStagedUpdate = staged
            updateState = .failed(UpdateFailureContext(
                title: "Yank \(staged.version) could not be relaunched",
                detail: error.localizedDescription,
                version: staged.version,
                tag: staged.tag
            ))
        }
        return true
    }

    private func saveStagedUpdate(_ staged: StagedUpdate) {
        do {
            let data = try JSONEncoder().encode(staged)
            UserDefaults.standard.set(data, forKey: Self.stagedUpdateKey)
        } catch {
            Log.update.error("Failed to persist staged update: \(error.localizedDescription)")
        }
    }

    private func restoreStagedUpdate() {
        guard let staged = persistedStagedUpdate(),
              stagedUpdateIsUsable(staged) else {
            clearStagedUpdate()
            return
        }
        updateState = .staged(staged)
    }

    private func persistedStagedUpdate() -> StagedUpdate? {
        guard let data = UserDefaults.standard.data(forKey: Self.stagedUpdateKey) else { return nil }
        return try? JSONDecoder().decode(StagedUpdate.self, from: data)
    }

    private func stagedUpdateIsUsable(_ staged: StagedUpdate) -> Bool {
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        // Pure applicability (newer + correct target bundle) is decided in YankCore; only the
        // on-disk existence of the staged payload stays here as an I/O check.
        return UpdateVersion.stagedUpdateApplies(
            stagedVersion: staged.version,
            currentVersion: current,
            targetAppName: URL(fileURLWithPath: staged.targetAppPath).lastPathComponent
        ) && FileManager.default.fileExists(atPath: staged.stagedAppPath)
    }

    private func clearStagedUpdate() {
        if let staged = updateState.stagedUpdate ?? persistedStagedUpdate() {
            UpdateInstaller.removeStagedUpdate(staged)
        }
        UserDefaults.standard.removeObject(forKey: Self.stagedUpdateKey)
        updateState = .idle
    }

}
