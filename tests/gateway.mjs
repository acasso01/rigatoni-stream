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
let clock=Date.now(),largeCatalog=false;const requests=[];
const fakeResponse=(body,headers={})=>Object.assign(Readable.from([Buffer.from(body)]),{statusCode:200,headers});
const fakeUpstream=async(input,options={})=>{
 const url=new URL(input);requests.push({url,options});
 if(largeCatalog&&url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_live_streams'){
   async function* catalog(){yield Buffer.from('[');for(let i=1;i<=21001;i++)yield Buffer.from((i>1?',':'')+JSON.stringify({stream_id:i,name:'Large channel '+i,category_id:1,unused:'x'.repeat(1024)}));yield Buffer.from(']');}
   return{url,response:Object.assign(Readable.from(catalog()),{statusCode:200,headers:{}})};
 }
 if(url.pathname==='/player_api.php')return{url,response:fakeResponse(JSON.stringify(url.searchParams.get('action')==='get_live_streams'?[{name:'Dummy test channel',stream_id:7,category_id:1,stream_icon:'http://private.invalid/secret.png'}]:[{category_id:1,category_name:'Dummy'}]))};
 if(url.pathname.endsWith('.m3u8'))return{url,response:fakeResponse('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:4,\nsegment.ts\n',{'content-type':'application/vnd.apple.mpegurl'})};
 return{url,response:fakeResponse('dummy-media-bytes',{'content-type':'video/mp2t','content-length':'17'})};
};
const gateway=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy-public-key',now:()=>clock,upstream:fakeUpstream,fetchVault:async(url,options)=>{
 assert.equal(url,'https://vault.example.invalid/functions/v1/provider-vault');assert.equal(options.cache,'no-store');
 if(options.headers.Authorization!=='Bearer dummy-auth')return{ok:false,status:401};
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
 r=await fetch(root+data.streams['7']);assert.equal(r.status,200);const playlist=await r.text();assert.ok(!playlist.includes('http://'));assert.ok(!playlist.includes('dummy-password'));const paths=[...playlist.matchAll(/\/media\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+/g)].map(m=>m[0]);assert.equal(paths.length,2);
 for(const path of paths){r=await fetch(root+path);assert.equal(r.status,200);assert.equal(await r.text(),'dummy-media-bytes')}
 r=await fetch(root+paths[1],{headers:{Range:'bytes=0-10'}});assert.equal(requests.at(-1).options.range,'bytes=0-10');await r.text();
 r=await fetch(root+paths[1],{headers:{Range:'bytes=0-1,3-4'}});assert.equal(r.status,400);
 r=await fetch(root+'/media/not-a-session/not-a-resource');assert.equal(r.status,401);
 clock+=14400001;r=await fetch(root+data.streams['7']);assert.equal(r.status,401);
 assert.throws(()=>rewritePlaylist('not a playlist','http://example.invalid',()=>''),/invalid_playlist/);
 largeCatalog=true;
 r=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy-auth',Origin:'https://acasso01.github.io'}});
 assert.equal(r.status,200);const large=await r.json();assert.equal(large.channels.length,21001);assert.equal(Object.keys(large.streams).length,21001);assert.ok(large.streams['21001']);assert.ok(!JSON.stringify(large).includes('unused'));
 r=await fetch(root+large.streams['21001']);assert.equal(r.status,200);assert.ok((await r.text()).startsWith('#EXTM3U'));
 console.log('PASS catalog above 15 MiB and 20,000 channels, UTF-8/chunk boundaries, metadata projection, malformed JSON and bounded parser limits');
 console.log('PASS gateway auth, CORS, SSRF protections, vault retrieval, opaque stream links, HLS playlist/key/segment relay, ranges, expiry and no-store');
}finally{gateway.closeAllConnections();await new Promise(resolve=>gateway.close(resolve))}
