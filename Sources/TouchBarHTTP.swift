import Foundation
import Network

struct TouchBarRequest { let method: String; let uri: String; let headers: [(String, String)]; let body: Data }
struct TouchBarResponse {
    let status: Int; let contentType: String; let body: Data
    init(status: Int, contentType: String = "application/json", body: Data) { self.status = status; self.contentType = contentType; self.body = body }
}
final class TouchBarHTTPServer {
    private let queue = DispatchQueue(label: "TouchBar.HTTP")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var running = false
    func start(handler: @escaping (TouchBarRequest, @escaping (TouchBarResponse) -> Void) -> Void) throws -> Int {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Int, Error>?
        listener.stateUpdateHandler = { state in
            lock.lock(); defer { lock.unlock() }
            guard result == nil else { return }
            switch state {
            case .ready: result = .success(Int(listener.port!.rawValue)); ready.signal()
            case .failed(let error): result = .failure(error); ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.running, self.clients.count < 16 else { connection.cancel(); return }
            let id = UUID(); self.clients[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.clients.removeValue(forKey: id) }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in connection?.cancel(); self?.clients.removeValue(forKey: id) }
            TouchBarHTTPSession(connection: connection) { request, respond in
                handler(request) { response in self.queue.async { respond(response) } }
            }.read()
        }
        self.listener = listener; running = true; listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { stop(); throw NSError(domain: "TouchBarHTTP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Listener startup timed out"]) }
        lock.lock(); let outcome = result!; lock.unlock()
        return try outcome.get()
    }
    func stop() {
        queue.sync { running = false; listener?.cancel(); listener = nil; clients.values.forEach { $0.cancel() }; clients.removeAll() }
    }
    deinit { listener?.cancel() }
}
private final class TouchBarHTTPSession {
    private let connection: NWConnection
    private let handler: (TouchBarRequest, @escaping (TouchBarResponse) -> Void) -> Void
    private var buffer = Data()
    private var headerEnd: Int?
    private var bodyLength = 0
    private var method = "", uri = ""
    private var headers: [(String, String)] = []
    private var finished = false
    init(connection: NWConnection, handler: @escaping (TouchBarRequest, @escaping (TouchBarResponse) -> Void) -> Void) { self.connection = connection; self.handler = handler }
    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            guard !finished else { return }
            if let data { buffer.append(data) }
            if headerEnd == nil {
                if let boundary = buffer.range(of: Data([13, 10, 13, 10])) {
                    guard boundary.upperBound <= 8192 else { reject(431); return }
                    headerEnd = boundary.upperBound
                    guard parseHead(Data(buffer[..<boundary.lowerBound])) else { return }
                } else if buffer.count > 8192 { reject(431); return }
            }
            if let end = headerEnd, buffer.count >= end + bodyLength {
                guard buffer.count == end + bodyLength else { reject(400); return }
                finished = true
                handler(TouchBarRequest(method: method, uri: uri, headers: headers, body: Data(buffer[end...]))) { [self] response in send(response) }
                return
            }
            if complete || error != nil { connection.cancel() } else { read() }
        }
    }
    private func parseHead(_ data: Data) -> Bool {
        guard data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }), let text = String(data: data, encoding: .ascii) else { reject(400); return false }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])), first[1].hasPrefix("/"), first[1].utf8.count <= 2048, lines.count <= 41 else { reject(400); return false }
        method = String(first[0]); uri = String(first[1])
        var names = Set<String>()
        let token = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { reject(400); return false }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ token.contains($0) }), names.insert(name).inserted else { reject(400); return false }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { reject(400); return false }
            headers.append((name, value))
        }
        let values = Dictionary(uniqueKeysWithValues: headers)
        guard values["host"] != nil, values["transfer-encoding"] == nil, values["expect"] == nil else { reject(400); return false }
        if let length = values["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(length) else { reject(400); return false }
            guard number <= 4096 else { reject(413); return false }; bodyLength = number
        } else if method == "POST" { reject(411); return false }
        guard method != "GET" || bodyLength == 0 else { reject(400); return false }
        return true
    }
    private func reject(_ status: Int) { finished = true; send(TouchBarResponse(status: status, body: Data("{\"message\":\"Invalid request\"}".utf8))) }
    private func send(_ response: TouchBarResponse) {
        let head = "HTTP/1.1 \(response.status) Response\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n"
        var bytes = Data(head.utf8); bytes.append(response.body)
        connection.send(content: bytes, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}
