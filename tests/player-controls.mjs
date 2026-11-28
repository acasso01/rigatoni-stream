// Tap-to-show controls (never pause) and one volume/mute state for every engine, incl. the WebCodecs canvas.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const read=f=>fs.readFileSync(new URL('../'+f,import.meta.url),'utf8');
// ---- tiny DOM: just enough for web/player.js ----
class Ev{constructor(type,target){this.type=type;this.target=target;this.stopped=false}stopPropagation(){this.stopped=true}preventDefault(){}}
class Node{
  constructor(tag){this.tagName=tag.toUpperCase();this.children=[];this.parentNode=null;this.attrs={};this.listeners={};this.style={setProperty(k,v){this[k]=v}};this.hidden=false;this.innerHTML='';this.textContent='';
    const set=new Set();this.classList={add:(...c)=>c.forEach(x=>set.add(x)),remove:(...c)=>c.forEach(x=>set.delete(x)),contains:c=>set.has(c),toggle:(c,f)=>{const on=f===undefined?!set.has(c):!!f;on?set.add(c):set.delete(c);return on}};}
  set className(v){String(v).split(/\s+/).filter(Boolean).forEach(c=>this.classList.add(c))}
  append(...c){for(const x of c){x.parentNode?.children.splice(x.parentNode.children.indexOf(x),1);x.parentNode=this;this.children.push(x)}}
  before(x){const p=this.parentNode;x.parentNode=p;p.children.splice(p.children.indexOf(this),0,x)}
  remove(){if(this.parentNode){this.parentNode.children.splice(this.parentNode.children.indexOf(this),1);this.parentNode=null}}
  setAttribute(k,v){this.attrs[k]=String(v)}getAttribute(k){return this.attrs[k]??null}removeAttribute(k){delete this.attrs[k]}
  addEventListener(t,f,cap){(this.listeners[t]??=[]).push({f,cap:!!cap})}removeEventListener(t,f){this.listeners[t]=(this.listeners[t]||[]).filter(x=>x.f!==f)}
  closest(sel){const tags=sel.split(',').map(s=>s.trim());for(let n=this;n&&n.tagName;n=n.parentNode){for(const t of tags){if(t.startsWith('.')?n.classList.contains(t.slice(1)):n.tagName===t.toUpperCase())return n}}return null}
  getContext(){return {drawImage(){}}}
  get onclick(){return this._onclick}set onclick(f){this._onclick=f}
}
const doc=new Node('#document');doc.readyState='complete';doc.activeElement=null;doc.body=new Node('body');doc.head=new Node('head');
const byId=new Map();doc.getElementById=id=>byId.get(id)||null;doc.createElement=t=>new Node(t);
const mk=(tag,id,parent)=>{const n=new Node(tag);n.id=id;byId.set(id,n);parent?.append(n);return n};
const watch=mk('div','watch',doc.body);const stage=mk('div','stage',watch);stage.classList.add('ant-stage');
const video=mk('video','video',stage);video.attrs.controls='';video.controls=true;video.paused=false;video.muted=false;video.volume=1;video.currentTime=0;video.duration=NaN;video.videoHeight=720;
const calls=[];video.pause=()=>{calls.push('pause');video.paused=true};video.play=()=>{calls.push('play');video.paused=false;return Promise.resolve()};video.load=()=>{};video.canPlayType=()=>'';
const bar=mk('div','watchbar',stage);const close=mk('button','close',bar);mk('div','playstatus',stage);
// Dispatch: capture listeners on document first, then bubble target → document (like a real tap).
function fire(type,target,extra={}){const e=Object.assign(new Ev(type,target),extra);
  for(const l of doc.listeners[type]||[])if(l.cap)l.f(e);
  for(let n=target;n&&!e.stopped;n=n.parentNode){if(type==='click'&&n._onclick)n._onclick(e);for(const l of n.listeners[type]||[])if(!l.cap||n!==doc)l.f(e)}
  return e}
const storage=new Map();
const ctx=vm.createContext({document:doc,localStorage:{getItem:k=>storage.has(k)?storage.get(k):null,setItem:(k,v)=>storage.set(k,String(v))},navigator:{userAgent:'Mozilla/5.0 Chrome Tesla/2026.44'},isSecureContext:true,MediaSource:function(){},setTimeout,clearTimeout,setInterval:()=>0,requestAnimationFrame:()=>0,performance,AbortController});
ctx.globalThis=ctx;
for(const f of ['web/titles.js','web/fmp4.js','web/webcodecs.js','web/player.js'])vm.runInContext(read(f),ctx);
const P=ctx.AntPlayer,A=ctx.AntAudio;
assert.ok(P&&A,'player + audio exported');
assert.equal(video.controls,false,'native controls removed (their tap-to-pause is gone)');assert.equal(video.getAttribute('controls'),null);
P.track({kind:'movie',stream_id:1,name:'Dune'});
const find=cls=>{const out=[];const walk=n=>{if(n.classList?.contains(cls))out.push(n);n.children.forEach(walk)};walk(stage);return out[0]};
const toggle=find('ant-play'),mute=find('ant-volwrap').children[0],vol=find('ant-vol'),sound=find('ant-sound');
assert.ok(toggle&&mute&&vol&&sound,'overlay has pause, mute, volume slider, tap-for-sound');
// ---- 1. tapping the picture never pauses; it toggles the overlay ----
stage.classList.remove('ant-idle');
fire('click',video);assert.deepEqual(calls,[],'tap on <video> does not pause');assert.ok(stage.classList.contains('ant-idle'),'tap with controls showing hides them');
fire('click',video);assert.deepEqual(calls,[],'tap does not play/pause');assert.ok(!stage.classList.contains('ant-idle'),'tap while hidden shows controls');
const canvas=new Node('canvas');stage.append(canvas);
fire('click',canvas);fire('click',canvas);assert.deepEqual(calls,[],'tap on the canvas engine does not pause');
fire('click',stage);assert.deepEqual(calls,[],'tap on the stage does not pause');
fire('pointermove',video,{pointerType:'touch'});fire('click',video);assert.deepEqual(calls,[]);
// ---- 2. only the pause button pauses ----
fire('click',toggle);assert.deepEqual(calls,['pause'],'pause button pauses');
fire('click',video);assert.deepEqual(calls,['pause'],'tap while paused does not resume');
fire('click',toggle);assert.deepEqual(calls,['pause','play'],'play button resumes');
console.log('PASS tap: picture/canvas taps only show or hide the controls; only the pause button pauses');
// ---- 3. volume + mute apply to the element and persist ----
vol.value='40';fire('input',vol);vol.oninput();
assert.equal(video.volume,0.4);assert.equal(storage.get('ant-volume'),'0.4');assert.equal(video.muted,false);
fire('click',mute);assert.equal(video.muted,true,'mute button mutes');assert.equal(storage.get('ant-muted'),'1');assert.equal(mute.getAttribute('aria-label'),'Unmute');
fire('click',mute);assert.equal(video.muted,false,'mute button unmutes');assert.equal(storage.get('ant-muted'),'0');
fire('click',mute);vol.value='70';vol.oninput();assert.equal(video.muted,false,'moving the slider unmutes');assert.equal(video.volume,0.7);
console.log('PASS volume: slider and mute drive the element and persist');
// ---- 4. blocked autoplay starts muted; the first tap anywhere turns sound on ----
let tries=0;video.play=()=>{tries++;if(!video.muted)return Promise.reject(Object.assign(Error('blocked'),{name:'NotAllowedError'}));video.paused=false;return Promise.resolve()};
video.addEventListener=(t,f)=>{if(t==='playing')setTimeout(f,5)};
assert.ok(P.__test?.VideoEngine,'VideoEngine exposed for tests');
const ve=new P.__test.VideoEngine(video,'native');await ve.start(1000);
await new Promise(r=>setTimeout(r,10));
assert.equal(tries,2,'retried muted after NotAllowedError');assert.equal(video.muted,true);assert.equal(A.autoMuted,true);assert.equal(sound.hidden,false,'"Tap for sound" shows');
fire('pointerup',video);assert.equal(A.autoMuted,false);assert.equal(video.muted,false,'first tap unmutes');assert.equal(sound.hidden,true);
// tapping the mute icon while auto-muted means "sound on", not "mute"
A.autoMuted=true;A.emit();fire("pointerup",mute);fire("click",mute);assert.equal(video.muted,false,'mute icon while auto-muted turns sound on');
console.log('PASS autoplay: blocked sound starts muted, first tap (or the speaker icon) unmutes');
// ---- 5. canvas engine: gain follows volume/mute, shared AudioContext, no queuing while suspended ----
class Param{constructor(){this.value=1}setValueAtTime(v){this.value=v}}
class FakeCtx{constructor(){this.state='suspended';this.currentTime=0;this.destination={};this.l=[];this.started=0}
  createGain(){return {gain:new Param(),connect(){},disconnect(){this.off=true}}}
  createBuffer(){return {copyToChannel(){}}}createBufferSource(){const c=this;return {connect(){},start(){c.started++},stop(){}}}
  addEventListener(t,f){this.l.push(f)}removeEventListener(){}resume(){this.state='running';this.l.forEach(f=>f());return Promise.resolve()}suspend(){this.state='suspended';return Promise.resolve()}close(){this.closed=true}}
const shared=new FakeCtx();
ctx.AudioDecoder=class{static isConfigSupported(){return Promise.resolve({supported:true})}configure(){}};ctx.AudioDecoder.prototype.state='configured';
ctx.VideoDecoder=class{static isConfigSupported(){return Promise.resolve({supported:true})}configure(){}};
const CE=new ctx.AntCanvasEngine.CanvasEngine(new Node('div'),{live:true,audio:{context:()=>shared,volume:0.3,muted:false}});
shared.resume=function(){return Promise.resolve()};// stays suspended: like Tesla before the first tap
await CE._init({tracks:new Map([[1,{kind:'video',codec:'avc1.64001f',width:1280,height:720}],[2,{kind:'audio',codec:'mp4a.40.2',sampleRate:48000,channels:2}]])});
assert.equal(CE.actx,shared,'canvas uses the shared AudioContext');assert.equal(CE.gain.gain.value,0.3,'gain starts at saved volume');
assert.equal(CE.audioBlocked,true,'suspended context reports blocked audio');
CE.base={media:0,wall:performance.now()};
const frame=()=>({timestamp:0,numberOfChannels:2,numberOfFrames:1024,sampleRate:48000,copyTo(){},close(){}});
CE._audio(frame());assert.equal(shared.started,0,'no audio queued on a suspended context');
shared.state='running';shared.l.forEach(f=>f());assert.equal(CE.audioBlocked,false);
CE._audio(frame());assert.equal(shared.started,1,'audio plays once the context runs');
CE.setVolume(0.8);assert.equal(CE.gain.gain.value,0.8);CE.setMuted(true);assert.equal(CE.gain.gain.value,0);CE.setMuted(false);assert.equal(CE.gain.gain.value,0.8);
CE.pause();assert.equal(shared.state,'running','pausing one stream never suspends the shared context');
CE.destroy();assert.ok(!shared.closed,'shared context survives engine teardown');
console.log('PASS canvas audio: shared context, gain = volume/mute, nothing queued while suspended');
