import Foundation
import IOKit
import IOKit.hidsystem
import PointerCore

/// The HID boundary used when enumerating and configuring pointing devices.
@MainActor protocol PointerDeviceService {
    var id: UInt64 { get }
    var identity: DeviceIdentity { get }
    var accelerationKey: String { get }
    func property(_ key: String) -> CFTypeRef?
    func setProperty(_ key: String, _ value: CFTypeRef) -> Bool
}

@MainActor struct SystemPointerDeviceService: PointerDeviceService {
    let service: IOHIDServiceClient
    let id: UInt64
    let identity: DeviceIdentity
    let accelerationKey: String

    init?(_ service: IOHIDServiceClient) {
        guard let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value else { return nil }
        let category: DeviceIdentity.Category
        if IOHIDServiceClientConformsTo(service, 0x0D, 0x05) != 0 {
            category = .trackpad
        } else if IOHIDServiceClientConformsTo(service, 0x01, 0x02) != 0 {
            category = .mouse
        } else {
            return nil
        }
        func property(_ key: String) -> CFTypeRef? { IOHIDServiceClientCopyProperty(service, key as CFString) }
        self.service = service
        self.id = id
        identity = DeviceIdentity(vendorID: (property("VendorID") as? Int) ?? 0,
                                  productID: (property("ProductID") as? Int) ?? 0,
                                  productName: property("Product") as? String,
                                  serialNumber: property("SerialNumber") as? String, category: category)
        accelerationKey = (property("HIDPointerAccelerationType") as? String) ?? "HIDMouseAcceleration"
    }

    func property(_ key: String) -> CFTypeRef? { IOHIDServiceClientCopyProperty(service, key as CFString) }
    func setProperty(_ key: String, _ value: CFTypeRef) -> Bool {
        IOHIDServiceClientSetProperty(service, key as CFString, value)
    }
}
