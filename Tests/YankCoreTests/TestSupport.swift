import Foundation
@testable import YankCore

/// Deterministic clip id from a small integer, shared across suites: a fixed `n`
/// always maps to the same UUID, so merge/sort/reconcile assertions stay stable.
func clipID(_ n: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
}
