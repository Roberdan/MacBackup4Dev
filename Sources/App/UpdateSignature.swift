import CryptoKit
import Foundation

/// Authenticity of an update, independent of Apple code signing (releases are ad-hoc signed,
/// which any build passes). Every `.app.zip` on GitHub ships with a `.sig`: the Ed25519
/// signature of the archive made by the release workflow with a private key that exists only
/// as a GitHub Actions secret (and a backup in the maintainer's Keychain). The app accepts an
/// update only if that signature verifies against the public key below — the same model as
/// Sparkle's EdDSA signatures.
enum UpdateSignature {
    /// Public half of the release signing key (Curve25519 / Ed25519, raw, base64).
    static let publicKeyBase64 = "HSZSUaA7dyjpk9M7YsKxZR3eyb8Td9X40i1MTzcCsZg="

    static func verify(_ data: Data, signatureBase64: String,
                       publicKeyBase64: String = UpdateSignature.publicKeyBase64) -> Bool {
        let cleaned = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: cleaned),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
