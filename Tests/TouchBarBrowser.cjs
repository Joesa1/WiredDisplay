// Browser fixtures only; no simulated state is bundled in the runtime page.
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
  const page = await browser.newPage();
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  let authorized=true, commands=[], stateRequests=0;
  const config={musicEnabled:true,agentsEnabled:true,weatherEnabled:true,appsEnabled:true,controlsEnabled:true};
  const state={host:'Test Mac',config,apps:Array.from({length:210},(_,i)=>({id:'app'+i,name:i===0?'<img src=x onerror=alert(1)>':'Application '+i,running:i<2,active:i===0})),music:{available:true,title:'Test Track',artist:'Artist',album:'Album',playing:true,position:20,duration:180},agents:{available:true,message:'',items:[{id:'a',name:'Codex',status:'working',detail:'Local task'}]},weather:{available:true,city:'Test City',temperature:22,high:24,low:15,description:'晴',attribution:'Open-Meteo'},controls:{volumeAvailable:true,volume:42,brightnessAvailable:false,accessibility:false,message:'Brightness unavailable'}};
  await page.route('http://touch.test/**',async route=>{
    const url=new URL(route.request().url());
    if(url.pathname==='/api/pair')return route.fulfill({json:{token:'test-token'}});
    if(url.pathname==='/api/state'){stateRequests++;return route.fulfill({status:authorized?200:401,json:authorized?state:{message:'Unauthorized'}});}
    if(url.pathname==='/api/command'){commands.push(route.request().postDataJSON());return route.fulfill({json:{ok:true,message:'Command accepted'}});}
    return route.fulfill({contentType:'text/html',body:fs.readFileSync(path.join(__dirname,'../Resources/touch-bar.html'),'utf8')});
  });
  await page.goto('http://touch.test/');assert(await page.locator('#pair').isVisible());await page.fill('#pair-code','123456');await page.click('#pair-submit');await page.waitForSelector('#pair',{state:'hidden'});
  assert.equal(await page.locator('#track-title').textContent(),'Test Track');assert(await page.locator('#brightness').isDisabled());assert(await page.locator('[data-action="key.desktop"]').isDisabled());
  assert.equal(await page.locator('#dock-apps img').count(),0);assert(await page.locator('#dock-apps button').first().getAttribute('aria-label').then(x=>x.includes('<img')));
  for(const [width,height] of [[844,390],[667,375],[568,320]]){await page.setViewportSize({width,height});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));const rect=await page.locator('#controls-card').boundingBox();assert(rect.y+rect.height<=height,`Controls overflow at ${width}x${height}: ${JSON.stringify(rect)}`);}
  await page.click('#toggle-play');assert.equal(commands[0].action,'music.playPause');await page.click('#open-launcher');await page.fill('#app-search','Application 209');assert.equal(await page.locator('#app-grid button').count(),1);await page.click('#close-launcher');
  state.music.available=false;state.music.permissionRequired=true;await page.waitForFunction(()=>document.getElementById('toggle-play').getAttribute('aria-label')==='授权并播放');assert(await page.locator('#toggle-play').isEnabled());
  for(const key in config)config[key]=false;await page.waitForSelector('#all-off:not([hidden])');assert(await page.locator('#dashboard').isHidden());
  authorized=false;await page.waitForSelector('#pair:not([hidden])');assert.equal(await page.evaluate(()=>localStorage.getItem('thunder-touch-bar-token')),null);const count=commands.length;await page.waitForTimeout(1200);assert.equal(commands.length,count);
  const desktop=await browser.newPage();await desktop.addInitScript(()=>{window.nativeCalls=[];window.webkit={messageHandlers:{thunderDisplay:{postMessage:m=>window.nativeCalls.push(m)}}};});await desktop.goto('file://'+path.resolve(__dirname,'../Resources/mvp-ui-prototype.html'));await desktop.click('[data-page="touch-bar"]');assert(await desktop.locator('#touch-bar').isVisible());assert.equal(await desktop.locator('#toolbar-title').textContent(),'Touch Bar');assert(await desktop.evaluate(()=>nativeCalls.some(m=>m.action==='touchBar'&&m.operation==='status')));
  await desktop.evaluate(()=>ThunderTouchBar.receive({enabled:true,url:'http://192.168.1.2:8765',code:'123456',config:{city:'Initial'}}));await desktop.fill('[name="city"]','Edited');await desktop.evaluate(()=>ThunderTouchBar.receive({enabled:true,config:{city:'Clobbered'}}));assert.equal(await desktop.inputValue('[name="city"]'),'Edited');await desktop.click('#tb-enable');assert(await desktop.evaluate(()=>nativeCalls.some(m=>m.operation==='disable')));
  assert.deepEqual(await desktop.locator('#transmission-mode option').evaluateAll(options=>options.map(o=>o.value)), ['lowLatency','fidelity','lossless','demo1','demo2']);
  await desktop.click('[data-page="settings"]');
  assert(await desktop.locator('#touch-bar').isHidden());
  assert.deepEqual(errors,[]);assert(stateRequests>0);await browser.close();console.log('Touch Bar browser checks passed (3 landscape sizes, pairing, state, controls, commands, search, all-off, revocation, desktop settings).');
})().catch(error=>{console.error(error);process.exit(1);});
