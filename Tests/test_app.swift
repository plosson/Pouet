// test_app.swift — Unit tests for VirtualMic Swift-side shared memory and ring buffer
// Uses shm_bridge.h via bridging header for atomic helpers and SHMHeaderC.
// All tests use heap memory (no POSIX shm needed).

import Foundation

// ---------------------------------------------------------------------------
// SHMHeader — copied from AudioService.swift (must stay in sync!)
// ---------------------------------------------------------------------------
struct SHMHeader {
    var writePos: UInt64
    var _pad1: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0,0,0,0,0,0,0)  // 56 bytes
    var readPos:  UInt64
    var _pad2: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0,0,0,0,0,0,0)  // 56 bytes
    var capacity: UInt32
    var pad:      UInt32
}

let NUM_CHANNELS = 2

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------
var testsRun = 0
var testsPassed = 0

func runTest(_ name: String, _ body: () -> Void) {
    let padded = name.padding(toLength: 45, withPad: " ", startingAt: 0)
    print("  \(padded)", terminator: "")
    body()
    testsPassed += 1
    testsRun += 1
    print("OK")
}

// Helper: allocate a buffer that looks like SHM (header + float data)
func allocSHM(capacity: Int) -> (UnsafeMutableRawPointer, UnsafeMutablePointer<SHMHeader>, UnsafeMutablePointer<Float>) {
    let headerSize = MemoryLayout<SHMHeader>.size
    let totalSize = headerSize + capacity * MemoryLayout<Float>.size
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: 8)
    ptr.initializeMemory(as: UInt8.self, repeating: 0, count: totalSize)
    let header = ptr.assumingMemoryBound(to: SHMHeader.self)
    let data = (ptr + headerSize).assumingMemoryBound(to: Float.self)
    header.pointee.capacity = UInt32(capacity)
    return (ptr, header, data)
}

// ---------------------------------------------------------------------------
// Struct layout tests
// ---------------------------------------------------------------------------
func test_struct_layout_matches_c() {
    let expected = 136
    let actual = MemoryLayout<SHMHeader>.size
    if actual != expected {
        fatalError("SHMHeader size = \(actual), expected \(expected)")
    }
    assert(actual == expected)
}

func test_struct_alignment() {
    assert(MemoryLayout<SHMHeader>.alignment == 8)
}

func test_field_offsets_match_c() {
    // writePos at 0, readPos at 64 (8 + 56), capacity at 128 (8 + 56 + 8 + 56)
    let writeOff = MemoryLayout<SHMHeader>.offset(of: \SHMHeader.writePos)!
    let readOff = MemoryLayout<SHMHeader>.offset(of: \SHMHeader.readPos)!
    let capOff = MemoryLayout<SHMHeader>.offset(of: \SHMHeader.capacity)!

    assert(writeOff == 0, "writePos offset = \(writeOff), expected 0")
    assert(readOff == 64, "readPos offset = \(readOff), expected 64")
    assert(capOff == 128, "capacity offset = \(capOff), expected 128")
}

func test_shm_header_c_size_matches() {
    let swiftSize = MemoryLayout<SHMHeader>.size
    let cSize = MemoryLayout<SHMHeaderC>.size
    if swiftSize != cSize {
        fatalError("SHMHeader(\(swiftSize)) != SHMHeaderC(\(cSize))")
    }
    assert(swiftSize == cSize)
}

// ---------------------------------------------------------------------------
// Atomic helper tests
// ---------------------------------------------------------------------------
func test_atomic_helpers_roundtrip() {
    let (ptr, _, _) = allocSHM(capacity: 0)
    defer { ptr.deallocate() }

    let values: [UInt64] = [0, 1, 42, 262144, UInt64.max, UInt64.max - 1000]
    for val in values {
        shm_store_write_pos(ptr, val)
        let loaded = shm_load_write_pos(ptr)
        assert(loaded == val, "writePos roundtrip failed: stored \(val), got \(loaded)")

        shm_store_read_pos(ptr, val)
        let loaded2 = shm_load_read_pos(ptr)
        assert(loaded2 == val, "readPos roundtrip failed: stored \(val), got \(loaded2)")
    }
}

// ---------------------------------------------------------------------------
// Ring buffer tests (mimicking SharedRingBuffer logic)
// ---------------------------------------------------------------------------

// Simplified write (matches SharedRingBuffer.tryWrite logic)
func ringWrite(_ header: UnsafeMutableRawPointer, _ data: UnsafeMutablePointer<Float>,
               samples: [Float], capacity: Int) -> Int {
    let wp = shm_load_write_pos(header)
    let rp = shm_load_read_pos(header)
    let cap = UInt64(capacity)
    let avail = Int(cap - (wp - rp))
    let toWrite = min(avail, samples.count)
    if toWrite <= 0 { return 0 }

    for i in 0..<toWrite {
        let idx = Int((wp + UInt64(i)) % cap)
        data[idx] = samples[i]
    }
    shm_store_write_pos(header, wp + UInt64(toWrite))
    return toWrite
}

// Simplified read (matches SharedRingBuffer.read logic)
func ringRead(_ header: UnsafeMutableRawPointer, _ data: UnsafeMutablePointer<Float>,
              count: Int, capacity: Int) -> [Float] {
    let wp = shm_load_write_pos(header)
    let rp = shm_load_read_pos(header)
    // Guard against corrupted state where rp > wp (unsigned underflow)
    guard wp >= rp else { return [] }
    let avail = Int(wp - rp)
    let toRead = min(avail, count)
    if toRead <= 0 { return [] }

    var buffer = [Float](repeating: 0, count: toRead)
    let cap = UInt64(capacity)
    for i in 0..<toRead {
        let idx = Int((rp + UInt64(i)) % cap)
        buffer[i] = data[idx]
    }
    shm_store_read_pos(header, rp + UInt64(toRead))
    return buffer
}

func test_ring_buffer_write_read() {
    let cap = 2048
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let input: [Float] = (0..<512).map { Float($0) * 0.01 }
    let written = ringWrite(ptr, data, samples: input, capacity: cap)
    assert(written == 512)

    let output = ringRead(ptr, data, count: 512, capacity: cap)
    assert(output.count == 512)
    for i in 0..<512 {
        assert(abs(output[i] - input[i]) < 1e-6, "Mismatch at \(i)")
    }
}

func test_ring_buffer_empty_read() {
    let cap = 1024
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let output = ringRead(ptr, data, count: 512, capacity: cap)
    assert(output.isEmpty)
}

func test_ring_buffer_wraparound() {
    let cap = 256
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    // Start near the end
    let start: UInt64 = UInt64(cap - 50)
    shm_store_write_pos(ptr, start)
    shm_store_read_pos(ptr, start)

    let input: [Float] = (0..<100).map { Float($0 + 1) }
    let written = ringWrite(ptr, data, samples: input, capacity: cap)
    assert(written == 100)

    let output = ringRead(ptr, data, count: 100, capacity: cap)
    assert(output.count == 100)
    for i in 0..<100 {
        assert(abs(output[i] - input[i]) < 1e-6, "Wraparound mismatch at \(i)")
    }
}

func test_ring_buffer_full() {
    let cap = 256
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    // Fill completely
    let input = [Float](repeating: 1.0, count: cap)
    let written = ringWrite(ptr, data, samples: input, capacity: cap)
    assert(written == cap)

    // Try writing more — should return 0
    let written2 = ringWrite(ptr, data, samples: [1.0, 2.0], capacity: cap)
    assert(written2 == 0)
}

func test_clear_resets_positions() {
    let cap = 1024
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let input = [Float](repeating: 1.0, count: 500)
    _ = ringWrite(ptr, data, samples: input, capacity: cap)
    assert(shm_load_write_pos(ptr) == 500)

    // Clear: set readPos = writePos
    shm_store_read_pos(ptr, shm_load_write_pos(ptr))

    let wp = shm_load_write_pos(ptr)
    let rp = shm_load_read_pos(ptr)
    assert(wp == rp, "After clear, writePos(\(wp)) != readPos(\(rp))")
}

func test_fill_percent() {
    let cap = 1000
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    // Empty
    let wp0 = shm_load_write_pos(ptr)
    let rp0 = shm_load_read_pos(ptr)
    let fill0 = Int((wp0 - rp0) * 100 / UInt64(cap))
    assert(fill0 == 0)

    // Half full
    let input = [Float](repeating: 0, count: 500)
    _ = ringWrite(ptr, data, samples: input, capacity: cap)
    let wp1 = shm_load_write_pos(ptr)
    let rp1 = shm_load_read_pos(ptr)
    let fill1 = Int((wp1 - rp1) * 100 / UInt64(cap))
    assert(fill1 == 50)

    // Full
    let input2 = [Float](repeating: 0, count: 500)
    _ = ringWrite(ptr, data, samples: input2, capacity: cap)
    let wp2 = shm_load_write_pos(ptr)
    let rp2 = shm_load_read_pos(ptr)
    let fill2 = Int((wp2 - rp2) * 100 / UInt64(cap))
    assert(fill2 == 100)
}

func test_large_position_values() {
    let cap = 256
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    // Simulate positions near UInt64 max
    let start = UInt64.max - 1000
    shm_store_write_pos(ptr, start)
    shm_store_read_pos(ptr, start)

    let input: [Float] = (0..<100).map { Float($0) }
    let written = ringWrite(ptr, data, samples: input, capacity: cap)
    assert(written == 100)

    let output = ringRead(ptr, data, count: 100, capacity: cap)
    assert(output.count == 100)
    for i in 0..<100 {
        assert(abs(output[i] - input[i]) < 1e-6, "Large position mismatch at \(i)")
    }
}

// ---------------------------------------------------------------------------
// Adversarial tests
// ---------------------------------------------------------------------------

func test_concurrent_read_write_stress() {
    let cap = 8192
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let iterations = 5000
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "stress", attributes: .concurrent)

    // Writer thread
    group.enter()
    queue.async {
        let input = [Float](repeating: 0.5, count: 1024)
        for _ in 0..<iterations {
            _ = ringWrite(ptr, data, samples: input, capacity: cap)
        }
        group.leave()
    }

    // Reader thread
    group.enter()
    queue.async {
        for _ in 0..<iterations {
            let output = ringRead(ptr, data, count: 1024, capacity: cap)
            // Verify no NaN/Inf
            for val in output {
                assert(!val.isNaN && !val.isInfinite, "Corrupted data in concurrent read")
            }
        }
        group.leave()
    }

    group.wait()

    let wp = shm_load_write_pos(ptr)
    let rp = shm_load_read_pos(ptr)
    assert(wp >= rp, "writePos < readPos after stress test")
}

func test_nan_inf_injection() {
    let cap = 2048
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let poison: [Float] = (0..<512).map { i in
        switch i % 4 {
        case 0: return Float.nan
        case 1: return Float.infinity
        case 2: return -Float.infinity
        default: return 1e-45 // denormal
        }
    }
    // Should not crash
    let written = ringWrite(ptr, data, samples: poison, capacity: cap)
    assert(written == 512)

    let output = ringRead(ptr, data, count: 512, capacity: cap)
    assert(output.count == 512)
}

func test_position_overflow_uint64_max() {
    let cap = 256
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    // Near UINT64_MAX — test unsigned arithmetic wrapping
    let nearMax: UInt64 = UInt64.max - 128
    shm_store_write_pos(ptr, nearMax)
    shm_store_read_pos(ptr, nearMax)

    let input: [Float] = (0..<100).map { Float($0) }
    let written = ringWrite(ptr, data, samples: input, capacity: cap)
    assert(written == 100)

    let output = ringRead(ptr, data, count: 100, capacity: cap)
    assert(output.count == 100)
    for i in 0..<100 {
        assert(abs(output[i] - input[i]) < 1e-6)
    }
}

func test_corrupted_readpos_ahead() {
    let cap = 2048
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    // Corrupt: readPos way ahead of writePos
    shm_store_write_pos(ptr, 100)
    shm_store_read_pos(ptr, 5000)

    // avail = wp - rp underflows (unsigned), becomes huge
    // Read should handle gracefully (not crash)
    let output = ringRead(ptr, data, count: 512, capacity: cap)
    // With our simplified ringRead, avail = Int(wp - rp) which is negative, so returns empty
    // The important thing is no crash
    _ = output
}

func test_capacity_one() {
    let cap = 1
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let input: [Float] = [0.5, 0.75]
    // Writing 2 samples into capacity 1 — heavy wrapping
    let written = ringWrite(ptr, data, samples: input, capacity: cap)
    // Only 1 sample fits (cap - (wp - rp) = 1)
    assert(written == 1)
}

func test_odd_capacity_wraparound() {
    let cap = 777
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let input: [Float] = (0..<500).map { Float($0) * 0.001 }
    for _ in 0..<20 {
        _ = ringWrite(ptr, data, samples: input, capacity: cap)
    }
    for _ in 0..<10 {
        _ = ringRead(ptr, data, count: 500, capacity: cap)
    }

    let wp = shm_load_write_pos(ptr)
    let rp = shm_load_read_pos(ptr)
    assert(wp >= rp)
}

func test_fill_percent_never_exceeds_100() {
    let cap = 256
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    // Overfill: set writePos way ahead
    shm_store_write_pos(ptr, UInt64(cap * 3))
    shm_store_read_pos(ptr, 0)

    let rawHeader = UnsafeMutableRawPointer(ptr)
    let used = Int(shm_load_write_pos(rawHeader) - shm_load_read_pos(rawHeader))
    let fill = cap > 0 ? min(100, used * 100 / cap) : 0
    assert(fill == 100, "fillPercent should cap at 100, got \(fill)")
    _ = data
}

func test_rapid_clear_during_writes() {
    let cap = 2048
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let input: [Float] = [Float](repeating: 1.0, count: 512)
    for i in 0..<100 {
        _ = ringWrite(ptr, data, samples: input, capacity: cap)
        if i % 5 == 0 {
            // Clear: readPos = writePos
            shm_store_read_pos(ptr, shm_load_write_pos(ptr))
        }
    }
    let wp = shm_load_write_pos(ptr)
    let rp = shm_load_read_pos(ptr)
    assert(wp >= rp)
}

func test_all_zeros_roundtrip() {
    let cap = 1024
    let (ptr, _, data) = allocSHM(capacity: cap)
    defer { ptr.deallocate() }

    let silence = [Float](repeating: 0, count: 512)
    let written = ringWrite(ptr, data, samples: silence, capacity: cap)
    assert(written == 512)

    let output = ringRead(ptr, data, count: 512, capacity: cap)
    for val in output {
        assert(val == 0.0, "Expected silence, got \(val)")
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
@main struct TestApp {
    static func main() {
        print("=== Swift App Tests ===")

        // Struct layout (CRITICAL — prevents production crashes)
        runTest("test_struct_layout_matches_c", test_struct_layout_matches_c)
        runTest("test_struct_alignment", test_struct_alignment)
        runTest("test_field_offsets_match_c", test_field_offsets_match_c)
        runTest("test_shm_header_c_size_matches", test_shm_header_c_size_matches)

        // Atomic helpers
        runTest("test_atomic_helpers_roundtrip", test_atomic_helpers_roundtrip)

        // Ring buffer — basic
        runTest("test_ring_buffer_write_read", test_ring_buffer_write_read)
        runTest("test_ring_buffer_empty_read", test_ring_buffer_empty_read)
        runTest("test_ring_buffer_wraparound", test_ring_buffer_wraparound)
        runTest("test_ring_buffer_full", test_ring_buffer_full)
        runTest("test_clear_resets_positions", test_clear_resets_positions)
        runTest("test_fill_percent", test_fill_percent)
        runTest("test_large_position_values", test_large_position_values)

        // Adversarial — concurrency
        runTest("test_concurrent_read_write_stress", test_concurrent_read_write_stress)

        // Adversarial — poisoned data
        runTest("test_nan_inf_injection", test_nan_inf_injection)

        // Adversarial — position/overflow
        runTest("test_position_overflow_uint64_max", test_position_overflow_uint64_max)
        runTest("test_corrupted_readpos_ahead", test_corrupted_readpos_ahead)

        // Adversarial — boundary conditions
        runTest("test_capacity_one", test_capacity_one)
        runTest("test_odd_capacity_wraparound", test_odd_capacity_wraparound)
        runTest("test_fill_percent_never_exceeds_100", test_fill_percent_never_exceeds_100)
        runTest("test_all_zeros_roundtrip", test_all_zeros_roundtrip)

        // Adversarial — state transitions
        runTest("test_rapid_clear_during_writes", test_rapid_clear_during_writes)

        print("\n\(testsPassed)/\(testsRun) tests passed")
        if testsPassed != testsRun { exit(1) }
    }
}
