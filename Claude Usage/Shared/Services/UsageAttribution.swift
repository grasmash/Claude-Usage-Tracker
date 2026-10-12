import Foundation

/// Which profile a finished usage fetch may be stored under.
enum UsageAttribution {
    /// The profile the fetch was made FOR, and only if it is still the active
    /// one; nil when the active profile changed while the request was in
    /// flight (the reading is then discarded — it must never be filed under the
    /// profile that happens to be active at completion time).
    static func saveTarget(fetchedFor: UUID?, activeNow: UUID?) -> UUID? {
        guard let fetchedFor, fetchedFor == activeNow else { return nil }
        return fetchedFor
    }
}
