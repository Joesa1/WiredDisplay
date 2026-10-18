const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const app = fs.readFileSync(path.join(root, 'Sources/App.swift'), 'utf8');
const ui = fs.readFileSync(path.join(root, 'Resources/mvp-ui-prototype.html'), 'utf8');

assert.match(app, /prototypeConnection\(live: false, starting: true, message: "已连接，正在启动桌面采集"/);
assert.match(app, /firstFrameAcknowledged = true[\s\S]*?prototypeConnection\(live: true\)/);
assert.match(app, /onFirstImage = \{[\s\S]*?prototypeConnection\(live: true\)/);
assert.match(app, /prototypeConnection\(live: false\)/);
assert.match(app, /prototypeStatus\(message, active: firstFrameAcknowledged \|\| videoWindow != nil\)/);
assert.match(app, /probe \? Wire\.legacyProtocolVersion : Wire\.protocolVersion\(for: transmissionMode\)/);
assert.match(app, /Wire\.allows\(config\.mode, on: protocolVersion\)/);
assert.match(ui, /var startingId = null/);
assert.match(app, /connection\(live, starting, roleName, message, peerId\)/);
assert.match(ui, /isStarting \? '<i style="background: var\(--orange\)"><\/i><span>正在启动画面<\/span>'/);
assert.match(ui, /startingId \? '正在启动，等待首帧' : '等待连接'/);
assert.match(ui, /targetButtons = \['toolbar-connect', 'version-refresh', 'toolbar-test', 'run-test'\]/);
assert.match(ui, /button\.dataset\.address = isLocal \? '' : \(device\.ip \|\| ''\)/);
assert.match(ui, /button\.dataset\.code = isLocal \? '' : \(device\.pairingCode \|\| ''\)/);
assert.doesNotMatch(ui, /<option value="demo[123]">/);
assert.match(ui, /<option value="duet">色彩低延迟 · 10-bit HEVC 有损<\/option>/);
assert.match(app, /case \.cursor:\s*\/\/ ScreenCaptureKit already carries the native cursor[\s\S]*?break/);
assert.doesNotMatch(app, /surface\.setPointer\(pointer\)/);

const bridge = app.match(/private var nativeBridgeScript: String \{\s*"""([\s\S]*?)"""\s*\}/)?.[1] || '';
assert.match(bridge, /const target = \(button\) => \(\{ address: button\.dataset\.address \|\| '', code: button\.dataset\.code \|\| '' \}\)/);
assert.match(bridge, /post\('session', \{[\s\S]*?\.\.\.target\(button\)/);
assert.doesNotMatch(bridge, /localStorage/);
assert.doesNotMatch(bridge, /all\[0\]/);

console.log('PASS: media presentation waits for the first decoded frame acknowledgment and binds each action to the rendered target.');
