import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {Readable} from 'node:stream';
import {createGateway,probeMedia,hlsProbeOptions,probeFailure} from '../gateway/server.mjs';
assert.deepEqual(hlsProbeOptions('allowed_extensions'),['-allowed_extensions','ALL']);
assert.deepEqual(hlsProbeOptions('allowed_extensions allowed_segment_extensions extension_picky'),['-allowed_extensions','ALL','-allowed_segment_extensions','ALL','-extension_picky','0']);
assert.equal(probeFailure({killed:true}),'media_probe_timeout');
assert.equal(probeFailure({},'URL http://dummy.invalid/secret is not in allowed_segment_extensions'),'media_probe_extension');
assert.equal(probeFailure({},'Failed to open segment http://dummy.invalid/secret'),'media_probe_download');
assert.equal(probeFailure({},'Invalid data found when processing input'),'media_probe_invalid');
await assert.rejects(()=>probeMedia('https://provider.example.invalid/private'),/unsafe_probe/);
await assert.rejects(()=>probeMedia('http://127.0.0.1:8787/media/a/b?password=dummy'),/unsafe_probe/);
const media=await new Promise((resolve,reject)=>execFile('ffmpeg',['-v','quiet','-f','lavfi','-i','testsrc2=size=1280x720:rate=5','-t','1','-an','-c:v','libx264','-threads','1','-preset','ultrafast','-f','mpegts','pipe:1'],{encoding:'buffer',maxBuffer:5*1024*1024},(err,stdout)=>err?reject(err):resolve(stdout)));
const movie=await new Promise((resolve,reject)=>execFile('ffmpeg',['-v','quiet','-f','lavfi','-i','testsrc2=size=1920x1080:rate=5','-t','1','-an','-c:v','libx264','-threads','1','-preset','ultrafast','-movflags','frag_keyframe+empty_moov','-f','mp4','pipe:1'],{encoding:'buffer',maxBuffer:5*1024*1024},(err,stdout)=>err?reject(err):resolve(stdout)));
const response=(body,type)=>Object.assign(Readable.from([Buffer.isBuffer(body)?body:Buffer.from(body)]),{statusCode:200,headers:{'content-type':type}});
const server=createGateway({supabaseUrl:'https://vault.example.invalid',publicKey:'dummy',fetchVault:async()=>({ok:true,json:async()=>({saved:true,server_url:'http://provider.example.invalid',username:'dummy-user',password:'dummy-pass'})}),upstream:async(input,options={})=>{
 const url=new URL(input);
 if(url.pathname==='/player_api.php'&&url.searchParams.get('action')==='get_vod_streams')return{url,response:response(JSON.stringify([{stream_id:8,name:'Movie test',container_extension:'mp4'}]),'application/json')};
 if(url.pathname.endsWith('.mp4')){let body=movie,status=200,headers={};if(options.range){const [,a,b]=options.range.match(/^bytes=(\d+)-(\d*)$/);const start=Number(a),end=b?Math.min(Number(b),movie.length-1):movie.length-1;body=movie.subarray(start,end+1);status=206;headers={'content-range':'bytes '+start+'-'+end+'/'+movie.length};}const stream=response(body,'video/mp4');stream.statusCode=status;stream.headers={...stream.headers,...headers,'content-length':String(body.length),'accept-ranges':'bytes'};return{url,response:stream}}
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
 const catalog=await fetch(root+data.movies_path);const movies=await catalog.json();const movieUrl=root+movies.streams[8];
 const ranged=await fetch(movieUrl,{headers:{Range:'bytes=0-31'}});assert.equal(ranged.status,206);assert.equal((await ranged.arrayBuffer()).byteLength,32);assert.match(ranged.headers.get('content-range'),/^bytes 0-31\//);
 const movieInfo=JSON.parse(await new Promise((resolve,reject)=>execFile('ffprobe',['-v','error','-show_entries','stream=codec_name,width,height','-of','json',movieUrl],{encoding:'utf8',timeout:15000},(err,out)=>err?reject(err):resolve(out))));assert.equal(movieInfo.streams[0].width,1920);assert.equal(movieInfo.streams[0].height,1080);
 console.log('PASS real 1080p MP4 movie catalog → opaque relay → HTTP 206 seeking → FFprobe');
 const invalid=await fetch(root+'/inspect/invalid/invalid');assert.equal(invalid.status,401);
 console.log('PASS real ffprobe reads HD HLS through opaque relay, returns sanitized codec/resolution, caches results and rejects invalid tickets/targets');
}finally{server.closeAllConnections();await new Promise(r=>server.close(r))}
