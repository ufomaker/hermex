const { spawn, execSync } = require('child_process');
const http = require('http');
const fs = require('fs');
const path = require('path');

const HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
const TARGET = '127.0.0.1:5555';
const ARTIFACT_DIR = '/Users/aplier/.gemini/antigravity-cli/brain/5b72ac7d-4237-482f-aedb-fe8176790aea';

function hdcExec(cmd) {
  try {
    return execSync(`${HDC} -t ${TARGET} ${cmd}`, { encoding: 'utf8', timeout: 15000 });
  } catch (err) {
    return (err.stdout || err.message || '').toString();
  }
}

function captureArtifacts(stageName) {
  try {
    const remoteJpg = `/data/local/tmp/snap_${stageName}.jpeg`;
    const localJpg = path.join(ARTIFACT_DIR, `snap_${stageName}.jpeg`);
    hdcExec(`shell "snapshot_display -f ${remoteJpg}"`);
    hdcExec(`file recv ${remoteJpg} ${localJpg}`);

    const localLayout = path.join(ARTIFACT_DIR, `layout_${stageName}.json`);
    hdcExec(`shell "uitest dumpLayout"`);
    const out = hdcExec(`shell "ls -t /data/local/tmp/layout_*.json | head -n 1"`).trim();
    if (out) {
      hdcExec(`file recv ${out} ${localLayout}`);
    }
    console.log(`[ARTIFACTS] Captured screenshot and layout for stage: ${stageName}`);
  } catch (e) {
    console.warn(`[ARTIFACTS] Warning capturing stage ${stageName}:`, e.message);
  }
}

// 1. Start Echo Server on 9198 if not already running
let echoServer = null;
try {
  echoServer = http.createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      const record = {
        timestamp: new Date().toISOString(),
        method: req.method,
        url: req.url,
        headers: req.headers,
        body: body
      };
      console.log('[ECHO_RECEIVED]', JSON.stringify(record));
      fs.appendFileSync('/tmp/patch-echo-receipt.jsonl', JSON.stringify(record) + '\n');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, received: record }));
    });
  });
  echoServer.listen(9198, '127.0.0.1');
  console.log('[COORDINATOR] Echo server listening on 127.0.0.1:9198');
} catch (e) {
  console.log('[COORDINATOR] Echo server notice:', e.message);
}

// 2. Ensure initial reverse port forwardings are clean and active
console.log('[COORDINATOR] Resetting reverse port forwards...');
hdcExec('fport rm tcp:9198 tcp:9198');
hdcExec('rport tcp:9198 tcp:9198');
hdcExec('fport rm tcp:9199 tcp:9199');
hdcExec('rport tcp:9199 tcp:9199');

// 3. Clear hilog buffer
hdcExec('shell "hilog -r"');

// 4. Start hilog watcher in real-time
console.log('[COORDINATOR] Starting hilog watcher...');
const hilogProc = spawn(HDC, ['-t', TARGET, 'shell', 'hilog', '-T', 'ChatApprovalUiTest']);
let hasDisconnected = false;
let hasReconnected = false;

hilogProc.stdout.on('data', (data) => {
  const text = data.toString();

  if (text.includes('Step 6: Real approval card detected') && !hasDisconnected) {
    captureArtifacts('01_approval_card');
  }

  if (text.includes('Step 7 PASS:') && !hasDisconnected) {
    captureArtifacts('02_exact_reply');
  }

  if (text.includes('Step 8 PASS:') && !hasDisconnected) {
    captureArtifacts('03_after_real_lifecycle');
  }

  if (text.includes('PHASE: DISCONNECT_TRIGGER_READY') && !hasDisconnected) {
    hasDisconnected = true;
    console.log('\n[COORDINATOR] Received DISCONNECT_TRIGGER_READY! Removing reverse port 9199...');
    captureArtifacts('04_before_disconnect');
    const rmRes = hdcExec('fport rm tcp:9199 tcp:9199');
    console.log('[COORDINATOR] Remove port 9199 result:', rmRes.trim());
  }

  if (text.includes('PHASE: DISCONNECT_VERIFIED_NOW_RECONNECT') && !hasReconnected) {
    hasReconnected = true;
    console.log('\n[COORDINATOR] Received DISCONNECT_VERIFIED_NOW_RECONNECT! Restoring reverse port 9199...');
    captureArtifacts('05_during_disconnect');
    const addRes = hdcExec('rport tcp:9199 tcp:9199');
    console.log('[COORDINATOR] Restore port 9199 result:', addRes.trim());
    console.log('[COORDINATOR] Active fports:', hdcExec('fport ls').trim());
  }

  if (text.includes('Step 9.2 PASS:')) {
    captureArtifacts('06_reconnected_history');
  }
});

// 5. Execute aa test
console.log('[COORDINATOR] Launching aa test on device...');
const testCmd = 'aa test -b com.uzairansaruzi.hermex.harmony -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 120000';
const testProc = spawn(HDC, ['-t', TARGET, 'shell', testCmd]);

let testOutput = '';
testProc.stdout.on('data', (d) => {
  const str = d.toString();
  testOutput += str;
  process.stdout.write(str);
});
testProc.stderr.on('data', (d) => {
  const str = d.toString();
  testOutput += str;
  process.stderr.write(str);
});

testProc.on('close', (code) => {
  console.log(`\n[COORDINATOR] aa test process closed with exit code ${code}`);
  hilogProc.kill();
  if (echoServer) {
    try { echoServer.close(); } catch (_e) {}
  }

  // Always ensure reverse ports are restored
  console.log('[COORDINATOR] Final cleanup: Ensuring port 9199 is active...');
  hdcExec('rport tcp:9199 tcp:9199');

  // Verify results
  const passMatch = testOutput.match(/Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+)/);
  if (passMatch) {
    const total = parseInt(passMatch[1]);
    const failures = parseInt(passMatch[2]);
    const errors = parseInt(passMatch[3]);
    const passed = parseInt(passMatch[4]);
    console.log(`[COORDINATOR] Summary: total=${total}, pass=${passed}, failures=${failures}, errors=${errors}`);
    if (failures === 0 && errors === 0 && passed > 0) {
      console.log('✅ ALL TEST SCENARIOS PASSED WITH ZERO FAILURES AND ZERO ERRORS!');
      process.exit(0);
    } else {
      console.error('❌ TEST FAILED WITH FAILURES OR ERRORS');
      process.exit(1);
    }
  } else {
    console.error('❌ Could not parse test report summary from output');
    process.exit(1);
  }
});
