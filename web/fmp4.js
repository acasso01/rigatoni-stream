/* Ant Streams — streaming fragmented-MP4 demuxer for the WebCodecs canvas engine.
   Reads the gateway's ffmpeg fMP4 output (empty_moov + moof/mdat fragments) and emits
   track configs and samples for VideoDecoder / AudioDecoder. Classic script → globalThis.AntFmp4. */
(function(root){
'use strict';
const str=(b,o)=>String.fromCharCode(b[o],b[o+1],b[o+2],b[o+3]);
const view=b=>new DataView(b.buffer,b.byteOffset,b.byteLength);
const hex2=n=>n.toString(16).padStart(2,'0');
const CONTAINERS=new Set(['moov','trak','mdia','minf','stbl','mvex','moof','traf','dinf','edts']);
function* boxes(b,start=0,end=b.length){
  const v=view(b);let o=start;
  while(o+8<=end){
    let size=v.getUint32(o),hdr=8;const type=str(b,o+4);
    if(size===1){if(o+16>end)return;size=Number(v.getBigUint64(o+8));hdr=16}
    else if(size===0)size=end-o;
    if(size<hdr||o+size>end)return;
    yield {type,start:o,hdr,size,body:o+hdr,end:o+size};
    o+=size;
  }
}
function find(b,box,path){
  let cur=[box];
  for(const name of path){const next=[];for(const c of cur)for(const x of boxes(b,c.body+(c.skip||0),c.end))if(x.type===name)next.push(x);cur=next;if(!cur.length)return [];}
  return cur;
}
function readDescriptor(b,o){
  const tag=b[o++];let len=0;
  for(let i=0;i<4;i++){const c=b[o++];len=(len<<7)|(c&0x7f);if(!(c&0x80))break}
  return {tag,len,body:o,end:o+len};
}
function esdsConfig(b,box){
  let o=box.body+4;let d=readDescriptor(b,o);if(d.tag!==3)return null;
  o=d.body+2;const flags=b[o++];if(flags&0x80)o+=2;if(flags&0x40)o+=1+b[o];if(flags&0x20)o+=2;
  d=readDescriptor(b,o);if(d.tag!==4)return null;const oti=b[d.body];o=d.body+13;
  if(o>=d.end)return {oti,asc:null};
  const s=readDescriptor(b,o);if(s.tag!==5)return {oti,asc:null};
  return {oti,asc:b.slice(s.body,s.end)};
}
function hevcCodec(prefix,c){
  const space=['','A','B','C'][c[1]>>6],tier=(c[1]>>5)&1,profile=c[1]&0x1f;
  let compat=((c[2]<<24)|(c[3]<<16)|(c[4]<<8)|c[5])>>>0,rev=0;for(let i=0;i<32;i++){rev=(rev<<1)|(compat&1);compat>>>=1}rev>>>=0;
  const cons=[...c.slice(6,12)];while(cons.length&&cons[cons.length-1]===0)cons.pop();
  return prefix+'.'+space+profile+'.'+rev.toString(16)+'.'+(tier?'H':'L')+c[12]+(cons.length?'.'+cons.map(x=>x.toString(16)).join('.'):'');
}
function parseMoov(b,moov){
  const v=view(b);const tracks=new Map();
  for(const trak of find(b,moov,['trak'])){
    const tkhd=find(b,trak,['tkhd'])[0],mdhd=find(b,trak,['mdia','mdhd'])[0],hdlr=find(b,trak,['mdia','hdlr'])[0],stsd=find(b,trak,['mdia','minf','stbl','stsd'])[0];
    if(!tkhd||!mdhd||!hdlr||!stsd)continue;
    const id=v.getUint32(tkhd.body+(b[tkhd.body]===1?20:12));
    const timescale=v.getUint32(mdhd.body+(b[mdhd.body]===1?20:12));
    const handler=str(b,hdlr.body+8);
    const entry=[...boxes(b,stsd.body+8,stsd.end)][0];if(!entry)continue;
    const t={id,timescale,handler,format:entry.type};
    if(handler==='vide'){
      t.kind='video';t.width=v.getUint16(entry.body+24);t.height=v.getUint16(entry.body+26);
      for(const c of boxes(b,entry.body+78,entry.end)){
        if(c.type==='avcC'){const d=b.slice(c.body,c.end);t.description=d;t.codec='avc1.'+hex2(d[1])+hex2(d[2])+hex2(d[3])}
        if(c.type==='hvcC'){const d=b.slice(c.body,c.end);t.description=d;t.codec=hevcCodec(entry.type==='hvc1'?'hvc1':'hev1',d)}
      }
    }else if(handler==='soun'){
      t.kind='audio';t.channels=v.getUint16(entry.body+16);t.sampleRate=v.getUint32(entry.body+24)>>>16;
      for(const c of boxes(b,entry.body+28,entry.end)){
        if(c.type==='esds'){const cfg=esdsConfig(b,c);if(cfg?.asc&&cfg.asc.length){t.description=cfg.asc;t.codec='mp4a.40.'+(cfg.asc[0]>>3);const sfi=((cfg.asc[0]&7)<<1)|(cfg.asc[1]>>7);const rates=[96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350];if(rates[sfi])t.sampleRate=rates[sfi];const ch=(cfg.asc[1]>>3)&15;if(ch)t.channels=ch}else if(cfg)t.codec=cfg.oti===0x6b?'mp3':'mp4a.40.2'}
        if(c.type==='Opus'||c.type==='dOps')t.codec='opus';
      }
      if(entry.type==='Opus')t.codec='opus';
    }else continue;
    tracks.set(id,t);
  }
  const defaults=new Map();
  for(const trex of find(b,moov,['mvex','trex'])){const o=trex.body+4;defaults.set(v.getUint32(o),{duration:v.getUint32(o+8),size:v.getUint32(o+12),flags:v.getUint32(o+16)})}
  return {tracks,defaults};
}
// Parse one moof+mdat pair (bytes start at the moof) into samples.
function parseFragment(b,init){
  const v=view(b);const moof=[...boxes(b)].find(x=>x.type==='moof');if(!moof)return [];
  const out=[];
  for(const traf of find(b,moof,['traf'])){
    const tfhd=find(b,traf,['tfhd'])[0];if(!tfhd)continue;
    const f=v.getUint32(tfhd.body)&0xffffff;let o=tfhd.body+4;const id=v.getUint32(o);o+=4;
    const track=init.tracks.get(id);if(!track)continue;const def={...(init.defaults.get(id)||{duration:0,size:0,flags:0})};
    let base=moof.start;if(f&1){base=Number(v.getBigUint64(o));o+=8}if(f&2)o+=4;if(f&8){def.duration=v.getUint32(o);o+=4}if(f&0x10){def.size=v.getUint32(o);o+=4}if(f&0x20){def.flags=v.getUint32(o);o+=4}
    const tfdt=find(b,traf,['tfdt'])[0];let dts=0;
    if(tfdt)dts=b[tfdt.body]===1?Number(v.getBigUint64(tfdt.body+4)):v.getUint32(tfdt.body+4);
    for(const trun of find(b,traf,['trun'])){
      const ver=b[trun.body],tf=v.getUint32(trun.body)&0xffffff;let p=trun.body+4;const count=v.getUint32(p);p+=4;
      let dataOffset=0;if(tf&1){dataOffset=v.getInt32(p);p+=4}let firstFlags=null;if(tf&4){firstFlags=v.getUint32(p);p+=4}
      let pos=base+dataOffset;
      for(let i=0;i<count;i++){
        const dur=tf&0x100?v.getUint32((p+=4)-4):def.duration;
        const size=tf&0x200?v.getUint32((p+=4)-4):def.size;
        let flags=tf&0x400?v.getUint32((p+=4)-4):(i===0&&firstFlags!==null?firstFlags:def.flags);
        const cts=tf&0x800?(ver===1?v.getInt32((p+=4)-4):v.getUint32((p+=4)-4)):0;
        if(pos+size>b.length)break;
        const key=track.kind==='audio'?true:!((flags>>>16)&1);
        out.push({track:id,kind:track.kind,key,dts,pts:dts+cts,duration:dur,timescale:track.timescale,data:b.subarray(pos,pos+size)});
        pos+=size;dts+=dur;
      }
    }
  }
  return out;
}
// Streaming reader: push(bytes) as they arrive; callbacks fire for init and each fragment.
class Demuxer{
  constructor({onInit,onSamples}){this.onInit=onInit;this.onSamples=onSamples;this.buf=new Uint8Array(0);this.init=null;this.moof=null}
  push(chunk){
    if(chunk&&chunk.length){const n=new Uint8Array(this.buf.length+chunk.length);n.set(this.buf);n.set(chunk,this.buf.length);this.buf=n}
    for(;;){
      if(this.buf.length<8)return;
      const v=view(this.buf);let size=v.getUint32(0);const type=str(this.buf,4);
      if(size===1){if(this.buf.length<16)return;size=Number(v.getBigUint64(8))}
      if(size<8||size>256*1024*1024)throw Object.assign(Error('Invalid media stream'),{code:'STREAM_INVALID'});
      if(this.buf.length<size)return;
      const box=this.buf.slice(0,size);this.buf=this.buf.slice(size);
      if(type==='moov'){this.init=parseMoov(box,{type,start:0,hdr:8,size,body:8,end:size});this.onInit?.(this.init)}
      else if(type==='moof')this.moof=box;
      else if(type==='mdat'&&this.moof&&this.init){const both=new Uint8Array(this.moof.length+box.length);both.set(this.moof);both.set(box,this.moof.length);this.moof=null;this.onSamples?.(parseFragment(both,this.init))}
    }
  }
}
const api={Demuxer,parseMoov,parseFragment,boxes,hevcCodec};
root.AntFmp4=api;
if(typeof module==='object'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:window);
