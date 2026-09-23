import Foundation
import librtlsdr
import SDRDeviceAccess

/// librtlsdr for `SDRDeviceAccess`'s preflight (`RTLSDRPreflight`), which
/// checks a pipeline's RTL-SDR can be opened — and who holds it when it can't
/// — before the pipeline is started. Blocks (~0.4 s per free device).
nonisolated struct LibRTLSDRBackend: RTLSDRBackend {
    func deviceCount() -> UInt32 { rtlsdr_get_device_count() }

    func serial(at index: UInt32) -> String? {
        var mfr  = [CChar](repeating: 0, count: 256)
        var prod = [CChar](repeating: 0, count: 256)
        var ser  = [CChar](repeating: 0, count: 256)
        guard rtlsdr_get_device_usb_strings(index, &mfr, &prod, &ser) == 0 else { return nil }
        return String(cString: ser)
    }

    func tryOpen(at index: UInt32) -> Int32 {
        var dev: OpaquePointer?
        let rc = rtlsdr_open(&dev, index)
        if rc == 0, let dev { rtlsdr_close(dev) }
        return rc
    }
}
