import CryptoKit
import Foundation
import Darwin
let arguments = CommandLine.arguments
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
let signature = Data(base64Encoded: arguments[2])!
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: arguments[3])!)
guard key.isValidSignature(signature, for: archive) else { FileHandle.standardError.write(Data("Update signature verification failed\n".utf8)); exit(1) }
print("Update archive signature verified.")
