import CryptoKit
import Flutter
import Security

/// Pinned HTTPS transport for the mod management server.
///
/// Mirrors the Android `MgmtApi` trust model: the leaf certificate's
/// SubjectPublicKeyInfo DER must equal the pinned SPKI bytes supplied by the
/// Dart layer (base64, MOD_MGMT_SPKI_PIN dart-define — the same value the
/// Android build bakes into BuildConfig C3) and nothing else is trusted, so
/// an active man-in-the-middle — provider included — cannot read or forge
/// heartbeats and console commands. The server has no domain, so no hostname
/// verification applies.
///
/// Apple's `SecKeyCopyExternalRepresentation` returns raw key bytes (X9.63
/// point for EC, PKCS#1 for RSA), so the SPKI DER is rebuilt from the key
/// attributes before comparing; see `SpkiDer.fromKey`.
final class ModMgmtChannel {
    func register(on messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "onexray/mod_mgmt", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            guard call.method == "request" else {
                result(FlutterError(code: "unimplemented", message: call.method, details: nil))
                return
            }
            guard let args = call.arguments as? [String: Any],
                  let urlText = args["url"] as? String,
                  let url = URL(string: urlText)
            else {
                result(FlutterError(code: "bad_arguments", message: nil, details: nil))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = args["method"] as? String ?? "GET"
            if let headers = args["headers"] as? [String: String] {
                for (name, value) in headers {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
            if let body = args["body"] as? String {
                request.httpBody = Data(body.utf8)
            }
            let pinB64 = args["pin"] as? String ?? ""
            PinnedRequest(pinB64: pinB64).run(request) { response in
                DispatchQueue.main.async { result(response) }
            }
        }
    }
}

/// One request with its own ephemeral session so the pin rides along as
/// delegate state; mgmt traffic is a few requests per minute, so per-request
/// session setup is irrelevant next to the handshake itself.
private final class PinnedRequest: NSObject, URLSessionDataDelegate {
    private let pin: Data?
    private var completion: ((Any?) -> Void)?
    private var session: URLSession?

    init(pinB64: String) {
        self.pin = Data(base64Encoded: pinB64)
        super.init()
    }

    func run(_ request: URLRequest, completion: @escaping (Any?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        self.completion = completion
        session.dataTask(with: request) { data, response, error in
            self.finish {
                if let error {
                    return FlutterError(
                        code: "network_error",
                        message: error.localizedDescription,
                        details: nil,
                    )
                }
                guard let http = response as? HTTPURLResponse else {
                    return FlutterError(code: "network_error", message: "no response", details: nil)
                }
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return ["status": http.statusCode, "body": text]
            }
        }.resume()
    }

    private func finish(_ build: () -> Any?) {
        session?.invalidateAndCancel()
        session = nil
        let built = build()
        completion?(built)
        completion = nil
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // An absent or undecodable pin fails closed for https requests.
        guard let pin, !pin.isEmpty,
            let spki = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?
                .first
                .flatMap(SecCertificateCopyKey)
                .flatMap({ SpkiDer.fromKey($0) }),
            spki == pin
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, URLCredential(trust: trust))
    }
}

/// Rebuilds the SubjectPublicKeyInfo DER that Android pins
/// (`certificate.publicKey.encoded`) from Apple's raw key export.
enum SpkiDer {
    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes = [UInt8]()
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func wrap(tag: UInt8, contents: [UInt8]) -> [UInt8] {
        [tag] + derLength(contents.count) + contents
    }

    /// `parameters` holds a curve OID for EC or the empty DER NULL for RSA
    /// (`05 00`, encoded explicitly by the caller).
    private static func algorithmIdentifier(oid: [UInt8], parameters: [UInt8]) -> [UInt8] {
        wrap(tag: 0x30, contents: wrap(tag: 0x06, contents: oid) + parameters)
    }

    private static func bitString(_ raw: [UInt8]) -> [UInt8] {
        wrap(tag: 0x03, contents: [0x00] + raw)
    }

    // Curve OIDs per RFC 5480: prime256v1, secp384r1, secp521r1.
    private static let curveOids: [Int: [UInt8]] = [
        256: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07],
        384: [0x2B, 0x81, 0x04, 0x00, 0x22],
        521: [0x2B, 0x81, 0x04, 0x00, 0x23],
    ]

    static func fromKey(_ key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        let keyType = attributes?[kSecAttrKeyType] as? String
        let keySize = attributes?[kSecAttrKeySizeInBits] as? Int ?? 0
        let rawBytes = [UInt8](raw)

        let algorithm: [UInt8]
        let publicKey: [UInt8]
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            guard let curve = curveOids[keySize] else { return nil }
            // EC keys export as the raw uncompressed point || X || Y.
            algorithm = algorithmIdentifier(
                oid: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01],
                parameters: wrap(tag: 0x06, contents: curve),
            )
            publicKey = bitString(rawBytes)
        } else if keyType == (kSecAttrKeyTypeRSA as String) {
            // RSA keys export as PKCS#1; SPKI wraps it in the rsaEncryption
            // AlgorithmIdentifier with the NULL parameter (05 00).
            algorithm = algorithmIdentifier(
                oid: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01],
                parameters: [0x05, 0x00],
            )
            publicKey = bitString(rawBytes)
        } else {
            return nil
        }
        return Data(wrap(tag: 0x30, contents: algorithm + publicKey))
    }
}
