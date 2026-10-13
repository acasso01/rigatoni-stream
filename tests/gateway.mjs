import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {createGateway,checkedTarget,publicAddress,rewritePlaylist,providerArray} from '../gateway/server.mjs';
const unicode=JSON.stringify([{name:'Café 🍝',extra:{value:'braces } and escaped " quotes',array:[1,2]}}]);
const parsed=await providerArray(Readable.from([...Buffer.from(unicode)].map(byte=>Buffer.from([byte]))),c=>({name:c.name}));
assert.deepEqual(parsed,[{name:'Café 🍝'}]);
for(const malformed of ['{}','[{"a":1},]','[{"a":1}] garbage','[{"a":1}','[{"a":1} {"a":2}]'])await assert.rejects(()=>providerArray(Readable.from([Buffer.from(malformed)]),c=>c));
await assert.rejects(()=>providerArray(Readable.from([Buffer.from('[{},{}]')]),c=>c,{maxItems:1}),/catalog_too_large/);
await assert.rejects(()=>providerArray(Readable.from([Buffer.from('[{}]')]),c=>c,{maxBytes:3}),/response_too_large/);
await assert.rejects(()=>providerArray(Readable.from([Buffer.from('[{"a":"too long"}]')]),c=>c,{maxItemBytes:5}),/response_too_large/);
for(const address of ['127.0.0.1','10.1.2.3','172.16.1.1','192.168.1.10','169.254.169.254','100.78.38.112','0.0.0.0','224.0.0.1','::1','fe80::1','fc00::1','::ffff:127.0.0.1','2001:db8::1','2002:7f00:1::'])assert.equal(publicAddress(address),false,address);
for(const address of ['8.8.8.8','1.1.1.1','2606:4700:4700::1111'])assert.equal(publicAddress(address),true,address);
await assert.rejects(()=>checkedTarget('http://provider.example.invalid',async()=>[{address:'8.8.8.8',family:4},{address:'127.0.0.1',family:4}]),/unsafe_target/);
await assert.rejects(()=>checkedTarget('file:///etc/passwd'),/unsafe_target/);
await assert.rejects(()=>checkedTarget('http://user:pass@8.8.8.8'),/unsafe_target/);
let clock=Date.now(),largeCatalog=false,largeMovies=false;const requests=[];
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
 if(url.pathname==='/player_api.php')return{url,response:fakeResponse(JSON.stringify(url.searchParams.get('action')==='get_live_streams'?[{name:'Dummy test channel',stream_id:7,category_id:1,stream_icon:'http://private.invalid/secret.png'}]:[{category_id:1,category_name:'Dummy'}]))};
 if(url.pathname.endsWith('.m3u8'))return{url,response:fakeResponse('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:4,\nsegment.ts\n',{'content-type':'application/vnd.apple.mpegurl'})};
 return{url,response:fakeResponse('dummy-media-bytes',{'content-type':'video/mp2t','content-length':'17'})};
};
const gateway=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy-public-key',now:()=>clock,upstream:fakeUpstream,probe:async url=>{assert.match(url,/^http:\/\/127\.0\.0\.1:\d+\/media\//);return{streams:[{type:'video',codec:'h264',width:1920,height:1080}]}},fetchVault:async(url,options)=>{
 assert.ok(url.startsWith('https://vault.example.invalid/functions/v1/provider-vault'));assert.equal(options.cache,'no-store');
 if(options.headers.Authorization!=='Bearer dummy-auth')return{ok:false,status:401};
 const idq=new URL(url).searchParams.get('id');
 if(idq==='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')return{ok:true,json:async()=>({saved:true,server_url:'http://provider2.example.invalid',username:'user2',password:'pass2'})};
 if(idq)return{ok:true,json:async()=>({saved:false})};
 return{ok:true,json:async()=>({saved:true,server_url:'http://provider.example.invalid',username:'dummy-user',password:'dummy-password'})};
}});
await new Promise(resolve=>gateway.listen(0,'127.0.0.1',resolve));
const root='http://127.0.0.1:'+gateway.address().port;
try{
 let r=await fetch(root+'/api/connect',{method:'POST'});assert.equal(r.status,401);
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer wrong'}});assert.equal(r.status,401);
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Origin:'https://untrusted.example.invalid',Authorization:'Bearer dummy-auth'}});assert.equal(r.status,403);
 r=await fetch(root+'/api/connect',{method:'OPTIONS',headers:{Origin:'https://acasso01.github.io'}});assert.equal(r.status,204);assert.equal(r.headers.get('access-control-allow-origin'),'https://acasso01.github.io');
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io'}});assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');const data=await r.json();assert.equal(data.channels.length,1);assert.equal(data.channels[0].stream_icon,'');assert.ok(!JSON.stringify(data).includes('dummy-password'));assert.ok(!JSON.stringify(data).includes('dummy-user'));
 r=await fetch(root+'/health');assert.equal(r.status,200);assert.deepEqual(await r.json(),{ok:true,service:'rigatoni-gateway',multi_provider:true});
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
 r=await fetch(root+data.streams['7'].replace('/media/','/inspect/'));assert.equal(r.status,200);assert.equal((await r.json()).streams[0].width,1920);
 r=await fetch(root+data.streams['7']);assert.equal(r.status,200);const playlist=await r.text();assert.ok(!playlist.includes('http://'));assert.ok(!playlist.includes('dummy-password'));const paths=[...playlist.matchAll(/\/media\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+/g)].map(m=>m[0]);assert.equal(paths.length,2);
 for(const path of paths){r=await fetch(root+path);assert.equal(r.status,200);assert.equal(await r.text(),'dummy-media-bytes')}
 r=await fetch(root+paths[1],{headers:{Range:'bytes=0-10'}});assert.equal(requests.at(-1).options.range,'bytes=0-10');await r.text();
 r=await fetch(root+paths[1],{headers:{Range:'bytes=0-1,3-4'}});assert.equal(r.status,400);
 r=await fetch(root+'/media/not-a-session/not-a-resource');assert.equal(r.status,401);
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
 console.log('PASS 50,001-movie catalog automatically switches to categories; scoped provider requests, cache/coalescing, eviction and category validation preserve playable opaque links');
 console.log('PASS catalog above 15 MiB and 20,000 channels, UTF-8/chunk boundaries, metadata projection, malformed JSON and bounded parser limits');
 console.log('PASS gateway auth, CORS, SSRF protections, vault retrieval, opaque stream links, HLS playlist/key/segment relay, ranges, expiry and no-store');
}finally{gateway.closeAllConnections();await new Promise(resolve=>gateway.close(resolve))}

console.log('PASS lazy/coalesced movie catalog, opaque movie/poster URLs, container extension, range forwarding and movie session expiry');
