// AudioMixing.swift — Pure audio mixing functions (no AudioUnit/framework deps)
// Extracted for testability. Used by micInputCallback and test_app.swift.

import Foundation

/// Compute peak absolute value in a buffer.
func audioPeakLevel(_ buffer: UnsafePointer<Float>, count: Int) -> Float {
    var peak: Float = 0.0
    for i in 0..<count {
        let v = abs(buffer[i])
        if v > peak { peak = v }
    }
    return peak
}

/// Apply volume to inject buffer, mix into capture buffer with clipping.
/// After this call, `inject` contains volume-scaled samples (for speaker output).
/// Returns the inject peak level (post-volume).
func applyInjectMix(
    capture: UnsafeMutablePointer<Float>,
    inject: UnsafeMutablePointer<Float>,
    count: Int,
    volume: Float
) -> Float {
    var injectPeak: Float = 0.0
    for i in 0..<count {
        inject[i] *= volume
        let v = abs(inject[i])
        if v > injectPeak { injectPeak = v }
        capture[i] = min(1.0, max(-1.0, capture[i] + inject[i]))
    }
    return injectPeak
}

/// Duplicate mono left channel to right for mono mic devices.
func monoToStereo(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
    for f in 0..<frames { buffer[f * 2 + 1] = buffer[f * 2] }
}
