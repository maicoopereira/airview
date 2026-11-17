import CryptoKit
import Foundation
import Security

/// Criptografia do AirView. O mesmo esquema está em android/.../Crypto.java — mudanças precisam ir nos dois.
///
/// Pareamento (uma vez por TV): ECDH P-256 → HKDF-SHA256 → chave K de 32 bytes, guardada no Keychain.
///   A TV mostra um código de 6 dígitos derivado de K e o usuário aceita com OK no controle; um intermediário
///   na rede geraria códigos diferentes no Mac e na TV.
/// Comandos (CONNECT/DISCONNECT): HMAC(K, desafio da TV + comando) — só Macs pareados, sem repetição.
/// Transmissão: chave de sessão S aleatória, entregue cifrada com K; cada conexão deriva a própria chave
///   de S + desafio do Mac e cifra cada mensagem com AES-256-GCM (nonce = contador).
enum AirViewCrypto {
    static func hmac(_ key: SymmetricKey, _ parts: Data...) -> Data {
        var mac = HMAC<SHA256>(key: key)
        for part in parts { mac.update(data: part) }
        return Data(mac.finalize())
    }

    static func hmac(_ key: SymmetricKey, _ label: String, _ parts: Data...) -> Data {
        var mac = HMAC<SHA256>(key: key)
        mac.update(data: Data(label.utf8))
        for part in parts { mac.update(data: part) }
        return Data(mac.finalize())
    }

    static func pairingKey(shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("airview-pair-v1".utf8),
                                       sharedInfo: Data("airview-key".utf8), outputByteCount: 32)
    }

    /// Código de verificação mostrado no Mac e na TV ("123 456").
    static func verificationCode(_ key: SymmetricKey) -> String {
        let digest = hmac(key, "airview-sas")
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return digits.prefix(3) + " " + digits.suffix(3)
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Cifra as mensagens de uma conexão de transmissão (um contador de nonce por conexão).
final class StreamCipher {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(sessionKey: SymmetricKey, challenge: Data) {
        key = SymmetricKey(data: AirViewCrypto.hmac(sessionKey, "airview-stream", challenge))
    }

    /// Quadro na rede: tamanho u32 (big-endian) | texto cifrado | tag de 16 bytes.
    func seal(_ message: Data) -> Data {
        var nonce = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { nonce.append(contentsOf: $0) }
        counter += 1
        let box = try! AES.GCM.seal(message, using: key, nonce: try! AES.GCM.Nonce(data: nonce))
        var frame = Data(capacity: 4 + message.count + 16)
        withUnsafeBytes(of: UInt32(message.count + 16).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }
}

/// Identidade deste Mac e chaves das TVs pareadas (no Keychain do usuário).
enum PairingStore {
    private static let service = "br.com.maico.airview.pairing"

    static var macID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "macID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "macID")
        return id
    }

    static func key(forTV name: String) -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    static func save(_ key: SymmetricKey, forTV name: String) {
        forget(tv: name)
        let data = key.withUnsafeBytes { Data($0) }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: name, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func forget(tv name: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        SecItemDelete(query as CFDictionary)
    }

    static func forgetAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}
