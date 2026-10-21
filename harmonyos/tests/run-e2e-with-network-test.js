const { spawn, execSync } = require('child_process');
const http = require('http');
const fs = require('fs');
const path = require('path');

const HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
const TARGET = '127.0.0.1:5555';

// 产物目录：优先使用环境变量 ARTIFACTS_DIR，缺省回退至项目相对目录 test-artifacts
const DEFAULT_ARTIFACTS_DIR = path.resolve(__dirname, '../../test-artifacts');
const ARTIFACTS_DIR = process.env.ARTIFACTS_DIR || DEFAULT_ARTIFACTS_DIR;
const BRAIN_DIR = process.env.BRAIN_DIR || '';

if (!fs.existsSync(ARTIFACTS_DIR)) {
  fs.mkdirSync(ARTIFACTS_DIR, { recursive: true });
}

function hdcExec(cmd, allowFail = false) {
  try {
    return execSync(`${HDC} -t ${TARGET} ${cmd}`, { encoding: 'utf8', timeout: 15000 });
  } catch (err) {
    if (allowFail) {
      return (err.stdout || err.message || '').toString();
    }
    throw new Error(`hdc command failed: ${cmd}\n${err.stderr || err.stdout || err.message}`);
  }
}

const capturedStages = new Set();

function captureArtifacts(stageName) {
  try {
    const remoteJpg = `/data/local/tmp/snap_${stageName}.jpeg`;
    const localJpg = path.join(ARTIFACTS_DIR, `snap_${stageName}.jpeg`);
    
    // 杜绝旧产物复用：捕获前清理远端及本地旧文件
    hdcExec(`shell "rm -f ${remoteJpg}"`, true);
    if (fs.existsSync(localJpg)) {
      try { fs.unlinkSync(localJpg); } catch (_e) {}
    }

    hdcExec(`shell "snapshot_display -f ${remoteJpg}"`);
    hdcExec(`file recv ${remoteJpg} ${localJpg}`);

    if (!fs.existsSync(localJpg)) {
      throw new Error(`Screenshot capture failed for stage ${stageName}: file not received`);
    }

    const imgBuf = fs.readFileSync(localJpg);
    if (imgBuf.length < 1000) {
      throw new Error(`Screenshot capture failed for stage ${stageName}: size is ${imgBuf.length} bytes (< 1000)`);
    }

    // 严密验证 JPEG 魔数格式 [0xFF, 0xD8, 0xFF]
    if (imgBuf[0] !== 0xFF || imgBuf[1] !== 0xD8 || imgBuf[2] !== 0xFF) {
      throw new Error(`Screenshot for stage ${stageName} is not a valid JPEG format (magic: ${imgBuf.slice(0, 3).toString('hex')})`);
    }

    const localLayout = path.join(ARTIFACTS_DIR, `layout_${stageName}.json`);
    if (fs.existsSync(localLayout)) {
      try { fs.unlinkSync(localLayout); } catch (_e) {}
    }

    // 清理远端旧 layout 文件以确保获取当前即时 dump
    hdcExec('shell "rm -f /data/local/tmp/layout_*.json"', true);
    hdcExec(`shell "uitest dumpLayout"`);
    const out = hdcExec(`shell "ls -t /data/local/tmp/layout_*.json | head -n 1"`).trim();
    if (!out) {
      throw new Error(`uitest dumpLayout returned no file for stage ${stageName}`);
    }
    hdcExec(`file recv ${out} ${localLayout}`);

    if (!fs.existsSync(localLayout) || fs.statSync(localLayout).size < 100) {
      throw new Error(`Layout dump failed for stage ${stageName}: size is ${fs.existsSync(localLayout) ? fs.statSync(localLayout).size : 0} bytes`);
    }

    // 严密校验布局树有效性
    const layoutContent = fs.readFileSync(localLayout, 'utf8');
    const parsedLayout = JSON.parse(layoutContent);
    if (!parsedLayout || !parsedLayout.children || parsedLayout.children.length === 0) {
      throw new Error(`Layout hierarchy empty for stage ${stageName}`);
    }

    // 若环境变量显式配置了 BRAIN_DIR 目录，镜像同步一份
    if (BRAIN_DIR && fs.existsSync(BRAIN_DIR)) {
      try {
        fs.copyFileSync(localJpg, path.join(BRAIN_DIR, `snap_${stageName}.jpeg`));
        fs.copyFileSync(localLayout, path.join(BRAIN_DIR, `layout_${stageName}.json`));
      } catch (_e) {}
    }

    capturedStages.add(stageName);
    console.log(`[ARTIFACTS] Verified capture for stage [${stageName}]: snap=${imgBuf.length}B (JPEG valid), layout=${fs.statSync(localLayout).size}B`);
  } catch (e) {
    console.error(`[ARTIFACTS ERROR] Failed capturing stage ${stageName}:`, e.message);
    ensureCleanup();
    process.exit(1);
  }
}

// 进程退出与信号统一清理
let isCleanedUp = false;
let hilogProc = null;
let testProc = null;
let echoServer = null;

function ensureCleanup() {
  if (isCleanedUp) return;
  isCleanedUp = true;
  console.log('[COORDINATOR] Executing ensureCleanup: terminating watchers & restoring port 9199...');
  try {
    if (hilogProc && !hilogProc.killed) {
      hilogProc.kill('SIGTERM');
    }
  } catch (_e) {}
  try {
    if (testProc && !testProc.killed) {
      testProc.kill('SIGTERM');
    }
  } catch (_e) {}
  try {
    if (echoServer) {
      echoServer.close();
    }
  } catch (_e) {}
  try {
    execSync(`${HDC} -t ${TARGET} rport tcp:9199 tcp:9199`, { timeout: 5000, stdio: 'ignore' });
    console.log('[COORDINATOR] Successfully ensured reverse port 9199 is active');
  } catch (e) {
    console.error('[COORDINATOR] Warning: failed restoring rport 9199 in cleanup:', e.message);
  }
}

process.on('exit', ensureCleanup);
process.on('SIGINT', () => { ensureCleanup(); process.exit(130); });
process.on('SIGTERM', () => { ensureCleanup(); process.exit(143); });
process.on('uncaughtException', (err) => {
  console.error('[COORDINATOR UNCAUGHT EXCEPTION]', err);
  ensureCleanup();
  process.exit(1);
});

// 1. 启动 9198 原生 RCP PATCH 回显验证服务
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
      fs.appendFileSync(path.join(ARTIFACTS_DIR, 'patch-echo-receipt.jsonl'), JSON.stringify(record) + '\n');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, received: record }));
    });
  });
  echoServer.listen(9198, '127.0.0.1');
  console.log('[COORDINATOR] Echo server listening on 127.0.0.1:9198');
} catch (e) {
  console.log('[COORDINATOR] Echo server notice:', e.message);
}

// 2. 清理并初始化反向端口转发规则
console.log('[COORDINATOR] Resetting reverse port forwards...');
hdcExec('fport rm tcp:9198 tcp:9198', true);
hdcExec('rport tcp:9198 tcp:9198');
hdcExec('fport rm tcp:9199 tcp:9199', true);
hdcExec('rport tcp:9199 tcp:9199');

// 3. 清理设备 hilog 缓冲区
hdcExec('shell "hilog -r"');

// 4. 实时监听应用与单测阶段事件
console.log('[COORDINATOR] Starting hilog watcher...');
hilogProc = spawn(HDC, ['-t', TARGET, 'shell', 'hilog', '-T', 'ChatApprovalUiTest']);
let hasDisconnected = false;
let hasReconnected = false;
let currentPromptTag = '';

hilogProc.stdout.on('data', (data) => {
  const text = data.toString();

  const tagMatch = text.match(/PROMPT_TAG:\s*([A-Za-z0-9_]+)/);
  if (tagMatch) {
    currentPromptTag = tagMatch[1];
    console.log(`[COORDINATOR] Tracking test prompt tag: ${currentPromptTag}`);
  }

  if (text.includes('PHASE: CAPTURE_STAGE_01_APPROVAL_CARD')) {
    captureArtifacts('01_approval_card');
  }

  if (text.includes('PHASE: CAPTURE_STAGE_02_EXACT_REPLY')) {
    captureArtifacts('02_exact_reply');
  }

  if (text.includes('PHASE: CAPTURE_STAGE_03_AFTER_LIFECYCLE')) {
    captureArtifacts('03_after_real_lifecycle');
  }

  if (text.includes('PHASE: CAPTURE_STAGE_04_BEFORE_DISCONNECT')) {
    captureArtifacts('04_before_disconnect');
  }

  if (text.includes('PHASE: DISCONNECT_TRIGGER_READY') && !hasDisconnected) {
    hasDisconnected = true;
    console.log('\n[COORDINATOR] Received DISCONNECT_TRIGGER_READY! Removing reverse port 9199...');
    const rmRes = hdcExec('fport rm tcp:9199 tcp:9199', true);
    console.log('[COORDINATOR] Remove port 9199 result:', rmRes.trim());
  }

  if (text.includes('PHASE: CAPTURE_STAGE_05_DURING_DISCONNECT')) {
    captureArtifacts('05_during_disconnect');
  }

  if (text.includes('PHASE: DISCONNECT_VERIFIED_NOW_RECONNECT') && !hasReconnected) {
    hasReconnected = true;
    console.log('\n[COORDINATOR] Received DISCONNECT_VERIFIED_NOW_RECONNECT! Restoring reverse port 9199...');
    const addRes = hdcExec('rport tcp:9199 tcp:9199');
    console.log('[COORDINATOR] Restore port 9199 result:', addRes.trim());
    console.log('[COORDINATOR] Active fports:', hdcExec('fport ls', true).trim());
  }

  if (text.includes('PHASE: CAPTURE_STAGE_06_RECONNECTED_HISTORY')) {
    captureArtifacts('06_reconnected_history');
  }
});

// 5. 执行真实设备 aa test 命令
console.log('[COORDINATOR] Launching aa test on device...');
const testCmd = 'aa test -b com.uzairansaruzi.hermex.harmony -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 180000';
testProc = spawn(HDC, ['-t', TARGET, 'shell', testCmd]);

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
  ensureCleanup();

  // 严格核验测试结果与关键阶段
  const passMatch = testOutput.match(/Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+)/);
  if (passMatch) {
    const total = parseInt(passMatch[1]);
    const failures = parseInt(passMatch[2]);
    const errors = parseInt(passMatch[3]);
    const passed = parseInt(passMatch[4]);
    console.log(`[COORDINATOR] Summary: total=${total}, pass=${passed}, failures=${failures}, errors=${errors}`);

    const expectedStages = [
      '01_approval_card',
      '02_exact_reply',
      '03_after_real_lifecycle',
      '04_before_disconnect',
      '05_during_disconnect',
      '06_reconnected_history'
    ];
    const missingStages = expectedStages.filter(s => !capturedStages.has(s));

    if (failures === 0 && errors === 0 && passed >= 4 && total >= 4 && hasDisconnected && hasReconnected && missingStages.length === 0) {
      console.log('✅ ALL TEST SCENARIOS PASSED WITH ZERO FAILURES, ZERO ERRORS, ALL PHASES AND VERIFIED ARTIFACTS!');
      process.exit(0);
    } else {
      console.error(`❌ TEST FAILED CRITERIA: failures=${failures}, errors=${errors}, passed=${passed}, hasDisconnected=${hasDisconnected}, hasReconnected=${hasReconnected}, missingStages=${missingStages.join(',')}`);
      process.exit(1);
    }
  } else {
    console.error('❌ Could not parse test report summary from output');
    process.exit(1);
  }
});
