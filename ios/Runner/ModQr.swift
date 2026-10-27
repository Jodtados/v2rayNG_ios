import CryptoKit
import Flutter

/// AES-256-GCM opening for the encrypted VNG1 QR profile transfer.
///
/// The Dart side (`ModQrTransfer`) validates the build-time secret, derives
/// the key (SHA-256 over the decoded Base32 secret) and strips the token
/// prefix; CryptoKit only opens the sealed box here: nonce = first 12 bytes,
/// ciphertext and 128-bit tag = the rest. A failed GCM tag surfaces as a
/// PlatformException so the Dart layer rejects the whole token without
/// importing anything.
final class ModQrChannel {
    func register(on messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "onexray/mod_qr", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "decrypt" else {
                result(FlutterError(code: "unimplemented", message: call.method, details: nil))
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let dataBase64 = args["data"] as? String,
                  let keyBase64 = args["key"] as? String,
                  let data = Data(base64Encoded: dataBase64),
                  let keyData = Data(base64Encoded: keyBase64),
                  data.count > 28
            else {
                result(FlutterError(code: "bad_arguments", message: nil, details: nil))
                return
            }
            do {
                let sealed = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: data.prefix(12)),
                    ciphertext: data.dropFirst(12).dropLast(16),
                    tag: data.suffix(16)
                )
                // CryptoKit takes the sealed box first, key second; no AAD —
                // the Android exporter seals with authenticatedData empty.
                let plain = try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
                guard let text = String(data: plain, encoding: .utf8) else {
                    result(FlutterError(code: "decrypt_failed", message: "not utf-8", details: nil))
                    return
                }
                result(text)
            } catch {
                result(FlutterError(code: "decrypt_failed", message: nil, details: nil))
            }
        }
    }
}
