import Foundation

/// Level values for VoiceOver and the Settings list.
public enum LevelText {
    public static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// An app at its own level has nothing to apply, so it never reads as a problem.
    public static func app(volume: Double, muted: Bool, applied: Bool) -> String {
        let level = percent(volume)
        if volume >= 1 && !muted { return level }
        if !applied {
            return muted ? String(localized: "Not applied, saved as muted at \(level)")
                : String(localized: "Not applied, saved at \(level)")
        }
        return output(volume: volume, muted: muted)
    }

    public static func output(volume: Double, muted: Bool) -> String {
        muted ? String(localized: "Muted, \(percent(volume)) when unmuted") : percent(volume)
    }
}
