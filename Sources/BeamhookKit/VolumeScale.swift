import Foundation

public enum VolumeScaleKind: Codable, Equatable, Sendable {
    case integer(max: Int)   // raw value is 0...max
    case unitFloat           // raw value is 0.0...1.0
    case none                // app exposes no scriptable volume
}

public enum VolumeScale {
    public static func toPercent(raw: Double, kind: VolumeScaleKind) -> Int? {
        guard raw.isFinite else { return nil }
        switch kind {
        case .none:
            return nil
        case .integer(let max):
            guard max > 0 else { return nil }
            if raw <= 0 { return 0 }
            if raw >= Double(max) { return 100 }
            return clampPercent(Int((raw / Double(max) * 100).rounded()))
        case .unitFloat:
            if raw <= 0 { return 0 }
            if raw >= 1 { return 100 }
            return clampPercent(Int((raw * 100).rounded()))
        }
    }

    public static func rawString(fromPercent percent: Int, kind: VolumeScaleKind) -> String? {
        let p = Double(clampPercent(percent))
        switch kind {
        case .none:
            return nil
        case .integer(let max):
            guard max > 0 else { return nil }
            // Scale without converting an arbitrary `max` through Double. At
            // Int.max, Double rounds up to 2^63 and converting it back traps.
            let clamped = clampPercent(percent)
            let whole = (max / 100) * clamped
            let roundedRemainder = ((max % 100) * clamped + 50) / 100
            return String(whole + roundedRemainder)
        case .unitFloat:
            return String(format: "%.3f", p / 100)
        }
    }

    static func clampPercent(_ v: Int) -> Int { min(100, max(0, v)) }
}
