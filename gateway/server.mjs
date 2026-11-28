import http from 'node:http';
import https from 'node:https';
import {lookup} from 'node:dns/promises';
import {isIP} from 'node:net';
import {randomBytes} from 'node:crypto';
import {pipeline} from 'node:stream/promises';
import {StringDecoder} from 'node:string_decoder';
import {execFile} from 'node:child_process';
import {createRemuxManager} from './remux.mjs';
import {createDownloadManager} from './downloads.mjs';
import {pathToFileURL} from 'node:url';
import {xtreamQuery,sanitizeProviderJson,parseM3U,m3uKind,decodeShortEpg,parseXmltv,parseAllowList,hostAllowed,fmp4Arguments,tsArguments,createLiveTranscoder,trendingTitles} from './iptv.mjs';

export function publicAddress(address) {
  if (isIP(address)===4) {
    const [a,b]=address.split('.').map(Number);
    return !(a===0||a===10||a===127||a>=224||a===169&&b===254||a===172&&b>=16&&b<=31||a===192&&(b===168||b===0||b===2)||a===100&&b>=64&&b<=127||a===198&&(b===18||b===19||b===51)||a===203&&b===0);
  }
  // Only global-unicast IPv6. Reject mapped IPv4, local, multicast and documentation addresses.
  if(isIP(address)!==6||!/^2[0-9a-f]{3}:/i.test(address))return false;
  const parts=address.toLowerCase().split(':');
  return !address.toLowerCase().startsWith('2002:')&&!(parts[0]==='2001'&&(parseInt(parts[1]||'0',16)<=0x1ff||parts[1]==='db8'));
}
export async function checkedTarget(input,resolver=lookup) {
  const url=new URL(input);
  if(!['http:','https:'].includes(url.protocol)||url.username||url.password)throw Error('unsafe_target');
  const hostname=url.hostname.replace(/^\[|\]$/g,'');
  const addresses=isIP(hostname)?[{address:hostname,family:isIP(hostname)}]:await resolver(hostname,{all:true,verbatim:true});
  if(!addresses.length||addresses.some(a=>!publicAddress(a.address)))throw Error('unsafe_target');
  return {url,hostname,...addresses[0]};
}
export async function providerRequest(input,{range,resolver=lookup,redirects=0}={}) {
  const target=await checkedTarget(input,resolver);
  const response=await new Promise((resolve,reject)=>{
    const request=(target.url.protocol==='http:'?http:https).get(target.url,{headers:{'User-Agent':'Rigatoni-Gateway/1.0',...(range?{Range:range}:{})},lookup:(_host,options,cb)=>{if(options.all)cb(null,[{address:target.address,family:target.family}]);else cb(null,target.address,target.family)},timeout:20000},resolve);
    request.on('timeout',()=>request.destroy(Error('upstream_timeout')));request.on('error',()=>reject(Error('upstream_unavailable')));
  });
  if([301,302,303,307,308].includes(response.statusCode)) {
    response.resume();if(redirects>=5||!response.headers.location)throw Error('upstream_redirect');
    return providerRequest(new URL(response.headers.location,target.url),{range,resolver,redirects:redirects+1});
  }
  return {response,url:target.url};
}
async function boundedBody(stream,limit) {
  const chunks=[];let size=0;
  for await(const chunk of stream){size+=chunk.length;if(size>limit){stream.destroy();throw Error('response_too_large')}chunks.push(chunk)}
  return Buffer.concat(chunks).toString('utf8');
}
// Discard unused provider metadata as each object arrives instead of buffering the whole catalog.
export async function providerArray(stream,project,{maxBytes=128*1024*1024,maxItems=100000,maxItemBytes=2*1024*1024}={}) {
  const decoder=new StringDecoder('utf8'),items=[];
  let bytes=0,state='start',item='',depth=0,inString=false,escaped=false;
  const consume=text=>{
    for(const char of text){
      if(state==='item'){
        item+=char;
        if(item.length>maxItemBytes)throw Error('response_too_large');
        if(inString){if(escaped)escaped=false;else if(char==='\\')escaped=true;else if(char==='"')inString=false;}
        else if(char==='"')inString=true;
        else if(char==='{'||char==='[')depth++;
        else if(char==='}'||char===']')depth--;
        if(depth===0){
          if(items.length>=maxItems)throw Error('catalog_too_large');
          items.push(project(JSON.parse(item)));item='';state='separator';
        }
        continue;
      }
      if(/\s/.test(char))continue;
      if(state==='start'&&char==='['){state='first';continue;}
      if((state==='first'||state==='next')&&char==='{'){state='item';item='{';depth=1;continue;}
      if((state==='first'||state==='separator')&&char===']'){state='done';continue;}
      if(state==='separator'&&char===','){state='next';continue;}
      throw Error('provider_connection_failed');
    }
  };
  try{
    for await(const chunk of stream){bytes+=chunk.length;if(bytes>maxBytes)throw Error('response_too_large');consume(decoder.write(chunk));}
    consume(decoder.end());if(state!=='done')throw Error('provider_connection_failed');
    return items;
  }catch(error){stream.destroy();throw error;}
}
const shortText=value=>String(value??'').slice(0,512);
export function rewritePlaylist(text,base,register) {
  if(!text.trimStart().startsWith('#EXTM3U'))throw Error('invalid_playlist');
  return text.split(/\r?\n/).map(line=>{
    if(!line.trim())return line;
    if(line.startsWith('#'))return line.replace(/URI="([^"]+)"/g,(_match,path)=>'URI="'+register(new URL(path,base))+'"');
    return register(new URL(line.trim(),base));
  }).join('\n');
}
export function safeDownloadFilename(raw,fallbackUrl){
  const clean=value=>String(value??'').replace(/[\u0000-\u001f\u007f]/g,' ').replace(/[/\\:*?"<>|]/g,' ').replace(/\s+/g,' ').trim().replace(/^\.+/,'').trim();
  let name=clean(raw);
  if(!name){
    try{name=clean(decodeURIComponent(String(new URL(fallbackUrl).pathname.split('/').pop()||'')))}catch{name=''}
  }
  if(!name)name='download';
  const dot=name.lastIndexOf('.');
  const ext=dot>0?name.slice(dot):'';
  let base=dot>0?name.slice(0,dot):name;
  const baseChars=[...base],extChars=[...ext];
  if(baseChars.length+extChars.length>150)base=baseChars.slice(0,Math.max(1,150-extChars.length)).join('').trim();
  return (base||'download')+ext;
}
export function downloadDisposition(filename){
  const fallback=filename.replace(/[^\x20-\x7e]/g,'_').replace(/["\\]/g,'_');
  const encoded=encodeURIComponent(filename).replace(/['()*]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
  return 'attachment; filename="'+fallback+'"; filename*=UTF-8\'\''+encoded;
}
const token=()=>randomBytes(24).toString('base64url');
export function hlsProbeOptions(help) {
  // FFmpeg 7/8 added independent extension checks. Relay tickets intentionally have no suffix.
  return ['-allowed_extensions','ALL',...(help.includes('allowed_segment_extensions')?['-allowed_segment_extensions','ALL']:[]),...(help.includes('extension_picky')?['-extension_picky','0']:[])];
}
let probeOptions;
async function supportedProbeOptions(){
  if(!probeOptions)probeOptions=new Promise((resolve,reject)=>execFile('ffprobe',['-hide_banner','-h','demuxer=hls'],{timeout:5000,maxBuffer:65536},(error,stdout)=>error?reject(Error('media_probe_unavailable')):resolve(hlsProbeOptions(stdout))));
  try{return await probeOptions}catch(error){probeOptions=null;throw error}
}
export function probeFailure(error,stderr=''){
  if(error?.killed)return 'media_probe_timeout';
  if(/not in allowed|mismatches allowed|extension.*blocked/i.test(stderr))return 'media_probe_extension';
  if(/HTTP error|Server returned|Unable to open|Failed to open|Error when loading first segment|Connection refused|timed out/i.test(stderr))return 'media_probe_download';
  if(/Invalid data found|Invalid.*NAL|Error parsing|could not find codec parameters/i.test(stderr))return 'media_probe_invalid';
  return 'media_probe_failed';
}
export async function probeMedia(url) {
  // Probe only our own opaque relay. Provider URLs and credentials never enter process arguments.
  const input=new URL(url);
  if(input.protocol!=='http:'||input.hostname!=='127.0.0.1'||!/^\/media\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/.test(input.pathname)||input.search||input.hash||input.username||input.password)throw Error('unsafe_probe');
  const options=await supportedProbeOptions();
  const raw=await new Promise((resolve,reject)=>execFile('ffprobe',['-v','error','-protocol_whitelist','http,tcp,crypto',...options,'-rw_timeout','10000000','-analyzeduration','5000000','-probesize','5000000','-show_entries','stream=codec_type,codec_name,width,height,pix_fmt,sample_rate,channels:format=format_name','-of','json',input.href],{timeout:20000,maxBuffer:65536,killSignal:'SIGKILL'},(error,stdout,stderr)=>error?reject(Error(probeFailure(error,stderr))):resolve(stdout)));
  const parsed=JSON.parse(raw);
  const streams=(parsed.streams||[]).slice(0,16).filter(s=>['video','audio'].includes(s.codec_type)).map(s=>({type:s.codec_type,codec:/^[a-z0-9_]+$/.test(s.codec_name||'')?s.codec_name:'unknown',...(s.codec_type==='video'?{width:Number(s.width)||0,height:Number(s.height)||0,pixel_format:/^[a-z0-9_]+$/.test(s.pix_fmt||'')?s.pix_fmt:'unknown'}:{channels:Number(s.channels)||0,sample_rate:Number(s.sample_rate)||0})}));
  if(!streams.length)throw Error('media_probe_failed');
  const container=/^[a-z0-9_,]+$/.test(parsed.format?.format_name||'')?parsed.format.format_name.slice(0,100):'unknown';
  return {streams,container};
}
export function createGateway({supabaseUrl,publicKey,origin='https://acasso01.github.io',fetchVault=fetch,upstream=providerRequest,probe=probeMedia,now=Date.now,maxSessions=20,moviesDir=process.env.MOVIES_PATH||'',tvDir=process.env.TV_PATH||'',downloadStatfs,tmdbKey=process.env.TMDB_API_KEY||'',tmdbFetch=fetch,allowedHosts=process.env.IPTV_ALLOWED_HOSTS||'',spawnFn,maxTranscodes=Number(process.env.MAX_TRANSCODES||2)}={}) {
  const sessions=new Map();
  const allowList=parseAllowList(allowedHosts);
  const transcoder=createLiveTranscoder({...(spawnFn?{spawn:spawnFn}:{}),maxJobs:maxTranscodes});
  const trendingCache=new Map();
  const remux=createRemuxManager({options:supportedProbeOptions,now});
  const downloads=createDownloadManager({upstream,moviesDir,tvDir,now,statfsFn:downloadStatfs});
  let probing=false;
  const inspection=async(session,key,input)=>{
    if(session.inspections?.has(key))return session.inspections.get(key);
    if(session.pendingInspections?.has(key))return session.pendingInspections.get(key);
    if(probing)throw Error('probe_busy');probing=true;
    session.pendingInspections??=new Map();
    const pending=Promise.resolve().then(()=>probe(input)).then(result=>{session.inspections??=new Map();if(session.inspections.size<20)session.inspections.set(key,result);return result}).finally(()=>{probing=false;session.pendingInspections.delete(key)});
    session.pendingInspections.set(key,pending);
    return pending;
  };
  const clean=()=>{for(const [id,s] of sessions)if(s.expires<=now()){sessions.delete(id);for(const key of s.compatibleKeys||[])void remux.stop(id+'/'+key)}};
  const json=(res,status,body)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(body))};
  const server=http.createServer(async(req,res)=>{
    res.setHeader('Cache-Control','no-store');res.setHeader('Referrer-Policy','no-referrer');res.setHeader('X-Content-Type-Options','nosniff');
    const requestOrigin=req.headers.origin;
    if(requestOrigin&&requestOrigin!==origin)return json(res,403,{error:'origin_not_allowed'});
    if(requestOrigin)res.setHeader('Access-Control-Allow-Origin',origin);
    res.setHeader('Vary','Origin');
    if(requestOrigin===origin&&req.headers['access-control-request-private-network']==='true')res.setHeader('Access-Control-Allow-Private-Network','true');
    if(req.method==='OPTIONS'){res.setHeader('Access-Control-Allow-Methods','POST, GET, OPTIONS');res.setHeader('Access-Control-Allow-Headers','authorization, content-type, range');res.writeHead(204);res.end();return}
    clean();
    try {
      const path=new URL(req.url,'http://localhost').pathname;
      if(path==='/health'&&req.method==='GET')return json(res,200,{ok:true,service:'rigatoni-gateway',multi_provider:true,downloads:true,server_downloads:downloads.configured,iptv:true,m3u:true,epg:true,engines:['relay','ts','fmp4'],trending:!!tmdbKey});
      if(path==='/api/connect'&&req.method==='POST') {
        const auth=req.headers.authorization;
        if(!auth?.startsWith('Bearer ')||auth.length>8192)return json(res,401,{error:'sign_in_required'});
        // Optional multi-provider selection. Legacy clients send no body and
        // keep the original single-provider behavior below.
        let providerId=null;
        const rawBody=await boundedBody(req,4096).catch(()=>null);
        if(rawBody){
          let parsed;try{parsed=JSON.parse(rawBody)}catch{return json(res,400,{error:'invalid_request'})}
          const candidate=parsed&&parsed.provider_id;
          if(candidate!==undefined&&candidate!==null&&candidate!==''){
            if(typeof candidate!=='string'||!/^[0-9a-fA-F-]{36}$/.test(candidate))return json(res,400,{error:'invalid_provider_id'});
            providerId=candidate;
          }
        }
        const vault=await fetchVault(supabaseUrl+'/functions/v1/provider-vault'+(providerId?'?id='+encodeURIComponent(providerId):''),{headers:{Authorization:auth,apikey:publicKey},cache:'no-store',signal:AbortSignal.timeout(15000)});
        if(!vault.ok)return json(res,vault.status===401?401:502,{error:'provider_vault_unavailable'});
        const saved=await vault.json();if(!saved.saved)return json(res,providerId?404:409,{error:providerId?'provider_not_found':'save_provider_first'});
        if(sessions.size>=maxSessions)return json(res,503,{error:'gateway_busy'});
        const base=new URL(saved.server_url);if(base.search||base.hash)throw Error('unsafe_target');
        if(!hostAllowed(base,allowList))return json(res,403,{error:'provider_host_not_allowed'});
        const api=async (action,project,maxItems,categoryId)=>{
          const url=new URL(base.href.replace(/\/+$/,'')+'/player_api.php');url.search=new URLSearchParams({username:saved.username,password:saved.password,action}).toString();
          if(categoryId!==undefined)url.searchParams.set('category_id',categoryId);
          const {response}=await upstream(url);if(response.statusCode!==200){response.resume();throw Error('provider_connection_failed')}
          return providerArray(response,project,{maxItems});
        };
        // Single-object player API calls (get_series_info returns an object, not an array).
        const apiObject=async(action,params)=>{
          const url=new URL(base.href.replace(/\/+$/,'')+'/player_api.php');url.search=new URLSearchParams({username:saved.username,password:saved.password,action,...(params||{})}).toString();
          const {response}=await upstream(url);if(response.statusCode!==200){response.resume();throw Error('provider_connection_failed')}
          const text=await boundedBody(response,16*1024*1024);
          let parsed;try{parsed=JSON.parse(text)}catch{throw Error('provider_connection_failed')}
          return parsed;
        };
        const categories=await api('get_live_categories',c=>({category_id:shortText(c.category_id),category_name:shortText(c.category_name)}),10000);
        const channels=await api('get_live_streams',c=>({stream_id:shortText(c.stream_id),name:shortText(c.name),category_id:shortText(c.category_id),stream_icon:''}),100000);
        if(!Array.isArray(channels))throw Error('provider_connection_failed');
        const id=token();const resources=new Map(),resourceKeys=new Map();const channelIds=new Set(channels.map(c=>String(c.stream_id)));
        const register=url=>{if(resourceKeys.has(url.href))return '/media/'+id+'/'+resourceKeys.get(url.href);if(!['http:','https:'].includes(url.protocol)||url.username||url.password)throw Error('unsafe_target');if(resources.size>=300000)throw Error('session_resource_limit');const key=token();resources.set(key,url.href);resourceKeys.set(url.href,key);return '/media/'+id+'/'+key};
        const streams={};for(const channelId of channelIds){if(!/^\d+$/.test(channelId))continue;streams[channelId]=register(new URL(base.href.replace(/\/+$/,'')+'/live/'+encodeURIComponent(saved.username)+'/'+encodeURIComponent(saved.password)+'/'+channelId+'.m3u8'))}
        sessions.set(id,{kind:'xtream',expires:now()+4*60*60*1000,resources,register,api,apiObject,base:base.href.replace(/\/+$/,''),username:saved.username,password:saved.password,secrets:[saved.password,encodeURIComponent(saved.password)].filter(x=>x&&x.length>=3)});
        // Provider icons can be HTTP or carry provider credentials. Keep cards but use the existing fallback artwork.
        return json(res,200,{categories,channels,streams,iptv_session:id,movies_path:'/api/movies/'+id,series_path:'/api/series/'+id,downloads_path:'/api/downloads/'+id,expires_in:14400});
      }
      if(path.startsWith('/api/movies/')&&req.method==='GET'){
        const match=path.match(/^\/api\/movies\/([A-Za-z0-9_-]+)$/),session=match&&sessions.get(match[1]);
        if(!session)return json(res,401,{error:'stream_session_expired'});
        const query=new URL(req.url,'http://localhost').searchParams;
        const categoryId=query.get('category_id');
        if(categoryId!==null&&!/^\d{1,20}$/.test(categoryId))return json(res,400,{error:'invalid_movie_category'});
        session.movieCategories??=session.api('get_vod_categories',c=>({category_id:shortText(c.category_id),category_name:shortText(c.category_name)}),10000).catch(error=>{session.movieCategories=null;throw error});
        const categories=await session.movieCategories;
        if(categoryId!==null&&!categories.some(c=>c.category_id===categoryId))return json(res,400,{error:'invalid_movie_category'});
        const getMovies=async()=>{
          const movies=await session.api('get_vod_streams',c=>({kind:'movie',stream_id:shortText(c.stream_id),name:shortText(c.name),category_id:shortText(c.category_id),stream_icon:'',poster:String(c.stream_icon||'').slice(0,2048),container_extension:/^(mp4|m4v|mov|mkv|avi|webm|ts|m3u8)$/.test(c.container_extension)?c.container_extension:'mp4'}),50000,categoryId===null?undefined:categoryId);
          const streams={};for(const movie of movies){if(!/^\d+$/.test(movie.stream_id))continue;streams[movie.stream_id]=session.register(new URL(session.base+'/movie/'+encodeURIComponent(session.username)+'/'+encodeURIComponent(session.password)+'/'+movie.stream_id+'.'+movie.container_extension));session.movieKeys??=new Set();session.movieKeys.add(streams[movie.stream_id].split('/').at(-1))}
          // Movie streams take priority over optional poster resources.
          for(const movie of movies){const poster=movie.poster;delete movie.poster;if(poster){try{movie.stream_icon=session.register(new URL(poster))}catch{}}}
          return{categories,movies,streams,...(categoryId===null?{}:{browse_by_category:true,category_id:categoryId})};
        };
        if(categoryId!==null){
          session.movieCatalogs??=new Map();
          if(!session.movieCatalogs.has(categoryId)){
            // Keep only two completed category catalogs; active loads remain coalesced.
            for(const [key,entry] of session.movieCatalogs){if(session.movieCatalogs.size<2)break;if(entry.done)session.movieCatalogs.delete(key)}
            if(session.movieCatalogs.size>=2)return json(res,429,{error:'movie_catalog_busy'});
            const entry={done:false};entry.promise=getMovies().then(result=>{entry.done=true;return result}).catch(error=>{session.movieCatalogs.delete(categoryId);throw error});session.movieCatalogs.set(categoryId,entry);
          }
          return json(res,200,await session.movieCatalogs.get(categoryId).promise);
        }
        if(!session.movies){
          session.movies=getMovies().catch(error=>{
            if(['catalog_too_large','response_too_large'].includes(error.message)&&categories.length)return{categories,movies:[],streams:{},browse_by_category:true};
            session.movies=null;throw error;
          });
        }
        return json(res,200,await session.movies);
      }
      if(path.startsWith('/api/series/')&&req.method==='GET'){
        const infoMatch=path.match(/^\/api\/series\/([A-Za-z0-9_-]+)\/info$/);
        if(infoMatch){
          const session=sessions.get(infoMatch[1]);
          if(!session)return json(res,401,{error:'stream_session_expired'});
          const seriesId=new URL(req.url,'http://localhost').searchParams.get('series_id');
          if(seriesId===null||!/^\d{1,20}$/.test(seriesId))return json(res,400,{error:'invalid_series_id'});
          const raw=await session.apiObject('get_series_info',{series_id:seriesId});
          if(!raw||typeof raw!=='object'||Array.isArray(raw)||typeof raw.episodes!=='object'||!raw.episodes)throw Error('provider_connection_failed');
          const infoRaw=(raw.info&&typeof raw.info==='object')?raw.info:{};
          const info={name:shortText(infoRaw.name),plot:String(infoRaw.plot||'').slice(0,2048),cast:shortText(infoRaw.cast),director:shortText(infoRaw.director),genre:shortText(infoRaw.genre),releaseDate:shortText(infoRaw.releaseDate),rating:shortText(infoRaw.rating),youtube_trailer:String(infoRaw.youtube_trailer||'').slice(0,512),episode_run_time:shortText(infoRaw.episode_run_time),stream_icon:''};
          if(typeof infoRaw.cover==='string'&&infoRaw.cover){try{info.stream_icon=session.register(new URL(infoRaw.cover))}catch{}}
          const seasons=(Array.isArray(raw.seasons)?raw.seasons:[]).map(s=>({season_number:Number(s.season_number)||0,episode_count:Number(s.episode_count)||0,name:shortText(s.name)}));
          const episodes={},streams={};
          session.episodeKeys??=new Set();
          for(const [seasonKey,list] of Object.entries(raw.episodes)){
            if(!Array.isArray(list))continue;
            const seasonNum=/^\d{1,20}$/.test(seasonKey)?seasonKey:'0';
            episodes[seasonNum]=[];
            for(const ep of list){
              if(!ep||!/^\d+$/.test(String(ep.id||'')))continue;
              const ext=/^(mp4|m4v|mov|mkv|avi|webm|ts|m3u8)$/.test(ep.container_extension)?ep.container_extension:'mp4';
              const registered=session.register(new URL(session.base+'/series/'+encodeURIComponent(session.username)+'/'+encodeURIComponent(session.password)+'/'+ep.id+'.'+ext));
              streams[String(ep.id)]=registered;session.episodeKeys.add(registered.split('/').at(-1));
              let epIcon='';
              if(ep.info&&typeof ep.info.movie_image==='string'&&ep.info.movie_image){try{epIcon=session.register(new URL(ep.info.movie_image))}catch{}}
              episodes[seasonNum].push({id:String(ep.id),episode_num:Number(ep.episode_num)||0,title:shortText(ep.title),season:Number(ep.season)||Number(seasonNum)||0,container_extension:ext,stream_icon:epIcon,plot:String(ep.info?.plot||'').slice(0,512)});
            }
          }
          if(!Object.keys(episodes).length)throw Error('provider_connection_failed');
          return json(res,200,{info,seasons,episodes,streams});
        }
        const match=path.match(/^\/api\/series\/([A-Za-z0-9_-]+)$/),session=match&&sessions.get(match[1]);
        if(!session)return json(res,401,{error:'stream_session_expired'});
        const query=new URL(req.url,'http://localhost').searchParams;
        const categoryId=query.get('category_id');
        if(categoryId!==null&&!/^\d{1,20}$/.test(categoryId))return json(res,400,{error:'invalid_series_category'});
        session.seriesCategories??=session.api('get_series_categories',c=>({category_id:shortText(c.category_id),category_name:shortText(c.category_name)}),10000).catch(error=>{session.seriesCategories=null;throw error});
        const categories=await session.seriesCategories;
        if(categoryId!==null&&!categories.some(c=>c.category_id===categoryId))return json(res,400,{error:'invalid_series_category'});
        const getSeries=async()=>{
          const series=await session.api('get_series',c=>({kind:'series',stream_id:shortText(c.series_id),name:shortText(c.name),category_id:shortText(c.category_id),poster:String(c.cover||'').slice(0,2048),rating:shortText(c.rating),genre:shortText(c.genre),releaseDate:shortText(c.releaseDate)}),50000,categoryId===null?undefined:categoryId);
          for(const item of series){const poster=item.poster;delete item.poster;if(poster){try{item.stream_icon=session.register(new URL(poster))}catch{}}}
          return{categories,series,...(categoryId===null?{}:{browse_by_category:true,category_id:categoryId})};
        };
        if(categoryId!==null){
          session.seriesCatalogs??=new Map();
          if(!session.seriesCatalogs.has(categoryId)){
            // Keep only two completed category catalogs; active loads remain coalesced.
            for(const [key,entry] of session.seriesCatalogs){if(session.seriesCatalogs.size<2)break;if(entry.done)session.seriesCatalogs.delete(key)}
            if(session.seriesCatalogs.size>=2)return json(res,429,{error:'series_catalog_busy'});
            const entry={done:false};entry.promise=getSeries().then(result=>{entry.done=true;return result}).catch(error=>{session.seriesCatalogs.delete(categoryId);throw error});session.seriesCatalogs.set(categoryId,entry);
          }
          return json(res,200,await session.seriesCatalogs.get(categoryId).promise);
        }
        if(!session.series){
          session.series=getSeries().catch(error=>{
            if(['catalog_too_large','response_too_large'].includes(error.message)&&categories.length)return{categories,series:[],browse_by_category:true};
            session.series=null;throw error;
          });
        }
        return json(res,200,await session.series);
      }
      // ---------- Web IPTV routes (Gigaplay-style player) ----------
      if(path==='/iptv/m3u'&&req.method==='POST'){
        // Create a live-TV session from an M3U link. The link (which usually carries the
        // provider login) is used here once and never returned to the browser.
        const auth=req.headers.authorization;
        if(!auth?.startsWith('Bearer ')||auth.length>8192)return json(res,401,{error:'sign_in_required'});
        const who=await fetchVault(supabaseUrl+'/auth/v1/user',{headers:{Authorization:auth,apikey:publicKey},cache:'no-store',signal:AbortSignal.timeout(15000)}).catch(()=>null);
        if(!who?.ok)return json(res,401,{error:'sign_in_required'});
        const rawBody=await boundedBody(req,8192).catch(()=>null);
        let body;try{body=JSON.parse(rawBody||'')}catch{return json(res,400,{error:'invalid_request'})}
        let link;try{link=new URL(String(body?.url||''))}catch{return json(res,400,{error:'invalid_m3u_url'})}
        if(!['http:','https:'].includes(link.protocol)||link.username||link.password||link.hash)return json(res,400,{error:'invalid_m3u_url'});
        if(!hostAllowed(link,allowList))return json(res,403,{error:'provider_host_not_allowed'});
        if(sessions.size>=maxSessions)return json(res,503,{error:'gateway_busy'});
        const {response}=await upstream(link);
        if(response.statusCode!==200){response.resume();throw Error('provider_connection_failed')}
        const parsed=parseM3U(await boundedBody(response,48*1024*1024),{maxItems:100000});
        const id=token(),resources=new Map(),resourceKeys=new Map();
        const register=url=>{if(resourceKeys.has(url.href))return '/media/'+id+'/'+resourceKeys.get(url.href);if(!['http:','https:'].includes(url.protocol)||url.username||url.password)throw Error('unsafe_target');if(resources.size>=300000)throw Error('session_resource_limit');const key=token();resources.set(key,url.href);resourceKeys.set(url.href,key);return '/media/'+id+'/'+key};
        const groups=new Map(),channels=[],streams={},tvg=new Map();let skipped=0;
        for(const entry of parsed.channels){
          if(m3uKind(entry.url)!=='live'){skipped++;continue}
          if(!groups.has(entry.group))groups.set(entry.group,String(groups.size+1));
          const streamId=String(channels.length+1);
          streams[streamId]=register(new URL(entry.url));
          let icon='';if(/^https?:\/\//i.test(entry.logo)){try{icon=register(new URL(entry.logo))}catch{}}
          channels.push({stream_id:streamId,name:entry.name,category_id:groups.get(entry.group),stream_icon:icon,epg_channel_id:entry.tvg_id,catchup:entry.catchup});
          if(entry.tvg_id)tvg.set(streamId,entry.tvg_id);
        }
        if(!channels.length)return json(res,422,{error:'m3u_has_no_live_channels'});
        let epgUrl=null;if(parsed.epgUrl){try{const u=new URL(parsed.epgUrl);if(['http:','https:'].includes(u.protocol)&&hostAllowed(u,allowList))epgUrl=u.href}catch{}}
        sessions.set(id,{kind:'m3u',expires:now()+4*60*60*1000,resources,register,tvg,epgUrl,secrets:[link.search.slice(1)].filter(x=>x.length>=3)});
        const categories=[...groups].map(([name,cid])=>({category_id:cid,category_name:String(name).slice(0,512)}));
        return json(res,200,{categories,channels:channels.map(({stream_id,name,category_id,stream_icon,catchup})=>({stream_id,name,category_id,stream_icon,catchup})),streams,iptv_session:id,epg:!!epgUrl,vod_skipped:skipped,expires_in:14400});
      }
      if(path.startsWith('/iptv/api/')&&req.method==='GET'){
        const match=path.match(/^\/iptv\/api\/([A-Za-z0-9_-]+)$/),session=match&&sessions.get(match[1]);
        if(!session)return json(res,401,{error:'stream_session_expired'});
        if(session.kind!=='xtream')return json(res,409,{error:'not_an_xtream_session'});
        let query;try{query=xtreamQuery(new URL(req.url,'http://localhost').search)}catch(error){return json(res,error.status||400,{error:error.message})}
        const {action,...params}=query;
        const raw=await session.apiObject(action,params);
        return json(res,200,sanitizeProviderJson(raw,{secrets:session.secrets||[],register:session.register}));
      }
      if(path.startsWith('/iptv/epg/')&&req.method==='GET'){
        const match=path.match(/^\/iptv\/epg\/([A-Za-z0-9_-]+)$/),session=match&&sessions.get(match[1]);
        if(!session)return json(res,401,{error:'stream_session_expired'});
        const ids=String(new URL(req.url,'http://localhost').searchParams.get('ids')||'').split(',').filter(Boolean);
        if(!ids.length||ids.length>40||ids.some(x=>!/^\d{1,20}$/.test(x)))return json(res,400,{error:'invalid_epg_ids'});
        session.epgCache??=new Map();const fresh=e=>e&&now()-e.at<10*60*1000;const epg={};
        if(session.kind==='m3u'){
          if(!session.epgUrl)return json(res,200,{epg:{},source:'none'});
          if(!session.xmltv||now()-session.xmltv.at>6*60*60*1000){
            session.xmltv={at:now(),data:(async()=>{const {response}=await upstream(session.epgUrl);if(response.statusCode!==200){response.resume();throw Error('provider_connection_failed')}const text=await boundedBody(response,96*1024*1024);const t=now()/1000;return parseXmltv(text,{channels:new Set(session.tvg.values()),from:t-2*3600,to:t+12*3600})})()};
            session.xmltv.data.catch(()=>{session.xmltv=null});
          }
          const map=await session.xmltv.data;
          for(const sid of ids){const tid=session.tvg.get(sid);epg[sid]=tid?map.get(tid)||[]:[]}
          return json(res,200,{epg,source:'xmltv'});
        }
        const queue=[...ids];
        const worker=async()=>{while(queue.length){const sid=queue.shift();const hit=session.epgCache.get(sid);if(fresh(hit)){epg[sid]=hit.list;continue}
          try{const raw=await session.apiObject('get_short_epg',{stream_id:sid,limit:'8'});const list=decodeShortEpg(raw,{limit:8});session.epgCache.set(sid,{at:now(),list});if(session.epgCache.size>5000)session.epgCache.delete(session.epgCache.keys().next().value);epg[sid]=list}catch{epg[sid]=[]}}};
        await Promise.all(Array.from({length:Math.min(6,ids.length)},worker));
        return json(res,200,{epg,source:'xtream'});
      }
      if(path.startsWith('/iptv/stream/')&&req.method==='GET'){
        const match=path.match(/^\/iptv\/stream\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)$/);
        if(!match)return json(res,404,{error:'not_found'});
        const [,id,key]=match,session=sessions.get(id);
        if(!session?.resources.has(key))return json(res,401,{error:'stream_session_expired'});
        const q=new URL(req.url,'http://localhost').searchParams;const mode=q.get('mode')||'relay';
        if(!['relay','ts','fmp4'].includes(mode))return json(res,400,{error:'invalid_mode'});
        if(mode==='relay'){res.writeHead(307,{Location:'/media/'+id+'/'+key,'Cache-Control':'no-store'});res.end();return}
        const requested=q.get('video')||'auto';if(!['auto','copy','transcode'].includes(requested))return json(res,400,{error:'invalid_video_mode'});
        const start=Number(q.get('t')||0),height=Number(q.get('q')||1080);
        if(!Number.isFinite(start)||start<0||start>86400*2||!Number.isFinite(height))return json(res,400,{error:'invalid_request'});
        const live=!(session.movieKeys?.has(key)||session.episodeKeys?.has(key));
        const input='http://127.0.0.1:'+server.address().port+'/media/'+id+'/'+key;
        const hlsOptions=live?await supportedProbeOptions().catch(()=>[]):[];
        if(mode==='ts')return void transcoder.start(tsArguments(input,{hlsOptions}),res,'video/mp2t');
        let video=requested;
        if(video==='auto'){
          // H.264 (and HEVC when the browser says it can decode it) is copied; anything else is converted.
          try{const info=await inspection(session,key,input);const codec=info.streams.find(s=>s.type==='video')?.codec;video=codec==='h264'||codec==='hevc'&&q.get('hevc')==='1'?'copy':'transcode'}catch{video='transcode'}
        }
        return void transcoder.start(fmp4Arguments(input,{video,start,live,height,hlsOptions}),res,'video/mp4');
      }
      if(path.startsWith('/iptv/trending/')&&req.method==='GET'){
        const match=path.match(/^\/iptv\/trending\/([A-Za-z0-9_-]+)$/),session=match&&sessions.get(match[1]);
        if(!session)return json(res,401,{error:'stream_session_expired'});
        if(!tmdbKey)return json(res,404,{error:'trending_unavailable'});
        const media=new URL(req.url,'http://localhost').searchParams.get('media')||'movie';
        if(!['movie','tv'].includes(media))return json(res,400,{error:'invalid_media'});
        const hit=trendingCache.get(media);
        if(!hit||now()-hit.at>6*60*60*1000){
          const entry={at:now(),data:(async()=>{const r=await tmdbFetch('https://api.themoviedb.org/3/trending/'+media+'/week?api_key='+encodeURIComponent(tmdbKey),{cache:'no-store',signal:AbortSignal.timeout(12000)});if(!r.ok)throw Error('trending_unavailable');const text=await r.text();if(text.length>2*1024*1024)throw Error('response_too_large');return trendingTitles(JSON.parse(text))})()};
          entry.data.catch(()=>trendingCache.delete(media));trendingCache.set(media,entry);
        }
        try{return json(res,200,{media,results:await trendingCache.get(media).data})}catch{return json(res,502,{error:'trending_unavailable'})}
      }
      if(path.startsWith('/compatible/')&&req.method==='POST'){
        const match=path.match(/^\/compatible\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)\/stop$/);
        if(!match)return json(res,404,{error:'not_found'});
        const [,id,key]=match;if(!sessions.get(id)?.resources.has(key))return json(res,401,{error:'stream_session_expired'});
        await remux.stop(id+'/'+key);return json(res,200,{stopped:true});
      }
      if(path.startsWith('/compatible/')&&req.method==='GET'){
        const match=path.match(/^\/compatible\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)\/(index\.m3u8|init\.mp4|segment-\d{6,}\.m4s)$/);
        if(!match)return json(res,404,{error:'not_found'});
        const [,id,key,file]=match,session=sessions.get(id);
        if(!session?.resources.has(key))return json(res,401,{error:'stream_session_expired'});
        const input='http://127.0.0.1:'+server.address().port+'/media/'+id+'/'+key;
        const info=await inspection(session,key,input);
        const video=info.streams.find(s=>s.type==='video'),audio=info.streams.find(s=>s.type==='audio');
        const movie=session.movieKeys?.has(key)||session.episodeKeys?.has(key)||false;
        if(!['h264','hevc'].includes(video?.codec)||!movie&&audio&&audio.codec!=='aac')return json(res,409,{error:'compatibility_codec'});
        session.compatibleKeys??=new Set();session.compatibleKeys.add(key);
        const data=await remux.read(id+'/'+key,input,video.codec,file,{movie,hls:info.container==='hls',audio:audio?.codec||'aac'});
        if(file==='index.m3u8'){
          const prefix='/compatible/'+id+'/'+key+'/';
          const playlist=data.toString('utf8').split(/\r?\n/).map(line=>line.startsWith('#')?line.replace(/URI="(init\.mp4)"/g,(_m,name)=>'URI="'+prefix+name+'"'):/^segment-\d{6,}\.m4s$/.test(line)?prefix+line:line).join('\n');
          res.writeHead(200,{'Content-Type':'application/vnd.apple.mpegurl'});res.end(playlist);return;
        }
        const type=file==='init.mp4'?'video/mp4':'video/iso.segment';
        const range=req.headers.range;
        if(range){
          const m=range.match(/^bytes=(\d*)-(\d*)$/);if(!m||!m[1]&&!m[2])return json(res,400,{error:'invalid_range'});
          const start=m[1]?Number(m[1]):Math.max(0,data.length-Number(m[2])),end=m[1]&&m[2]?Math.min(Number(m[2]),data.length-1):data.length-1;
          if(start>end||start>=data.length){res.writeHead(416,{'Content-Range':'bytes */'+data.length});res.end();return}
          const slice=data.subarray(start,end+1);res.writeHead(206,{'Content-Type':type,'Content-Length':slice.length,'Content-Range':'bytes '+start+'-'+end+'/'+data.length,'Accept-Ranges':'bytes'});res.end(slice);return;
        }
        res.writeHead(200,{'Content-Type':type,'Content-Length':data.length,'Accept-Ranges':'bytes'});res.end(data);return;
      }
      if(path.startsWith('/inspect/')&&req.method==='GET') {
        const [, ,id,key]=path.split('/');const session=sessions.get(id);
        if(!session?.resources.has(key))return json(res,401,{error:'stream_session_expired'});
        const result=await inspection(session,key,'http://127.0.0.1:'+server.address().port+'/media/'+id+'/'+key);
        return json(res,200,result);
      }
      if(path.startsWith('/media/')&&req.method==='GET') {
        const [, ,id,key]=path.split('/');const session=sessions.get(id);const url=session?.resources.get(key);
        if(!url)return json(res,401,{error:'stream_session_expired'});
        const range=req.headers.range;if(range&&!/^bytes=\d*-\d*$/.test(range))return json(res,400,{error:'invalid_range'});
        const {response,url:finalUrl}=await upstream(url,{range});
        if(![200,206].includes(response.statusCode)){response.resume();return json(res,502,{error:'stream_unavailable'})}
        const type=String(response.headers['content-type']||'application/octet-stream');
        if(/mpegurl/i.test(type)||/\.m3u8$/i.test(finalUrl.pathname)){
          const text=await boundedBody(response,2*1024*1024);
          const playlist=rewritePlaylist(text,finalUrl,session.register);
          res.writeHead(200,{'Content-Type':'application/vnd.apple.mpegurl'});res.end(playlist);return;
        }
        for(const header of ['content-type','content-length','content-range','accept-ranges'])if(response.headers[header])res.setHeader(header,response.headers[header]);
        res.writeHead(response.statusCode);res.on('close',()=>response.destroy());await pipeline(response,res);return;
      }
      if(path.startsWith('/download/')&&(req.method==='GET'||req.method==='HEAD')) {
        const [, ,id,key]=path.split('/');const session=sessions.get(id);const url=session?.resources.get(key);
        if(!url)return json(res,401,{error:'stream_session_expired'});
        const range=req.headers.range;if(range&&!/^bytes=\d*-\d*$/.test(range))return json(res,400,{error:'invalid_range'});
        const {response,url:finalUrl}=await upstream(url,{range});
        if(![200,206].includes(response.statusCode)){response.destroy();return json(res,502,{error:'stream_unavailable'})}
        const type=String(response.headers['content-type']||'application/octet-stream');
        if(/mpegurl/i.test(type)||/\.m3u8$/i.test(finalUrl.pathname)){response.destroy();return json(res,409,{error:'download_not_supported'})}
        const filename=safeDownloadFilename(new URL(req.url,'http://localhost').searchParams.get('filename'),finalUrl);
        res.setHeader('Content-Disposition',downloadDisposition(filename));
        for(const header of ['content-type','content-length','content-range','accept-ranges'])if(response.headers[header])res.setHeader(header,response.headers[header]);
        if(req.method==='HEAD'){response.destroy();res.writeHead(response.statusCode);res.end();return}
        res.writeHead(response.statusCode);res.on('close',()=>response.destroy());await pipeline(response,res);return;
      }
      if(path.startsWith('/api/downloads/')) {
        const jobMatch=path.match(/^\/api\/downloads\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)$/);
        const listMatch=!jobMatch&&path.match(/^\/api\/downloads\/([A-Za-z0-9_-]+)$/);
        if(jobMatch&&req.method==='GET'){
          const session=sessions.get(jobMatch[1]);
          if(!session)return json(res,401,{error:'stream_session_expired'});
          const job=downloads.get(jobMatch[2]);
          if(!job)return json(res,404,{error:'download_not_found'});
          return json(res,200,job);
        }
        if(listMatch&&req.method==='GET'){
          const session=sessions.get(listMatch[1]);
          if(!session)return json(res,401,{error:'stream_session_expired'});
          return json(res,200,{jobs:downloads.list()});
        }
        if(listMatch&&req.method==='POST'){
          const session=sessions.get(listMatch[1]);
          if(!session)return json(res,401,{error:'stream_session_expired'});
          const rawBody=await boundedBody(req,4096).catch(()=>null);
          if(!rawBody)return json(res,400,{error:'invalid_request'});
          let body;try{body=JSON.parse(rawBody)}catch{return json(res,400,{error:'invalid_request'})}
          try{
            const job=downloads.create({session,body});
            return json(res,202,job);
          }catch(error){
            if(error.status&&error.code)return json(res,error.status,{error:error.code});
            throw error;
          }
        }
        return json(res,404,{error:'not_found'});
      }
      return json(res,404,{error:'not_found'});
    } catch(error) {
      if(res.headersSent){res.destroy();return}
      const known=['transcoder_busy','invalid_playlist','catalog_too_large','unsafe_target','upstream_timeout','upstream_unavailable','provider_connection_failed','response_too_large','catalog_too_large','invalid_playlist','session_resource_limit','media_probe_failed','media_probe_unavailable','media_probe_timeout','media_probe_extension','media_probe_download','media_probe_invalid','compatibility_busy','compatibility_failed','compatibility_timeout','compatibility_segment_expired','probe_busy'];
      return json(res,['probe_busy','transcoder_busy'].includes(error.message)?429:502,{error:known.includes(error.message)?error.message:'gateway_request_failed'});
    }
  });
  server.on('close',()=>{void remux.close();downloads.close();transcoder.close()});server.closeCompatibility=()=>remux.close();
  server.requestTimeout=30000;server.headersTimeout=15000;
  return server;
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href){
  const supabaseUrl=process.env.SUPABASE_URL,publicKey=process.env.SUPABASE_ANON_KEY;
  if(!supabaseUrl||!publicKey)throw Error('Set SUPABASE_URL and SUPABASE_ANON_KEY (public configuration only).');
  createGateway({supabaseUrl,publicKey}).listen(Number(process.env.PORT||8787),process.env.HOST||'127.0.0.1',()=>console.log('Rigatoni gateway listening; credential and request URL logging disabled.'));
}
