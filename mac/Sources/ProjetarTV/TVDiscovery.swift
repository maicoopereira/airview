import CryptoKit
import Foundation
import Network

/// TV com o app AirView anunciada na rede (o ControlService da TV anuncia `_projetartv-tv._tcp`).
struct DiscoveredTV: Equatable {
    let name: String
    let endpoint: NWEndpoint
}

/// Lista as TVs da rede, atualizando conforme ligam e desligam.
final class TVBrowser {
    var onChange: (() -> Void)?
    private(set) var tvs: [DiscoveredTV] = []
    /// Por que a busca não funciona (ex.: permissão de Rede Local negada), para mostrar no menu.
    private(set) var problem: String?
    private var browser: NWBrowser?

    func start() {
        let browser = NWBrowser(for: .bonjour(type: "_projetartv-tv._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.tvs = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredTV(name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            self?.onChange?()
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error), .failed(let error):
                self?.problem = "Busca de TVs bloqueada (\(error)). Libere a Rede Local para o AirView em Ajustes do " +
                    "Sistema → Privacidade e Segurança → Rede Local."
            case .ready:
                self?.problem = nil
            default:
                break
            }
            self?.onChange?()
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}

/// Conexão de controle com a TV: linhas de texto. A TV abre com "AIRVIEW 1 <desafio>" e cada comando sensível
/// leva HMAC(chave de pareamento, desafio + comando), então só Macs pareados mandam e nada pode ser repetido.
private final class ControlLink {
    private let connection: NWConnection
    private var buffer = Data()
    private let queue = DispatchQueue(label: "tv.control")
    private(set) var challenge = Data()

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    /// Conecta e lê o desafio da TV.
    func open(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        var done = false
        let finish: (Bool) -> Void = { ok in
            guard !done else { return }
            done = true
            completion(ok)
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readLine(timeout: timeout) { line in
                    let parts = line?.split(separator: " ") ?? []
                    guard parts.count == 3, parts[0] == "AIRVIEW", parts[1] == "1",
                          let nonce = Data(base64Encoded: String(parts[2])), nonce.count == 16 else { return finish(false) }
                    self?.challenge = nonce
                    finish(true)
                }
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    func send(_ line: String) {
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    /// Lê uma linha (máx. 4 KB) ou nil em erro/tempo esgotado.
    func readLine(timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        var done = false
        let finish: (String?) -> Void = { line in
            guard !done else { return }
            done = true
            completion(line)
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        func receive() {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[..<newline], encoding: .utf8)
                buffer.removeSubrange(...newline)
                return finish(line)
            }
            guard buffer.count < 4096 else { return finish(nil) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self, let data, !data.isEmpty, error == nil else { return finish(nil) }
                self.buffer.append(data)
                if isComplete && self.buffer.firstIndex(of: 0x0A) == nil { return finish(nil) }
                receive()
            }
        }
        queue.async { receive() }
    }

    func close() { connection.cancel() }
}

enum TVControlError: LocalizedError {
    case unreachable, refused, notPaired

    var errorDescription: String? {
        switch self {
        case .unreachable: return "A TV não respondeu. Confira se ela está ligada e na mesma rede."
        case .refused: return "A TV recusou."
        case .notPaired: return "Esta TV não reconhece mais este Mac. Pareie de novo."
        }
    }
}

enum TVControl {
    /// Comando assinado: "<comando> <hmac>", com HMAC(K, desafio + comando).
    private static func signed(_ command: String, key: SymmetricKey, challenge: Data) -> String {
        command + " " + AirViewCrypto.hmac(key, challenge, Data(command.utf8)).base64EncodedString()
    }

    /// Pede à TV para abrir a projeção e conectar neste Mac, entregando a chave da sessão cifrada.
    static func connect(_ tv: DiscoveredTV, key: SymmetricKey, port: UInt16, macName: String, sessionKey: SymmetricKey,
                        completion: @escaping (Result<Void, TVControlError>) -> Void) {
        let sealed = try! AES.GCM.seal(sessionKey.withUnsafeBytes { Data($0) }, using: key).combined!
        let command = "CONNECT \(PairingStore.macID) \(port) \(Data(macName.utf8).base64EncodedString()) " +
            sealed.base64EncodedString()
        run(command, on: tv, key: key, completion: completion)
    }

    static func disconnect(_ tv: DiscoveredTV, key: SymmetricKey) {
        run("DISCONNECT \(PairingStore.macID)", on: tv, key: key) { _ in }
    }

    private static func run(_ command: String, on tv: DiscoveredTV, key: SymmetricKey,
                            completion: @escaping (Result<Void, TVControlError>) -> Void) {
        let link = ControlLink(endpoint: tv.endpoint)
        link.open(timeout: 5) { ok in
            guard ok else {
                link.close()
                return DispatchQueue.main.async { completion(.failure(.unreachable)) }
            }
            link.send(signed(command, key: key, challenge: link.challenge))
            link.readLine(timeout: 5) { reply in
                link.close()
                let result: Result<Void, TVControlError>
                switch reply {
                case let r? where r.hasPrefix("OK"): result = .success(())
                case let r? where r.contains("pareado"): result = .failure(.notPaired)
                case .some: result = .failure(.refused)
                case nil: result = .failure(.unreachable)
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Pareamento: troca de chaves ECDH; `showCode` recebe o código para mostrar enquanto a TV pede OK no controle.
    static func pair(_ tv: DiscoveredTV, macName: String, showCode: @escaping (String) -> Void,
                     completion: @escaping (Result<SymmetricKey, TVControlError>) -> Void) {
        let link = ControlLink(endpoint: tv.endpoint)
        let finish: (Result<SymmetricKey, TVControlError>) -> Void = { result in
            link.close()
            DispatchQueue.main.async { completion(result) }
        }
        link.open(timeout: 5) { ok in
            guard ok else { return finish(.failure(.unreachable)) }
            let privateKey = P256.KeyAgreement.PrivateKey()
            link.send("PAIR \(PairingStore.macID) \(Data(macName.utf8).base64EncodedString()) " +
                      privateKey.publicKey.derRepresentation.base64EncodedString())
            link.readLine(timeout: 5) { line in
                let parts = line?.split(separator: " ") ?? []
                guard parts.count == 2, parts[0] == "PUB", let der = Data(base64Encoded: String(parts[1])),
                      let tvKey = try? P256.KeyAgreement.PublicKey(derRepresentation: der),
                      let shared = try? privateKey.sharedSecretFromKeyAgreement(with: tvKey)
                else { return finish(.failure(.refused)) }
                let key = AirViewCrypto.pairingKey(shared: shared)
                DispatchQueue.main.async { showCode(AirViewCrypto.verificationCode(key)) }
                link.send("CONFIRM " + AirViewCrypto.hmac(key, "airview-confirm").base64EncodedString())
                // Espera o usuário aceitar na TV (OK no controle).
                link.readLine(timeout: 90) { reply in
                    let parts = reply?.split(separator: " ") ?? []
                    guard parts.count == 2, parts[0] == "OK", let proof = Data(base64Encoded: String(parts[1])),
                          AirViewCrypto.constantTimeEquals(proof, AirViewCrypto.hmac(key, "airview-tv-ok"))
                    else { return finish(.failure(.refused)) }
                    finish(.success(key))
                }
            }
        }
    }
}
