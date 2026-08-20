import CloudKit
import Foundation
import Testing
import UIKit
@testable import YankiOS

@Suite("iOS Cloud sync lifecycle")
@MainActor
struct IOSCloudSyncLifecycleTests {
    @Test("Disabling during account lookup rejects a late available result")
    func disableDuringAccountLookup() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "IOSCloudSyncLifecycleTests.\(UUID().uuidString)")
        )
        defaults.set(true, forKey: SettingsKeys.syncEnabled)
        let settings = IOSSettings(defaults: defaults)
        let store = ClipStore(context: nil)
        let database = LifecycleCloudKitDatabase()
        let accountGate = LifecycleTestGate()
        var serviceCreationCount = 0
        var registrationCount = 0
        var unregistrationCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: {
                        await accountGate.wait()
                        return .available
                    }
                )
            },
            makeService: { database, store, settingsStore in
                serviceCreationCount += 1
                return CloudKitSyncService(
                    containerIdentifier: "test.\(UUID().uuidString)",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: defaults
                )
            },
            registerForRemoteNotifications: {
                registrationCount += 1
            },
            unregisterForRemoteNotifications: {
                unregistrationCount += 1
            }
        )

        let startTask = Task { await controller.start() }
        while !accountGate.hasWaiter {
            await Task.yield()
        }
        controller.stop()
        accountGate.resume()
        await startTask.value

        #expect(serviceCreationCount == 0)
        #expect(registrationCount == 0)
        #expect(unregistrationCount == 1)
        #expect(!controller.iCloudSignedOut)
        #expect(store.syncStatus == .localOnly(reason: .disabled))
        #expect(!database.ensuredZone)
    }

    @Test("Account loss and lookup errors tear down existing services")
    func unavailableAccountAndErrorTearDownExistingServices() async throws {
        enum AccountOutcome {
            case status(CKAccountStatus)
            case failure
        }

        let defaults = try #require(
            UserDefaults(suiteName: "IOSCloudSyncLifecycleTests.\(UUID().uuidString)")
        )
        defaults.set(true, forKey: SettingsKeys.syncEnabled)
        let settings = IOSSettings(defaults: defaults)
        let store = ClipStore(context: nil)
        let database = LifecycleCloudKitDatabase()
        var accountOutcome = AccountOutcome.status(.available)
        var serviceCreationCount = 0
        var registrationCount = 0
        var unregistrationCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: {
                        switch accountOutcome {
                        case .status(let status):
                            return status
                        case .failure:
                            throw LifecycleTestError.accountLookup
                        }
                    }
                )
            },
            makeService: { database, store, settingsStore in
                serviceCreationCount += 1
                return CloudKitSyncService(
                    containerIdentifier: "test.lifecycle",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: defaults
                )
            },
            registerForRemoteNotifications: {
                registrationCount += 1
            },
            unregisterForRemoteNotifications: {
                unregistrationCount += 1
            }
        )

        await controller.start()
        #expect(serviceCreationCount == 1)
        #expect(registrationCount == 1)

        accountOutcome = .status(.noAccount)
        await controller.refreshForeground()
        #expect(unregistrationCount == 1)
        #expect(store.syncStatus == .localOnly(reason: .notAuthenticated))

        accountOutcome = .status(.available)
        await controller.start()
        #expect(serviceCreationCount == 2)
        #expect(registrationCount == 2)

        accountOutcome = .failure
        await controller.refreshForeground()
        #expect(unregistrationCount == 2)
        guard case .failed = store.syncStatus else {
            Issue.record("Expected the account lookup error to mark sync failed")
            return
        }

        accountOutcome = .status(.available)
        await controller.start()
        #expect(serviceCreationCount == 3)
        #expect(registrationCount == 3)
    }

    @Test("Only a missing or restricted account is a hard sync teardown")
    func accountDecisionSeparatesTransientStatesFromHardOnes() {
        #expect(IOSCloudSyncController.accountDecision(for: .available) == .proceed)
        #expect(IOSCloudSyncController.accountDecision(for: .noAccount)
                == .hardUnavailable(reason: .notAuthenticated))
        #expect(IOSCloudSyncController.accountDecision(for: .restricted)
                == .hardUnavailable(reason: .notAuthenticated))

        for status in [CKAccountStatus.temporarilyUnavailable, .couldNotDetermine] {
            guard case .transient(let message) =
                    IOSCloudSyncController.accountDecision(for: status) else {
                Issue.record("Expected \(status) to be treated as transient")
                return
            }
            #expect(!message.isEmpty)
        }
    }

    @Test("Transient account states keep the service and its push registration")
    func transientAccountStatesKeepTheServiceRegistered() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "IOSCloudSyncLifecycleTests.\(UUID().uuidString)")
        )
        defaults.set(true, forKey: SettingsKeys.syncEnabled)
        let settings = IOSSettings(defaults: defaults)
        let store = ClipStore(context: nil)
        let database = LifecycleCloudKitDatabase()
        var accountStatus = CKAccountStatus.available
        var serviceCreationCount = 0
        var registrationCount = 0
        var unregistrationCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: { accountStatus }
                )
            },
            makeService: { database, store, settingsStore in
                serviceCreationCount += 1
                return CloudKitSyncService(
                    containerIdentifier: "test.transient",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: defaults
                )
            },
            registerForRemoteNotifications: { registrationCount += 1 },
            unregisterForRemoteNotifications: { unregistrationCount += 1 }
        )

        await controller.start()
        #expect(serviceCreationCount == 1)
        #expect(registrationCount == 1)

        for transient in [CKAccountStatus.temporarilyUnavailable, .couldNotDetermine] {
            accountStatus = transient
            await controller.refreshForeground()
            #expect(unregistrationCount == 0)
            #expect(!controller.iCloudSignedOut)
            guard case .failed = store.syncStatus else {
                Issue.record("Expected \(transient) to surface a sync failure message")
                return
            }
        }

        accountStatus = .available
        await controller.refreshForeground()
        #expect(serviceCreationCount == 1)
        #expect(registrationCount == 2)
        #expect(unregistrationCount == 0)
        #expect(!controller.iCloudSignedOut)
    }

    @Test("A push that arrives before the handler is wired refreshes once on wiring")
    func remoteChangeArrivingBeforeWiringRefreshesOnceOnWiring() async {
        let delegate = YankAppDelegate(syncEnabledProvider: { true })
        var results: [UIBackgroundFetchResult] = []
        var handlerCallCount = 0

        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { results.append($0) }
        )
        while results.isEmpty {
            await Task.yield()
        }
        #expect(results == [.noData])

        delegate.remoteChangeHandler = {
            handlerCallCount += 1
            return true
        }
        while handlerCallCount == 0 {
            await Task.yield()
        }

        // The latch is one-shot: re-wiring must not replay the same missed notification.
        delegate.remoteChangeHandler = {
            handlerCallCount += 1
            return true
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(handlerCallCount == 1)
        #expect(results == [.noData])
    }

    @Test("Disabling a remote notification completes once and preserves re-enable delivery")
    func disableRemoteNotificationCompletesExactlyOnceAndReenables() async {
        let handlerGate = LifecycleTestGate()
        let syncEnabled = LifecycleSyncEnabled()
        var handlerCallCount = 0
        let delegate = YankAppDelegate(syncEnabledProvider: { syncEnabled.value })
        delegate.remoteChangeHandler = {
            handlerCallCount += 1
            if handlerCallCount == 1 {
                await handlerGate.wait()
            }
            return true
        }
        var results: [UIBackgroundFetchResult] = []

        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { results.append($0) }
        )
        while !handlerGate.hasWaiter {
            await Task.yield()
        }
        syncEnabled.value = false
        delegate.disableRemoteChanges()

        #expect(results == [.noData])
        handlerGate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(results == [.noData])

        syncEnabled.value = true
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { results.append($0) }
        )
        while results.count < 2 {
            await Task.yield()
        }
        #expect(handlerCallCount == 2)
        #expect(results == [.noData, .newData])
    }

    @Test("Cancellation before dispatch never invokes the remote handler")
    func cancelBeforeRemoteTaskStarts() async {
        let syncEnabled = LifecycleSyncEnabled()
        var handlerCallCount = 0
        let delegate = YankAppDelegate(syncEnabledProvider: { syncEnabled.value })
        delegate.remoteChangeHandler = {
            handlerCallCount += 1
            return true
        }
        var results: [UIBackgroundFetchResult] = []

        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { results.append($0) }
        )
        syncEnabled.value = false
        delegate.disableRemoteChanges()
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(handlerCallCount == 0)
        #expect(results == [.noData])
    }

    @Test("Disabled delivery cancels older work and completes both callbacks once")
    func disabledDeliveryCancelsPendingRemoteChange() async {
        let handlerGate = LifecycleTestGate()
        let syncEnabled = LifecycleSyncEnabled()
        var handlerCallCount = 0
        let delegate = YankAppDelegate(syncEnabledProvider: { syncEnabled.value })
        delegate.remoteChangeHandler = {
            handlerCallCount += 1
            await handlerGate.wait()
            return true
        }
        var firstResults: [UIBackgroundFetchResult] = []
        var secondResults: [UIBackgroundFetchResult] = []

        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { firstResults.append($0) }
        )
        while !handlerGate.hasWaiter {
            await Task.yield()
        }
        syncEnabled.value = false
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { secondResults.append($0) }
        )

        #expect(firstResults == [.noData])
        #expect(secondResults == [.noData])
        handlerGate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(handlerCallCount == 1)
        #expect(firstResults == [.noData])
        #expect(secondResults == [.noData])
    }

    @Test("A newer delivery replaces older work without duplicate completion")
    func newerDeliveryReplacesPendingRemoteChange() async {
        let firstHandlerGate = LifecycleTestGate()
        var handlerCallCount = 0
        let delegate = YankAppDelegate(syncEnabledProvider: { true })
        delegate.remoteChangeHandler = {
            handlerCallCount += 1
            if handlerCallCount == 1 {
                await firstHandlerGate.wait()
            }
            return true
        }
        var firstResults: [UIBackgroundFetchResult] = []
        var secondResults: [UIBackgroundFetchResult] = []

        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { firstResults.append($0) }
        )
        while !firstHandlerGate.hasWaiter {
            await Task.yield()
        }
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { secondResults.append($0) }
        )
        while secondResults.isEmpty {
            await Task.yield()
        }

        #expect(firstResults == [.noData])
        #expect(secondResults == [.newData])
        firstHandlerGate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(handlerCallCount == 2)
        #expect(firstResults == [.noData])
        #expect(secondResults == [.newData])
    }

    @Test("Missing and unsuccessful handlers complete deterministically")
    func missingAndUnsuccessfulRemoteHandlers() async {
        let delegate = YankAppDelegate(syncEnabledProvider: { true })
        var results: [UIBackgroundFetchResult] = []

        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { results.append($0) }
        )
        while results.isEmpty {
            await Task.yield()
        }
        delegate.remoteChangeHandler = { false }
        delegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [:],
            fetchCompletionHandler: { results.append($0) }
        )
        while results.count < 2 {
            await Task.yield()
        }

        #expect(results == [.noData, .failed])
    }

    @Test("A failed start is retried by the next foreground refresh, not just pulled")
    func failedStartIsReattemptedByForegroundRequest() async throws {
        let fixture = try makeWorkingStoreFixture()
        defer { fixture.cleanUp() }
        let settings = IOSSettings(defaults: fixture.defaults)
        let store = fixture.store
        let database = RecordingCloudKitDatabase()
        database.ensureZoneError = LifecycleTestError.accountLookup
        var serviceCreationCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: { .available }
                )
            },
            makeService: { database, store, settingsStore in
                serviceCreationCount += 1
                return CloudKitSyncService(
                    containerIdentifier: "test.retry-foreground",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: fixture.defaults
                )
            },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {}
        )

        await controller.start()
        #expect(database.ensureZoneCallCount == 1)
        #expect(serviceCreationCount == 1)
        guard case .failed = store.syncStatus else {
            Issue.record("Expected the failed bring-up to mark sync failed")
            return
        }

        database.ensureZoneError = nil
        await controller.refreshForeground()
        #expect(database.ensureZoneCallCount == 2)
        #expect(serviceCreationCount == 1)
        guard case .healthy = store.syncStatus else {
            Issue.record("Expected the re-attempted start to succeed")
            return
        }
    }

    @Test("A failed start is retried by a remote change request, not just pulled")
    func failedStartIsReattemptedByRemoteRequest() async throws {
        let fixture = try makeWorkingStoreFixture()
        defer { fixture.cleanUp() }
        let settings = IOSSettings(defaults: fixture.defaults)
        let store = fixture.store
        let database = RecordingCloudKitDatabase()
        database.ensureZoneError = LifecycleTestError.accountLookup
        var serviceCreationCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: { .available }
                )
            },
            makeService: { database, store, settingsStore in
                serviceCreationCount += 1
                return CloudKitSyncService(
                    containerIdentifier: "test.retry-remote",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: fixture.defaults
                )
            },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {}
        )

        await controller.start()
        #expect(database.ensureZoneCallCount == 1)
        guard case .failed = store.syncStatus else {
            Issue.record("Expected the failed bring-up to mark sync failed")
            return
        }

        database.ensureZoneError = nil
        _ = await controller.handleRemoteChange()
        #expect(database.ensureZoneCallCount == 2)
        #expect(serviceCreationCount == 1)
        guard case .healthy = store.syncStatus else {
            Issue.record("Expected the re-attempted start to succeed")
            return
        }
    }

    @Test("A successful start is not re-run by later foreground or remote requests")
    func successfulStartIsNotReattemptedByFastPaths() async throws {
        let fixture = try makeWorkingStoreFixture()
        defer { fixture.cleanUp() }
        let settings = IOSSettings(defaults: fixture.defaults)
        let store = fixture.store
        let database = RecordingCloudKitDatabase()
        var serviceCreationCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: { .available }
                )
            },
            makeService: { database, store, settingsStore in
                serviceCreationCount += 1
                return CloudKitSyncService(
                    containerIdentifier: "test.no-restart",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: fixture.defaults
                )
            },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {}
        )

        await controller.start()
        #expect(database.ensureZoneCallCount == 1)
        #expect(serviceCreationCount == 1)
        guard case .healthy = store.syncStatus else {
            Issue.record("Expected the initial start to succeed")
            return
        }

        await controller.refreshForeground()
        _ = await controller.handleRemoteChange()
        await controller.refreshForeground()

        #expect(database.ensureZoneCallCount == 1)
        #expect(serviceCreationCount == 1)
    }

    @Test("A transient account status retries once and resumes without another foreground")
    func transientAccountStatusRetriesOnceAndResumes() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "IOSCloudSyncLifecycleTests.\(UUID().uuidString)")
        )
        defaults.set(true, forKey: SettingsKeys.syncEnabled)
        let settings = IOSSettings(defaults: defaults)
        let store = ClipStore(context: nil)
        let database = RecordingCloudKitDatabase()
        var accountStatus = CKAccountStatus.available
        var registrationCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: { accountStatus }
                )
            },
            makeService: { database, store, settingsStore in
                CloudKitSyncService(
                    containerIdentifier: "test.transient-retry",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: defaults
                )
            },
            registerForRemoteNotifications: { registrationCount += 1 },
            unregisterForRemoteNotifications: {},
            transientRetryDelayNanoseconds: 20_000_000
        )

        await controller.start()
        #expect(registrationCount == 1)

        accountStatus = .couldNotDetermine
        await controller.refreshForeground()
        #expect(registrationCount == 1)
        guard case .failed = store.syncStatus else {
            Issue.record("Expected the transient status to mark sync failed")
            return
        }

        // The account recovers before the retry fires; the scheduled retry alone must pick
        // this up without another foreground refresh.
        accountStatus = .available
        while registrationCount < 2 {
            await Task.yield()
        }
        #expect(registrationCount == 2)
    }

    @Test("A transient account status retries at most once before falling back to natural triggers")
    func transientAccountStatusDoesNotChainRetries() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "IOSCloudSyncLifecycleTests.\(UUID().uuidString)")
        )
        defaults.set(true, forKey: SettingsKeys.syncEnabled)
        let settings = IOSSettings(defaults: defaults)
        let store = ClipStore(context: nil)
        let database = RecordingCloudKitDatabase()
        var accountStatusCallCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: {
                        accountStatusCallCount += 1
                        return .couldNotDetermine
                    }
                )
            },
            makeService: { database, store, settingsStore in
                CloudKitSyncService(
                    containerIdentifier: "test.transient-bounded",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: defaults
                )
            },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {},
            transientRetryDelayNanoseconds: 20_000_000
        )

        await controller.start()
        #expect(accountStatusCallCount == 1)

        while accountStatusCallCount < 2 {
            await Task.yield()
        }
        #expect(accountStatusCallCount == 2)

        // No chained retry: waiting well past another retry interval must not add a third
        // evaluation. Recovery beyond the single retry waits for the next real trigger.
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(accountStatusCallCount == 2)
    }

    @Test("Stopping or disabling sync cancels a scheduled transient retry")
    func transientRetryIsCancelledOnStopOrDisable() async throws {
        let stopDefaults = try #require(
            UserDefaults(suiteName: "IOSCloudSyncLifecycleTests.\(UUID().uuidString)")
        )
        stopDefaults.set(true, forKey: SettingsKeys.syncEnabled)
        let stopSettings = IOSSettings(defaults: stopDefaults)
        let stopStore = ClipStore(context: nil)
        let stopDatabase = RecordingCloudKitDatabase()
        var stopAccountCallCount = 0
        let stopController = IOSCloudSyncController(
            store: stopStore,
            settings: stopSettings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: stopDatabase,
                    accountStatus: {
                        stopAccountCallCount += 1
                        return .couldNotDetermine
                    }
                )
            },
            makeService: { database, store, settingsStore in
                CloudKitSyncService(
                    containerIdentifier: "test.transient-stop",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: stopDefaults
                )
            },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {},
            transientRetryDelayNanoseconds: 20_000_000
        )
        await stopController.start()
        #expect(stopAccountCallCount == 1)
        stopController.stop()
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(stopAccountCallCount == 1)

        let disableDefaults = try #require(
            UserDefaults(suiteName: "IOSCloudSyncLifecycleTests.\(UUID().uuidString)")
        )
        disableDefaults.set(true, forKey: SettingsKeys.syncEnabled)
        let disableSettings = IOSSettings(defaults: disableDefaults)
        let disableStore = ClipStore(context: nil)
        let disableDatabase = RecordingCloudKitDatabase()
        var disableAccountCallCount = 0
        let disableController = IOSCloudSyncController(
            store: disableStore,
            settings: disableSettings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: disableDatabase,
                    accountStatus: {
                        disableAccountCallCount += 1
                        return .couldNotDetermine
                    }
                )
            },
            makeService: { database, store, settingsStore in
                CloudKitSyncService(
                    containerIdentifier: "test.transient-disable",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: disableDefaults
                )
            },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {},
            transientRetryDelayNanoseconds: 20_000_000
        )
        await disableController.start()
        #expect(disableAccountCallCount == 1)
        disableSettings.syncEnabled = false
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(disableAccountCallCount == 1)
    }

    @Test("A remote trigger arriving mid-refresh coalesces into exactly one follow-up pull")
    func remoteTriggerDuringInFlightOperationRunsOneFollowUpPull() async throws {
        let fixture = try makeWorkingStoreFixture()
        defer { fixture.cleanUp() }
        let settings = IOSSettings(defaults: fixture.defaults)
        let store = fixture.store
        let database = RecordingCloudKitDatabase()
        let accountGate = LifecycleTestGate()
        var accountCallCount = 0
        let controller = IOSCloudSyncController(
            store: store,
            settings: settings,
            makeContainer: {
                IOSCloudSyncController.ContainerHandle(
                    database: database,
                    accountStatus: {
                        accountCallCount += 1
                        if accountCallCount == 2 {
                            await accountGate.wait()
                        }
                        return .available
                    }
                )
            },
            makeService: { database, store, settingsStore in
                CloudKitSyncService(
                    containerIdentifier: "test.coalesce",
                    store: store,
                    database: database,
                    settingsStore: settingsStore,
                    defaults: fixture.defaults
                )
            },
            registerForRemoteNotifications: {},
            unregisterForRemoteNotifications: {}
        )

        await controller.start()
        #expect(database.fetchZoneChangesCallCount == 1)
        guard case .healthy = store.syncStatus else {
            Issue.record("Expected the initial start to succeed")
            return
        }

        let foregroundTask = Task { await controller.refreshForeground() }
        while !accountGate.hasWaiter {
            await Task.yield()
        }

        let remoteTask = Task { await controller.handleRemoteChange() }
        // Let the remote request observe the in-flight foreground operation and register
        // itself as a pending trigger before the gated account lookup resumes.
        for _ in 0..<10 {
            await Task.yield()
        }

        accountGate.resume()
        await foregroundTask.value
        _ = await remoteTask.value

        // One pull from `start()`, one from the foreground refresh, and exactly one
        // coalesced follow-up pull for the remote trigger that arrived mid-flight.
        #expect(database.fetchZoneChangesCallCount == 3)
        #expect(accountCallCount == 2)
    }

    /// A `ClipStore` backed by a real, writable App Group so `CloudKitSyncService.start()` can
    /// actually reach `.started` — `ClipStore(context: nil)` disables history writes outright,
    /// which is fine for the failure-path tests above but hides a genuine bring-up success.
    private func makeWorkingStoreFixture() throws -> CloudSyncFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSCloudSyncLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "IOSCloudSyncLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: SettingsKeys.syncEnabled)
        let context = AppGroupContext(containerURL: root, defaults: defaults)
        return CloudSyncFixture(root: root, defaultsName: defaultsName, defaults: defaults, store: ClipStore(context: context))
    }
}

private struct CloudSyncFixture {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let store: ClipStore

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }
}

private enum LifecycleTestError: Error {
    case accountLookup
}

@MainActor
private final class LifecycleSyncEnabled {
    var value = true
}

@MainActor
private final class LifecycleTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var hasWaiter: Bool {
        continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class LifecycleCloudKitDatabase: CloudKitDatabase {
    private(set) var ensuredZone = false

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        ensuredZone = true
    }

    func ensureSubscription(id subscriptionID: String) async throws {}

    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        CloudKitZoneChanges(
            changedRecords: [],
            deletedRecordNames: [],
            changeToken: token,
            moreComing: false
        )
    }

    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence {
        CloudKitRecordPresence(missingRecordNames: Set(recordNames))
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitFetchedRecords {
        CloudKitFetchedRecords()
    }

    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult {
        CloudKitRecordSaveResult()
    }

    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome {
        .saved
    }
}

/// Counts zone-bring-up and pull calls so tests can tell a re-attempted `start()` apart from
/// a plain pull, and optionally fails `ensureZone` to simulate a failed bring-up.
@MainActor
private final class RecordingCloudKitDatabase: CloudKitDatabase {
    private(set) var ensureZoneCallCount = 0
    private(set) var fetchZoneChangesCallCount = 0
    var ensureZoneError: Error?

    func ensureZone(_ zoneID: CKRecordZone.ID) async throws {
        ensureZoneCallCount += 1
        if let ensureZoneError {
            throw ensureZoneError
        }
    }

    func ensureSubscription(id subscriptionID: String) async throws {}

    func fetchZoneChanges(
        _ zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        fetchZoneChangesCallCount += 1
        return CloudKitZoneChanges(
            changedRecords: [],
            deletedRecordNames: [],
            changeToken: token,
            moreComing: false
        )
    }

    func fetchRecordPresence(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitRecordPresence {
        CloudKitRecordPresence(missingRecordNames: Set(recordNames))
    }

    func fetchRecords(
        for recordNames: [String],
        in zoneID: CKRecordZone.ID
    ) async throws -> CloudKitFetchedRecords {
        CloudKitFetchedRecords()
    }

    func saveRecords(_ records: [CKRecord]) async throws -> CloudKitRecordSaveResult {
        CloudKitRecordSaveResult()
    }

    func saveRecordIfUnchanged(_ record: CKRecord) async throws -> CloudKitConditionalSaveOutcome {
        .saved
    }
}
