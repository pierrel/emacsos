// Browser integration checks and downloadable contact sheets, using bundled fonts.
import { chromium } from './.tools/node_modules/playwright/index.mjs';
import { fileURLToPath } from 'node:url';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
const root=path.dirname(fileURLToPath(import.meta.url));
const executable=process.env.TYPE_STUDY_CHROMIUM;
if(!executable) throw new Error('Set TYPE_STUDY_CHROMIUM to your local Chromium executable.');
const browser=await chromium.launch({executablePath:executable,headless:true,args:['--no-sandbox']});
try {
 const page=await browser.newPage({viewport:{width:1584,height:1100},deviceScaleFactor:1});
 const failures=[]; const remote=[];
 page.on('pageerror',e=>failures.push(e.message));
 page.on('request',r=>{if(!r.url().startsWith('file:')&&!r.url().startsWith('data:'))remote.push(r.url());});
 const base='file://'+path.join(root,'index.html');
 await page.goto(base);
 await page.evaluate(()=>window.fontsReady);
 if(await page.locator('.phone').count()!==8) throw new Error('Expected eight directions');
 const geometry=await page.locator('.phone').evaluateAll(els=>els.map(el=>({width:el.offsetWidth,height:el.offsetHeight,keyboard:el.querySelector('.keyboard').offsetHeight,buffer:el.querySelector('.buffer').offsetHeight})));
 if(geometry.some(g=>g.width!==360||g.height!==720||g.keyboard!==300||g.buffer!==397)) throw new Error('Unexpected source-derived geometry: '+JSON.stringify(geometry));
 const manifest=JSON.parse(await readFile(path.join(root,'font-manifest.json'),'utf8'));
 for(const item of manifest.assets){const {createHash}=await import('node:crypto');const hash=createHash('sha256').update(await readFile(path.join(root,item.file))).digest('hex');if(hash!==item.sha256)throw new Error('Asset hash mismatch: '+item.file);}
 for(const view of ['chat','sms','network','code','reading','glyphs']) {
   await page.selectOption('#view',view);
   if(await page.locator(`.buffer.${view}`).count()!==8)throw new Error('View did not update: '+view);
 }
 await page.selectOption('#focus','plex');
 if(await page.locator('.phone').count()!==2)throw new Error('Baseline A/B did not narrow to two phones');
 await page.selectOption('#weight','600');
 await page.locator('#size').fill('20');
 await page.locator('#leading').fill('1.45');
 await page.locator('#tracking').fill('0.2');
 await page.selectOption('#theme','light');
 await page.selectOption('#keyboard','hidden');
 if(await page.locator('.keyboard').first().evaluate(el=>getComputedStyle(el).display)!=='none')throw new Error('Keyboard hide failed');
 const changed=await page.locator('.buffer').first().evaluate(el=>({size:getComputedStyle(el).fontSize,weight:getComputedStyle(el).fontWeight,spacing:getComputedStyle(el).letterSpacing,line:getComputedStyle(el).lineHeight}));
 if(changed.size!=='20px'||changed.weight!=='600'||changed.spacing!=='0.2px'||changed.line!=='29px')throw new Error('Controls not applied: '+JSON.stringify(changed));
 await page.reload();await page.evaluate(()=>window.fontsReady);
 if(await page.locator('.phone').count()!==2||await page.locator('#size').inputValue()!=='20')throw new Error('Shareable state did not survive reload');
 await page.click('#reset');
 if(await page.locator('.phone').count()!==8||await page.locator('#size').inputValue()!=='18')throw new Error('Reset failed');
 const shots=[['chat-dark','chat','dark','visible'],['chat-light','chat','light','visible'],['sms','sms','dark','visible'],['network','network','dark','visible'],['code','code','dark','visible'],['reading','reading','light','hidden'],['glyphs','glyphs','light','hidden']];
 for(const [name,view,theme,keyboard]of shots){
   await page.goto(base+`?capture=1&view=${view}&theme=${theme}&keyboard=${keyboard}`);
   await page.evaluate(()=>window.fontsReady);
   await page.screenshot({path:path.join(root,'screenshots',name+'.png'),fullPage:true});
 }
 await page.goto(base);await page.evaluate(()=>window.fontsReady);
 await page.screenshot({path:path.join(root,'screenshots','interactive.png'),fullPage:true});
 const phonePage=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:2});
 await phonePage.goto(base);await phonePage.evaluate(()=>window.fontsReady);
 if(await phonePage.evaluate(()=>document.documentElement.scrollWidth>innerWidth))throw new Error('Preview page has horizontal overflow at mobile width');
 for(const d of ['droid','plex','inter','source','atkinson','geist','manrope','serif'])await phonePage.locator(`[data-direction="${d}"] .phone`).screenshot({path:path.join(root,'screenshots',d+'-phone.png')});
 if(failures.length||remote.length)throw new Error(JSON.stringify({failures,remote}));
 const evidence={geometry,controls:changed,directions:8,views:6,contactSheets:7,individualPhoneImages:8,assetHashes:manifest.assets.length,pageErrors:failures,remoteRequests:remote,rendering:'Chromium browser approximation. Source-derived geometry; actual Emacs metrics unavailable.'};
 await writeFile(path.join(root,'checks.json'),JSON.stringify(evidence,null,2)+'\n');
 console.log(JSON.stringify(evidence));
} finally { await browser.close(); }
