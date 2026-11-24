import Foundation
import IOKit
import IOKit.serial
import IOKit.usb

/// Finds USB serial ports by vendor ID and reports hot-plug events via IOKit.
final class SerialPortScanner {
    let vendorID: Int
    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var onChange: (() -> Void)?

    init(vendorID: Int) { self.vendorID = vendorID }

    deinit { stopMonitoring() }

    /// Callout paths (`/dev/cu.*`) of serial ports whose USB device has `vendorID`.
    func matchingPorts() -> [String] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else { return [] }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var result = [String]()
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                             kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            let vid = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString,
                                                      kCFAllocatorDefault,
                                                      IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            if let vid = vid as? NSNumber, vid.intValue == vendorID {
                result.append(path)
            }
        }
        return result.sorted()
    }

    /// Calls `onChange` (on `queue`) whenever any serial port appears or disappears.
    func startMonitoring(queue: DispatchQueue, onChange: @escaping () -> Void) {
        stopMonitoring()
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            SerialPortScanner.drain(iterator)
            guard let refcon else { return }
            Unmanaged<SerialPortScanner>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }
        // Draining each iterator once arms its notification.
        if let matching = IOServiceMatching(kIOSerialBSDServiceValue),
           IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, callback, refcon,
                                            &addedIter) == KERN_SUCCESS {
            SerialPortScanner.drain(addedIter)
        }
        if let matching = IOServiceMatching(kIOSerialBSDServiceValue),
           IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching, callback, refcon,
                                            &removedIter) == KERN_SUCCESS {
            SerialPortScanner.drain(removedIter)
        }
    }

    func stopMonitoring() {
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    private static func drain(_ iterator: io_iterator_t) {
        while true {
            let obj = IOIteratorNext(iterator)
            if obj == 0 { break }
            IOObjectRelease(obj)
        }
    }
}
