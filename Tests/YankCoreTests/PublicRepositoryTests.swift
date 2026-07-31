import Foundation
import Testing

@Suite("Public repository")
struct PublicRepositoryTests {
    @Test("Public Markdown relative links resolve")
    func publicMarkdownLinksResolve() throws {
        let root = repositoryRoot
        let files = try publicRepositoryFiles(at: root, extensions: ["md"])
        var brokenLinks: [String] = []

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let links = markdownLinks(in: source)
            brokenLinks.append(contentsOf: links.undefinedReferences.map {
                "\(relativePath(for: file)): undefined reference [\($0)]"
            })
            for destination in links.destinations {
                guard let target = localMarkdownTarget(
                    from: destination,
                    sourceFile: file
                ) else { continue }
                let standardizedTarget = target.file.standardizedFileURL
                let isInsideRepository = standardizedTarget.path == root.path
                    || standardizedTarget.path.hasPrefix(root.path + "/")
                if !isInsideRepository
                    || !FileManager.default.fileExists(atPath: standardizedTarget.path) {
                    brokenLinks.append("\(relativePath(for: file)): \(destination)")
                    continue
                }
                if let anchor = target.anchor,
                   standardizedTarget.pathExtension.lowercased() == "md",
                   !markdownAnchors(in: standardizedTarget).contains(anchor) {
                    brokenLinks.append(
                        "\(relativePath(for: file)): missing anchor #\(anchor) in \(destination)"
                    )
                }
            }
        }

        #expect(brokenLinks.isEmpty, "Broken relative links: \(brokenLinks.sorted())")
    }

    @Test("Every property list and privacy manifest is valid")
    func propertyListsAndPrivacyManifestsAreValid() throws {
        let files = try publicRepositoryFiles(
            at: repositoryRoot,
            extensions: ["plist", "xcprivacy"]
        )
        var invalidFiles: [String] = []

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let propertyList = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                )
                if file.pathExtension == "xcprivacy" {
                    let errors = privacyManifestErrors(in: propertyList)
                    invalidFiles.append(contentsOf: errors.map {
                        "\(relativePath(for: file)): \($0)"
                    })
                }
            } catch {
                invalidFiles.append(relativePath(for: file))
            }
        }

        #expect(!files.isEmpty)
        #expect(invalidFiles.isEmpty, "Invalid property lists: \(invalidFiles.sorted())")
    }

    @Test("CloudKit environment is explicit for Debug and Release")
    func cloudKitEnvironmentIsExplicit() throws {
        let root = repositoryRoot
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        for relativePath in ["Yank.entitlements", "iOS/Yank-iOS.entitlements"] {
            let entitlementData = try Data(
                contentsOf: root.appendingPathComponent(relativePath)
            )
            let entitlements = try #require(
                try PropertyListSerialization.propertyList(
                    from: entitlementData,
                    options: [],
                    format: nil
                ) as? [String: Any]
            )
            #expect(
                entitlements["com.apple.developer.icloud-container-environment"] as? String
                    == "$(ICLOUD_CONTAINER_ENVIRONMENT)"
            )
        }
        let projectLines = Set(project.split(separator: "\n", omittingEmptySubsequences: false))
        #expect(projectLines.contains("    ICLOUD_CONTAINER_ENVIRONMENT: Development"))
        #expect(projectLines.contains("      ICLOUD_CONTAINER_ENVIRONMENT: Production"))
    }

    @Test("Generated targets package every declared plist and privacy manifest")
    func projectConfigurationReferencesPublicMetadata() throws {
        let root = repositoryRoot
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let targets = [
            (
                name: "Yank",
                infoPlist: "Info.plist",
                privacyManifest: "Privacy/Yank/PrivacyInfo.xcprivacy"
            ),
            (
                name: "YankiOS",
                infoPlist: "iOS/App-Info.plist",
                privacyManifest: "Privacy/YankiOS/PrivacyInfo.xcprivacy"
            ),
            (
                name: "YankKeyboard",
                infoPlist: "iOS/Keyboard-Info.plist",
                privacyManifest: "Privacy/Extensions/PrivacyInfo.xcprivacy"
            ),
            (
                name: "YankShare",
                infoPlist: "iOS/Share-Info.plist",
                privacyManifest: "Privacy/Extensions/PrivacyInfo.xcprivacy"
            )
        ]

        for target in targets {
            let block = try #require(
                targetBlock(named: target.name, in: project),
                "Missing target \(target.name)"
            )
            for path in [target.infoPlist, target.privacyManifest] {
                #expect(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(path).path
                    ),
                    "Missing repository metadata: \(path)"
                )
            }
            let lines = Set(block.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            #expect(
                lines.contains("INFOPLIST_FILE: \(target.infoPlist)"),
                "\(target.name) does not use \(target.infoPlist)"
            )
            #expect(
                lines.contains("- path: \(target.privacyManifest)"),
                "\(target.name) does not package \(target.privacyManifest)"
            )
        }
    }

    @Test("Version 1.0.4 is shared by every application bundle")
    func releaseVersionIsSharedByEveryApplicationBundle() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(project.contains(#"MARKETING_VERSION: "1.0.4""#))
        #expect(project.contains(#"CURRENT_PROJECT_VERSION: "1""#))

        for relativePath in [
            "Info.plist",
            "iOS/App-Info.plist",
            "iOS/Keyboard-Info.plist",
            "iOS/Share-Info.plist"
        ] {
            let data = try Data(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath)
            )
            let plist = try #require(
                try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any]
            )
            #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
            #expect(plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
        }
    }

    @Test("Workflow actions are immutable and checkout does not retain credentials")
    func workflowDependenciesArePinned() throws {
        let workflows = try publicRepositoryFiles(
            at: repositoryRoot.appendingPathComponent(".github/workflows"),
            extensions: ["yml", "yaml"]
        )
        let pinnedAction = try NSRegularExpression(
            pattern: #"uses:\s+[^@\s]+@[0-9a-f]{40}\s+#\s+\S.*$"#
        )
        var unpinnedActions: [String] = []
        var credentialedCheckouts: [String] = []

        for workflow in workflows {
            let source = try String(contentsOf: workflow, encoding: .utf8)
            for line in source.split(separator: "\n").map(String.init) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- uses:"), !trimmed.contains("uses: ./") else { continue }
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if pinnedAction.firstMatch(in: trimmed, range: range) == nil {
                    unpinnedActions.append("\(workflow.lastPathComponent): \(trimmed)")
                }
            }
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated()
            where line.contains("- uses: actions/checkout@") {
                let indentation = line.prefix { $0 == " " }.count
                let endIndex = lines[(index + 1)...].firstIndex { candidate in
                    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                    let candidateIndentation = candidate.prefix { $0 == " " }.count
                    return candidateIndentation <= indentation && trimmed.hasPrefix("- ")
                } ?? lines.endIndex
                let checkoutBlock = lines[index..<endIndex]
                if !checkoutBlock.contains(where: {
                    $0.trimmingCharacters(in: .whitespaces) == "persist-credentials: false"
                }) {
                    credentialedCheckouts.append(
                        "\(workflow.lastPathComponent):\(index + 1)"
                    )
                }
            }
        }

        #expect(!workflows.isEmpty)
        #expect(unpinnedActions.isEmpty, "Unpinned workflow actions: \(unpinnedActions)")
        #expect(
            credentialedCheckouts.isEmpty,
            "Checkout retains credentials: \(credentialedCheckouts)"
        )
    }

    @Test("TestFlight workflow preserves the release security boundary")
    func testFlightWorkflowPreservesReleaseSecurityBoundary() throws {
        let workflowURL = repositoryRoot
            .appendingPathComponent(".github/workflows/testflight.yml")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)
        let promoteRange = try #require(workflow.range(of: "\n  promote:\n"))
        let verifySection = workflow[..<promoteRange.lowerBound]
        let promoteSection = workflow[promoteRange.lowerBound...]
        let materializeRange = try #require(
            promoteSection.range(of: "- name: Materialize dedicated App Store Connect key")
        )
        let uploadRange = try #require(
            promoteSection.range(of: "- name: Upload to App Store Connect")
        )
        let validateRange = try #require(
            promoteSection.range(of: "- name: Validate signed archive")
        )
        let cleanupRange = try #require(
            promoteSection.range(
                of: "- name: Remove signing credentials and temporary release files"
            )
        )

        #expect(workflow.contains("  workflow_dispatch:"))
        #expect(!workflow.contains("\n  push:"))
        #expect(!workflow.contains("\n  pull_request:"))
        #expect(!workflow.contains("\n  schedule:"))
        #expect(workflow.contains("  contents: read"))
        #expect(!workflow.contains("contents: write"))
        #expect(!workflow.contains("actions: write"))
        #expect(!workflow.contains("id-token: write"))
        #expect(workflow.contains("group: testflight-internal-promotion"))
        #expect(workflow.contains("cancel-in-progress: false"))
        #expect(workflow.contains("queue: max"))
        #expect(workflow.contains(#"if: github.ref == 'refs/heads/main'"#))
        #expect(workflow.contains(#""refs/heads/main""#))
        #expect(promoteSection.contains("name: testflight"))
        #expect(promoteSection.contains("deployment: true"))
        #expect(promoteSection.contains("APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}"))
        #expect(!promoteSection.contains("APPLE_TEAM_ID: ${{ vars.APPLE_TEAM_ID }}"))
        #expect(!verifySection.contains("secrets."))
        #expect(!verifySection.contains("environment:"))
        #expect(materializeRange.lowerBound < uploadRange.lowerBound)
        #expect(validateRange.lowerBound < uploadRange.lowerBound)
        #expect(cleanupRange.lowerBound > uploadRange.lowerBound)
        #expect(promoteSection.contains("if: always()"))
        #expect(promoteSection.contains(#"rm -f "$ASC_KEY_PATH""#))
        #expect(promoteSection.contains("testFlightInternalTestingOnly -bool YES"))
        #expect(promoteSection.contains("manageAppVersionAndBuildNumber -bool NO"))
        #expect(promoteSection.contains("verify-assignment"))
        #expect(!workflow.contains("actions/upload-artifact"))

        let sourceExportOptions = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("scripts/ExportOptions-AppStore.plist"),
            encoding: .utf8
        )
        #expect(sourceExportOptions.contains("<string>export</string>"))
        #expect(sourceExportOptions.contains("<string>YOUR_TEAM_ID</string>"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private struct MarkdownLinks {
        let destinations: [String]
        let undefinedReferences: [String]
    }

    private struct LocalMarkdownTarget {
        let file: URL
        let anchor: String?
    }

    private func publicRepositoryFiles(
        at root: URL,
        extensions: Set<String>
    ) throws -> [URL] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", repositoryRoot.path,
            "ls-files", "--cached", "--others", "--exclude-standard", "-z"
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PublicRepositoryTestError.gitFileEnumerationFailed
        }

        let relativeRoot = root.path == repositoryRoot.path
            ? ""
            : root.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "") + "/"
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\0")
            .map(String.init)
            .filter {
                $0.hasPrefix(relativeRoot)
                    && extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
            }
            .map { repositoryRoot.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private func privacyManifestErrors(in propertyList: Any) -> [String] {
        guard let manifest = propertyList as? [String: Any] else {
            return ["root is not a dictionary"]
        }
        var errors: [String] = []
        if manifest["NSPrivacyTracking"] as? Bool == nil {
            errors.append("NSPrivacyTracking is not Boolean")
        }
        if manifest["NSPrivacyTrackingDomains"] as? [String] == nil {
            errors.append("NSPrivacyTrackingDomains is not a string array")
        }
        guard let collected = manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] else {
            errors.append("NSPrivacyCollectedDataTypes is not a dictionary array")
            return errors
        }
        for entry in collected {
            if (entry["NSPrivacyCollectedDataType"] as? String)?.isEmpty != false {
                errors.append("collected data type is missing its identifier")
            }
            if entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == nil
                || entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == nil {
                errors.append("collected data type is missing Boolean declarations")
            }
            if (entry["NSPrivacyCollectedDataTypePurposes"] as? [String])?.isEmpty != false {
                errors.append("collected data type has no purpose")
            }
        }
        guard let accessed = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
            errors.append("NSPrivacyAccessedAPITypes is not a dictionary array")
            return errors
        }
        for entry in accessed {
            if (entry["NSPrivacyAccessedAPIType"] as? String)?.isEmpty != false {
                errors.append("accessed API type is missing its category")
            }
            if (entry["NSPrivacyAccessedAPITypeReasons"] as? [String])?.isEmpty != false {
                errors.append("accessed API type has no reason")
            }
        }
        return errors
    }

    private func targetBlock(named target: String, in project: String) -> String? {
        guard let targetsStart = project.range(of: "\ntargets:\n"),
              let targetStart = project.range(
                of: "\n  \(target):\n",
                range: targetsStart.upperBound..<project.endIndex
              ) else {
            return nil
        }
        let remainder = project[targetStart.upperBound...]
        let nextTargetPattern = #"(?m)^  [A-Za-z][A-Za-z0-9_-]*:\s*$"#
        let expression = try? NSRegularExpression(pattern: nextTargetPattern)
        let searchRange = NSRange(remainder.startIndex..<remainder.endIndex, in: project)
        guard let match = expression?.firstMatch(in: project, range: searchRange),
              let nextTargetRange = Range(match.range, in: project) else {
            return String(remainder)
        }
        return String(project[targetStart.upperBound..<nextTargetRange.lowerBound])
    }

    private func markdownLinks(in source: String) -> MarkdownLinks {
        var definitions: [String: String] = [:]
        let definitionPattern = #"(?m)^\s{0,3}\[([^\]]+)\]:\s*(\S+)"#
        if let expression = try? NSRegularExpression(pattern: definitionPattern) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard let labelRange = Range(match.range(at: 1), in: source),
                      let destinationRange = Range(match.range(at: 2), in: source) else {
                    continue
                }
                definitions[normalizedReferenceLabel(String(source[labelRange]))] =
                    String(source[destinationRange])
            }
        }

        var destinations = Array(definitions.values)
        let inlinePattern = #"\[[^\]\n]*\]\(([^)\n]+)\)"#
        if let expression = try? NSRegularExpression(pattern: inlinePattern) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            destinations.append(contentsOf: expression.matches(in: source, range: range).compactMap {
                guard let range = Range($0.range(at: 1), in: source) else { return nil }
                return String(source[range])
            })
        }

        var undefinedReferences: [String] = []
        let referencePattern = #"\[([^\]\n]+)\]\[([^\]\n]*)\]"#
        if let expression = try? NSRegularExpression(pattern: referencePattern) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard let textRange = Range(match.range(at: 1), in: source),
                      let labelRange = Range(match.range(at: 2), in: source) else {
                    continue
                }
                let explicitLabel = String(source[labelRange])
                let label = explicitLabel.isEmpty ? String(source[textRange]) : explicitLabel
                let normalized = normalizedReferenceLabel(label)
                if let destination = definitions[normalized] {
                    destinations.append(destination)
                } else {
                    undefinedReferences.append(label)
                }
            }
        }
        return MarkdownLinks(
            destinations: destinations,
            undefinedReferences: undefinedReferences
        )
    }

    private func normalizedReferenceLabel(_ label: String) -> String {
        label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private func localMarkdownTarget(
        from destination: String,
        sourceFile: URL
    ) -> LocalMarkdownTarget? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTarget: String
        if trimmed.hasPrefix("<"), let closing = trimmed.firstIndex(of: ">") {
            rawTarget = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
        } else {
            rawTarget = String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
        }

        guard !rawTarget.isEmpty,
              !rawTarget.hasPrefix("mailto:"),
              !rawTarget.contains("://") else {
            return nil
        }
        let pathAndAnchor = rawTarget.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let pathWithQuery = String(pathAndAnchor.first ?? "")
        let path = pathWithQuery.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? pathWithQuery
        let decodedPath = path.removingPercentEncoding ?? path
        let file: URL
        if decodedPath.isEmpty {
            file = sourceFile
        } else if decodedPath.hasPrefix("/") {
            file = repositoryRoot.appendingPathComponent(String(decodedPath.dropFirst()))
        } else {
            file = sourceFile.deletingLastPathComponent().appendingPathComponent(decodedPath)
        }
        let anchor = pathAndAnchor.count == 2
            ? String(pathAndAnchor[1]).removingPercentEncoding?.lowercased()
            : nil
        return LocalMarkdownTarget(file: file, anchor: anchor)
    }

    private func markdownAnchors(in file: URL) -> Set<String> {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let headingPattern = #"(?m)^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$"#
        guard let expression = try? NSRegularExpression(pattern: headingPattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var slugCounts: [String: Int] = [:]
        var anchors: Set<String> = []
        for match in expression.matches(in: source, range: range) {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            let base = githubHeadingSlug(String(source[range]))
            let count = slugCounts[base, default: 0]
            slugCounts[base] = count + 1
            anchors.insert(count == 0 ? base : "\(base)-\(count)")
        }
        return anchors
    }

    private func githubHeadingSlug(_ heading: String) -> String {
        var slug = ""
        var previousWasSeparator = false
        for scalar in heading.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar.value > 127 {
                slug.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar), !previousWasSeparator {
                slug.append("-")
                previousWasSeparator = true
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func relativePath(for file: URL) -> String {
        file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
    }
}

private enum PublicRepositoryTestError: Error {
    case gitFileEnumerationFailed
}
