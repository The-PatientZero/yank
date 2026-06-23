/// Pure outside-click dismissal rules for the history surface. AppKit supplies the
/// live window events; this type keeps the product behavior explicit and testable.
struct HistoryDismissalPolicy: Equatable {
    var keepsHistoryWindowOpen: Bool
    var settingsScreenIsActive: Bool

    var shouldDismissOnOutsideClick: Bool {
        !keepsHistoryWindowOpen && !settingsScreenIsActive
    }
}
