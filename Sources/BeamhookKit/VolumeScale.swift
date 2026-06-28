import Foundation

public enum VolumeScaleKind: Codable, Equatable {
    case integer(max: Int)   // raw value is 0...max
    case unitFloat           // raw value is 0.0...1.0
    case none                // app exposes no scriptable volume
}

public enum VolumeScale {
    public static func toPercent(raw: Double, kind: VolumeScaleKind) -> Int? {
        switch kind {
        case .none:
            return nil
        case .integer(let max):
            guard max > 0 else { return nil }
            return clampPercent(Int((raw / Double(max) * 100).rounded()))
        case .unitFloat:
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
            return String(Int((p / 100 * Double(max)).rounded()))
        case .unitFloat:
            return String(format: "%.3f", p / 100)
        }
    }

    static func clampPercent(_ v: Int) -> Int { min(100, max(0, v)) }
}
