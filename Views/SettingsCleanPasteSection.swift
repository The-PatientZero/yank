import SwiftUI

extension SettingsView {
    private static let cleanPasteCaption = "Removes padding spaces, shared indentation, colour codes and frame characters when pasting. Shift-Return pastes the other version."

    private var addableCleanPasteApps: [String] {
        var seen = manager.cleanPasteApps
        return (store?.items ?? []).sorted { $0.timestamp > $1.timestamp }.compactMap { item in
            guard let name = item.sourceApp, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    var cleanPasteSection: some View {
        field("Clean terminal text", Self.cleanPasteCaption) {
            Picker("Clean terminal text", selection: Binding(
                get: { manager.cleanPasteMode },
                set: { mode in
                    manager.cleanPasteMode = mode
                    manager.save()
                })) {
                ForEach(CleanPasteMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Clean terminal text")
            .accessibilityValue(manager.cleanPasteMode.label)
            .accessibilityHint(Self.cleanPasteCaption)

            if manager.cleanPasteMode == .chosenApps {
                VStack(alignment: .leading, spacing: Space.md) {
                    if manager.cleanPasteApps.isEmpty {
                        Text("No apps chosen.")
                            .font(.system(size: TypeScale.caption))
                            .foregroundColor(.secondary)
                            .padding(.vertical, Space.xs)
                    } else {
                        VStack(spacing: Space.xs) {
                            ForEach(manager.cleanPasteApps.sorted(), id: \.self) { name in
                                cleanPasteAppRow(name)
                            }
                        }
                    }
                    cleanPasteAddMenu
                }
            }
        }
    }

    private func cleanPasteAppRow(_ name: String) -> some View {
        HStack(spacing: Space.md) {
            Text(name).font(.system(size: TypeScale.body)).lineLimit(1)
            Spacer(minLength: Space.sm)
            IconButton(systemName: "xmark.circle.fill", label: "Stop cleaning text from \(name)") {
                manager.cleanPasteApps.remove(name)
                manager.save()
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Color.yankSurface, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.yankHairline, lineWidth: Hairline.width))
    }

    private var cleanPasteAddMenu: some View {
        let apps = addableCleanPasteApps
        return VStack(alignment: .leading, spacing: Space.xs) {
            Menu {
                ForEach(apps, id: \.self) { name in
                    Button(name) {
                        manager.cleanPasteApps.insert(name)
                        manager.save()
                    }
                }
            } label: {
                Label("Add App", systemImage: "plus")
                    .font(.system(size: TypeScale.control, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(apps.isEmpty)
            .accessibilityLabel("Add app for clean terminal text")
            if apps.isEmpty {
                Text("No more apps in the current history. Copy something from another app to add it.")
                    .font(.system(size: TypeScale.micro))
                    .foregroundColor(.yankTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
