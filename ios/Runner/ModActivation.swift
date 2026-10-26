import Flutter
import UIKit

/// Keychain-backed storage for the one-time mod activation flag.
///
/// The keychain survives app reinstalls, keeping activation one-time across
/// deletes and fresh sideloads. Mirrors the Dart ModActivationService over
/// the `onexray/mod` method channel.
final class ModActivationChannel {
    private let service = "onexray.mod"
    private let account = "activated"

    func register(on messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "onexray/mod", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "unavailable", message: "store released", details: nil))
                return
            }
            switch call.method {
            case "isActivated":
                result(self.isActivated())
            case "activate":
                self.activate()
                result(nil)
            default:
                result(FlutterError(code: "unimplemented", message: call.method, details: nil))
            }
        }
    }

    private func activationQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func isActivated() -> Bool {
        var query = activationQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    private func activate() {
        var query = activationQuery()
        let update: [String: Any] = [kSecValueData as String: Data("1".utf8)]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
            return
        }
        query[kSecValueData as String] = Data("1".utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}
