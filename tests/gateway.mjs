import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {mkdtemp, rm, readFile, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createGateway,checkedTarget,publicAddress,rewritePlaylist,providerArray,safeDownloadFilename,downloadDisposition} from '../gateway/server.mjs';
const unicode=JSON.stringify([{name:'Café 🍝',extra:{value:'braces } and escaped " quotes',array:[1,2]}}]);
const parsed=await providerArray(Readable.from([...Buffer.from(unicode)].map(byte=>Buffer.from([byte]))),c=>({name:c.name}));
assert.deepEqual(parsed,[{name:'Café 🍝'}]);
for(const malformed of ['{}','[{"a":1},]','[{"a":1}] garbage','[{"a":1}','[{"a":1} {"a":2}]'])await assert.rejects(()=>providerArray(Readable.from([Buffer.from(malformed)]),c=>c));
await assert.rejects(()=>providerArray(Readable.from([Buffer.from('[{},{}]')]),c=>c,{maxItems:1}),/catalog_too_large/);
await assert.rejects(()=>providerArray(Readable.from([Buffer.from('[{}]')]),c=>c,{maxBytes:3}),/response_too_large/);
await assert.rejects(()=>providerArray(Readable.from([Buffer.from('[{"a":"too long"}]')]),c=>c,{maxItemBytes:5}),/response_too_large/);
assert.equal(safeDownloadFilename('Dune (2021).mp4'),'Dune (2021).mp4');
assert.equal(safeDownloadFilename('a/b\\c:d*e?f"g<h>i|j.mp4'),'a b c d e f g h i j.mp4');
assert.equal(safeDownloadFilename('../../etc/passwd'),'.. etc passwd');
assert.ok(!safeDownloadFilename('x\r\ny').includes('\r')&&!safeDownloadFilename('x\r\ny').includes('\n'));
assert.equal(safeDownloadFilename(''),'download');
assert.equal(safeDownloadFilename('.mp4'),'mp4');
assert.ok(safeDownloadFilename('x'.repeat(200)+'.mp4').length<=150&&safeDownloadFilename('x'.repeat(200)+'.mp4').endsWith('.mp4'));
assert.equal(safeDownloadFilename(null,'http://provider.example.invalid/movie/u/p/7.mp4'),'7.mp4');
assert.match(downloadDisposition('Café (2024).mp4'),/attachment; filename="Caf_ \(2024\)\.mp4"; filename\*=UTF-8''Caf%C3%A9%20%282024%29\.mp4/);
console.log('PASS download filenames: traversal/control-character sanitizing, length cap, provider fallback and RFC 5987 disposition');
const dlMoviesDir=await mkdtemp(join(tmpdir(),'rigatoni-dl-movies-'));
const dlTvDir=await mkdtemp(join(tmpdir(),'rigatoni-dl-tv-'));
for(const address of ['127.0.0.1','10.1.2.3','172.16.1.1','192.168.1.10','169.254.169.254','100.78.38.112','0.0.0.0','224.0.0.1','::1','fe80::1','fc00::1','::ffff:127.0.0.1','2001:db8::1','2002:7f00:1::'])assert.equal(publicAddress(address),false,address);
for(const address of ['8.8.8.8','1.1.1.1','2606:4700:4700::1111'])assert.equal(publicAddress(address),true,address);
await assert.rejects(()=>checkedTarget('http://provider.example.invalid',async()=>[{address:'8.8.8.8',family:4},{address:'127.0.0.1',family:4}]),/unsafe_target/);
await assert.rejects(()=>checkedTarget('file:///etc/passwd'),/unsafe_target/);
await assert.rejects(()=>checkedTarget('http://user:pass@8.8.8.8'),/unsafe_target/);
let clock=Date.now(),largeCatalog=false,largeMovies=false,largeSeries=false;const requests=[];
const fakeResponse=(body,headers={})=>Object.assign(Readable.from([Buffer.from(body)]),{statusCode:200,headers});
const fakeUpstream=async(input,options={})=>{
 const url=new URL(input);requests.push({url,options});
 if(largeCatalog&&url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_live_streams'){
   async function* catalog(){yield Buffer.from('[');for(let i=1;i<=21001;i++)yield Buffer.from((i>1?',':'')+JSON.stringify({stream_id:i,name:'Large channel '+i,category_id:1,unused:'x'.repeat(1024)}));yield Buffer.from(']');}
   return{url,response:Object.assign(Readable.from(catalog()),{statusCode:200,headers:{}})};
 }
 if(url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_vod_categories')return{url,response:fakeResponse(JSON.stringify([{category_id:9,category_name:'Test Movies'},{category_id:10,category_name:'Other Movies'},{category_id:11,category_name:'More Movies'}]))};
 if(largeMovies&&url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_vod_streams'&&!url.searchParams.has('category_id')){
  async function* catalog(){yield Buffer.from('[');for(let i=1;i<=50001;i++)yield Buffer.from((i>1?',':'')+JSON.stringify({stream_id:i,name:'Movie '+i,category_id:9}));yield Buffer.from(']');}
  return{url,response:Object.assign(Readable.from(catalog()),{statusCode:200,headers:{}})};
 }
 if(url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_vod_streams')return{url,response:fakeResponse(JSON.stringify([{stream_id:7,name:'Dummy movie',category_id:9,container_extension:'mp4',stream_icon:'http://provider.example.invalid/poster?username=dummy-user&password=dummy-password',unused:'discard'}]))};
 if(url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_series_categories')return{url,response:fakeResponse(JSON.stringify([{category_id:9,category_name:'Test Series'},{category_id:10,category_name:'Other Series'},{category_id:11,category_name:'More Series'}]))};
 if(largeSeries&&url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_series'&&!url.searchParams.has('category_id')){
  async function* catalog(){yield Buffer.from('[');for(let i=1;i<=50001;i++)yield Buffer.from((i>1?',':'')+JSON.stringify({series_id:i,name:'Series '+i,category_id:9}));yield Buffer.from(']');}
  return{url,response:Object.assign(Readable.from(catalog()),{statusCode:200,headers:{}})};
 }
 if(url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_series')return{url,response:fakeResponse(JSON.stringify([{series_id:5,name:'Dummy series',category_id:9,cover:'http://provider.example.invalid/poster?username=dummy-user&password=dummy-password',rating:'8.5',genre:'Drama',releaseDate:'2024-01-01',unused:'discard'}]))};
 if(url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_series_info'){
  if(url.searchParams.get('series_id')!=='5')return{url,response:fakeResponse(JSON.stringify({info:{},seasons:[],episodes:{}}))};
  return{url,response:fakeResponse(JSON.stringify({info:{name:'Dummy series',cover:'http://provider.example.invalid/poster',plot:'A test plot.',cast:'Actor One',genre:'Drama',releaseDate:'2024-01-01',rating:'8.5'},seasons:[{season_number:1,episode_count:2,name:'Season 1'}],episodes:{'1':[{id:101,episode_num:1,title:'Pilot',container_extension:'mp4',season:1,info:{movie_image:'http://provider.example.invalid/ep-poster',plot:'Pilot plot.'}},{id:102,episode_num:2,title:'Second',container_extension:'mkv',season:1,info:{}}]}}))};
 }
 if(url.pathname==='/player_api.php')return{url,response:fakeResponse(JSON.stringify(url.searchParams.get('action')==='get_live_streams'?[{name:'Dummy test channel',stream_id:7,category_id:1,stream_icon:'http://private.invalid/secret.png'}]:[{category_id:1,category_name:'Dummy'}]))};
 if(url.pathname==='/movie/dummy-user/dummy-password/8.mp4'){
   const body=Buffer.from('dummy-media-bytes');
   const m=String(options.range||'').match(/^bytes=(\d+)-$/);
   if(m){const start=Number(m[1]);const slice=body.subarray(start);return{url,response:Object.assign(Readable.from([slice]),{statusCode:206,headers:{'content-type':'video/mp4','content-length':String(slice.length),'content-range':'bytes '+start+'-'+(body.length-1)+'/'+body.length}})}}
   return{url,response:fakeResponse('dummy-media-bytes',{'content-type':'video/mp4','content-length':'17'})};
 }
 if(['/movie/dummy-user/dummy-password/9.mp4','/movie/dummy-user/dummy-password/10.mp4','/movie/dummy-user/dummy-password/11.mp4'].includes(url.pathname)){
   async function* slow(){for(let i=0;i<30;i++){await new Promise(r=>setTimeout(r,30));yield Buffer.from('x')}}
   return{url,response:Object.assign(Readable.from(slow()),{statusCode:200,headers:{'content-type':'video/mp4','content-length':'30'}})};
 }
 if(url.pathname.endsWith('.m3u8'))return{url,response:fakeResponse('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:4,\nsegment.ts\n',{'content-type':'application/vnd.apple.mpegurl'})};
 return{url,response:fakeResponse('dummy-media-bytes',{'content-type':'video/mp2t','content-length':'17'})};
};
const fakeVault=async(url,options)=>{
 assert.ok(url.startsWith('https://vault.example.invalid/functions/v1/provider-vault'));assert.equal(options.cache,'no-store');
 if(options.headers.Authorization!=='Bearer dummy-auth')return{ok:false,status:401};
 const idq=new URL(url).searchParams.get('id');
 if(idq==='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')return{ok:true,json:async()=>({saved:true,server_url:'http://provider2.example.invalid',username:'user2',password:'pass2'})};
 if(idq)return{ok:true,json:async()=>({saved:false})};
 return{ok:true,json:async()=>({saved:true,server_url:'http://provider.example.invalid',username:'dummy-user',password:'dummy-password'})};
};
const gateway=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy-public-key',now:()=>clock,upstream:fakeUpstream,moviesDir:dlMoviesDir,tvDir:dlTvDir,probe:async url=>{assert.match(url,/^http:\/\/127\.0\.0\.1:\d+\/media\//);return{streams:[{type:'video',codec:'h264',width:1920,height:1080}]}},fetchVault:fakeVault});
await new Promise(resolve=>gateway.listen(0,'127.0.0.1',resolve));
const root='http://127.0.0.1:'+gateway.address().port;
try{
 let r=await fetch(root+'/api/connect',{method:'POST'});assert.equal(r.status,401);
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer wrong'}});assert.equal(r.status,401);
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Origin:'https://untrusted.example.invalid',Authorization:'Bearer dummy-auth'}});assert.equal(r.status,403);
 r=await fetch(root+'/api/connect',{method:'OPTIONS',headers:{Origin:'https://acasso01.github.io'}});assert.equal(r.status,204);assert.equal(r.headers.get('access-control-allow-origin'),'https://acasso01.github.io');
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io'}});assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');const data=await r.json();assert.equal(data.channels.length,1);assert.equal(data.channels[0].stream_icon,'');assert.ok(!JSON.stringify(data).includes('dummy-password'));assert.ok(!JSON.stringify(data).includes('dummy-user'));
 r=await fetch(root+'/health');assert.equal(r.status,200);assert.deepEqual(await r.json(),{ok:true,service:'rigatoni-gateway',multi_provider:true,downloads:true,server_downloads:true,iptv:true,m3u:true,epg:true,engines:['relay','ts','fmp4'],trending:false});
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io','Content-Type':'application/json'},body:JSON.stringify({provider_id:'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'})});assert.equal(r.status,200);const mpConnect=await r.json();assert.equal(mpConnect.channels.length,1);
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io','Content-Type':'application/json'},body:JSON.stringify({provider_id:'not-a-uuid'})});assert.equal(r.status,400);assert.equal((await r.json()).error,'invalid_provider_id');
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io','Content-Type':'application/json'},body:JSON.stringify({provider_id:'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'})});assert.equal(r.status,404);assert.equal((await r.json()).error,'provider_not_found');
 console.log('PASS multi-provider gateway: health flag, provider_id connect, invalid id rejected, unknown id 404');
 assert.ok(!requests.some(r=>r.url.searchParams.get('action')?.startsWith('get_vod')));
 const movieReplies=await Promise.all([fetch(root+data.movies_path),fetch(root+data.movies_path)]);for(const response of movieReplies)assert.equal(response.status,200);const movieData=await movieReplies[0].json();await movieReplies[1].json();
 assert.equal(requests.filter(r=>r.url.searchParams.get('action')==='get_vod_streams').length,1);assert.equal(movieData.movies[0].kind,'movie');assert.equal(movieData.movies[0].container_extension,'mp4');assert.equal(movieData.categories[0].category_name,'Test Movies');assert.ok(!JSON.stringify(movieData).includes('dummy-password'));assert.ok(!JSON.stringify(movieData).includes('dummy-user'));assert.ok(!JSON.stringify(movieData).includes('unused'));
 r=await fetch(root+movieData.streams[7],{headers:{Range:'bytes=0-10'}});assert.equal(r.status,200);await r.text();assert.equal(requests.at(-1).options.range,'bytes=0-10');assert.equal(requests.at(-1).url.pathname,'/movie/dummy-user/dummy-password/7.mp4');
 r=await fetch(root+movieData.movies[0].stream_icon);assert.equal(r.status,200);await r.text();assert.equal(requests.at(-1).url.pathname,'/poster');
 r=await fetch(root+'/api/movies/invalid');assert.equal(r.status,401);
 const seriesReplies=await Promise.all([fetch(root+data.series_path),fetch(root+data.series_path)]);for(const response of seriesReplies)assert.equal(response.status,200);const seriesData=await seriesReplies[0].json();await seriesReplies[1].json();
 assert.equal(requests.filter(r=>r.url.searchParams.get('action')==='get_series').length,1);assert.equal(seriesData.series[0].kind,'series');assert.equal(seriesData.series[0].name,'Dummy series');assert.equal(seriesData.categories[0].category_name,'Test Series');assert.ok(!JSON.stringify(seriesData).includes('dummy-password'));assert.ok(!JSON.stringify(seriesData).includes('dummy-user'));assert.ok(!JSON.stringify(seriesData).includes('unused'));
 r=await fetch(root+seriesData.series[0].stream_icon);assert.equal(r.status,200);await r.text();assert.equal(requests.at(-1).url.pathname,'/poster');
 r=await fetch(root+data.series_path+'/info?series_id=5');assert.equal(r.status,200);const seriesInfo=await r.json();assert.equal(seriesInfo.info.name,'Dummy series');assert.equal(seriesInfo.episodes['1'].length,2);assert.equal(seriesInfo.episodes['1'][0].title,'Pilot');assert.ok(seriesInfo.streams['101']);assert.ok(!JSON.stringify(seriesInfo).includes('dummy-password'));
 r=await fetch(root+seriesInfo.streams['101']);assert.equal(r.status,200);await r.text();assert.equal(requests.at(-1).url.pathname,'/series/dummy-user/dummy-password/101.mp4');
 r=await fetch(root+data.series_path+'/info?series_id=bad');assert.equal(r.status,400);
 r=await fetch(root+data.series_path+'/info?series_id=999');assert.equal(r.status,502);
 r=await fetch(root+'/api/series/invalid');assert.equal(r.status,401);
 r=await fetch(root+'/api/series/invalid/info?series_id=5');assert.equal(r.status,401);
 console.log('PASS series catalog, seasons/episodes detail, opaque episode links, poster relay and id validation');
 r=await fetch(root+data.streams['7'].replace('/media/','/inspect/'));assert.equal(r.status,200);assert.equal((await r.json()).streams[0].width,1920);
 r=await fetch(root+data.streams['7']);assert.equal(r.status,200);const playlist=await r.text();assert.ok(!playlist.includes('http://'));assert.ok(!playlist.includes('dummy-password'));const paths=[...playlist.matchAll(/\/media\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+/g)].map(m=>m[0]);assert.equal(paths.length,2);
 for(const path of paths){r=await fetch(root+path);assert.equal(r.status,200);assert.equal(await r.text(),'dummy-media-bytes')}
 r=await fetch(root+paths[1],{headers:{Range:'bytes=0-10'}});assert.equal(requests.at(-1).options.range,'bytes=0-10');await r.text();
 r=await fetch(root+paths[1],{headers:{Range:'bytes=0-1,3-4'}});assert.equal(r.status,400);
 const movieDl=movieData.streams[7].replace('/media/','/download/')+'?filename='+encodeURIComponent('Dune (2021).mp4');
 r=await fetch(root+movieDl);assert.equal(r.status,200);assert.equal(r.headers.get('content-disposition'),'attachment; filename="Dune (2021).mp4"; filename*=UTF-8\'\'Dune%20%282021%29.mp4');assert.equal(r.headers.get('content-type'),'video/mp2t');assert.equal(r.headers.get('content-length'),'17');assert.equal(await r.text(),'dummy-media-bytes');assert.equal(requests.at(-1).url.pathname,'/movie/dummy-user/dummy-password/7.mp4');
 r=await fetch(root+movieDl,{method:'HEAD'});assert.equal(r.status,200);assert.equal(r.headers.get('content-disposition'),'attachment; filename="Dune (2021).mp4"; filename*=UTF-8\'\'Dune%20%282021%29.mp4');assert.equal(r.headers.get('content-length'),'17');assert.equal(await r.text(),'');
 r=await fetch(root+movieDl,{headers:{Range:'bytes=0-10'}});assert.equal(r.status,200);assert.equal(requests.at(-1).options.range,'bytes=0-10');await r.text();
 r=await fetch(root+movieDl,{headers:{Range:'bytes=0-1,3-4'}});assert.equal(r.status,400);
 r=await fetch(root+'/download/not-a-session/not-a-resource');assert.equal(r.status,401);assert.equal((await r.json()).error,'stream_session_expired');
 const channelDl=data.streams['7'].replace('/media/','/download/')+'?filename=Channel.m3u8';
 r=await fetch(root+channelDl);assert.equal(r.status,409);assert.equal((await r.json()).error,'download_not_supported');
 r=await fetch(root+movieDl.split('?')[0]+'?filename='+encodeURIComponent('../../etc/passwd'));assert.equal(r.status,200);assert.ok(r.headers.get('content-disposition').includes('filename=".. etc passwd"'));assert.ok(!r.headers.get('content-disposition').includes('/'));assert.ok(!r.headers.get('content-disposition').includes('\\'));await r.text();
 console.log('PASS download route: attachment disposition with Jellyfin filename, HEAD probe, range forwarding, session expiry, playlist refusal and filename sanitizing');
 r=await fetch(root+'/media/not-a-session/not-a-resource');assert.equal(r.status,401);
 const dlSession=data.movies_path.split('/').at(-1);
 const dlBase=root+'/api/downloads/'+dlSession;
 const waitJob=async(id,timeoutMs=15000)=>{const deadline=Date.now()+timeoutMs;for(;;){const jr=await fetch(dlBase+'/'+id);assert.equal(jr.status,200);const job=await jr.json();if(job.status==='done'||job.status==='error')return job;if(Date.now()>deadline)throw Error('download job timed out: '+id);await new Promise(r=>setTimeout(r,100))}};
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'7',container_extension:'mp4',filename:'Dune (2021).mp4'})});
 assert.equal(r.status,202);const movieJob=await r.json();assert.ok(movieJob.job_id);assert.equal(movieJob.status,'queued');assert.equal(movieJob.filename,'Dune (2021).mp4');assert.ok(!JSON.stringify(movieJob).includes(dlMoviesDir));
 const doneMovie=await waitJob(movieJob.job_id);assert.equal(doneMovie.status,'done');assert.equal(doneMovie.bytes,17);assert.equal(doneMovie.total_bytes,17);assert.equal(doneMovie.error,null);
 assert.equal(await readFile(join(dlMoviesDir,'Dune (2021).mp4'),'utf8'),'dummy-media-bytes');
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'episode',stream_id:'101',container_extension:'mp4',filename:'Dummy series - S01E01 - Pilot.mp4',show:'Dummy series',season:1})});
 assert.equal(r.status,202);const epJob=await r.json();
 const doneEp=await waitJob(epJob.job_id);assert.equal(doneEp.status,'done');
 assert.equal(await readFile(join(dlTvDir,'Dummy series','Season 01','Dummy series - S01E01 - Pilot.mp4'),'utf8'),'dummy-media-bytes');
 assert.equal(requests.at(-1).url.pathname,'/series/dummy-user/dummy-password/101.mp4');
 r=await fetch(dlBase);assert.equal(r.status,200);const listed=await r.json();assert.ok(Array.isArray(listed.jobs));assert.ok(listed.jobs.some(j=>j.job_id===movieJob.job_id));assert.ok(listed.jobs.some(j=>j.job_id===epJob.job_id));
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'7',container_extension:'m3u8',filename:'X.m3u8'})});assert.equal(r.status,409);assert.equal((await r.json()).error,'download_not_supported');
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'live',stream_id:'7',container_extension:'mp4',filename:'X.mp4'})});assert.equal(r.status,400);assert.equal((await r.json()).error,'invalid_request');
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'abc',container_extension:'mp4',filename:'X.mp4'})});assert.equal(r.status,400);
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:'not json'});assert.equal(r.status,400);
 r=await fetch(root+'/api/downloads/invalid-session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'7',container_extension:'mp4',filename:'X.mp4'})});assert.equal(r.status,401);assert.equal((await r.json()).error,'stream_session_expired');
 r=await fetch(dlBase+'/no-such-job');assert.equal(r.status,404);assert.equal((await r.json()).error,'download_not_found');
 await writeFile(join(dlMoviesDir,'Resume Test (2024).mp4.part'),'dummy-medi');
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'8',container_extension:'mp4',filename:'Resume Test (2024).mp4'})});
 assert.equal(r.status,202);const resumeJob=await waitJob((await r.json()).job_id);assert.equal(resumeJob.status,'done');
 assert.equal(await readFile(join(dlMoviesDir,'Resume Test (2024).mp4'),'utf8'),'dummy-media-bytes');
 assert.ok(requests.some(x=>x.options.range==='bytes=10-'));
 await writeFile(join(dlMoviesDir,'Fallback (2024).mp4.part'),'dummy-medi');
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'7',container_extension:'mp4',filename:'Fallback (2024).mp4'})});
 assert.equal(r.status,202);const fallbackJob=await waitJob((await r.json()).job_id);assert.equal(fallbackJob.status,'done');
 assert.equal(await readFile(join(dlMoviesDir,'Fallback (2024).mp4'),'utf8'),'dummy-media-bytes');
 const slowIds=[];
 for(const id of ['9','10','11']){r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:id,container_extension:'mp4',filename:'Slow '+id+'.mp4'})});assert.equal(r.status,202);slowIds.push((await r.json()).job_id)}
 r=await fetch(dlBase,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'9',container_extension:'mp4',filename:'Slow 9.mp4'})});assert.equal(r.status,202);assert.equal((await r.json()).job_id,slowIds[0]);
 r=await fetch(dlBase);const queuedList=(await r.json()).jobs.filter(j=>slowIds.includes(j.job_id));
 assert.equal(queuedList.filter(j=>j.status==='downloading').length,2);assert.equal(queuedList.filter(j=>j.status==='queued').length,1);
 for(const id of slowIds){const done=await waitJob(id,20000);assert.equal(done.status,'done');assert.equal(done.bytes,30);assert.equal(done.total_bytes,30)}
 console.log('PASS server downloads: movie + episode to Jellyfin folders, resume (206 and 200 fallback), 2-job concurrency queue, duplicate dedupe, validation errors and job list');
 const noSpace=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy-public-key',now:()=>clock,upstream:fakeUpstream,fetchVault:fakeVault,moviesDir:dlMoviesDir,tvDir:dlTvDir,downloadStatfs:async()=>({bavail:0,bsize:4096,blocks:0,bfree:0})});
 await new Promise(resolve=>noSpace.listen(0,'127.0.0.1',resolve));
 const noSpaceRoot='http://127.0.0.1:'+noSpace.address().port;
 r=await fetch(noSpaceRoot+'/health');assert.equal((await r.json()).server_downloads,true);
 r=await fetch(noSpaceRoot+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io'}});assert.equal(r.status,200);const noSpaceData=await r.json();
 r=await fetch(noSpaceRoot+'/api/downloads/'+noSpaceData.movies_path.split('/').at(-1),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'7',container_extension:'mp4',filename:'No Space (2024).mp4'})});
 assert.equal(r.status,202);const noSpaceJob=await r.json();let noSpaceDone=null;
 for(let i=0;i<50;i++){const jr=await fetch(noSpaceRoot+'/api/downloads/'+noSpaceData.movies_path.split('/').at(-1)+'/'+noSpaceJob.job_id);noSpaceDone=await jr.json();if(noSpaceDone.status==='error')break;await new Promise(res=>setTimeout(res,100))}
 assert.equal(noSpaceDone.error,'disk_full');
 noSpace.closeAllConnections();await new Promise(resolve=>noSpace.close(resolve));
 const noDirs=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy-public-key',now:()=>clock,upstream:fakeUpstream,fetchVault:fakeVault});
 await new Promise(resolve=>noDirs.listen(0,'127.0.0.1',resolve));
 const noDirsRoot='http://127.0.0.1:'+noDirs.address().port;
 r=await fetch(noDirsRoot+'/health');assert.equal((await r.json()).server_downloads,false);
 r=await fetch(noDirsRoot+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io'}});assert.equal(r.status,200);const noDirsData=await r.json();
 r=await fetch(noDirsRoot+'/api/downloads/'+noDirsData.movies_path.split('/').at(-1),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'movie',stream_id:'7',container_extension:'mp4',filename:'X.mp4'})});
 assert.equal(r.status,503);assert.equal((await r.json()).error,'server_downloads_unavailable');
 noDirs.closeAllConnections();await new Promise(resolve=>noDirs.close(resolve));
 console.log('PASS server downloads: disk-full job error and unconfigured gateway reports server_downloads false');
 clock+=14400001;r=await fetch(root+data.streams['7']);assert.equal(r.status,401);r=await fetch(root+data.movies_path);assert.equal(r.status,401);
 assert.throws(()=>rewritePlaylist('not a playlist','http://example.invalid',()=>''),/invalid_playlist/);
 largeCatalog=true;
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io'}});
 assert.equal(r.status,200);const large=await r.json();assert.equal(large.channels.length,21001);assert.equal(Object.keys(large.streams).length,21001);assert.ok(large.streams['21001']);assert.ok(!JSON.stringify(large).includes('unused'));
 r=await fetch(root+large.streams['21001']);assert.equal(r.status,200);assert.ok((await r.text()).startsWith('#EXTM3U'));
 largeMovies=true;
 r=await fetch(root+large.movies_path);assert.equal(r.status,200);const overview=await r.json();assert.equal(overview.browse_by_category,true);assert.equal(overview.movies.length,0);assert.equal(overview.categories.length,3);
 const bulkRequests=()=>requests.filter(r=>r.url.searchParams.get('action')==='get_vod_streams'&&!r.url.searchParams.has('category_id')).length;
 const before=bulkRequests();r=await fetch(root+large.movies_path);assert.equal(r.status,200);await r.json();assert.equal(bulkRequests(),before);
 const categoriesReplies=await Promise.all([fetch(root+large.movies_path+'?category_id=9'),fetch(root+large.movies_path+'?category_id=9')]);const selected=await categoriesReplies[0].json();await categoriesReplies[1].json();assert.equal(selected.category_id,'9');assert.equal(selected.movies[0].name,'Dummy movie');assert.ok(!JSON.stringify(selected).includes('dummy-password'));assert.equal(requests.filter(r=>r.url.searchParams.get('category_id')==='9').length,1);
 for(const category of ['10','11','9']){r=await fetch(root+large.movies_path+'?category_id='+category);assert.equal(r.status,200);assert.equal((await r.json()).category_id,category)}
 assert.equal(requests.filter(r=>r.url.searchParams.get('category_id')==='9').length,2);
 for(const category of ['999','bad','9%26password=bad']){const count=requests.length;r=await fetch(root+large.movies_path+'?category_id='+category);assert.equal(r.status,400);assert.equal(requests.length,count)}
 r=await fetch(root+selected.streams[7]);assert.equal(r.status,200);await r.text();
 largeSeries=true;
 r=await fetch(root+large.series_path);assert.equal(r.status,200);const seriesOverview=await r.json();assert.equal(seriesOverview.browse_by_category,true);assert.equal(seriesOverview.series.length,0);assert.equal(seriesOverview.categories.length,3);
 const bulkSeriesRequests=()=>requests.filter(r=>r.url.searchParams.get('action')==='get_series'&&!r.url.searchParams.has('category_id')).length;
 const seriesBefore=bulkSeriesRequests();r=await fetch(root+large.series_path);assert.equal(r.status,200);await r.json();assert.equal(bulkSeriesRequests(),seriesBefore);
 const seriesCategoriesReplies=await Promise.all([fetch(root+large.series_path+'?category_id=9'),fetch(root+large.series_path+'?category_id=9')]);const seriesSelected=await seriesCategoriesReplies[0].json();await seriesCategoriesReplies[1].json();assert.equal(seriesSelected.category_id,'9');assert.equal(seriesSelected.series[0].name,'Dummy series');assert.ok(!JSON.stringify(seriesSelected).includes('dummy-password'));assert.equal(requests.filter(r=>r.url.searchParams.get('category_id')==='9'&&r.url.searchParams.get('action')==='get_series').length,1);
 for(const category of ['10','11','9']){r=await fetch(root+large.series_path+'?category_id='+category);assert.equal(r.status,200);assert.equal((await r.json()).category_id,category)}
 for(const category of ['999','bad','9%26password=bad']){const count=requests.length;r=await fetch(root+large.series_path+'?category_id='+category);assert.equal(r.status,400);assert.equal(requests.length,count)}
 console.log('PASS 50,001-series catalog automatically switches to categories; scoped provider requests, cache/coalescing, eviction and category validation preserve playable opaque links');
 console.log('PASS 50,001-movie catalog automatically switches to categories; scoped provider requests, cache/coalescing, eviction and category validation preserve playable opaque links');
 console.log('PASS catalog above 15 MiB and 20,000 channels, UTF-8/chunk boundaries, metadata projection, malformed JSON and bounded parser limits');
 console.log('PASS gateway auth, CORS, SSRF protections, vault retrieval, opaque stream links, HLS playlist/key/segment relay, ranges, expiry and no-store');
}finally{gateway.closeAllConnections();await new Promise(resolve=>gateway.close(resolve));await rm(dlMoviesDir,{recursive:true,force:true});await rm(dlTvDir,{recursive:true,force:true})}

console.log('PASS lazy/coalesced movie catalog, opaque movie/poster URLs, container extension, range forwarding and movie session expiry');
