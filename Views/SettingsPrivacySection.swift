import SwiftUI

// Privacy card section — capture exclusions, Spotlight indexing, and on-device AI tagging.
extension SettingsView {
    var privacySection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            CaptureExclusionSection(settings: manager)
            Divider().overlay(Color.yankHairline)
            toggleRow(
                "Find clips in Spotlight",
                "Lets macOS search your clips system-wide. Off by default — clip history can contain passwords and tokens.",
                isOn: Binding(
                    get: { manager.spotlightIndexingEnabled },
                    set: { manager.setSpotlightIndexingEnabled($0) }))
            if FoundationModelEnricher.isAvailable {
                Divider().overlay(Color.yankHairline)
                toggleRow(
                    "Suggest tags with Apple Intelligence",
                    "Adds on-device topic tags to new text clips — private, never leaves your Mac. Off by default.",
                    isOn: Binding(
                        get: { manager.aiTaggingEnabled },
                        set: { manager.setAITaggingEnabled($0) }))
            }
        }
    }
}
