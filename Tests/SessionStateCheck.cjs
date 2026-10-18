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
assert.match(ui, /var startingId = null/);
assert.match(app, /connection\(live, starting, roleName, message, peerId\)/);
assert.match(ui, /isStarting \? '<i style="background: var\(--orange\)"><\/i><span>正在启动画面<\/span>'/);
assert.match(ui, /startingId \? '正在启动，等待首帧' : '等待连接'/);

console.log('PASS: media presentation waits for the first decoded frame acknowledgment.');
