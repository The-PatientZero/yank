import Foundation
import Testing
@testable import YankiOS

@Suite
@MainActor
struct IOSForegroundRefreshCoordinatorTests {
    @Test("A new text generation is captured once while every foreground refresh pulls sync")
    func capturesNewGenerationAndAlwaysRefreshesSync() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var captured: [String] = []
        var readCount = 0
        var syncCount = 0

        let firstCaptured = await coordinator.refresh(
            pasteboardChangeCount: 7,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                readCount += 1
                return "  exact text  "
            },
            capture: { text, _, _ in
                captured.append(text)
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let secondCaptured = await coordinator.refresh(
            pasteboardChangeCount: 7,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                readCount += 1
                return "should not be read"
            },
            capture: { text, _, _ in
                captured.append(text)
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(firstCaptured)
        #expect(!secondCaptured)
        #expect(captured == ["  exact text  "])
        #expect(readCount == 1)
        #expect(syncCount == 2)
    }

    @Test("Shared rich classification reaches capture before the plain fallback is stored")
    func forwardsRichRepresentationIdentity() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var captures: [(text: String, generation: Int, hasRichContent: Bool)] = []
        var syncCount = 0

        let richCaptured = await coordinator.refresh(
            pasteboardChangeCount: 8,
            pasteboardTypes: ["public.utf8-plain-text", "public.rtf"],
            isAutomaticCaptureAuthorized: { true },
            readText: { "same fallback" },
            capture: { text, generation, hasRichContent in
                captures.append((text, generation, hasRichContent))
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let plainCaptured = await coordinator.refresh(
            pasteboardChangeCount: 9,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: { "same fallback" },
            capture: { text, generation, hasRichContent in
                captures.append((text, generation, hasRichContent))
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(richCaptured)
        #expect(plainCaptured)
        #expect(captures.map { $0.text } == ["same fallback", "same fallback"])
        #expect(captures.map { $0.generation } == [8, 9])
        #expect(captures.map { $0.hasRichContent } == [true, false])
        #expect(syncCount == 2)
    }

    @Test("A Yank-authored pasteboard generation is not recaptured")
    func skipsHandledGeneration() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        coordinator.markPasteboardChangeHandled(11)
        var didRead = false
        var captured: [String] = []
        var syncCount = 0

        let didCapture = await coordinator.refresh(
            pasteboardChangeCount: 11,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                didRead = true
                return "already copied by Yank"
            },
            capture: { text, _, _ in
                captured.append(text)
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!didCapture)
        #expect(!didRead)
        #expect(captured.isEmpty)
        #expect(syncCount == 1)
    }

    @Test("Concealed and whitespace-only generations stay out of history")
    func skipsIneligibleGenerations() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var readCount = 0
        var captured: [String] = []
        var syncCount = 0

        let concealedCapture = await coordinator.refresh(
            pasteboardChangeCount: 20,
            pasteboardTypes: [
                "public.utf8-plain-text",
                "org.nspasteboard.ConcealedType"
            ],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                readCount += 1
                return "secret"
            },
            capture: { text, _, _ in
                captured.append(text)
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let repeatedConcealedCapture = await coordinator.refresh(
            pasteboardChangeCount: 20,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                Issue.record("A terminal policy rejection must not be read again")
                return "unexpected"
            },
            capture: { _, _, _ in
                Issue.record("A terminal policy rejection must not be captured")
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let whitespaceCapture = await coordinator.refresh(
            pasteboardChangeCount: 21,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                readCount += 1
                return " \n\t "
            },
            capture: { text, _, _ in
                captured.append(text)
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let repeatedWhitespaceCapture = await coordinator.refresh(
            pasteboardChangeCount: 21,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                Issue.record("A terminal empty-content rejection must not be read again")
                return "unexpected"
            },
            capture: { _, _, _ in
                Issue.record("A terminal empty-content rejection must not be captured")
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!concealedCapture)
        #expect(!repeatedConcealedCapture)
        #expect(!whitespaceCapture)
        #expect(!repeatedWhitespaceCapture)
        #expect(readCount == 1)
        #expect(captured.isEmpty)
        #expect(syncCount == 4)
    }

    @Test("Capture completes before the foreground sync refresh")
    func capturesBeforeRefreshingSync() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var events: [String] = []

        _ = await coordinator.refresh(
            pasteboardChangeCount: 30,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: { "new local clip" },
            capture: { _, _, _ in
                events.append("capture")
                return .durable
            },
            refreshSync: { events.append("sync") }
        )

        #expect(events == ["capture", "sync"])
    }

    @Test("Denied automatic authorization skips every pasteboard callback but still refreshes sync")
    func deniedAuthorizationAvoidsPasteboardBoundary() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var syncCount = 0

        let captured = await coordinator.refresh(
            pasteboardChangeCount: 31,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { false },
            currentPasteboardChangeCount: {
                Issue.record("Denied authorization must not read the current generation")
                return 31
            },
            isPasteboardOwnedByThisInstallation: {
                Issue.record("Denied authorization must not inspect the origin marker")
                return false
            },
            readText: {
                Issue.record("Denied authorization must not read clipboard text")
                return "unexpected"
            },
            capture: { _, _, _ in
                Issue.record("Denied authorization must not capture clipboard text")
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!captured)
        #expect(syncCount == 1)
    }

    @Test("A nil pasteboard read is retried for the same generation")
    func retriesNilRead() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var reads: [String?] = [nil, "available after permission"]
        var captured: [String] = []
        var syncCount = 0

        let first = await coordinator.refresh(
            pasteboardChangeCount: 40,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: { reads.removeFirst() },
            capture: { text, _, _ in
                captured.append(text)
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let second = await coordinator.refresh(
            pasteboardChangeCount: 40,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: { reads.removeFirst() },
            capture: { text, _, _ in
                captured.append(text)
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!first)
        #expect(second)
        #expect(captured == ["available after permission"])
        #expect(syncCount == 2)
    }

    @Test("A failed durable capture is retried before its generation advances")
    func retriesFailedDurableCapture() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var attempts = 0
        var syncCount = 0

        let first = await coordinator.refresh(
            pasteboardChangeCount: 50,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: { "retry me" },
            capture: { text, generation, _ in
                #expect(text == "retry me")
                #expect(generation == 50)
                attempts += 1
                return .retryableFailure
            },
            refreshSync: { syncCount += 1 }
        )
        let second = await coordinator.refresh(
            pasteboardChangeCount: 50,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: { "retry me" },
            capture: { _, _, _ in
                attempts += 1
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let third = await coordinator.refresh(
            pasteboardChangeCount: 50,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                Issue.record("A durably handled generation must not be read again")
                return "unexpected"
            },
            capture: { _, _, _ in
                Issue.record("A durably handled generation must not be captured again")
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!first)
        #expect(second)
        #expect(!third)
        #expect(attempts == 2)
        #expect(syncCount == 3)
    }

    @Test("Overlapping refreshes await one capture for the same generation")
    func coalescesOverlappingRefreshes() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let gate = IOSCaptureGate()
        var captureCount = 0
        var syncCount = 0

        let first = Task { @MainActor in
            await coordinator.refresh(
                pasteboardChangeCount: 70,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                readText: { "single flight" },
                capture: { _, _, _ in
                    captureCount += 1
                    await gate.suspend()
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        await gate.waitUntilSuspended()

        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return await coordinator.refresh(
                pasteboardChangeCount: 70,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                readText: {
                    Issue.record("The coalesced refresh must reuse the in-flight read")
                    return "unexpected"
                },
                capture: { _, _, _ in
                    Issue.record("The coalesced refresh must reuse the in-flight capture")
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        while !secondStarted {
            await Task.yield()
        }
        await Task.yield()

        #expect(captureCount == 1)
        #expect(syncCount == 0)

        await gate.resume()
        #expect(await first.value)
        #expect(await second.value)
        #expect(captureCount == 1)
        #expect(syncCount == 2)
    }

    @Test("Overlapping retryable refreshes share one failure and remain retryable")
    func coalescesRetryableOverlappingRefreshes() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let gate = IOSCaptureGate()
        var captureCount = 0
        var syncCount = 0

        let first = Task { @MainActor in
            await coordinator.refresh(
                pasteboardChangeCount: 75,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                readText: { "retryable single flight" },
                capture: { _, _, _ in
                    captureCount += 1
                    await gate.suspend()
                    return .retryableFailure
                },
                refreshSync: { syncCount += 1 }
            )
        }
        await gate.waitUntilSuspended()

        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return await coordinator.refresh(
                pasteboardChangeCount: 75,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                readText: {
                    Issue.record("The overlapping refresh must reuse the retryable capture")
                    return "unexpected"
                },
                capture: { _, _, _ in
                    Issue.record("The overlapping refresh must not start another capture")
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        while !secondStarted {
            await Task.yield()
        }
        await Task.yield()
        #expect(captureCount == 1)

        await gate.resume()
        #expect(!(await first.value))
        #expect(!(await second.value))
        #expect(captureCount == 1)
        #expect(syncCount == 2)

        let retry = await coordinator.refresh(
            pasteboardChangeCount: 75,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: { "retryable single flight" },
            capture: { _, _, _ in
                captureCount += 1
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )
        let suppressed = await coordinator.refresh(
            pasteboardChangeCount: 75,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            readText: {
                Issue.record("The successful retry must advance the generation")
                return "unexpected"
            },
            capture: { _, _, _ in
                Issue.record("The successful retry must not capture again")
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(retry)
        #expect(!suppressed)
        #expect(captureCount == 2)
        #expect(syncCount == 4)
    }

    @Test("A generation change during lazy read cannot capture the old generation")
    func retriesWhenGenerationChangesDuringRead() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        var currentGeneration = 80
        var captured: [(String, Int)] = []

        let stale = await coordinator.refresh(
            pasteboardChangeCount: 80,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            currentPasteboardChangeCount: { currentGeneration },
            readText: {
                currentGeneration = 81
                return "stale value"
            },
            capture: { text, generation, _ in
                captured.append((text, generation))
                return .durable
            },
            refreshSync: {}
        )
        let current = await coordinator.refresh(
            pasteboardChangeCount: 81,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            currentPasteboardChangeCount: { currentGeneration },
            readText: { "current value" },
            capture: { text, generation, _ in
                captured.append((text, generation))
                return .durable
            },
            refreshSync: {}
        )

        #expect(!stale)
        #expect(current)
        #expect(captured.count == 1)
        #expect(captured.first?.0 == "current value")
        #expect(captured.first?.1 == 81)
    }

    @Test("Different generations serialize their durable capture transactions")
    func serializesDifferentGenerations() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let gate = IOSCaptureGate()
        var currentGeneration = 90
        var captureOrder: [Int] = []
        var syncCount = 0

        let first = Task { @MainActor in
            await coordinator.refresh(
                pasteboardChangeCount: 90,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                currentPasteboardChangeCount: { currentGeneration },
                readText: { "first generation" },
                capture: { _, generation, _ in
                    captureOrder.append(generation)
                    await gate.suspend()
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        await gate.waitUntilSuspended()
        currentGeneration = 91

        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return await coordinator.refresh(
                pasteboardChangeCount: 91,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                currentPasteboardChangeCount: { currentGeneration },
                readText: { "second generation" },
                capture: { _, generation, _ in
                    captureOrder.append(generation)
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        while !secondStarted {
            await Task.yield()
        }
        await Task.yield()

        #expect(captureOrder == [90])
        #expect(syncCount == 0)

        await gate.resume()
        #expect(await first.value)
        #expect(await second.value)
        #expect(captureOrder == [90, 91])
        #expect(syncCount == 2)
    }

    @Test("Opting out while a newer generation waits prevents every deferred pasteboard read")
    func optOutStopsDeferredGenerationBeforePasteboardReads() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let gate = IOSCaptureGate()
        var isAuthorized = true
        var currentGenerationReads = 0
        var deferredBoundaryReads = 0
        var captureCount = 0
        var syncCount = 0

        let first = Task { @MainActor in
            await coordinator.refresh(
                pasteboardChangeCount: 120,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { isAuthorized },
                currentPasteboardChangeCount: {
                    currentGenerationReads += 1
                    return 120
                },
                readText: { "authorized snapshot" },
                capture: { _, _, _ in
                    captureCount += 1
                    await gate.suspend()
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        await gate.waitUntilSuspended()

        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return await coordinator.refresh(
                pasteboardChangeCount: 121,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { isAuthorized },
                currentPasteboardChangeCount: {
                    deferredBoundaryReads += 1
                    return 121
                },
                isPasteboardOwnedByThisInstallation: {
                    deferredBoundaryReads += 1
                    return false
                },
                readText: {
                    deferredBoundaryReads += 1
                    return "must not be read"
                },
                capture: { _, _, _ in
                    deferredBoundaryReads += 1
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        while !secondStarted {
            await Task.yield()
        }
        await Task.yield()

        isAuthorized = false
        await gate.resume()

        #expect(!(await first.value))
        #expect(!(await second.value))
        #expect(captureCount == 1)
        #expect(currentGenerationReads == 1)
        #expect(deferredBoundaryReads == 0)
        #expect(syncCount == 2)
    }

    @Test("Opting out during durable capture prevents acknowledgement and permits a later retry")
    func optOutDuringCaptureLeavesGenerationRetryable() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let gate = IOSCaptureGate()
        var isAuthorized = true
        var currentGenerationReads = 0
        var captureCount = 0

        let interrupted = Task { @MainActor in
            await coordinator.processPasteboard(
                pasteboardChangeCount: 130,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { isAuthorized },
                currentPasteboardChangeCount: {
                    currentGenerationReads += 1
                    return 130
                },
                readText: { "durable before opt-out" },
                capture: { _, _, _ in
                    captureCount += 1
                    await gate.suspend()
                    return .durable
                }
            )
        }
        await gate.waitUntilSuspended()
        isAuthorized = false
        await gate.resume()

        #expect(!(await interrupted.value))
        #expect(currentGenerationReads == 1)
        #expect(captureCount == 1)

        isAuthorized = true
        let retry = await coordinator.processPasteboard(
            pasteboardChangeCount: 130,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { isAuthorized },
            currentPasteboardChangeCount: {
                currentGenerationReads += 1
                return 130
            },
            readText: { "durable before opt-out" },
            capture: { _, _, _ in
                captureCount += 1
                return .durable
            }
        )
        let suppressed = await coordinator.processPasteboard(
            pasteboardChangeCount: 130,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { isAuthorized },
            currentPasteboardChangeCount: {
                Issue.record("An acknowledged generation must not inspect the pasteboard")
                return 130
            },
            readText: {
                Issue.record("An acknowledged generation must not read text")
                return "unexpected"
            },
            capture: { _, _, _ in
                Issue.record("An acknowledged generation must not capture again")
                return .durable
            }
        )

        #expect(retry)
        #expect(!suppressed)
        #expect(currentGenerationReads == 3)
        #expect(captureCount == 2)
    }

    @Test("A newer generation proceeds after an older retryable transaction")
    func serializesNewGenerationAfterRetryableFailure() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let gate = IOSCaptureGate()
        var currentGeneration = 95
        var captureOrder: [Int] = []
        var syncCount = 0

        let first = Task { @MainActor in
            await coordinator.refresh(
                pasteboardChangeCount: 95,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                currentPasteboardChangeCount: { currentGeneration },
                readText: { "old retryable generation" },
                capture: { _, generation, _ in
                    captureOrder.append(generation)
                    await gate.suspend()
                    return .retryableFailure
                },
                refreshSync: { syncCount += 1 }
            )
        }
        await gate.waitUntilSuspended()
        currentGeneration = 96

        var secondStarted = false
        let second = Task { @MainActor in
            secondStarted = true
            return await coordinator.refresh(
                pasteboardChangeCount: 96,
                pasteboardTypes: ["public.utf8-plain-text"],
                isAutomaticCaptureAuthorized: { true },
                currentPasteboardChangeCount: { currentGeneration },
                readText: { "new durable generation" },
                capture: { _, generation, _ in
                    captureOrder.append(generation)
                    return .durable
                },
                refreshSync: { syncCount += 1 }
            )
        }
        while !secondStarted {
            await Task.yield()
        }
        await Task.yield()
        #expect(captureOrder == [95])

        await gate.resume()
        #expect(!(await first.value))
        #expect(await second.value)

        let suppressed = await coordinator.refresh(
            pasteboardChangeCount: 96,
            pasteboardTypes: ["public.utf8-plain-text"],
            isAutomaticCaptureAuthorized: { true },
            currentPasteboardChangeCount: { currentGeneration },
            readText: {
                Issue.record("The newer durable generation must be suppressed")
                return "unexpected"
            },
            capture: { _, _, _ in
                Issue.record("The newer durable generation must not capture twice")
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!suppressed)
        #expect(captureOrder == [95, 96])
        #expect(syncCount == 3)
    }

    @Test("A fresh coordinator suppresses a matching persisted origin marker after relaunch")
    func suppressesMarkedPasteboardAfterRelaunch() async {
        let coordinatorAfterRelaunch = IOSForegroundRefreshCoordinator()
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("stable-installation-token".utf8)
        )
        let types = ["public.utf8-plain-text", marker.pasteboardType]
        var didReadText = false
        var didCapture = false
        var syncCount = 0

        let captured = await coordinatorAfterRelaunch.refresh(
            pasteboardChangeCount: 110,
            pasteboardTypes: types,
            isAutomaticCaptureAuthorized: { true },
            isPasteboardOwnedByThisInstallation: {
                marker.matches(pasteboardTypes: types) { type in
                    type == marker.pasteboardType ? marker.tokenData : nil
                }
            },
            readText: {
                didReadText = true
                return "Yank-authored value"
            },
            capture: { _, _, _ in
                didCapture = true
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!captured)
        #expect(!didReadText)
        #expect(!didCapture)
        #expect(syncCount == 1)
    }

    @Test("Byte-identical unmarked external text remains eligible")
    func capturesUnmarkedExternalTwin() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let text = "byte-identical value"
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("stable-installation-token".utf8)
        )
        let externalTypes = ["public.utf8-plain-text"]
        var capturedText: String?

        let captured = await coordinator.refresh(
            pasteboardChangeCount: 111,
            pasteboardTypes: externalTypes,
            isAutomaticCaptureAuthorized: { true },
            isPasteboardOwnedByThisInstallation: {
                marker.matches(pasteboardTypes: externalTypes) { _ in
                    Issue.record("An absent private type must not be read")
                    return marker.tokenData
                }
            },
            readText: { text },
            capture: { value, _, _ in
                capturedText = value
                return .durable
            },
            refreshSync: {}
        )

        #expect(captured)
        #expect(capturedText == text)
    }

    @Test("A wrong-token private type remains eligible for capture")
    func capturesWrongTokenMarker() async {
        let coordinator = IOSForegroundRefreshCoordinator()
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("this-installation-token".utf8)
        )
        let types = ["public.utf8-plain-text", marker.pasteboardType]
        var capturedText: String?

        let captured = await coordinator.refresh(
            pasteboardChangeCount: 112,
            pasteboardTypes: types,
            isAutomaticCaptureAuthorized: { true },
            isPasteboardOwnedByThisInstallation: {
                marker.matches(pasteboardTypes: types) { _ in
                    Data("another-installation-token".utf8)
                }
            },
            readText: { "external value" },
            capture: { value, _, _ in
                capturedText = value
                return .durable
            },
            refreshSync: {}
        )

        #expect(captured)
        #expect(capturedText == "external value")
    }

    @Test("A fresh coordinator suppresses a marked PNG without reading text")
    func suppressesMarkedPNGAfterRelaunch() async {
        let coordinatorAfterRelaunch = IOSForegroundRefreshCoordinator()
        let marker = IOSPasteboardOriginMarker(
            pasteboardType: "org.example.yank-fork.pasteboard-origin",
            tokenData: Data("stable-installation-token".utf8)
        )
        let types = ["public.png", marker.pasteboardType]
        var syncCount = 0

        let captured = await coordinatorAfterRelaunch.refresh(
            pasteboardChangeCount: 113,
            pasteboardTypes: types,
            isAutomaticCaptureAuthorized: { true },
            isPasteboardOwnedByThisInstallation: {
                marker.matches(pasteboardTypes: types) { _ in marker.tokenData }
            },
            readText: {
                Issue.record("A matching image marker must suppress before any text read")
                return nil
            },
            capture: { _, _, _ in
                Issue.record("A matching image marker must not be captured as text")
                return .durable
            },
            refreshSync: { syncCount += 1 }
        )

        #expect(!captured)
        #expect(syncCount == 1)
    }

    @Test("Undecided and explicit-only modes never evaluate the pasteboard boundary")
    func nonAutomaticModesAvoidPasteboardBoundary() async {
        for mode in [IOSForegroundCaptureMode.undecided, .explicitOnly] {
            var events: [String] = []
            var pasteboardBoundaryEvaluations = 0
            var recordedSources: Set<String> = []

            await IOSForegroundRefreshPipeline.refresh(
                currentMode: { mode },
                drainExplicitCaptures: {
                    events.append("drain")
                    return mode == .explicitOnly ? ["Share", "Shortcuts"] : []
                },
                recordSuccessfulCaptureMethods: { sources in
                    events.append("record")
                    recordedSources = sources
                },
                captureAutomatically: {
                    pasteboardBoundaryEvaluations += 1
                    Issue.record(
                        "A non-automatic mode must not construct or inspect the pasteboard"
                    )
                },
                refreshSync: { events.append("sync") }
            )

            #expect(pasteboardBoundaryEvaluations == 0)
            #expect(events == ["drain", "record", "sync"])
            if mode == .explicitOnly {
                #expect(recordedSources == ["Share", "Shortcuts"])
            }
        }
    }

    @Test("Automatic mode evaluates the pasteboard boundary between drain and sync")
    func automaticModeEvaluatesPasteboardBoundary() async {
        var events: [String] = []

        await IOSForegroundRefreshPipeline.refresh(
            currentMode: { .automatic },
            drainExplicitCaptures: {
                events.append("drain")
                return ["Share"]
            },
            recordSuccessfulCaptureMethods: { _ in events.append("record") },
            captureAutomatically: { events.append("pasteboard") },
            refreshSync: { events.append("sync") }
        )

        #expect(events == ["drain", "record", "pasteboard", "sync"])
    }

    @Test("Switching to automatic requests an immediate foreground refresh")
    func automaticModeTransitionRefreshesImmediately() async {
        var refreshCount = 0

        await IOSForegroundRefreshPipeline.refreshAfterModeChange(
            from: .explicitOnly,
            to: .automatic,
            refresh: { refreshCount += 1 }
        )
        await IOSForegroundRefreshPipeline.refreshAfterModeChange(
            from: .automatic,
            to: .explicitOnly,
            refresh: { refreshCount += 1 }
        )

        #expect(refreshCount == 1)
    }

    @Test("A queued automatic refresh rechecks mode after drain before pasteboard access")
    func queuedRefreshHonorsSwitchToExplicitOnly() async {
        let gate = IOSCaptureGate()
        var mode = IOSForegroundCaptureMode.automatic
        var pasteboardBoundaryEvaluations = 0
        var syncCount = 0

        let refresh = Task { @MainActor in
            await IOSForegroundRefreshPipeline.refresh(
                currentMode: { mode },
                drainExplicitCaptures: {
                    await gate.suspend()
                    return []
                },
                recordSuccessfulCaptureMethods: { _ in },
                captureAutomatically: {
                    pasteboardBoundaryEvaluations += 1
                },
                refreshSync: { syncCount += 1 }
            )
        }
        await gate.waitUntilSuspended()
        mode = .explicitOnly
        await gate.resume()
        await refresh.value

        #expect(pasteboardBoundaryEvaluations == 0)
        #expect(syncCount == 1)
    }

    @Test("Unavailable shared defaults cannot enable automatic pasteboard access")
    func missingDefaultsRejectAutomaticModeAndPasteboardAccess() async {
        let settings = IOSSettings(defaults: nil)
        var pasteboardBoundaryEvaluations = 0

        #expect(!settings.setForegroundCaptureMode(.automatic))
        #expect(settings.foregroundCaptureMode == .undecided)

        await IOSForegroundRefreshPipeline.refresh(
            currentMode: { settings.foregroundCaptureMode },
            drainExplicitCaptures: { [] },
            recordSuccessfulCaptureMethods: { _ in },
            captureAutomatically: {
                pasteboardBoundaryEvaluations += 1
            },
            refreshSync: {}
        )

        #expect(pasteboardBoundaryEvaluations == 0)
    }
}

private actor IOSCaptureGate {
    private var isSuspended = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var suspendedContinuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        let suspendedContinuations = self.suspendedContinuations
        self.suspendedContinuations.removeAll()
        for continuation in suspendedContinuations {
            continuation.resume()
        }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspendedContinuations.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
