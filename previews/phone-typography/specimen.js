'use strict';
const directions = [
  {id:'droid',name:'Droid Sans',sans:'Droid',mono:'DroidMono',label:'Droid Sans Mono',description:'The current family baseline. Familiar, open, and a little uneven beside the newer families.'},
  {id:'plex',name:'IBM Plex Sans',sans:'Plex',mono:'PlexMono',label:'IBM Plex Mono',description:'Precise with a human edge. My first choice for a phone that still feels like Emacs.'},
  {id:'inter',name:'Inter',sans:'Inter',mono:'JetBrains',label:'JetBrains Mono',description:'Clear, restrained, almost invisible. The quietest all-purpose direction.'},
  {id:'source',name:'Source Sans 3',sans:'Source',mono:'SourceMono',label:'Source Code Pro',description:'An easy reading rhythm, open shapes, and more room for words.'},
  {id:'atkinson',name:'Atkinson Hyperlegible Next',sans:'Atkinson',mono:'AtkinsonMono',label:'Atkinson Hyperlegible Mono',description:'Distinct letterforms. Compare I, l, 1 and O, 0 before judging the overall texture.'},
  {id:'geist',name:'Geist',sans:'Geist',mono:'GeistMono',label:'Geist Mono',description:'Crisp and contemporary. A compact, systematic visual voice.'},
  {id:'manrope',name:'Manrope',sans:'Manrope',mono:'JetBrains',label:'JetBrains Mono',description:'Geometric, round, and composed. More visual personality; watch its wider words.'},
  {id:'serif',name:'Source Serif 4',sans:'SourceSerif',mono:'SourceMono',label:'Source Code Pro',description:'An editorial wildcard for long reading. Useful contrast; less convincing for every control.'}
];
const views = {
chat:`<div class="message"><span class="role">you&gt; </span>Give me a simple plan for tomorrow.</div><div class="message"><span class="role">bot&gt; </span>Keep the morning open. Pick one thing that matters, then leave room to walk.</div><h3>A little structure</h3><p>Start at 9:30. Work for an hour, take a break, and decide what deserves the next hour.</p><p>Keep your notes in <code>tomorrow.org</code>.</p><div class="draft">&gt; Make it a little quieter.<span class="cursor"></span></div>`,
sms:`<div class="screen-title">SMS +12025550142</div><div class="message"><span class="role">bot&gt; </span>Meet by the library at 10? I can bring coffee.</div><div class="message"><span class="role">you&gt; </span>Sounds good. The entrance on Oak Street?<span class="suffix"> [sent]</span></div><div class="message"><span class="role">bot&gt; </span>Yes. See you there!</div><div class="draft">&gt; See you at 10.<span class="cursor"></span></div>`,
network:`<div class="network-row">Networks</div><div class="network-row action">Done</div><div class="network-row">* Studio  92%</div><div class="network-row">[lock] Library  78%</div><div class="network-row">Garden Guest  61%</div><div class="network-row">[lock] Oak Street  48%</div><div class="network-row action">Next</div>`,
code:`<pre><span class="dim">;; One useful thing at a time.</span>\n(defun quiet-morning ()\n  (interactive)\n  (find-file "tomorrow.org"))\n\n<span class="dim"># Keep the columns honest.</span>\n$ printf '%s\\n' "ready"\nready\n\nname      size   state\nnotes      128   saved\nplan       064   draft\n\n<span class="dim"># Distinguish the ambiguous.</span>\nI l 1 | O 0 | rn m | {} []\n~/notes/tomorrow.org:14:2\n$ <span class="cursor"></span></pre>`,
reading:`<div class="date">Thursday, 8 October</div><h3>Enough room to think</h3><p>A small screen asks for a little care. A good line should feel easy to enter and easy to leave.</p><p>There is no need to fill every corner. The words can carry the shape of the page: a short heading, an ordinary sentence, a pause.</p><p>Tomorrow, walk to the library. Find a quiet table near the window. Read until the light changes, and write down the one idea that stays with you.</p><h3>Keep one good note</h3><p>A note does not need to explain everything. It can be a useful question, a clear observation, or a small fact you would otherwise forget.</p><p>The rest can wait. Leave enough room for the next thought.</p>`,
glyphs:`<h3>Shapes you live with</h3><div class="glyph-line">I l 1 · O 0 · rn m<br>ag ef rt · 5 S · 8 B</div><p>The quick brown fox jumps over the lazy dog.</p><p>Il était déjà près de l’été.<br>“Clean type”, she said…</p><p>08:45 · 14:30 · 23:59<br>0123456789 · +12025550142</p><h3>Fixed-pitch forms</h3><div class="mono-sample">I l 1 | O 0 | rn m\n{ [ ( ) ] } &lt; &gt; / \\\nfoo_bar = 0x10;\n1.25  10.00  128.50</div>`
};
const controls = ['view','size','weight','leading','tracking','theme','keyboard','focus'];
const defaults = {view:'chat',size:'18',weight:'400',leading:'1.35',tracking:'0',theme:'dark',keyboard:'visible',focus:'all'};
const params = new URLSearchParams(location.search);
for (const d of directions.slice(1)) document.querySelector('#focus').add(new Option(`Droid + ${d.name}`,d.id));
for (const key of controls) {
  const el = document.getElementById(key);
  if(params.has(key)) el.value=params.get(key);
  if(!el.value || (el.tagName==='INPUT' && !Number.isFinite(+el.value))) el.value=defaults[key];
  el.addEventListener('input',render);
}
if(params.has('capture')) document.body.classList.add('capture');
function keyboard() {
  const row=(keys,classes='')=>`<div class="keyrow ${classes}">${keys.map(k=>`<span class="key ${k==='space'?'space':k.length>1?'function':''}">${k==='space'?'':k}</span>`).join('')}</div>`;
  return `<div class="suggest"><span>quiet</span><span>quieter</span><span>quite</span></div>${row(['q','w','e','r','t','y','u','i','o','p'])}${row(['a','s','d','f','g','h','j','k','l'],'offset')}${row(['Shift','z','x','c','v','b','n','m','Del'])}${row(['123','Ctr','Meta','space','Enter'])}`;
}
function render() {
  const state=Object.fromEntries(controls.map(k=>[k,document.getElementById(k).value]));
  const shown=directions.filter(d=>state.focus==='all'||d.id==='droid'||d.id===state.focus);
  document.getElementById('size-value').value=`${state.size}px`;
  document.getElementById('leading-value').value=state.leading;
  document.getElementById('tracking-value').value=`${state.tracking}px`;
  document.getElementById('study-summary').textContent=`${document.querySelector('#view option:checked').textContent} · ${state.size}px prose / ${+state.size-1}px code · ${state.weight} weight · ${state.leading} line height · 360 × 720 logical pixels`;
  document.getElementById('gallery').innerHTML=shown.map(d=>`<article class="card" data-direction="${d.id}"><p class="number">${String(directions.indexOf(d)+1).padStart(2,'0')} / ${d.id==='droid'?'BASELINE FAMILY':'TYPE DIRECTION'}</p><h2>${d.name}</h2><p class="description">${d.description}</p><div class="phone ${state.theme==='light'?'light':''}" style="--sans:${d.sans};--mono:${d.mono};--size:${state.size}px;--mono-size:${+state.size-1}px;--weight:${state.weight};--leading:${state.leading};--tracking:${state.tracking}px"><div class="buffer ${state.view}" tabindex="0" aria-label="${d.name} ${state.view} specimen">${views[state.view]}</div><div class="mode-line">EmacsOS  LTE  ▴  08:45  84%</div><div class="keyboard ${state.keyboard==='hidden'?'hidden':''}" aria-hidden="true">${keyboard()}</div></div><p class="metrics">${d.name} + ${d.label} · ${state.size}/${+state.size-1}px · ${state.weight} · ${state.leading}</p></article>`).join('');
  const next=new URLSearchParams(state);if(params.has('capture')) next.set('capture','1');
  history.replaceState(null,'',`${location.pathname}?${next}`);
  window.specimenState=state;
}
document.getElementById('reset').addEventListener('click',()=>{for(const key of controls) document.getElementById(key).value=defaults[key];render();});
render();
window.fontsReady=Promise.all([...new Set(directions.flatMap(d=>[d.sans,d.mono]))].map(f=>document.fonts.load(`18px ${f}`))).then(fonts=>{
  const missing=fonts.filter(f=>f.length===0).length;
  if(missing) throw new Error(`${missing} font families did not load`);
  document.getElementById('font-status').textContent='All specimen fonts loaded · scroll each screen';
  document.body.dataset.fonts='ready';
}).catch(e=>{document.getElementById('font-status').textContent=`Font load failed: ${e.message}`;document.body.dataset.fonts='failed';throw e;});
