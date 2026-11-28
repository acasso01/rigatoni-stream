import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {execFileSync,spawnSync} from 'node:child_process';
const ctx=vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../web/fmp4.js',import.meta.url),'utf8'),ctx);
const {Demuxer,hevcCodec}=ctx.AntFmp4;
// HEVC codec string from a Main profile, level 4.0 hvcC header
const hv=new Uint8Array(23);hv[0]=1;hv[1]=0x01;hv[2]=0x60;hv[6]=0x90;hv[12]=120;
assert.equal(hevcCodec('hev1',hv),'hev1.1.6.L120.90');
if(spawnSync('ffmpeg',['-version']).status!==0){console.log('SKIP fmp4 demux (ffmpeg not installed)');process.exit(0)}
// Same muxer flags the gateway uses for the canvas engine
const mp4=execFileSync('ffmpeg',['-v','error','-f','lavfi','-i','testsrc=size=320x240:rate=25','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','3','-c:v','libx264','-preset','ultrafast','-g','25','-pix_fmt','yuv420p','-c:a','aac','-ac','2','-ar','48000','-f','mp4','-movflags','frag_keyframe+empty_moov+default_base_moof','-frag_duration','1000000','pipe:1'],{maxBuffer:64*1024*1024});
let init=null;const samples=[];
const d=new Demuxer({onInit:i=>init=i,onSamples:s=>samples.push(...s)});
// Feed in awkward chunk sizes, like a network stream
for(let o=0;o<mp4.length;o+=777)d.push(new Uint8Array(mp4.subarray(o,o+777)));
const tracks=[...init.tracks.values()];
const video=tracks.find(t=>t.kind==='video'),audio=tracks.find(t=>t.kind==='audio');
assert.match(video.codec,/^avc1\.[0-9a-f]{6}$/);assert.equal(video.width,320);assert.equal(video.height,240);assert.ok(video.description.length>8);
assert.equal(audio.codec,'mp4a.40.2');assert.equal(audio.sampleRate,48000);assert.equal(audio.channels,2);
const v=samples.filter(s=>s.kind==='video'),a=samples.filter(s=>s.kind==='audio');
assert.equal(v.length,75,'3 s at 25 fps');assert.ok(v[0].key&&v[25].key&&!v[1].key,'keyframe every 25 frames');
assert.ok(a.length>=130&&a.length<=145,'about 3 s of AAC frames: '+a.length);
const secs=v.at(-1).pts/v.at(-1).timescale;assert.ok(secs>2.8&&secs<3.1,'pts '+secs);
// Each video sample is a length-prefixed NAL unit stream (AVCC), as VideoDecoder expects with a description
const first=v[0].data;const nal=new DataView(first.buffer,first.byteOffset).getUint32(0);assert.ok(nal>0&&nal<first.length);
console.log('PASS fmp4 demux: gateway-style fragmented MP4 → avc1/mp4a configs, '+v.length+' video + '+a.length+' audio samples, keyframes and timestamps, chunked input');
