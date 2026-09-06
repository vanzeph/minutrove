import Darwin
import Foundation

enum DurableClock {
  enum SampleError: Error { case bootUnavailable }

  static func now() throws -> [String: Any] {
    // A boot UUID stays stable across process launches and wall-clock changes.
    // kern.boottime, or wall minus uptime, cannot provide that guarantee.
    var bytes = [CChar](repeating: 0, count: 37)
    var length = bytes.count
    let status = bytes.withUnsafeMutableBufferPointer {
      sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &length, nil, 0)
    }
    guard status == 0, length > 1, length <= bytes.count,
          bytes[length - 1] == 0 else { throw SampleError.bootUnavailable }
    let boot = String(bytes: bytes.prefix(length - 1).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    guard let boot, UUID(uuidString: boot) != nil else { throw SampleError.bootUnavailable }
    // CLOCK_MONOTONIC_RAW is Apple's nanosecond equivalent of
    // mach_continuous_time and includes time asleep. Integer conversion avoids
    // both floating-point tick rounding and a timebase multiplication overflow.
    let monotonic = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000
    let utc = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    return ["utcMilliseconds": utc,
            "monotonicMilliseconds": Int64(monotonic),
            "bootId": "ios-boot-\(boot)"]
  }
}
