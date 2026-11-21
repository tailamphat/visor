import Foundation

/// Reading values out of `JSONSerialization` objects.
extension Dictionary where Key == String, Value == Any {
    /// A number as an Int; 0 when it's missing or not a number.
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }
}
