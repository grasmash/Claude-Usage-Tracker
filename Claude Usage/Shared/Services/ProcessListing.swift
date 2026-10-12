import Darwin
import Foundation

/// A process listing that spawns nothing: libproc's pid table, each pid's
/// executable path and parent. Used when `ps` cannot be run or returns
/// nothing (2026-10-12: seven hours of "cannot list processes"). It cannot
/// read a process's environment, so `configDir` is always nil and every
/// Claude Code process counts as a holder of the shared login — the
/// refusal-leaning reading `MainLoginSwapPolicy` is built for.
enum ProcessListing {

    static func listViaLibproc() -> [MainLoginSwapPolicy.RunningProcess] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        count += 64   // room for processes born between the two calls
        var pids = [pid_t](repeating: 0, count: Int(count))
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        var out: [MainLoginSwapPolicy.RunningProcess] = []
        out.reserveCapacity(Int(filled))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let capacity = path.count
            path.withUnsafeMutableBufferPointer { _ = $0.baseAddress.map { memset($0, 0, capacity) } }
            let length = proc_pidpath(pid, &path, UInt32(capacity))
            let command: String
            if length > 0 {
                command = String(cString: path)
            } else {
                // No path (a zombie, or not ours): the short name is all we have.
                command = withUnsafePointer(to: &info.pbi_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
                }
            }
            guard !command.isEmpty else { continue }
            out.append(MainLoginSwapPolicy.RunningProcess(pid: pid, ppid: Int32(info.pbi_ppid), command: command, configDir: nil, argvKnown: false))
        }
        return out
    }

    /// When `pid` started, or nil when there is no such process (or it cannot
    /// be read). With the pid, it identifies a process across pid reuse.
    static func startTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
