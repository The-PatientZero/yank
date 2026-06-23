import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Privacy: apps whose copies are never recorded. A managed list, not a
/// pile of toggles — excluded apps are uniform removable rows; adding is one "Add app…"
/// menu that offers installed password managers plus a Browse option.
struct CaptureExclusionSection: View {
    private let settings = SettingsManager.shared

    /// Currently-excluded apps, sorted by display name.
    private var excluded: [String] {
        settings.excludedBundleIDs.sorted {
            appName(for: $0).localizedCaseInsensitiveCompare(appName(for: $1)) == .orderedAscending
        }
    }

    /// Suggested apps that are installed and not yet excluded — offered in the menu.
    private var addableSuggestions: [AppExclusionSuggestion] {
        suggestedExclusions.filter {
            isInstalled($0.bundleID) && !settings.excludedBundleIDs.contains($0.bundleID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Add any app whose copies you never want Yank to record. Password managers installed on this Mac are suggested below.")
                .font(.system(size: TypeScale.micro))
                .foregroundColor(.yankTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if excluded.isEmpty {
                HStack(spacing: Space.sm) {
                    Image(systemName: "hand.raised").foregroundColor(.yankTextTertiary)
                        .accessibilityHidden(true)
                    Text("No apps excluded.").foregroundColor(.secondary)
                }
                .font(.system(size: TypeScale.caption))
                .padding(.vertical, Space.xs)
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(excluded, id: \.self) { bundleID in excludedRow(bundleID) }
                }
            }

            addMenu
        }
    }

    private func excludedRow(_ bundleID: String) -> some View {
        HStack(spacing: Space.md) {
            appIcon(for: bundleID).frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(appName(for: bundleID)).font(.system(size: TypeScale.body)).lineLimit(1)
            Spacer(minLength: Space.sm)
            IconButton(systemName: "xmark.circle.fill",
                       label: "Stop excluding \(appName(for: bundleID))") {
                settings.setExclusion(bundleID: bundleID, enabled: false)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Color.yankSurface, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.yankHairline, lineWidth: 0.5))
        .help(bundleID)
    }

    private var addMenu: some View {
        Menu {
            ForEach(addableSuggestions) { suggestion in
                Button(suggestion.name) {
                    settings.setExclusion(bundleID: suggestion.bundleID, enabled: true)
                }
            }
            if !addableSuggestions.isEmpty { Divider() }
            Button("Browse…", action: addApp)
        } label: {
            Label("Add app…", systemImage: "plus")
                .font(.system(size: TypeScale.control, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: TypeScale.body))
                .foregroundColor(.yankTextTertiary)
        }
    }

    private func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // Fall back to the suggestion's friendly name, else the raw id.
            return suggestedExclusions.first { $0.bundleID == bundleID }?.name ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.setExclusion(bundleID: bundleID, enabled: true)
    }
}
