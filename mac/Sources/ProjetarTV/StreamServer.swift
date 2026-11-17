import CryptoKit
import Foundation
import Network

/// Conexão: o Mac manda "AVW1" + desafio de 16 bytes; a TV responde HMAC(S, "airview-hello" + desafio) em 3 s,
/// provando que recebeu a chave de sessão S pelo comando CONNECT. Depois, cada mensagem vai cifrada (StreamCipher).
/// Mensagem (big-endian, antes de cifrar): tipo (1 byte) | tamanho do payload (4 bytes) | PTS em µs (8 bytes) | payload.
enum MessageType: UInt8 {
    /// largura u16 | altura u16 | tamanho SPS u16 | SPS | tamanho PPS u16 | PPS
    case videoConfig = 1
    /// é quadro-chave u8 | H.264 Annex B
    case videoFrame = 2
    /// taxa de amostragem u32 | canais u8
    case audioConfig = 3
    /// PCM 16-bit intercalado little-endian
    case audioData = 4
    /// nome do Mac em UTF-8, enviado ao conectar (a TV mostra "Conectando com <nome>")
    case deviceName = 5
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

private func message(_ type: MessageType, pts: Int64 = 0, payload: Data) -> Data {
    var data = Data(capacity: 13 + payload.count)
    data.append(type.rawValue)
    data.appendBigEndian(UInt32(payload.count))
    data.appendBigEndian(pts)
    data.append(payload)
    return data
}

/// Servidor TCP da sessão (não é anunciado na rede: a TV recebe o endereço pelo comando CONNECT).
final class StreamServer {
    /// Chamado quando alguma TV precisa de um quadro-chave (nova conexão ou recuperação de atraso).
    var onKeyframeNeeded: (() -> Void)?
    var onClientsChanged: ((Int) -> Void)?
    /// O servidor não conseguiu abrir a porta.
    var onFailure: ((String) -> Void)?

    private final class Client {
        let connection: NWConnection
        let challenge = AirViewCrypto.randomBytes(16)
        var cipher: StreamCipher?
        /// Autenticada: respondeu o desafio com a chave da sessão.
        var ready = false
        var pendingBytes = 0
        var waitingKeyframe = true
        var sentAudioConfig: Data?

        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// Acima disso de dados não confirmados pela rede, descartamos vídeo até a TV alcançar (~0,5 s a 15 Mbps).
    private let videoBacklogLimit = 1_000_000
    private let audioBacklogLimit = 3_000_000

    private let listener: NWListener
    private let queue = DispatchQueue(label: "server", qos: .userInteractive)
    private var clients: [ObjectIdentifier: Client] = [:]
    private var videoConfig: Data?
    private var audioConfig: Data?
    private var audioFormat: (Int, Int)?
    private var lastKeyframeRequest = Date.distantPast

    private let serviceName: String
    private let sessionKey: SymmetricKey
    /// Conexões que ainda não se autenticaram; acima disso, recusa (contra enxurrada de conexões).
    private let maxPendingClients = 4

    /// `sessionKey` é a chave entregue à TV no CONNECT; só quem a conhece recebe a transmissão.
    init(port: UInt16, serviceName: String, sessionKey: SymmetricKey) throws {
        self.serviceName = serviceName
        self.sessionKey = sessionKey
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true // permite religar na mesma porta logo após desconectar
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                let message = "Servidor falhou: \(error). A porta \(port) já está em uso?"
                print(message)
                self?.onFailure?(message)
            }
        }
        listener.start(queue: queue)
    }

    /// Encerra o servidor: para de anunciar e derruba as conexões.
    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
        }
    }

    func setVideoParameterSets(width: Int, height: Int, sps: Data, pps: Data) {
        var payload = Data()
        payload.appendBigEndian(UInt16(width))
        payload.appendBigEndian(UInt16(height))
        payload.appendBigEndian(UInt16(sps.count))
        payload.append(sps)
        payload.appendBigEndian(UInt16(pps.count))
        payload.append(pps)
        let config = message(.videoConfig, payload: payload)
        queue.async { self.videoConfig = config }
    }

    func sendVideoFrame(_ annexB: Data, keyframe: Bool, pts: Int64) {
        var payload = Data([keyframe ? 1 : 0])
        payload.append(annexB)
        let frame = message(.videoFrame, pts: pts, payload: payload)

        queue.async {
            var needsKeyframe = false
            for client in self.clients.values where client.ready {
                if client.pendingBytes >= self.videoBacklogLimit {
                    // Rede não está dando conta: pula quadros e recomeça do próximo quadro-chave.
                    client.waitingKeyframe = true
                    continue
                }
                if client.waitingKeyframe && !keyframe {
                    needsKeyframe = true
                    continue
                }
                if keyframe, let config = self.videoConfig { self.send(config, to: client) }
                client.waitingKeyframe = false
                self.send(frame, to: client)
            }
            if needsKeyframe { self.requestKeyframe(throttled: true) }
        }
    }

    func sendAudio(_ chunk: AudioPCM.Chunk) {
        let data = message(.audioData, pts: chunk.pts, payload: chunk.data)
        queue.async {
            if self.audioFormat == nil || self.audioFormat! != (chunk.sampleRate, chunk.channels) {
                var payload = Data()
                payload.appendBigEndian(UInt32(chunk.sampleRate))
                payload.append(UInt8(chunk.channels))
                self.audioFormat = (chunk.sampleRate, chunk.channels)
                self.audioConfig = message(.audioConfig, payload: payload)
            }
            guard let config = self.audioConfig else { return }
            for client in self.clients.values where client.ready && client.pendingBytes < self.audioBacklogLimit {
                if client.sentAudioConfig != config {
                    self.send(config, to: client)
                    client.sentAudioConfig = config
                }
                self.send(data, to: client)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.values.filter({ !$0.ready }).count < maxPendingClients else {
            connection.cancel()
            return
        }
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        clients[id] = client

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var hello = Data("AVW1".utf8)
                hello.append(client.challenge)
                connection.send(content: hello, completion: .contentProcessed { _ in })
                self.authenticate(client, id: id)
            case .failed, .cancelled:
                if let removed = self.clients.removeValue(forKey: id), removed.ready {
                    print("TV desconectada: \(connection.endpoint)")
                    self.onClientsChanged?(self.clients.values.filter(\.ready).count)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Quem não se autentica em 3 s é derrubado.
        queue.asyncAfter(deadline: .now() + 3) {
            if !client.ready { connection.cancel() }
        }
    }

    private func authenticate(_ client: Client, id: ObjectIdentifier) {
        client.connection.receive(minimumIncompleteLength: 32, maximumLength: 32) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 32, error == nil,
                  AirViewCrypto.constantTimeEquals(data, AirViewCrypto.hmac(self.sessionKey, "airview-hello", client.challenge))
            else {
                client.connection.cancel()
                return
            }
            client.cipher = StreamCipher(sessionKey: self.sessionKey, challenge: client.challenge)
            client.ready = true
            self.send(message(.deviceName, payload: Data(self.serviceName.utf8)), to: client)
            print("TV conectada: \(client.connection.endpoint)")
            self.onClientsChanged?(self.clients.values.filter(\.ready).count)
            self.requestKeyframe(throttled: false)
            self.receiveUntilClosed(client.connection)
        }
    }

    /// Depois de autenticada a TV não manda dados; só lemos para perceber quando ela fecha a conexão.
    private func receiveUntilClosed(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil || data != nil {
                connection.cancel()
            } else {
                self?.receiveUntilClosed(connection)
            }
        }
    }

    private func send(_ message: Data, to client: Client) {
        guard let cipher = client.cipher else { return }
        let data = cipher.seal(message)
        client.pendingBytes += data.count
        client.connection.send(content: data, completion: .contentProcessed { error in
            client.pendingBytes -= data.count
            if error != nil { client.connection.cancel() }
        })
    }

    private func requestKeyframe(throttled: Bool) {
        if throttled && Date().timeIntervalSince(lastKeyframeRequest) < 0.5 { return }
        lastKeyframeRequest = Date()
        onKeyframeNeeded?()
    }
}
