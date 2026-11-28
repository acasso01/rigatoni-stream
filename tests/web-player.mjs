import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const read=f=>fs.readFileSync(new URL('../'+f,import.meta.url),'utf8');
// ---- engine ladder (no DOM) ----
const storage=new Map();
const ctx=vm.createContext({localStorage:{getItem:k=>storage.has(k)?storage.get(k):null,setItem:(k,v)=>storage.set(k,String(v))},navigator:{userAgent:'Mozilla/5.0 Chrome'},isSecureContext:true,MediaSource:function(){},VideoDecoder:function(){},EncodedVideoChunk:function(){},setTimeout,clearTimeout});
ctx.globalThis=ctx;
for(const f of ['web/titles.js','web/fmp4.js','web/webcodecs.js','web/player.js'])vm.runInContext(read(f),ctx);
const P=ctx.AntPlayer;const chrome={canPlayType:()=>''},safari={canPlayType:t=>t.includes('mpegurl')?'maybe':''};
const gw=P.sourcesFor('https://pi.tail.ts.net/media/SESSION/TICKET',{origin:'https://pi.tail.ts.net',id:'SESSION'},true);
assert.equal(gw.ts,'https://pi.tail.ts.net/iptv/stream/SESSION/TICKET?mode=ts');assert.equal(gw.fmp4,'https://pi.tail.ts.net/iptv/stream/SESSION/TICKET?mode=fmp4&video=auto&hevc=1');
const direct=P.sourcesFor('https://provider.example/live/u/p/1.m3u8',null,false);assert.deepEqual(Object.keys(direct),['hls']);
const other=P.sourcesFor('https://pi.tail.ts.net/media/OTHER/TICKET',{origin:'https://pi.tail.ts.net',id:'SESSION'});assert.equal(other.fmp4,undefined,'never mixes sessions');
assert.deepEqual([...P.ladder({video:chrome,sources:gw,forced:'auto',tesla:false})],['hlsjs','mpegts','canvas']);
assert.deepEqual([...P.ladder({video:safari,sources:gw,forced:'auto',tesla:false})],['native','hlsjs','mpegts','canvas']);
assert.deepEqual([...P.ladder({video:chrome,sources:gw,forced:'auto',tesla:true})],['canvas','hlsjs','mpegts'],'Tesla: canvas first');
assert.deepEqual([...P.ladder({video:chrome,sources:gw,forced:'mpegts',tesla:false})],['mpegts','hlsjs','canvas'],'forced engine first, others still fall back');
assert.deepEqual([...P.ladder({video:chrome,sources:direct,forced:'canvas',tesla:false})],['hlsjs'],'no gateway: only HLS engines');
ctx.isSecureContext=false;assert.deepEqual([...P.ladder({video:chrome,sources:gw,forced:'auto',tesla:false})],['hlsjs','mpegts'],'WebCodecs needs a secure context');ctx.isSecureContext=true;
// progress for Continue watching
P.saveProgress({kind:'movie',stream_id:5,name:'Dune'},600,6000);assert.equal(P.progress()['movie:5'].t,600);
P.saveProgress({kind:'movie',stream_id:5,name:'Dune'},5900,6000);assert.equal(P.progress()['movie:5'],undefined,'finished movies leave Continue watching');
P.saveProgress({kind:'movie',stream_id:6,name:'Short'},10,6000);assert.equal(P.progress()['movie:6'],undefined);
console.log('PASS web player: gateway sources, engine ladder order (Safari, Chrome, Tesla, forced, direct, insecure), Continue-watching progress rules');
// ---- SRI pins: every CDN script the web player loads is pinned ----
const player=read('web/player.js');for(const m of player.matchAll(/src:'(https:[^']+)',integrity:'(sha384-[^']+)'/g))assert.ok(m[2].length>60,m[1]);
assert.ok(!/api_key|TMDB_API_KEY|tmdbKey/.test(player+read('web/ui.js')),'no TMDB key in browser JS');
// ---- xtream.html hooks: live play delegates to the ladder; titles cleaned; hidden categories ----
const html=read('xtream.html');const code=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1])[1];
const nodes=new Map(),get=id=>{if(!nodes.has(id))nodes.set(id,{id,value:'',textContent:'',children:[],style:{},classList:{add(){},remove(){},toggle(){}},append(...c){this.children.push(...c)},prepend(){},setAttribute(){},pause(){},load(){},removeAttribute(){},replaceChildren(){this.children=[]},scrollIntoView(){},play:()=>new Promise(()=>{})});return nodes.get(id)};
const make=tag=>({tag,children:[],style:{cssText:''},className:'',textContent:'',classList:{add(){},remove(){},toggle(){}},append(...c){this.children.push(...c)},prepend(){},setAttribute(){},remove(){},replaceChildren(...c){this.children=c},scrollIntoView(){}});
const calls=[];const w={scrollTo(){},AntTitles:ctx.AntTitles,AntPlayer:{handles:()=>true,playLive:o=>{calls.push(o);return 'hlsjs'},stop(){},track(){}},AntCategories:{visible:(s,id)=>!(s==='live'&&id==='2'),decorate(){}}};
const vctx=vm.createContext({document:{getElementById:get,querySelectorAll:()=>[],querySelector:()=>null,createElement:make,documentElement:{setAttribute(){}}},window:w,localStorage:{getItem:()=>null,setItem(){}},location:{protocol:'https:'},URL,AbortController,setTimeout,clearTimeout,fetch:async()=>new Response('{}')});
vm.runInContext(code,vctx);
vm.runInContext("credentials={base:'http://provider.example.invalid',user:'u',pass:'p'};gatewayStreams={7:'https://pi.tail.ts.net/media/S/K'};iptvSession={origin:'https://pi.tail.ts.net',id:'S'};categories=[{category_id:'1',category_name:'US| News'},{category_id:'2',category_name:'Hidden'}];channels=[{stream_id:7,name:'US| TUBI RAW 60fps',category_id:'1'},{stream_id:8,name:'Secret',category_id:'2'}];tab='live';",vctx);
await vm.runInContext("play({stream_id:7,name:'US| TUBI RAW 60fps'})",vctx);
assert.equal(calls.length,1);assert.equal(calls[0].url,'https://pi.tail.ts.net/media/S/K');assert.equal(JSON.stringify(calls[0].iptv),JSON.stringify({origin:'https://pi.tail.ts.net',id:'S'}));assert.equal(typeof calls[0].legacy.compatible,'function');
const tile=vm.runInContext("makeTile({stream_id:7,name:'US| TUBI RAW 60fps',category_id:'1'})",vctx);assert.equal(tile.children.find(c=>c.className==='name').textContent,'Tubi');
vm.runInContext('render()',vctx);
const names=[];const walk=n=>{for(const c of n.children||[]){if(c.className==='name')names.push(c.textContent);walk(c)}};walk(get('rows'));
assert.ok(names.includes('Tubi')&&!names.includes('Secret'),'hidden category removed: '+names.join(','));
// Movies keep the classic path (no ladder) so seeking/compatible movie playback is unchanged
vm.runInContext("movieStreams={9:'https://pi.tail.ts.net/media/S/M'}",vctx);void vm.runInContext("play({kind:'movie',stream_id:9,name:'Dune',container_extension:'mp4'})",vctx);await new Promise(r=>setImmediate(r));assert.equal(calls.length,1);assert.equal(get('video').src,'https://pi.tail.ts.net/media/S/M');vm.runInContext('stopVideo()',vctx);
console.log('PASS xtream.html hooks: live channels use the engine ladder with the gateway session, movies stay on the classic path, cleaned tile titles, hidden categories filtered');
