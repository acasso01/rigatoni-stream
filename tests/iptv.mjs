import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {execFileSync,spawnSync} from 'node:child_process';
import {createGateway} from '../gateway/server.mjs';
import {xtreamQuery,sanitizeProviderJson,parseM3U,m3uKind,decodeShortEpg,parseXmltv,xmltvTime,parseAllowList,hostAllowed,fmp4Arguments,tsArguments,assertRelayInput,trendingTitles} from '../gateway/iptv.mjs';

// ---- pure helpers ----
assert.deepEqual(xtreamQuery('?action=get_short_epg&stream_id=7&limit=4'),{action:'get_short_epg',stream_id:'7',limit:'4'});
for(const bad of ['?action=get_account_info','?action=get_live_streams&category_id=1;rm','?action=get_live_streams&username=x','?','?action=__proto__'])assert.throws(()=>xtreamQuery(bad),/action_not_allowed|invalid_parameter/,bad);
const reg=u=>'/media/s/'+Buffer.from(u.href).toString('base64url').slice(0,8);
const cleaned=sanitizeProviderJson({user_info:{username:'u',password:'secret-pass'},items:[{name:'A',stream_icon:'http://cdn.example/a.png',direct_source:'http://p/u/secret-pass/1.ts',note:'http://p/live/u/secret-pass/1.m3u8',plain:'ok'}]},{secrets:['secret-pass'],register:reg});
assert.equal(cleaned.user_info,undefined);assert.equal(cleaned.items[0].direct_source,undefined);assert.equal(cleaned.items[0].note,'');assert.equal(cleaned.items[0].plain,'ok');assert.match(cleaned.items[0].stream_icon,/^\/media\/s\//);
assert.ok(!JSON.stringify(cleaned).includes('secret-pass'));
const m3u=parseM3U('#EXTM3U url-tvg="http://epg.example/guide.xml"\n#EXTINF:-1 tvg-id="tubi.us" tvg-logo="http://logo.example/t.png" group-title="US| Entertainment",US| TUBI RAW 60fps\nhttp://p.example/live/u/p/1.ts\n#EXTINF:-1 group-title="Movies",Dune (2021)\nhttp://p.example/movie/u/p/9.mkv\n#EXTINF:-1,No Group\nftp://bad.example/x\n#EXTINF:-1 tvg-name="Named, with comma",\nhttps://p.example/hls/2.m3u8\n');
assert.equal(m3u.epgUrl,'http://epg.example/guide.xml');assert.equal(m3u.channels.length,3);
assert.deepEqual([m3u.channels[0].name,m3u.channels[0].tvg_id,m3u.channels[0].group],['US| TUBI RAW 60fps','tubi.us','US| Entertainment']);
assert.equal(m3u.channels[2].name,'Named, with comma');assert.equal(m3u.channels[2].group,'Channels');
assert.equal(m3uKind(m3u.channels[1].url),'movie');assert.equal(m3uKind(m3u.channels[0].url),'live');
assert.throws(()=>parseM3U('<html>'),/invalid_playlist/);assert.throws(()=>parseM3U('#EXTM3U\n'),/invalid_playlist/);
assert.throws(()=>parseM3U('#EXTM3U\n#EXTINF:-1,a\nhttp://x/1\n#EXTINF:-1,b\nhttp://x/2',{maxItems:1}),/catalog_too_large/);
const epg=decodeShortEpg({epg_listings:[{title:Buffer.from('Evening News').toString('base64'),description:Buffer.from('Top stories').toString('base64'),start_timestamp:'1800000000',stop_timestamp:'1800003600'},{title:'eA==',start_timestamp:'5',stop_timestamp:'1'}]});
assert.deepEqual(epg,[{title:'Evening News',description:'Top stories',start:1800000000,end:1800003600}]);
assert.equal(xmltvTime('20261128013000 +0000'),Date.UTC(2026,10,28,1,30)/1000);assert.equal(xmltvTime('20261127183000 -0700'),Date.UTC(2026,10,28,1,30)/1000);
const xml='<tv><programme start="20261128010000 +0000" stop="20261128020000 +0000" channel="tubi.us"><title lang="en">Late &amp; Live</title><desc>CDATA <![CDATA[ok]]></desc></programme><programme start="20261128010000 +0000" stop="20261128020000 +0000" channel="other"><title>x</title></programme></tv>';
const xm=parseXmltv(xml,{channels:new Set(['tubi.us']),from:Date.UTC(2026,10,28,0)/1000,to:Date.UTC(2026,10,28,6)/1000});
assert.equal(xm.get('tubi.us')[0].title,'Late & Live');assert.equal(xm.get('tubi.us')[0].description,'CDATA ok');assert.equal(xm.has('other'),false);
const allow=parseAllowList(' provider.example, *.cdn.example ');
assert.ok(hostAllowed('http://provider.example:8080/x',allow));assert.ok(hostAllowed('http://a.cdn.example/x',allow));
assert.ok(!hostAllowed('http://cdn.example.evil/x',allow));assert.ok(!hostAllowed('http://evilprovider.example/x',allow));assert.ok(hostAllowed('http://anything/x',[]));
for(const bad of ['http://provider.example/media/a/b','http://127.0.0.1:8787/media/a/b?x=1','http://127.0.0.1/other/a/b','file:///etc/passwd','http://127.0.0.1/media/a/b/../../x'])assert.throws(()=>assertRelayInput(bad),/unsafe_target/,bad);
const copy=fmp4Arguments('http://127.0.0.1:9/media/abc/def');assert.ok(copy.includes('copy')&&copy.includes('frag_keyframe+empty_moov+default_base_moof')&&copy.at(-1)==='pipe:1'&&!copy.includes('-re'));
const tx=fmp4Arguments('http://127.0.0.1:9/media/abc/def',{video:'transcode',start:90,live:false,height:720});assert.ok(tx.includes('libx264')&&tx.includes('-re')&&tx[tx.indexOf('-ss')+1]==='90'&&tx.some(a=>a.includes('min(720')));
assert.ok(tsArguments('http://127.0.0.1:9/media/abc/def').includes('mpegts'));
assert.deepEqual(trendingTitles({results:[{title:'Dune',release_date:'2021-10-22',poster_path:'/abc.jpg'},{name:'Show',first_air_date:'2024-01-01',poster_path:'javascript:x'},{}]}).map(r=>[r.title,r.year,r.poster]),[['Dune','2021','https://image.tmdb.org/t/p/w342/abc.jpg'],['Show','2024','']]);
console.log('PASS iptv helpers: Xtream action allowlist, credential scrubbing, M3U/XMLTV/short-EPG parsing, host allowlist, loopback-only ffmpeg inputs, TMDB parsing');

// ---- gateway routes ----
const haveFfmpeg=spawnSync('ffmpeg',['-version']).status===0;
const segment=haveFfmpeg?execFileSync('ffmpeg',['-v','error','-f','lavfi','-i','testsrc=size=320x240:rate=25','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','4','-c:v','libx264','-preset','ultrafast','-g','25','-pix_fmt','yuv420p','-c:a','aac','-f','mpegts','pipe:1'],{maxBuffer:64*1024*1024}):Buffer.from('');
const requests=[];
const fake=(body,headers={},statusCode=200)=>({response:Object.assign(Readable.from([Buffer.isBuffer(body)?body:Buffer.from(body)]),{statusCode,headers})});
const upstream=async(input)=>{
  const url=new URL(input);requests.push(url.href);
  if(url.hostname==='blocked.example')throw Error('unsafe_target');
  if(url.pathname==='/player_api.php'){
    const a=url.searchParams.get('action');
    if(a==='get_live_categories')return{url,...fake(JSON.stringify([{category_id:'1',category_name:'US| News'}]))};
    if(a==='get_live_streams')return{url,...fake(JSON.stringify([{stream_id:7,name:'US| TUBI RAW 60fps',category_id:'1'}]))};
    if(a==='get_short_epg')return{url,...fake(JSON.stringify({epg_listings:[{title:Buffer.from('Morning Show').toString('base64'),description:'',start_timestamp:String(Math.floor(Date.now()/1000)-600),stop_timestamp:String(Math.floor(Date.now()/1000)+1200)}]}))};
    if(a==='get_vod_info')return{url,...fake(JSON.stringify({info:{name:'Dune',cover_big:'http://img.example/d.jpg'},movie_data:{stream_id:3,direct_source:'http://p/movie/dummy-user/dummy-pass/3.mkv'},user_info:{password:'dummy-pass'}}))};
  }
  if(url.pathname==='/playlist.m3u')return{url,...fake('#EXTM3U url-tvg="http://epg.example/guide.xml"\n#EXTINF:-1 tvg-id="tubi.us" group-title="Entertainment",US| TUBI RAW\nhttp://provider.example/live/m3uuser/m3upass/11.m3u8\n#EXTINF:-1 group-title="Movies",Film\nhttp://provider.example/movie/m3uuser/m3upass/12.mp4\n')};
  if(url.pathname==='/guide.xml'){const s=new Date(Date.now()-1800e3),e=new Date(Date.now()+1800e3);const f=d=>d.toISOString().replace(/[-:T]/g,'').slice(0,14)+' +0000';return{url,...fake('<tv><programme start="'+f(s)+'" stop="'+f(e)+'" channel="tubi.us"><title>Tubi Tonight</title></programme></tv>')}}
  if(/\.m3u8$/.test(url.pathname))return{url,...fake('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n',{'content-type':'application/vnd.apple.mpegurl'})};
  if(/seg0\.ts$/.test(url.pathname))return{url,...fake(segment,{'content-type':'video/mp2t','content-length':String(segment.length)})};
  return{url,...fake('not found',{},404)};
};
const vault=async(url,{headers})=>{
  if(headers.Authorization!=='Bearer dummy-auth')return new Response('{}',{status:401});
  if(String(url).includes('/auth/v1/user'))return new Response(JSON.stringify({id:'user-1'}),{status:200});
  return new Response(JSON.stringify({saved:true,server_url:'http://provider.example',username:'dummy-user',password:'dummy-pass'}),{status:200});
};
let tmdbCalls=0;
const tmdbFetch=async url=>{tmdbCalls++;assert.match(String(url),/api\.themoviedb\.org\/3\/trending\/movie\/week\?api_key=server-side-key/);return new Response(JSON.stringify({results:[{title:'Dune',release_date:'2021-10-22',poster_path:'/dune.jpg'}]}))};
const gateway=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy-public-key',fetchVault:vault,upstream,tmdbKey:'server-side-key',tmdbFetch,allowedHosts:'provider.example,epg.example',probe:async()=>({streams:[{type:'video',codec:'h264',width:320,height:240},{type:'audio',codec:'aac'}],container:'hls'})});
await new Promise(r=>gateway.listen(0,'127.0.0.1',r));
const root='http://127.0.0.1:'+gateway.address().port,auth={Authorization:'Bearer dummy-auth'};
try{
  let r=await fetch(root+'/health');const health=await r.json();assert.equal(health.iptv,true);assert.deepEqual(health.engines,['relay','ts','fmp4']);assert.equal(health.trending,true);
  r=await fetch(root+'/api/connect',{method:'POST',headers:auth});assert.equal(r.status,200);const xt=await r.json();
  assert.match(xt.iptv_session,/^[A-Za-z0-9_-]+$/);const sid=xt.iptv_session;const ticket=xt.streams['7'].split('/').at(-1);
  // Xtream passthrough: allowlisted actions only, credentials scrubbed
  r=await fetch(root+'/iptv/api/'+sid+'?action=get_vod_info&vod_id=3');assert.equal(r.status,200);const info=await r.text();
  assert.ok(!info.includes('dummy-pass')&&!info.includes('dummy-user'));assert.match(JSON.parse(info).info.cover_big,/^\/media\//);
  r=await fetch(root+'/iptv/api/'+sid+'?action=get_account_info');assert.equal(r.status,400);
  r=await fetch(root+'/iptv/api/nope?action=get_live_categories');assert.equal(r.status,401);
  // EPG
  r=await fetch(root+'/iptv/epg/'+sid+'?ids=7');const e1=await r.json();assert.equal(e1.epg['7'][0].title,'Morning Show');
  const before=requests.length;r=await fetch(root+'/iptv/epg/'+sid+'?ids=7');await r.json();assert.equal(requests.length,before,'EPG is cached');
  for(const bad of ['','?ids=a','?ids='+Array.from({length:41},(_,i)=>i).join(',')]){r=await fetch(root+'/iptv/epg/'+sid+bad);assert.equal(r.status,400,bad)}
  // Trending: key stays server-side, response is cached
  r=await fetch(root+'/iptv/trending/'+sid+'?media=movie');const tr=await r.json();assert.equal(tr.results[0].title,'Dune');assert.ok(!JSON.stringify(tr).includes('server-side-key'));
  await fetch(root+'/iptv/trending/'+sid+'?media=movie');assert.equal(tmdbCalls,1);
  r=await fetch(root+'/iptv/trending/'+sid+'?media=people');assert.equal(r.status,400);
  // Stream modes
  r=await fetch(root+'/iptv/stream/'+sid+'/'+ticket+'?mode=relay',{redirect:'manual'});assert.equal(r.status,307);assert.equal(r.headers.get('location'),'/media/'+sid+'/'+ticket);
  r=await fetch(root+'/iptv/stream/'+sid+'/'+ticket+'?mode=evil');assert.equal(r.status,400);
  r=await fetch(root+'/iptv/stream/'+sid+'/'+ticket+'?mode=fmp4&video=sideways');assert.equal(r.status,400);
  r=await fetch(root+'/iptv/stream/'+sid+'/unknown?mode=fmp4');assert.equal(r.status,401);
  if(haveFfmpeg){
    r=await fetch(root+'/iptv/stream/'+sid+'/'+ticket+'?mode=fmp4');assert.equal(r.status,200);assert.equal(r.headers.get('content-type'),'video/mp4');
    const mp4=Buffer.from(await r.arrayBuffer());assert.equal(mp4.subarray(4,8).toString(),'ftyp');assert.ok(mp4.includes(Buffer.from('moof'))&&mp4.includes(Buffer.from('avc1')),'fragmented MP4 with H.264');
    r=await fetch(root+'/iptv/stream/'+sid+'/'+ticket+'?mode=ts');assert.equal(r.status,200);const ts=Buffer.from(await r.arrayBuffer());assert.equal(ts[0],0x47);assert.equal(ts[188],0x47);
    r=await fetch(root+'/iptv/stream/'+sid+'/'+ticket+'?mode=fmp4&video=transcode&q=180');const small=Buffer.from(await r.arrayBuffer());assert.equal(small.subarray(4,8).toString(),'ftyp');
    console.log('PASS iptv stream: fMP4 copy and transcode for the canvas engine, MPEG-TS for mpegts.js, all from the loopback relay');
  }else console.log('SKIP iptv stream ffmpeg checks (ffmpeg not installed)');
  // M3U sessions
  r=await fetch(root+'/iptv/m3u',{method:'POST',body:JSON.stringify({url:'http://provider.example/playlist.m3u'})});assert.equal(r.status,401);
  r=await fetch(root+'/iptv/m3u',{method:'POST',headers:{Authorization:'Bearer wrong'},body:JSON.stringify({url:'http://provider.example/playlist.m3u'})});assert.equal(r.status,401);
  r=await fetch(root+'/iptv/m3u',{method:'POST',headers:auth,body:JSON.stringify({url:'http://elsewhere.example/playlist.m3u'})});assert.equal(r.status,403);
  r=await fetch(root+'/iptv/m3u',{method:'POST',headers:auth,body:JSON.stringify({url:'file:///etc/passwd'})});assert.equal(r.status,400);
  r=await fetch(root+'/iptv/m3u',{method:'POST',headers:auth,body:'nope'});assert.equal(r.status,400);
  r=await fetch(root+'/iptv/m3u',{method:'POST',headers:auth,body:JSON.stringify({url:'http://provider.example/playlist.m3u?username=m3uuser&password=m3upass'})});assert.equal(r.status,200);
  const text=await r.text();assert.ok(!text.includes('m3upass')&&!text.includes('provider.example'),'M3U login never returned');
  const m=JSON.parse(text);assert.equal(m.channels.length,1);assert.equal(m.vod_skipped,1);assert.equal(m.categories[0].category_name,'Entertainment');assert.equal(m.epg,true);assert.match(m.streams['1'],/^\/media\//);
  r=await fetch(root+'/iptv/epg/'+m.iptv_session+'?ids=1');const me=await r.json();assert.equal(me.source,'xmltv');assert.equal(me.epg['1'][0].title,'Tubi Tonight');
  r=await fetch(root+'/iptv/api/'+m.iptv_session+'?action=get_live_streams');assert.equal(r.status,409);
  r=await fetch(root+'/iptv/m3u',{method:'POST',headers:{...auth,Origin:'https://evil.example'},body:JSON.stringify({url:'http://provider.example/playlist.m3u'})});assert.equal(r.status,403);
  console.log('PASS iptv routes: Xtream passthrough scrubbing, cached short EPG, server-side TMDB trending, relay redirect, input validation, signed-in M3U sessions with XMLTV and host allowlist');
}finally{gateway.close();gateway.closeAllConnections?.()}
// Provider host allowlist also guards Xtream connect
const strict=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'k',fetchVault:vault,upstream,allowedHosts:'only.example'});
await new Promise(r=>strict.listen(0,'127.0.0.1',r));
try{const r=await fetch('http://127.0.0.1:'+strict.address().port+'/api/connect',{method:'POST',headers:auth});assert.equal(r.status,403);assert.equal((await r.json()).error,'provider_host_not_allowed');
const t=await fetch('http://127.0.0.1:'+strict.address().port+'/iptv/trending/x');assert.equal(t.status,401);
console.log('PASS IPTV_ALLOWED_HOSTS blocks unlisted Xtream providers');}finally{strict.close();strict.closeAllConnections?.()}
