#!/usr/bin/env node
// test_webrtc.mjs — Tests Pouet through Chrome's voice processing pipeline
// Compares raw capture vs processed (echoCancellation + noiseSuppression + AGC)
// This simulates what Google Meet / Zoom do to the audio.

import { chromium } from 'playwright';
import { execSync, spawn } from 'child_process';
import { createServer } from 'http';
import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const TONE_DURATION = 20;
const TIMEOUT_MS = 30000;

function log(msg) { console.log(`[test] ${msg}`); }

async function main() {
  let toneProc = null;
  let server = null;
  let exitCode = 0;

  try {
    if (!existsSync('/Library/Audio/Plug-Ins/HAL/Pouet.driver')) {
      throw new Error('Driver not installed. Run: make install');
    }

    // Compile and start tone injector
    log('Compiling tone_injector...');
    execSync(`clang -O2 -o "${join(ROOT, 'build', 'tone_injector')}" "${join(__dirname, 'tone_injector.c')}" -lm`);

    log(`Starting tone_injector (${TONE_DURATION}s)...`);
    toneProc = spawn(join(ROOT, 'build', 'tone_injector'), [String(TONE_DURATION)], {
      stdio: ['ignore', 'ignore', 'inherit'],
    });
    await new Promise(r => setTimeout(r, 1000));

    // HTTP server
    const html = readFileSync(join(__dirname, 'webrtc_loopback.html'), 'utf-8');
    server = await new Promise(resolve => {
      const srv = createServer((req, res) => {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(html);
      });
      srv.listen(0, '127.0.0.1', () => resolve(srv));
    });
    const port = server.address().port;
    log(`HTTP server on http://127.0.0.1:${port}`);

    // Launch Chrome
    log('Launching Chrome...');
    const browser = await chromium.launch({
      channel: 'chrome',
      headless: false,
      args: [
        '--use-fake-ui-for-media-stream',
        '--autoplay-policy=no-user-gesture-required',
      ],
    });

    const context = await browser.newContext({ permissions: ['microphone'] });
    const page = await context.newPage();

    const resultPromise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Timeout')), TIMEOUT_MS);
      page.on('console', msg => {
        const text = msg.text();
        if (text.startsWith('TEST_RESULT:')) {
          clearTimeout(timer);
          resolve(JSON.parse(text.replace('TEST_RESULT:', '')));
        } else {
          console.log(`  [chrome] ${text}`);
        }
      });
    });

    await page.goto(`http://127.0.0.1:${port}`);
    log('Waiting for analysis...');
    const results = await resultPromise;
    await browser.close();

    // Report
    console.log('');
    console.log('═══════════════════════════════════════════');
    console.log('  Pouet Voice Processing Test');
    console.log('═══════════════════════════════════════════');
    if (results.error) {
      console.log(`  Error: ${results.error}`);
    } else {
      const r = results.raw, p = results.processed;
      console.log(`  Raw:        ${r.rmsDb.toFixed(1)} dBFS | ${r.medianFreq.toFixed(0)} Hz | ${r.nonZeroSamples} samples`);
      console.log(`  Processed:  ${p.rmsDb.toFixed(1)} dBFS | ${p.medianFreq.toFixed(0)} Hz | ${p.nonZeroSamples} samples`);
      console.log(`  Vol drop:   ${results.volumeDropDb.toFixed(1)} dB from voice processing`);
      console.log('───────────────────────────────────────────');
      console.log(`  Raw signal:       ${results.rawSignalPresent ? 'PASS' : 'FAIL'}`);
      console.log(`  Processed signal: ${results.processedSignalPresent ? 'PASS' : 'FAIL'}`);
      console.log(`  Processed volume: ${results.processedVolumeOk ? 'PASS' : 'FAIL'}`);
      console.log(`  Processed freq:   ${results.processedFreqOk ? 'PASS' : 'FAIL'}`);
    }
    console.log('───────────────────────────────────────────');
    console.log(`  ${results.pass ? 'PASS' : 'FAIL'}`);
    console.log('═══════════════════════════════════════════');
    console.log('');

    exitCode = results.pass ? 0 : 1;
  } catch (err) {
    console.error(`\nFATAL: ${err.message}\n`);
    exitCode = 1;
  } finally {
    if (toneProc) toneProc.kill('SIGTERM');
    if (server) server.close();
  }

  process.exit(exitCode);
}

main();
