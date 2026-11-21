import AppKit
import Darwin

enum ProcessTree {
    /// The app a process runs under (the terminal or editor hosting Claude
    /// Code), found by walking up its parents to the first one inside a .app.
    static func hostAppPath(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(current, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
            }
            guard let parent = parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    /// The bundle id of that app, to bring it to the front.
    static func hostBundleID(of pid: Int32) -> String? {
        hostAppPath(of: pid).flatMap { Bundle(path: $0)?.bundleIdentifier }
    }

    /// The name that app shows, e.g. "Ghostty".
    static func appName(at app: String) -> String {
        let bundle = Bundle(path: app)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Works for processes of any user (proc_pidinfo can't read root's, such as /usr/bin/login).
    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The processes a process started, e.g. the shells an agent runs commands in.
    static func children(of pid: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    /// A process's command line, its arguments joined by spaces, as `ps` shows it.
    static func arguments(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // argc, the executable path, padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var fields = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true).dropFirst()
        fields = fields.prefix(Int(argc))
        return fields.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
    }

    /// Hooks may run under an intermediate shell; walk up to the agent's process
    /// (claude, copilot or agy) so its exit can be noticed. Falls back to the pid given.
    static func agentAncestor(of pid: Int32) -> Int32 {
        var current = pid
        for _ in 0..<4 where current > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let lower = name.lowercased()
            if lower.contains("claude") || lower.contains("copilot") || lower == "agy" || lower.contains("antigravity") {
                return current
            }
            current = Int32(info.pbi_ppid)
        }
        return pid
    }
}
