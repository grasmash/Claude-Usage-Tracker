import Foundation

/// The only way an HTTP body, response or request, may reach an error's details, the system log or the network
/// logger.
///
/// A server can echo a credential in a response body (an OAuth refresh token in an error description, a session
/// cookie in a challenge page), and a request body can carry one too (a refresh grant). Those sinks are read by people
/// and tools (os_log is %{public}@). So a body is described by its size and its error code only, never by its text. Enforced for every app source file by
/// `ResponseBodyLeakTests` (PR #3 review, 2026-11-07).
enum ResponseBody {
    /// "123 bytes", or "123 bytes, error=invalid_grant" when the body is JSON with an OAuth `error` string or an
    /// API `error.type` that looks like a code (lowercase letters and underscores, at most 40). "no body" for nil.
    static func summary(_ data: Data?) -> String {
        guard let data else { return "no body" }
        guard let code = errorCode(data) else { return "\(data.count) bytes" }
        return "\(data.count) bytes, error=\(code)"
    }

    static func errorCode(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw = (obj["error"] as? String) ?? ((obj["error"] as? [String: Any])?["type"] as? String)
        guard let code = raw, !code.isEmpty, code.count <= 40,
              code.allSatisfy({ ($0 >= "a" && $0 <= "z") || $0 == "_" }) else { return nil }
        return code
    }
}
