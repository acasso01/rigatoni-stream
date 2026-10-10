import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {Readable} from 'node:stream';
import {createGateway} from '../gateway/server.mjs';
import {remuxArguments} from '../gateway/remux.mjs';
const input='http://127.0.0.1:8787/media/session/resource';
const args=remuxArguments(input,'/tmp/dummy',['-allowed_extensions','ALL']);
assert.equal(args[args.indexOf('-c:v')+1],'copy');assert.equal(args[args.indexOf('-c:a')+1],'copy');assert.ok(!args.includes('-vf'));assert.ok(!args.includes('-s'));
assert.ok(remuxArguments(input,'/tmp/dummy',[],'hevc').includes('hvc1'));
assert.throws(()=>remuxArguments('http://provider.example.invalid/secret','/tmp/dummy'),/unsafe_target/);
const command=(bin,args,encoding='buffer')=>new Promise((resolve,reject)=>execFile(bin,args,{encoding,maxBuffer:12*1024*1024,timeout:30000},(err,out)=>err?reject(err):resolve(out)));
for(const [width,height] of [[1920,1080],[3840,2160]]){
const media=await command('ffmpeg',['-v','quiet','-f','lavfi','-i','testsrc2=size='+width+'x'+height+':rate=2','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','6','-c:v','libx264','-threads','1','-preset','ultrafast','-g','2','-c:a','aac','-f','mpegts','pipe:1']);
const response=(body,type)=>Object.assign(Readable.from([Buffer.isBuffer(body)?body:Buffer.from(body)]),{statusCode:200,headers:{'content-type':type}});
const server=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy',fetchVault:async()=>({ok:true,json:async()=>({saved:true,server_url:'http://provider.example.invalid',username:'dummy-user',password:'dummy-pass'})}),upstream:async input=>{
 const url=new URL(input);
 if(url.pathname==='/player_api.php')return{url,response:response(JSON.stringify(url.searchParams.get('action')==='get_live_streams'?[{stream_id:7,name:'1080p test',category_id:1}]:[]),'application/json')};
 if(url.pathname.endsWith('.m3u8'))return{url,response:response('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n','application/vnd.apple.mpegurl')};
 return{url,response:response(media,'video/mp2t')};
}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));const root='http://127.0.0.1:'+server.address().port;
try{
 const connect=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy'}});const data=await connect.json();
 const compatible=root+data.streams[7].replace('/media/','/compatible/')+'/index.m3u8';
 let r=await fetch(compatible);assert.equal(r.status,200);const playlist=await r.text();assert.match(playlist,/#EXT-X-MAP/);assert.match(playlist,/init.mp4/);assert.match(playlist,/segment-\d+.m4s/);assert.ok(!playlist.includes('dummy-user'));assert.ok(!playlist.includes('dummy-pass'));
 const init=playlist.match(/URI="([^"]+)"/)[1];r=await fetch(root+init,{headers:{Range:'bytes=0-31'}});assert.equal(r.status,206);assert.equal((await r.arrayBuffer()).byteLength,32);
 const segments=playlist.split('\n').filter(s=>s.startsWith('/compatible/'));for(const path of segments){r=await fetch(root+path);assert.equal(r.status,200);assert.ok((await r.arrayBuffer()).byteLength>0)}
 const info=JSON.parse(await command('ffprobe',['-v','quiet','-show_entries','stream=codec_name,codec_type,width,height','-of','json',compatible],'utf8'));
 assert.ok(info.streams.some(s=>s.codec_name==='h264'&&s.width===width&&s.height===height));assert.ok(info.streams.some(s=>s.codec_name==='aac'));
 const decoded=await command('ffmpeg',['-v','error','-i',compatible,'-frames:v','2','-an','-f','framemd5','pipe:1'],'utf8');assert.ok(decoded.split('\n').filter(s=>s&&!s.startsWith('#')).length===2);
 r=await fetch(compatible.replace('index.m3u8','stop'),{method:'POST'});assert.equal(r.status,200);assert.equal((await r.json()).stopped,true);
 r=await fetch(compatible.replace('index.m3u8','../anything'));assert.ok([401,404].includes(r.status));
 console.log('PASS real '+width+'x'+height+' H264/AAC repackaging: codec-copy/no resize, fMP4 HLS, init/segments, Safari byte ranges, FFprobe metadata and decoded frames');
}finally{await server.closeCompatibility();server.closeAllConnections();await new Promise(r=>server.close(r))}

}
