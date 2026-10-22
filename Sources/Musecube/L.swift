import Foundation

/// Localized UI string. Keys are the Chinese source text; en.lproj supplies English.
@inline(__always) func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
