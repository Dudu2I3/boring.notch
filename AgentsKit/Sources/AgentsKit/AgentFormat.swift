import Foundation

public enum AgentFormat {
    /// "<1 мин", "14 мин", "2 ч".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "<1 мин" }
        if minutes < 60 { return "\(minutes) мин" }
        return "\(minutes / 60) ч"
    }
}
