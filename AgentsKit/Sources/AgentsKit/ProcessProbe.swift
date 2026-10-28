import Darwin

public enum ProcessProbe {
    /// Uses sysctl because kill(pid, 0) is denied inside the App Sandbox.
    /// When the kernel refuses to answer, reports "alive" so the idle timeout decides instead.
    public static func isAlive(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return true }
        return size > 0 && info.kp_proc.p_pid == pid
    }
}
