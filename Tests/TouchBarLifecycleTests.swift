import AppKit

@main enum TouchBarLifecycleTests {
    static func wait(_ done: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done(), "Timed out")
    }
    static func main() {
        // Queue behind a deterministic barrier, then revoke before it is dispatched.
        let worker = DispatchQueue(label: "test.media.worker")
        let barrier = DispatchSemaphore(value: 0)
        worker.async { barrier.wait() }
        var dispatched = 0
        let provider = TouchBarProviders(worker: worker, playerRunning: { _ in true }, mediaAction: { _, _, _, _ in dispatched += 1; return (true, "") })
        provider.configure(["appsEnabled": false, "musicEnabled": true])
        var completed = false
        provider.perform(["action": "music.next"]) { ok, _ in precondition(!ok); completed = true }
        provider.invalidateCommands()
        barrier.signal()
        wait { completed }
        precondition(dispatched == 0, "Revoked queued action executed")

        // Permission can wait while main queue handles stop, reset or reconfiguration.
        for operation in ["reset", "stop", "configure"] {
            let permissionEntered = DispatchSemaphore(value: 0)
            let permissionReturn = DispatchSemaphore(value: 0)
            var scriptCount = 0
            let provider = TouchBarProviders(playerRunning: { _ in true }, mediaAction: { action, value, id, valid in
                TouchBarMedia.perform(action, value: value, playerID: id, isValid: valid,
                    requestPermission: { _, _ in permissionEntered.signal(); permissionReturn.wait(); return true },
                    dispatch: { _, _ in scriptCount += 1; return (nil, nil) })
            })
            provider.configure(["appsEnabled": false, "musicEnabled": true])
            var done = false
            provider.perform(["action": "music.next"]) { ok, _ in precondition(!ok); done = true }
            var entered = false
            wait { if !entered { entered = permissionEntered.wait(timeout: .now()) == .success }; return entered }
            switch operation {
            case "stop": provider.stop()
            case "configure": provider.configure(["appsEnabled": false, "musicEnabled": false])
            default: provider.invalidateCommands()
            }
            permissionReturn.signal()
            wait { done }
            precondition(scriptCount == 0, "Action executed after permission wait and \(operation)")
        }
        print("PASS: queued revocation and permission-wait reset/stop/reconfiguration block script dispatch")
    }
}
