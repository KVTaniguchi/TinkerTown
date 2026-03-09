import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public func sha256Hex(_ input: String) -> String {
    guard let data = input.data(using: .utf8) else { return "" }
    #if canImport(CryptoKit)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    return String(data.count)
    #endif
}
