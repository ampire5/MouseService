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
        func property(_ key: String) -> CFTypeRef? { IOHIDServiceClientCopyProperty(service, key as CFString) }
        let pointerType = property("HIDPointerAccelerationType") as? String
        let vendor = (property("VendorID") as? Int) ?? 0
        let product = (property("ProductID") as? Int) ?? 0
        let trackpad = pointerType == "HIDTrackpadAcceleration" || IOHIDServiceClientConformsTo(service, 0x0D, 0x05) != 0
        let mouse = IOHIDServiceClientConformsTo(service, 0x01, 0x02) != 0
        guard let category = Self.pointerCategory(primaryPage: property("PrimaryUsagePage") as? Int,
                                                  primaryUsage: property("PrimaryUsage") as? Int,
                                                  vendor: vendor, product: product,
                                                  trackpad: trackpad, mouse: mouse) else { return nil }
        self.service = service
        self.id = id
        identity = DeviceIdentity(vendorID: vendor, productID: product,
                                  productName: property("Product") as? String,
                                  serialNumber: property("SerialNumber") as? String, category: category)
        accelerationKey = pointerType ?? "HIDMouseAcceleration"
    }

    static func pointerCategory(primaryPage: Int?, primaryUsage: Int?, vendor: Int, product: Int,
                                trackpad: Bool, mouse: Bool) -> DeviceIdentity.Category? {
        if trackpad { return .trackpad }
        guard mouse else { return nil }
        // TourBox Lite BT exposes a primary mouse collection for its control emulation.
        if vendor == 0x1915 && product == 0xeeee { return .other }
        // A keyboard can advertise a secondary mouse collection for mouse keys.
        if let primaryPage, let primaryUsage, primaryPage != 1 || primaryUsage != 2 { return .other }
        return .mouse
    }

    func property(_ key: String) -> CFTypeRef? { IOHIDServiceClientCopyProperty(service, key as CFString) }
    func setProperty(_ key: String, _ value: CFTypeRef) -> Bool {
        IOHIDServiceClientSetProperty(service, key as CFString, value)
    }
}
