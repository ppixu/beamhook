import Foundation

public enum MediaKeyDecoder {
    /// NSSystemDefined subtype carrying aux/media-key button events.
    public static let systemDefinedMediaKeysSubtype = 8

    public static func decode(subtype: Int, data1: Int) -> MediaKeyEvent? {
        guard subtype == systemDefinedMediaKeysSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF0000) >> 16
        guard let key = MediaKey(keyCode: keyCode) else { return nil }
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isDown = (keyState == 0x0A)
        let isRepeat = (keyFlags & 0x1) == 0x1
        return MediaKeyEvent(key: key, isDown: isDown, isRepeat: isRepeat)
    }
}
