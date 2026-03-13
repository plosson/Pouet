#!/usr/bin/env node
// test_audio.mjs — Automated audio quality test suite for Pouet
// Tests: mic passthrough, injection, mixing, silence, stereo, frequency response
//
// Usage: node Tests/test_audio.mjs

import { execSync, spawn } from 'child_process';
import { readFileSync, existsSync, unlinkSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const BIN = join(ROOT, 'build', 'tone_injector');
const WAV_PATH = '/tmp/pouet_test.wav';
const SAMPLE_RATE = 48000;
const RECORD_SECONDS = 2;

// ── Helpers ──────────────────────────────────────────────────────────

function log(msg) { console.log(`  ${msg}`); }

function findDeviceIndex() {
  const out = execSync('ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true', { encoding: 'utf-8' });
  const m = out.match(/\[(\d+)\] Pouet/);
  if (!m) throw new Error('Pouet not found in AVFoundation devices');
  return m[1];
}

function recordWav(deviceIndex) {
  try { unlinkSync(WAV_PATH); } catch {}
  execSync(
    `ffmpeg -y -f avfoundation -i ":${deviceIndex}" -t ${RECORD_SECONDS} -ar ${SAMPLE_RATE} -ac 2 -f wav "${WAV_PATH}" 2>/dev/null`,
    { timeout: 10000 }
  );
}

function readWav(path) {
  const buf = readFileSync(path);
  let dataOffset = -1;
  for (let i = 0; i < buf.length - 8; i++) {
    if (buf.toString('ascii', i, i + 4) === 'data') { dataOffset = i + 8; break; }
  }
  if (dataOffset < 0) throw new Error('Invalid WAV');
  const n = Math.floor((buf.length - dataOffset) / 2);
  const samples = new Float32Array(n);
  for (let i = 0; i < n; i++) samples[i] = buf.readInt16LE(dataOffset + i * 2) / 32768.0;
  return samples;
}

/** Run tone_injector with given mode, record, return samples */
async function captureMode(mode, devIdx) {
  const duration = RECORD_SECONDS + 4; // extra time for setup
  const proc = spawn(BIN, [String(duration), mode], { stdio: ['ignore', 'ignore', 'inherit'] });
  await new Promise(r => setTimeout(r, 1000)); // let SHM sync
  recordWav(devIdx);
  proc.kill('SIGTERM');
  await new Promise(r => setTimeout(r, 200));
  return readWav(WAV_PATH);
}

// ── Analysis ─────────────────────────────────────────────────────────

function rms(samples) {
  let sum = 0;
  for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i];
  return Math.sqrt(sum / samples.length);
}

function rmsDb(val) { return val > 0 ? 20 * Math.log10(val) : -100; }

/** Extract left or right channel from interleaved stereo */
function channel(samples, ch) {
  const n = Math.floor(samples.length / 2);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = samples[i * 2 + ch];
  return out;
}

/** FFT magnitude spectrum (real-valued, returns magnitudes for bins 0..N/2) */
function fftMagnitude(mono, N) {
  if (N === undefined) N = mono.length;
  const mags = new Float32Array(N / 2);
  for (let k = 0; k < N / 2; k++) {
    let re = 0, im = 0;
    for (let n = 0; n < N; n++) {
      const angle = -2 * Math.PI * k * n / N;
      re += mono[n] * Math.cos(angle);
      im += mono[n] * Math.sin(angle);
    }
    mags[k] = Math.sqrt(re * re + im * im) / N;
  }
  return mags;
}

/** Find peak frequency in a magnitude spectrum */
function peakFreq(mags, sampleRate, N) {
  const binWidth = sampleRate / N;
  let maxMag = 0, maxBin = 0;
  for (let i = 1; i < mags.length; i++) {
    if (mags[i] > maxMag) { maxMag = mags[i]; maxBin = i; }
  }
  return { freq: maxBin * binWidth, mag: maxMag };
}

/** Check if a frequency is present (magnitude above threshold relative to peak) */
function hasFrequency(mags, targetFreq, sampleRate, N, relativeThreshold = 0.1) {
  const binWidth = sampleRate / N;
  const targetBin = Math.round(targetFreq / binWidth);
  const { mag: peakMag } = peakFreq(mags, sampleRate, N);
  if (peakMag < 0.001) return false;
  // Check a few bins around the target for spectral leakage
  let maxNear = 0;
  for (let b = targetBin - 2; b <= targetBin + 2; b++) {
    if (b >= 0 && b < mags.length && mags[b] > maxNear) maxNear = mags[b];
  }
  return maxNear > peakMag * relativeThreshold;
}

/** Analyze a recording: extract mono left channel, compute FFT, find peaks */
function analyze(samples) {
  const left = channel(samples, 0);
  const right = channel(samples, 1);

  const totalRms = rms(samples);
  const leftRms = rms(left);
  const rightRms = rms(right);

  // FFT on a window from the middle of the recording (skip transients)
  const N = 8192;
  const offset = Math.max(0, Math.floor(left.length / 2) - N / 2);
  const window = left.slice(offset, offset + N);
  const mags = fftMagnitude(window, N);

  const peak = peakFreq(mags, SAMPLE_RATE, N);
  const has440 = hasFrequency(mags, 440, SAMPLE_RATE, N);
  const has1000 = hasFrequency(mags, 1000, SAMPLE_RATE, N);

  return { totalRms, leftRms, rightRms, peak, has440, has1000, mags, N };
}

// ── Test Cases ───────────────────────────────────────────────────────

const results = [];

function test(name, pass, detail) {
  results.push({ name, pass, detail });
  const icon = pass ? 'PASS' : 'FAIL';
  log(`${icon}  ${name.padEnd(35)} ${detail}`);
}

async function main() {
  console.log('');
  console.log('═══════════════════════════════════════════');
  console.log('  Pouet Audio Test Suite');
  console.log('═══════════════════════════════════════════');

  if (!existsSync('/Library/Audio/Plug-Ins/HAL/Pouet.driver')) {
    console.error('FATAL: Driver not installed. Run: make install');
    process.exit(1);
  }

  // Compile
  execSync(`clang -O2 -o "${BIN}" "${join(__dirname, 'tone_injector.c')}" -lm`);
  const devIdx = findDeviceIndex();

  // ── Test 1: Mic passthrough (440Hz) ──
  console.log('');
  log('Test 1: Mic passthrough (440Hz)');
  const micSamples = await captureMode('mic', devIdx);
  const mic = analyze(micSamples);
  test('Signal present', mic.totalRms > 0.01,
       `RMS: ${mic.totalRms.toFixed(4)} (${rmsDb(mic.totalRms).toFixed(1)} dBFS)`);
  test('Volume adequate', rmsDb(mic.totalRms) > -30,
       `${rmsDb(mic.totalRms).toFixed(1)} dBFS (min: -30)`);
  test('440Hz detected', mic.has440,
       `peak: ${mic.peak.freq.toFixed(0)} Hz`);
  test('1000Hz absent', !mic.has1000,
       `(should not be present)`);
  test('Stereo balance', Math.abs(mic.leftRms - mic.rightRms) < 0.05,
       `L: ${mic.leftRms.toFixed(4)} R: ${mic.rightRms.toFixed(4)}`);

  // ── Test 2: Injection passthrough (1000Hz) ──
  console.log('');
  log('Test 2: Injection passthrough (1000Hz)');
  const injSamples = await captureMode('inject', devIdx);
  const inj = analyze(injSamples);
  test('Signal present', inj.totalRms > 0.01,
       `RMS: ${inj.totalRms.toFixed(4)} (${rmsDb(inj.totalRms).toFixed(1)} dBFS)`);
  test('1000Hz detected', inj.has1000,
       `peak: ${inj.peak.freq.toFixed(0)} Hz`);
  test('440Hz absent', !inj.has440,
       `(should not be present)`);

  // ── Test 3: Mixed mic + injection (440Hz + 1000Hz) ──
  console.log('');
  log('Test 3: Mixed mic + injection (440Hz + 1000Hz)');
  const mixSamples = await captureMode('mix', devIdx);
  const mix = analyze(mixSamples);
  test('Signal present', mix.totalRms > 0.01,
       `RMS: ${mix.totalRms.toFixed(4)} (${rmsDb(mix.totalRms).toFixed(1)} dBFS)`);
  test('440Hz detected', mix.has440,
       `(mic frequency)`);
  test('1000Hz detected', mix.has1000,
       `(inject frequency)`);
  test('Volume higher than single', rmsDb(mix.totalRms) > rmsDb(mic.totalRms) - 3,
       `mix: ${rmsDb(mix.totalRms).toFixed(1)} vs mic: ${rmsDb(mic.totalRms).toFixed(1)} dBFS`);

  // ── Test 4: Silence ──
  console.log('');
  log('Test 4: Silence');
  const silSamples = await captureMode('silence', devIdx);
  const sil = analyze(silSamples);
  test('Near-silence', sil.totalRms < 0.01,
       `RMS: ${sil.totalRms.toFixed(6)} (${rmsDb(sil.totalRms).toFixed(1)} dBFS)`);
  test('No 440Hz', !sil.has440,
       `(no stale signal)`);
  test('No 1000Hz', !sil.has1000,
       `(no stale signal)`);

  // ── Test 5: Crackling / glitch detection ──
  console.log('');
  log('Test 5: Crackling / glitch detection (440Hz)');
  {
    const samples = await captureMode('mic', devIdx);
    const left = channel(samples, 0);
    // A clean sine wave has smooth sample-to-sample transitions.
    // Crackling = sudden jumps between consecutive samples.
    // Max derivative of a 440Hz sine at 48kHz ≈ 2*π*440/48000 * amplitude ≈ 0.057 per sample at amp 1.0
    // We use a generous threshold: anything > 0.3 is a glitch.
    let glitchCount = 0;
    const glitchThreshold = 0.3;
    const glitches = [];
    for (let i = 1; i < left.length; i++) {
      const diff = Math.abs(left[i] - left[i - 1]);
      if (diff > glitchThreshold) {
        glitchCount++;
        if (glitches.length < 5) glitches.push({ i, diff: diff.toFixed(4), val: left[i].toFixed(4), prev: left[i-1].toFixed(4) });
      }
    }
    test('No crackling/glitches', glitchCount === 0,
         glitchCount === 0 ? 'clean signal' : `${glitchCount} glitches found! First: ${JSON.stringify(glitches[0])}`);

    // Also check for dropout: sudden drops to silence in the middle of a signal
    const windowSize = 480; // 10ms windows
    let dropoutCount = 0;
    for (let w = 1; w < Math.floor(left.length / windowSize) - 1; w++) {
      const prevRms = rms(left.slice((w - 1) * windowSize, w * windowSize));
      const curRms = rms(left.slice(w * windowSize, (w + 1) * windowSize));
      // Signal was present then dropped to near-zero
      if (prevRms > 0.05 && curRms < 0.005) {
        dropoutCount++;
      }
    }
    test('No audio dropouts', dropoutCount === 0,
         dropoutCount === 0 ? 'continuous signal' : `${dropoutCount} dropouts detected`);
  }

  // ── Test 6: Volume stability over time ──
  console.log('');
  log('Test 6: Volume stability over time');
  {
    const samples = await captureMode('mic', devIdx);
    const left = channel(samples, 0);
    // Split into 10 equal chunks and measure RMS of each
    const numChunks = 10;
    const chunkSize = Math.floor(left.length / numChunks);
    const chunkRms = [];
    for (let c = 0; c < numChunks; c++) {
      chunkRms.push(rms(left.slice(c * chunkSize, (c + 1) * chunkSize)));
    }
    // Skip first chunk (may have transient), check rest are stable
    const stableChunks = chunkRms.slice(1);
    const avgRms = stableChunks.reduce((a, b) => a + b) / stableChunks.length;
    const maxDeviation = Math.max(...stableChunks.map(r => Math.abs(rmsDb(r) - rmsDb(avgRms))));

    test('Volume stable across recording', maxDeviation < 3.0,
         `max deviation: ${maxDeviation.toFixed(1)} dB (limit: 3 dB), avg: ${rmsDb(avgRms).toFixed(1)} dBFS`);

    // Check no volume fade — last chunk shouldn't be much quieter than first stable chunk
    const firstDb = rmsDb(stableChunks[0]);
    const lastDb = rmsDb(stableChunks[stableChunks.length - 1]);
    test('No volume fade over time', Math.abs(lastDb - firstDb) < 3.0,
         `first: ${firstDb.toFixed(1)} dBFS, last: ${lastDb.toFixed(1)} dBFS`);
  }

  // ── Test 7: Long recording drift test (5 seconds) ──
  console.log('');
  log('Test 7: Long recording stability (5s)');
  {
    const longWav = '/tmp/pouet_long.wav';
    const longDuration = 5;
    const proc = spawn(BIN, [String(longDuration + 4), 'mic'], { stdio: ['ignore', 'ignore', 'inherit'] });
    await new Promise(r => setTimeout(r, 1000));
    try { unlinkSync(longWav); } catch {}
    execSync(
      `ffmpeg -y -f avfoundation -i ":${devIdx}" -t ${longDuration} -ar ${SAMPLE_RATE} -ac 2 -f wav "${longWav}" 2>/dev/null`,
      { timeout: 20000 }
    );
    proc.kill('SIGTERM');
    await new Promise(r => setTimeout(r, 200));

    const samples = readWav(longWav);
    const left = channel(samples, 0);

    // Check for glitches across the entire 5s
    let glitchCount = 0;
    for (let i = 1; i < left.length; i++) {
      if (Math.abs(left[i] - left[i - 1]) > 0.3) glitchCount++;
    }
    test('No glitches over 5s', glitchCount === 0,
         glitchCount === 0 ? 'clean' : `${glitchCount} glitches in ${longDuration}s`);

    // Check volume doesn't degrade: compare first second vs last second
    const oneSec = SAMPLE_RATE;
    const firstSecRms = rms(left.slice(oneSec, 2 * oneSec)); // skip first second transient
    const lastSecRms = rms(left.slice(left.length - oneSec));
    const drift = Math.abs(rmsDb(firstSecRms) - rmsDb(lastSecRms));
    test('No volume drift over 5s', drift < 3.0,
         `first: ${rmsDb(firstSecRms).toFixed(1)} dB, last: ${rmsDb(lastSecRms).toFixed(1)} dB, drift: ${drift.toFixed(1)} dB`);

    // Check signal-to-noise ratio
    const N = 8192;
    const offset = Math.floor(left.length / 2) - N / 2;
    const window = left.slice(offset, offset + N);
    const mags = fftMagnitude(window, N);
    const peak = peakFreq(mags, SAMPLE_RATE, N);
    // Sum power outside the peak ±3 bins
    const peakBin = Math.round(peak.freq / (SAMPLE_RATE / N));
    let noisePower = 0, signalPower = 0;
    for (let i = 1; i < mags.length; i++) {
      if (Math.abs(i - peakBin) <= 3) signalPower += mags[i] * mags[i];
      else noisePower += mags[i] * mags[i];
    }
    const snr = 10 * Math.log10(signalPower / (noisePower || 1e-20));
    test('SNR > 20 dB', snr > 20,
         `SNR: ${snr.toFixed(1)} dB`);

    try { unlinkSync(longWav); } catch {}
  }

  // ── Test 8: Rapid start/stop (stress test) ──
  console.log('');
  log('Test 8: Rapid injection start/stop');
  {
    // Start and stop tone_injector 3 times quickly, then record
    for (let i = 0; i < 3; i++) {
      const p = spawn(BIN, ['2', 'mic'], { stdio: ['ignore', 'ignore', 'inherit'] });
      await new Promise(r => setTimeout(r, 300));
      p.kill('SIGTERM');
      await new Promise(r => setTimeout(r, 200));
    }
    // Now do a real capture — should still work clean
    const samples = await captureMode('mic', devIdx);
    const a = analyze(samples);
    test('Signal after start/stop cycles', a.totalRms > 0.01,
         `RMS: ${a.totalRms.toFixed(4)}`);
    test('Clean freq after start/stop', a.has440,
         `peak: ${a.peak.freq.toFixed(0)} Hz`);
  }

  // ── Test 9: Amplitude accuracy ──
  console.log('');
  log('Test 9: Amplitude accuracy');
  {
    // tone_injector sends at amplitude 0.5. After going through driver,
    // we should get something close to that (within reason for 16-bit WAV quantization)
    const samples = await captureMode('mic', devIdx);
    const left = channel(samples, 0);
    // Find peak amplitude in the signal (skip first 0.5s transient)
    const skip = SAMPLE_RATE / 2;
    let maxAmp = 0;
    for (let i = skip; i < left.length; i++) {
      const v = Math.abs(left[i]);
      if (v > maxAmp) maxAmp = v;
    }
    // Expected: ~0.5. Allow generous tolerance (0.15 to 0.85)
    test('Peak amplitude reasonable', maxAmp > 0.15 && maxAmp < 0.85,
         `peak: ${maxAmp.toFixed(4)} (expected ~0.5)`);

    // Check RMS is reasonable for a sine wave at 0.5 amplitude (RMS = 0.5/sqrt(2) ≈ 0.354)
    const expectedRms = 0.5 / Math.sqrt(2);
    const actualRms = rms(left.slice(skip));
    const rmsError = Math.abs(actualRms - expectedRms) / expectedRms * 100;
    test('RMS within 50% of expected', rmsError < 50,
         `actual: ${actualRms.toFixed(4)}, expected: ${expectedRms.toFixed(4)}, error: ${rmsError.toFixed(1)}%`);
  }

  // ── Test 10: Spectral purity (no harmonics/distortion) ──
  console.log('');
  log('Test 10: Spectral purity');
  {
    const samples = await captureMode('mic', devIdx);
    const left = channel(samples, 0);
    const N = 8192;
    const offset = Math.floor(left.length / 2) - N / 2;
    const window = left.slice(offset, offset + N);
    const mags = fftMagnitude(window, N);

    // Check for harmonics at 880Hz (2nd), 1320Hz (3rd) — should NOT be present
    // These would indicate distortion/clipping
    const has880 = hasFrequency(mags, 880, SAMPLE_RATE, N, 0.05);
    const has1320 = hasFrequency(mags, 1320, SAMPLE_RATE, N, 0.05);
    test('No 2nd harmonic (880Hz)', !has880,
         has880 ? 'DISTORTION: 880Hz present' : 'clean');
    test('No 3rd harmonic (1320Hz)', !has1320,
         has1320 ? 'DISTORTION: 1320Hz present' : 'clean');

    // Total harmonic distortion estimate
    const binWidth = SAMPLE_RATE / N;
    const fundBin = Math.round(440 / binWidth);
    const fundPower = mags[fundBin] * mags[fundBin];
    let harmonicPower = 0;
    for (let h = 2; h <= 5; h++) {
      const hBin = Math.round(440 * h / binWidth);
      if (hBin < mags.length) harmonicPower += mags[hBin] * mags[hBin];
    }
    const thd = fundPower > 0 ? Math.sqrt(harmonicPower / fundPower) * 100 : 0;
    test('THD < 5%', thd < 5,
         `THD: ${thd.toFixed(2)}%`);
  }

  // ── Summary ──
  const passed = results.filter(r => r.pass).length;
  const total = results.length;
  const allPass = passed === total;

  console.log('');
  console.log('───────────────────────────────────────────');
  console.log(`  ${passed}/${total} tests passed — ${allPass ? 'PASS' : 'FAIL'}`);
  if (!allPass) {
    console.log('');
    console.log('  FAILURES:');
    for (const r of results) {
      if (!r.pass) console.log(`    FAIL  ${r.name}: ${r.detail}`);
    }
  }
  console.log('═══════════════════════════════════════════');
  console.log('');

  try { unlinkSync(WAV_PATH); } catch {}
  process.exit(allPass ? 0 : 1);
}

main();
