import Foundation
import IOKit
import IOKit.pwr_mgt
import CProcInfo

public final class SleepWatcher {
    public typealias Handler = (Event) -> Void
    public enum Event { case willSleep, didWake }

    private var rootPort: io_object_t = 0
    private var notifier: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var handler: Handler?

    public init() {}

    public func start(handler: @escaping Handler) {
        self.handler = handler

        let context = Unmanaged.passUnretained(self).toOpaque()
        var notificationObj: io_object_t = 0
        let port = IORegisterForSystemPower(
            context,
            &notifier,
            { (refcon, _, messageType, messageArgument) in
                guard let refcon = refcon else { return }
                let watcher = Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.handle(messageType: messageType, messageArgument: messageArgument)
            },
            &notificationObj
        )
        guard port != MACH_PORT_NULL else {
            FileHandle.standardError.write(Data("SleepWatcher: IORegisterForSystemPower returned MACH_PORT_NULL — sleep events won't be tracked\n".utf8))
            return
        }
        self.rootPort = port
        self.notification = notificationObj
        guard let np = notifier else {
            FileHandle.standardError.write(Data("SleepWatcher: notification port nil after register — sleep events won't be tracked\n".utf8))
            return
        }
        // Daemon main thread'inin run loop'una source ekle
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(np).takeUnretainedValue(),
            .defaultMode
        )
        FileHandle.standardError.write(Data("SleepWatcher: registered for system power notifications (port=\(port))\n".utf8))
    }

    public func stop() {
        if rootPort != 0 {
            IODeregisterForSystemPower(&notification)
            IOServiceClose(rootPort)
            if let np = notifier {
                IONotificationPortDestroy(np)
            }
            rootPort = 0
            notifier = nil
        }
    }

    private func handle(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        let arg = Int(bitPattern: messageArgument)
        switch messageType {
        case BT_kIOMessageSystemWillSleep:
            handler?(.willSleep)
            IOAllowPowerChange(rootPort, arg)
        case BT_kIOMessageCanSystemSleep:
            IOAllowPowerChange(rootPort, arg)
        case BT_kIOMessageSystemHasPoweredOn:
            handler?(.didWake)
        default:
            break
        }
    }
}
