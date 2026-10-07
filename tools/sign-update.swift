// Release-only: signs an update archive with the Ed25519 key in $UPDATE_SIGNING_KEY (base64,
// raw 32-byte private key) and writes <file>.sig (base64 signature). Verifies the signature
// against the public key compiled into the app before succeeding, so a key mismatch fails
// the release instead of shipping an update nobody can install.
//
//   UPDATE_SIGNING_KEY=… swift tools/sign-update.swift RustyMacBackup-3.2.0.app.zip <publicKeyBase64>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write("usage: sign-update.swift <file> <publicKeyBase64>\n".data(using: .utf8)!); exit(2) }
guard let secret = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
      let raw = Data(base64Encoded: secret.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write("UPDATE_SIGNING_KEY missing or invalid\n".data(using: .utf8)!); exit(1)
}
let file = URL(fileURLWithPath: args[1])
let data = try Data(contentsOf: file)
let signature = try key.signature(for: data)
guard key.publicKey.rawRepresentation.base64EncodedString() == args[2],
      key.publicKey.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write("signing key does not match the app's public key\n".data(using: .utf8)!); exit(1)
}
try signature.base64EncodedString().write(to: file.appendingPathExtension("sig"), atomically: true, encoding: .utf8)
print("signed \(file.lastPathComponent) (sha256 \(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))")
