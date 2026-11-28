// IPTV relay helpers for the web player (Gigaplay-style playback).
// Everything here runs on the Pi. Provider credentials, M3U links and the TMDB key stay
// server-side; the browser only ever sees opaque /media/<session>/<key> tickets.
import {spawn as nodeSpawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';

export const XTREAM_ACTIONS={
  get_live_categories:{},
  get_live_streams:{category_id:/^\d{1,20}$/},
  get_vod_categories:{},
  get_vod_streams:{category_id:/^\d{1,20}$/},
  get_vod_info:{vod_id:/^\d{1,20}$/},
  get_series_categories:{},
  get_series:{category_id:/^\d{1,20}$/},
  get_series_info:{series_id:/^\d{1,20}$/},
  get_short_epg:{stream_id:/^\d{1,20}$/,limit:/^\d{1,2}$/},
  get_simple_data_table:{stream_id:/^\d{1,20}$/}
};
export function xtreamQuery(search){
  const params=new URLSearchParams(search);const action=params.get('action');
  const allowed=Object.hasOwn(XTREAM_ACTIONS,action||'')?XTREAM_ACTIONS[action]:null;
  if(!allowed)throw Object.assign(Error('action_not_allowed'),{status:400});
  const out={action};
  for(const [key,value] of params){
    if(key==='action')continue;
    if(!Object.hasOwn(allowed,key)||!allowed[key].test(value))throw Object.assign(Error('invalid_parameter'),{status:400});
    out[key]=value;
  }
  return out;
}
const IMAGE_KEYS=new Set(['stream_icon','cover','cover_big','movie_image','logo','backdrop']);
const DROP_KEYS=new Set(['user_info','server_info','direct_source','password','username']);
// Remove anything that could carry credentials and swap artwork for opaque tickets.
export function sanitizeProviderJson(value,{secrets=[],register=null,depth=0}={}){
  if(depth>12)return null;
  const hasSecret=s=>secrets.some(x=>x&&s.includes(x));
  if(typeof value==='string'){if(hasSecret(value)||hasSecret(safeDecode(value)))return '';return value.length>8192?value.slice(0,8192):value}
  if(Array.isArray(value))return value.slice(0,200000).map(v=>sanitizeProviderJson(v,{secrets,register,depth:depth+1}));
  if(value&&typeof value==='object'){
    const out={};
    for(const [k,v] of Object.entries(value)){
      if(DROP_KEYS.has(k))continue;
      if(register&&(IMAGE_KEYS.has(k)||k==='backdrop_path')){
        const images=Array.isArray(v)?v:[v];const mapped=[];
        for(const img of images){if(typeof img!=='string'||!/^https?:\/\//i.test(img)){continue}try{mapped.push(register(new URL(img)))}catch{}}
        out[k]=Array.isArray(v)?mapped:(mapped[0]||'');continue;
      }
      out[k]=sanitizeProviderJson(v,{secrets,register,depth:depth+1});
    }
    return out;
  }
  return value;
}
function safeDecode(s){try{return decodeURIComponent(s)}catch{return s}}

// ---- M3U ----
const attr=(line,name)=>{const m=line.match(new RegExp('\\b'+name+'="([^"]*)"','i'));return m?m[1].trim():''};
export function parseM3U(text,{maxItems=100000}={}){
  const source=String(text||'').replace(/^\uFEFF/,'');
  if(!source.trimStart().startsWith('#EXTM3U'))throw Error('invalid_playlist');
  const lines=source.split(/\r?\n/);const header=lines[0];
  const epgUrl=(attr(header,'url-tvg')||attr(header,'x-tvg-url')).split(',')[0].trim();
  const channels=[];let pending=null,group='';
  for(const raw of lines.slice(1)){
    const line=raw.trim();if(!line)continue;
    if(line.startsWith('#EXTINF')){
      const comma=line.indexOf(',',line.lastIndexOf('"')>0?line.lastIndexOf('"'):0);
      pending={name:(comma>=0?line.slice(comma+1):'').trim().slice(0,512),tvg_id:attr(line,'tvg-id').slice(0,256),tvg_name:attr(line,'tvg-name').slice(0,512),logo:attr(line,'tvg-logo').slice(0,2048),group:attr(line,'group-title').slice(0,256),catchup:attr(line,'catchup')||attr(line,'tvg-rec')?true:false};
      continue;
    }
    if(line.startsWith('#EXTGRP:')){group=line.slice(8).trim().slice(0,256);continue}
    if(line.startsWith('#'))continue;
    if(!pending)pending={name:'',tvg_id:'',tvg_name:'',logo:'',group:'',catchup:false};
    let url;try{url=new URL(line)}catch{pending=null;continue}
    if(!['http:','https:'].includes(url.protocol)){pending=null;continue}
    if(channels.length>=maxItems)throw Error('catalog_too_large');
    channels.push({...pending,group:pending.group||group||'Channels',name:pending.name||pending.tvg_name||'Channel '+(channels.length+1),url:url.href});
    pending=null;
  }
  if(!channels.length)throw Error('invalid_playlist');
  return {epgUrl,channels};
}
// Classify M3U entries the same way Xtream labels them: /movie/ and /series/ paths are VOD.
export function m3uKind(url){const p=new URL(url).pathname;return /\/movie\//.test(p)?'movie':/\/series\//.test(p)?'episode':'live'}

// ---- EPG ----
const b64=s=>{try{const t=Buffer.from(String(s||''),'base64').toString('utf8');return /\uFFFD/.test(t)?String(s||''):t}catch{return String(s||'')}};
export function decodeShortEpg(json,{limit=8}={}){
  const list=Array.isArray(json?.epg_listings)?json.epg_listings:[];
  return list.slice(0,limit).map(e=>{
    const start=Number(e.start_timestamp)||Math.floor(Date.parse(String(e.start||'').replace(' ','T')+'Z')/1000)||0;
    const end=Number(e.stop_timestamp)||Math.floor(Date.parse(String(e.end||e.stop||'').replace(' ','T')+'Z')/1000)||0;
    return {title:b64(e.title).slice(0,200),description:b64(e.description).slice(0,600),start,end};
  }).filter(e=>e.start&&e.end>e.start);
}
export function xmltvTime(s){
  const m=String(s||'').match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-]\d{4})?/);if(!m)return 0;
  let t=Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5],+(m[6]||0))/1000;
  if(m[7]){const sign=m[7][0]==='-'?-1:1;t-=sign*(Number(m[7].slice(1,3))*3600+Number(m[7].slice(3,5))*60)}
  return t;
}
const unxml=s=>String(s||'').replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g,'$1').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&apos;/g,"'").replace(/&#(\d+);/g,(_m,n)=>String.fromCodePoint(Number(n))).replace(/&amp;/g,'&').trim();
export function parseXmltv(text,{channels,from,to,perChannel=12}={}){
  const out=new Map();
  const re=/<programme\b([^>]*)>([\s\S]*?)<\/programme>/g;let m;
  while((m=re.exec(text))){
    const attrs=m[1];const ch=unxml((attrs.match(/channel="([^"]*)"/)||[])[1]);
    if(!ch||channels&&!channels.has(ch))continue;
    const start=xmltvTime((attrs.match(/start="([^"]*)"/)||[])[1]),end=xmltvTime((attrs.match(/stop="([^"]*)"/)||[])[1]);
    if(!start||end<=start||end<from||start>to)continue;
    const list=out.get(ch)||[];if(list.length>=perChannel)continue;
    list.push({title:unxml((m[2].match(/<title[^>]*>([\s\S]*?)<\/title>/)||[])[1]).slice(0,200),description:unxml((m[2].match(/<desc[^>]*>([\s\S]*?)<\/desc>/)||[])[1]).slice(0,600),start,end});
    out.set(ch,list);
  }
  for(const list of out.values())list.sort((a,b)=>a.start-b.start);
  return out;
}

// ---- Host allowlist (on top of checkedTarget's private-address SSRF block) ----
export function parseAllowList(value){return String(value||'').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean)}
export function hostAllowed(url,list){
  if(!list.length)return true;
  const host=new URL(url).hostname.toLowerCase().replace(/^\[|\]$/g,'');
  return list.some(rule=>rule.startsWith('*.')?host.endsWith(rule.slice(1))&&host.length>rule.length-1:host===rule);
}

// ---- ffmpeg arguments: input is always our own loopback opaque relay ----
export function assertRelayInput(input){
  const url=new URL(input);
  if(url.protocol!=='http:'||url.hostname!=='127.0.0.1'||!/^\/media\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/.test(url.pathname)||url.search||url.hash||url.username||url.password)throw Error('unsafe_target');
  return url.href;
}
export function fmp4Arguments(input,{video='copy',start=0,live=true,height=1080,hlsOptions=[]}={}){
  const src=assertRelayInput(input);
  const seek=!live&&start>0?['-ss',String(Math.floor(start))]:[];
  const v=video==='transcode'
    ?['-c:v','libx264','-preset','veryfast','-tune','zerolatency','-profile:v','high','-level:v','4.1','-pix_fmt','yuv420p','-g','48','-keyint_min','48','-sc_threshold','0','-vf','scale=-2:min('+Math.max(240,Math.min(2160,Number(height)||1080))+'\\,ih)']
    :['-c:v','copy'];
  return ['-nostdin','-v','error','-protocol_whitelist','http,tcp,crypto',...hlsOptions,'-rw_timeout','15000000','-fflags','+genpts+discardcorrupt',...(live?[]:['-re']),...seek,'-i',src,
    '-map','0:v:0','-map','0:a:0?',...v,'-c:a','aac','-b:a','160k','-ac','2','-ar','48000',
    '-f','mp4','-movflags','frag_keyframe+empty_moov+default_base_moof','-frag_duration','1000000','-muxdelay','0','pipe:1'];
}
export function tsArguments(input,{hlsOptions=[]}={}){
  const src=assertRelayInput(input);
  return ['-nostdin','-v','error','-protocol_whitelist','http,tcp,crypto',...hlsOptions,'-rw_timeout','15000000','-fflags','+genpts+discardcorrupt','-i',src,'-map','0:v:0','-map','0:a:0?','-c','copy','-f','mpegts','pipe:1'];
}
// Live remux processes: bounded count, killed when the viewer goes away.
export function createLiveTranscoder({spawn=nodeSpawn,maxJobs=2}={}){
  const jobs=new Set();
  return {
    get size(){return jobs.size},
    start(args,res,contentType){
      if(jobs.size>=maxJobs)throw Error('transcoder_busy');
      const child=spawn('ffmpeg',args,{stdio:['ignore','pipe','ignore']});jobs.add(child);
      const end=()=>{if(jobs.delete(child)){try{child.kill('SIGKILL')}catch{}}};
      child.on('error',()=>{end();if(!res.headersSent){res.writeHead(502,{'Content-Type':'application/json'});res.end('{"error":"transcoder_unavailable"}')}else res.destroy()});
      child.on('exit',()=>{jobs.delete(child);if(!res.writableEnded)res.end()});
      res.on('close',end);
      res.writeHead(200,{'Content-Type':contentType,'Cache-Control':'no-store','X-Accel-Buffering':'no'});
      child.stdout.pipe(res);
      return child;
    },
    close(){for(const child of jobs){try{child.kill('SIGKILL')}catch{}}jobs.clear()}
  };
}

// ---- TMDB trending (key stays on the Pi) ----
export function trendingTitles(json){
  return (Array.isArray(json?.results)?json.results:[]).slice(0,20).map(r=>({title:String(r.title||r.name||'').trim().slice(0,200),year:String(r.release_date||r.first_air_date||'').slice(0,4),poster:/^\/[A-Za-z0-9_-]+\.(jpg|png)$/.test(r.poster_path||'')?'https://image.tmdb.org/t/p/w342'+r.poster_path:'',backdrop:/^\/[A-Za-z0-9_-]+\.(jpg|png)$/.test(r.backdrop_path||'')?'https://image.tmdb.org/t/p/w780'+r.backdrop_path:'',overview:String(r.overview||'').slice(0,400)})).filter(r=>r.title);
}
export const ticket=()=>randomBytes(24).toString('base64url');
