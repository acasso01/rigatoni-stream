import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const scripts=[...fs.readFileSync(new URL('../xtream.html',import.meta.url),'utf8').matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const code=scripts[1];
const nodes=new Map(),get=id=>{if(!nodes.has(id))nodes.set(id,{value:'',textContent:'',classList:{add(){},remove(){},toggle(){}},pause(){},load(){},removeAttribute(){},replaceChildren(){},play:()=>new Promise(()=>{})});return nodes.get(id)};
const timers=new Map();let tid=0;const requests=[];let reply,inspection=null;
const ctx=vm.createContext({document:{getElementById:get,querySelectorAll:()=>[],querySelector:()=>null,documentElement:{setAttribute(){}}},window:{scrollTo(){}},localStorage:{getItem:()=>null},location:{protocol:'https:'},URL,AbortController,setTimeout:(fn,ms)=>{const id=++tid;timers.set(id,{fn,ms});return id},clearTimeout:id=>timers.delete(id),fetch:async(url,options)=>{requests.push({url,options});if(url.includes('/inspect/'))return new Response(JSON.stringify(inspection||{}),{status:inspection?200:404});return typeof reply==='function'?reply():reply}});
vm.runInContext(code,ctx);
vm.runInContext("credentials={base:'http://provider.example.invalid',user:'dummy-user',pass:'dummy-password'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'}",ctx);
const tick=()=>new Promise(r=>setImmediate(r));
const start=()=>{void vm.runInContext("play({stream_id:7,name:'Dummy'})",ctx)};
reply=new Response(JSON.stringify({error:'stream_unavailable'}),{status:502,headers:{'content-type':'application/json'}});
start();get('video').error={code:4};get('video').onerror();await tick();assert.match(get('playstatus').textContent,/Media error 4/);assert.match(get('playstatus').textContent,/provider refused/);
void get('compatible').onclick();assert.match(get('video').src,/\/compatible\/session\/resource\/index\.m3u8$/);vm.runInContext('stopVideo()',ctx);await tick();assert.ok(requests.some(r=>r.options.method==='POST'&&r.url.endsWith('/stop')));
reply=new Response('#EXTM3U\n#EXTINF:4,\n/media/session/segment',{headers:{'content-type':'application/vnd.apple.mpegurl'}});
start();get('video').error={code:2};get('video').onerror();await tick();assert.match(get('playstatus').textContent,/playlist is reachable/);
reply=new Response(JSON.stringify({error:'stream_session_expired'}),{status:401});
start();get('video').error={code:4};get('video').onerror();await tick();assert.match(get('playstatus').textContent,/session expired/);
reply=()=>{throw Error('network')};start();const waiting=[...timers.values()].find(t=>t.ms===20000);assert.ok(waiting);waiting.fn();await tick();assert.match(get('playstatus').textContent,/20 seconds/);assert.match(get('playstatus').textContent,/could not connect/);
inspection={streams:[{type:'video',codec:'hevc',width:3840,height:2160,pixel_format:'yuv420p10le'},{type:'audio',codec:'aac'}]};
reply=new Response('#EXTM3U',{headers:{'content-type':'application/vnd.apple.mpegurl'}});start();get('video').error={code:3};get('video').onerror();await tick();assert.match(get('playstatus').textContent,/HEVC 3840×2160/);assert.match(get('playstatus').textContent,/AAC audio/);
let finish;reply=()=>new Promise(r=>finish=r);start();get('video').error={code:2};get('video').onerror();await tick();get('video').onplaying();finish(new Response('#EXTM3U',{headers:{'content-type':'application/vnd.apple.mpegurl'}}));await tick();assert.equal(get('playstatus').textContent,'Now playing');
vm.runInContext('stopVideo()',ctx);assert.equal(timers.size,0);
// Alternate MMS/MSE path must use only the opaque gateway link and release resources.
let instance;
class FakeHls{
 static Events={ERROR:'error',MANIFEST_PARSED:'manifest',FRAG_BUFFERED:'buffered'};
 static DefaultConfig={manifestLoadPolicy:{default:{timeoutRetry:null,errorRetry:null}}};
 static isSupported(){return true}
 constructor(config){this.config=config;this.handlers={};instance=this}
 on(event,handler){this.handlers[event]=handler}
 loadSource(url){this.url=url}
 attachMedia(video){this.video=video}
 destroy(){this.destroyed=true}
 emit(event,data){this.handlers[event]?.(event,data)}
}
ctx.window.Hls=FakeHls;
get('video').error=null;
await vm.runInContext("play({stream_id:7,name:'Dummy'},false,true)",ctx);
assert.equal(instance.url,'https://homepi.test.ts.net/media/session/resource');
assert.equal(instance.config.preferManagedMediaSource,true);
assert.equal(instance.config.maxBufferSize,32*1024*1024);
assert.equal(get('video').disableRemotePlayback,true);
instance.emit('manifest');get('video').onplaying();
assert.equal(get('playstatus').textContent,'Now playing · Alternate player');
const playingInstance=instance;vm.runInContext('stopVideo()',ctx);
assert.equal(playingInstance.destroyed,true);assert.equal(get('video').disableRemotePlayback,false);assert.equal(timers.size,0);
await vm.runInContext("play({stream_id:7,name:'Dummy'},false,true)",ctx);
instance.emit('error',{fatal:true,details:'fragLoadError',response:{code:502,url:'secret-url'}});
assert.match(get('playstatus').textContent,/video segment download failed.*HTTP 502/);assert.ok(!get('playstatus').textContent.includes('secret-url'));assert.equal(instance.destroyed,true);
await vm.runInContext("play({stream_id:7,name:'Dummy'},false,true)",ctx);
instance.emit('error',{fatal:true,details:'dummy-password',error:{message:'secret-url'}});
assert.equal(get('playstatus').textContent,'Alternate player: stream playback failed.');
FakeHls.isSupported=()=>false;
await vm.runInContext("play({stream_id:7,name:'Dummy'},false,true)",ctx);
assert.match(get('playstatus').textContent,/not supported/);assert.equal(get('video').disableRemotePlayback,false);
vm.runInContext('stopVideo()',ctx);
// A library that finishes loading after the user closes the player cannot attach.
let script;ctx.window.Hls=undefined;
ctx.document.createElement=()=>({remove(){this.removed=true}});ctx.document.head={append:s=>script=s};
void vm.runInContext("play({stream_id:7,name:'Dummy'},false,true)",ctx);
assert.match(script.src,/hls.js@1\.7\.3/);assert.match(script.integrity,/^sha384-/);assert.equal(script.crossOrigin,'anonymous');assert.equal(script.referrerPolicy,'no-referrer');
vm.runInContext('stopVideo()',ctx);ctx.window.Hls=FakeHls;script.onload();await tick();assert.equal(get('video').disableRemotePlayback,false);
ctx.window.Hls=undefined;vm.runInContext('hlsLibrary=null',ctx);
void vm.runInContext("play({stream_id:7,name:'Dummy'},false,true)",ctx);script.onerror();await tick();assert.match(get('playstatus').textContent,/could not be loaded/);assert.equal(script.removed,true);assert.equal(vm.runInContext('hlsLibrary',ctx),null);
vm.runInContext('stopVideo()',ctx);assert.equal(timers.size,0);
console.log('PASS alternate player: opaque URLs, bounded buffers, MMS opt-in, native AirPlay restoration, safe fragment errors, unsupported and stale-load cleanup');
assert.ok(requests.every(r=>r.options.cache==='no-store'&&!r.url.includes('dummy')&&r.options.body===undefined));
console.log('PASS playback media errors, gateway refusal, reachable playlist, expired session, startup timeout, recovery race and credential-free diagnostics');

// Non-HLS movie failures inspect the real media and expose a bounded compatibility fallback.
vm.runInContext("credentials={base:'http://provider.example.invalid',user:'dummy-user',pass:'dummy-password'};movieStreams={8:'https://homepi.test.ts.net/media/session/movie'}",ctx);
inspection={container:'matroska,webm',streams:[{type:'video',codec:'h264',width:1920,height:1080},{type:'audio',codec:'ac3'}]};reply=()=>new Response('dummy bytes',{headers:{'content-type':'video/x-matroska'}});
void vm.runInContext("play({kind:'movie',stream_id:8,name:'Movie',container_extension:'mkv'})",ctx);
get('video').error={code:4};get('video').onerror();await tick();assert.match(get('playstatus').textContent,/Movie formats: H264 1920×1080; AC3 audio/);assert.match(get('playstatus').textContent,/matroska/);assert.equal(requests.findLast(r=>r.url.endsWith('/media/session/movie')).options.headers.Range,'bytes=0-65535');assert.match(get('compatible').textContent,/movie playback/);
void get('compatible').onclick();assert.equal(get('video').src,'https://homepi.test.ts.net/compatible/session/movie/index.m3u8');assert.equal(vm.runInContext('activeCompatibility',ctx),get('video').src);get('video').onplaying();assert.match(get('playstatus').textContent,/Seeking is limited/);
vm.runInContext('stopVideo()',ctx);
console.log('PASS movie diagnostics use a bounded byte-range check, report actual formats and offer original-quality compatible playback with seeking limits');

FakeHls.isSupported=()=>true;ctx.window.Hls=FakeHls;let starts=0;get('video').play=()=>{starts++;return Promise.resolve()};get('video').currentTime=0;let bufferEnd=4;get('video').buffered={length:1,start:()=>0,end:()=>bufferEnd};get('video').error=null;
await vm.runInContext("play({kind:'movie',stream_id:8,name:'Movie',container_extension:'mkv'},true,true)",ctx);
assert.equal(instance.config.maxBufferSize,64*1024*1024);assert.equal(instance.config.maxBufferLength,30);assert.equal(instance.config.manifestLoadPolicy.default.maxTimeToFirstByteMs,60000);assert.equal(get('video').autoplay,false);
instance.emit('manifest');instance.emit('buffered');assert.equal(starts,0);bufferEnd=8;instance.emit('buffered');assert.equal(starts,1);get('video').onplaying();
get('video').currentTime=7;get('video').onwaiting();assert.match(get('playstatus').textContent,/Refilling/);instance.emit('buffered');assert.equal(starts,1);bufferEnd=15;instance.emit('buffered');assert.equal(starts,2);
vm.runInContext('stopVideo()',ctx);assert.equal(get('video').autoplay,true);
// Short finished movies do not wait for more seconds than the movie contains.
get('video').currentTime=0;bufferEnd=6;await vm.runInContext("play({kind:'movie',stream_id:8,name:'Short',container_extension:'mkv'},true,true)",ctx);instance.currentLevel=0;instance.levels=[{details:{live:false,edge:6}}];instance.emit('buffered');assert.equal(starts,3);vm.runInContext('stopVideo()',ctx);
console.log('PASS movie-only startup and refill buffer gates, short movie completion, 64 MiB memory bound and native autoplay restoration; live defaults unchanged');
