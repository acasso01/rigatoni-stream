import http from 'node:http';
import https from 'node:https';
import {lookup} from 'node:dns/promises';
import {isIP} from 'node:net';
import {randomBytes} from 'node:crypto';
import {pipeline} from 'node:stream/promises';
import {StringDecoder} from 'node:string_decoder';
import {execFile} from 'node:child_process';
import {pathToFileURL} from 'node:url';

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
  const raw=await new Promise((resolve,reject)=>execFile('ffprobe',['-v','error','-protocol_whitelist','http,tcp,crypto',...options,'-rw_timeout','10000000','-analyzeduration','5000000','-probesize','5000000','-show_entries','stream=codec_type,codec_name,width,height,pix_fmt,sample_rate,channels','-of','json',input.href],{timeout:20000,maxBuffer:65536,killSignal:'SIGKILL'},(error,stdout,stderr)=>error?reject(Error(probeFailure(error,stderr))):resolve(stdout)));
  const parsed=JSON.parse(raw);
  const streams=(parsed.streams||[]).slice(0,16).filter(s=>['video','audio'].includes(s.codec_type)).map(s=>({type:s.codec_type,codec:/^[a-z0-9_]+$/.test(s.codec_name||'')?s.codec_name:'unknown',...(s.codec_type==='video'?{width:Number(s.width)||0,height:Number(s.height)||0,pixel_format:/^[a-z0-9_]+$/.test(s.pix_fmt||'')?s.pix_fmt:'unknown'}:{channels:Number(s.channels)||0,sample_rate:Number(s.sample_rate)||0})}));
  if(!streams.length)throw Error('media_probe_failed');
  return {streams};
}
export function createGateway({supabaseUrl,publicKey,origin='https://acasso01.github.io',fetchVault=fetch,upstream=providerRequest,probe=probeMedia,now=Date.now,maxSessions=20}={}) {
  const sessions=new Map();
  let probing=false;
  const clean=()=>{for(const [id,s] of sessions)if(s.expires<=now())sessions.delete(id)};
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
      if(path==='/health'&&req.method==='GET')return json(res,200,{ok:true,service:'rigatoni-gateway'});
      if(path==='/api/connect'&&req.method==='POST') {
        const auth=req.headers.authorization;
        if(!auth?.startsWith('Bearer ')||auth.length>8192)return json(res,401,{error:'sign_in_required'});
        const vault=await fetchVault(supabaseUrl+'/functions/v1/provider-vault',{headers:{Authorization:auth,apikey:publicKey},cache:'no-store',signal:AbortSignal.timeout(15000)});
        if(!vault.ok)return json(res,vault.status===401?401:502,{error:'provider_vault_unavailable'});
        const saved=await vault.json();if(!saved.saved)return json(res,409,{error:'save_provider_first'});
        if(sessions.size>=maxSessions)return json(res,503,{error:'gateway_busy'});
        const base=new URL(saved.server_url);if(base.search||base.hash)throw Error('unsafe_target');
        const api=async (action,project,maxItems)=>{
          const url=new URL(base.href.replace(/\/+$/,'')+'/player_api.php');url.search=new URLSearchParams({username:saved.username,password:saved.password,action}).toString();
          const {response}=await upstream(url);if(response.statusCode!==200){response.resume();throw Error('provider_connection_failed')}
          return providerArray(response,project,{maxItems});
        };
        const categories=await api('get_live_categories',c=>({category_id:shortText(c.category_id),category_name:shortText(c.category_name)}),10000);
        const channels=await api('get_live_streams',c=>({stream_id:shortText(c.stream_id),name:shortText(c.name),category_id:shortText(c.category_id),stream_icon:''}),100000);
        if(!Array.isArray(channels))throw Error('provider_connection_failed');
        const id=token();const resources=new Map(),resourceKeys=new Map();const channelIds=new Set(channels.map(c=>String(c.stream_id)));
        const register=url=>{if(resourceKeys.has(url.href))return '/media/'+id+'/'+resourceKeys.get(url.href);if(!['http:','https:'].includes(url.protocol)||url.username||url.password)throw Error('unsafe_target');if(resources.size>=120000)throw Error('session_resource_limit');const key=token();resources.set(key,url.href);resourceKeys.set(url.href,key);return '/media/'+id+'/'+key};
        const streams={};for(const channelId of channelIds){if(!/^\d+$/.test(channelId))continue;streams[channelId]=register(new URL(base.href.replace(/\/+$/,'')+'/live/'+encodeURIComponent(saved.username)+'/'+encodeURIComponent(saved.password)+'/'+channelId+'.m3u8'))}
        sessions.set(id,{expires:now()+4*60*60*1000,resources,register});
        // Provider icons can be HTTP or carry provider credentials. Keep cards but use the existing fallback artwork.
        return json(res,200,{categories,channels,streams,expires_in:14400});
      }
      if(path.startsWith('/inspect/')&&req.method==='GET') {
        const [, ,id,key]=path.split('/');const session=sessions.get(id);
        if(!session?.resources.has(key))return json(res,401,{error:'stream_session_expired'});
        if(probing)return json(res,429,{error:'probe_busy'});
        if(session.inspections?.has(key))return json(res,200,session.inspections.get(key));
        probing=true;
        try{
          const result=await probe('http://127.0.0.1:'+server.address().port+'/media/'+id+'/'+key);
          session.inspections??=new Map();if(session.inspections.size<20)session.inspections.set(key,result);
          return json(res,200,result);
        }finally{probing=false}
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
      return json(res,404,{error:'not_found'});
    } catch(error) {
      if(res.headersSent){res.destroy();return}
      const known=['unsafe_target','upstream_timeout','upstream_unavailable','provider_connection_failed','response_too_large','catalog_too_large','invalid_playlist','session_resource_limit','media_probe_failed','media_probe_unavailable','media_probe_timeout','media_probe_extension','media_probe_download','media_probe_invalid'];
      return json(res,502,{error:known.includes(error.message)?error.message:'gateway_request_failed'});
    }
  });
  server.requestTimeout=30000;server.headersTimeout=15000;
  return server;
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href){
  const supabaseUrl=process.env.SUPABASE_URL,publicKey=process.env.SUPABASE_ANON_KEY;
  if(!supabaseUrl||!publicKey)throw Error('Set SUPABASE_URL and SUPABASE_ANON_KEY (public configuration only).');
  createGateway({supabaseUrl,publicKey}).listen(Number(process.env.PORT||8787),process.env.HOST||'127.0.0.1',()=>console.log('Rigatoni gateway listening; credential and request URL logging disabled.'));
}
