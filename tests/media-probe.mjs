import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {Readable} from 'node:stream';
import {createGateway,probeMedia} from '../gateway/server.mjs';
await assert.rejects(()=>probeMedia('https://provider.example.invalid/private'),/unsafe_probe/);
await assert.rejects(()=>probeMedia('http://127.0.0.1:8787/media/a/b?password=dummy'),/unsafe_probe/);
const media=await new Promise((resolve,reject)=>execFile('ffmpeg',['-v','quiet','-f','lavfi','-i','testsrc2=size=1280x720:rate=5','-t','1','-an','-c:v','libx264','-threads','1','-preset','ultrafast','-f','mpegts','pipe:1'],{encoding:'buffer',maxBuffer:5*1024*1024},(err,stdout)=>err?reject(err):resolve(stdout)));
const response=(body,type)=>Object.assign(Readable.from([Buffer.isBuffer(body)?body:Buffer.from(body)]),{statusCode:200,headers:{'content-type':type}});
const server=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy',fetchVault:async()=>({ok:true,json:async()=>({saved:true,server_url:'http://provider.example.invalid',username:'dummy-user',password:'dummy-pass'})}),upstream:async input=>{
 const url=new URL(input);
 if(url.pathname==='/player_api.php')return{url,response:response(JSON.stringify(url.searchParams.get('action')==='get_live_streams'?[{stream_id:7,name:'HD test',category_id:1}]:[]),'application/json')};
 if(url.pathname.endsWith('.m3u8'))return{url,response:response('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n','application/vnd.apple.mpegurl')};
 return{url,response:response(media,'video/mp2t')};
}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const root='http://127.0.0.1:'+server.address().port;
try{
 const connect=await fetch(root+'/api/connect',{method:'POST',headers:{Authorization:'Bearer dummy'}});const data=await connect.json();
 const result=await fetch(root+data.streams[7].replace('/media/','/inspect/'));assert.equal(result.status,200);const info=await result.json();
 assert.equal(info.streams[0].codec,'h264');assert.equal(info.streams[0].width,1280);assert.equal(info.streams[0].height,720);
 assert.ok(!JSON.stringify(info).includes('dummy'));
 const repeat=await fetch(root+data.streams[7].replace('/media/','/inspect/'));assert.deepEqual(await repeat.json(),info);
 const invalid=await fetch(root+'/inspect/invalid/invalid');assert.equal(invalid.status,401);
 console.log('PASS real ffprobe reads HD HLS through opaque relay, returns sanitized codec/resolution, caches results and rejects invalid tickets/targets');
}finally{server.closeAllConnections();await new Promise(r=>server.close(r))}
