import Foundation

// Test provider never reads or changes the host machine.
final class TouchBarProviders {
    func configure(_ config: [String: Any]) {}
    func snapshot(completion: @escaping ([String: Any]) -> Void) { completion(["apps": []]) }
    func perform(_ command: [String: Any], completion: @escaping (Bool, String) -> Void) { completion(true, "Test operation") }
    func refreshApplications() {}
    func stop() {}
    func invalidateCommands() {}
}
@main struct Harness {
    static func main() {
        var addresses = ["192.0.2.1"]
        let service = TouchBarService(addressProvider: { addresses })
        service.onStatus = { status in
            print(String(data: try! JSONSerialization.data(withJSONObject: status), encoding: .utf8)!)
            fflush(stdout)
        }
        service.handle(["operation": "enable"])
        DispatchQueue.global().async {
            while let operation = readLine() {
                DispatchQueue.main.async {
                    if operation == "changeAddress" { addresses = ["192.0.2.2"]; print("changed"); fflush(stdout) }
                    else { service.handle(["operation": operation]) }
                }
            }
            DispatchQueue.main.async { service.stop(); exit(0) }
        }
        RunLoop.main.run()
    }
}
