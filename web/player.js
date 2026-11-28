/* Ant Streams — playback engine ladder + Gigaplay-style player overlay.
   Live TV tries engines in order and falls back automatically:
     Native HLS (Safari) → hls.js (MSE) → mpegts.js (MPEG-TS via the Pi) → Canvas (WebCodecs fMP4 via the Pi)
     → the existing "compatible playback" remux.
   Tesla Mode puts the canvas engine first, because Tesla's browser pauses <video> in Drive.
   Classic script → globalThis.AntPlayer. Library loads are pinned with SRI. */
(function(root){
'use strict';
const doc=root.document;
const LIBS={
  hls:{src:'https://cdn.jsdelivr.net/npm/hls.js@1.7.3/dist/hls.min.js',integrity:'sha384-cciJ0zi8d1uMKC2zJd7jvPY4HQt7W4ByUI/FlMkltvBi31aW61rcpVBhpmW8/NwX',global:'Hls'},
  mpegts:{src:'https://cdn.jsdelivr.net/npm/mpegts.js@1.8.2/dist/mpegts.js',integrity:'sha384-sQp+4cJv0jChNCYvgy6W0RSfQZB/w6d3ZTDoIBlY4Uorfw4PLS56T2yM2z47bSkl',global:'mpegts'}
};
const loading={};
function loadLib(name){
  const lib=LIBS[name];if(root[lib.global])return Promise.resolve(root[lib.global]);
  if(name==='hls'&&typeof root.__antLoadHls==='function')return root.__antLoadHls();
  return loading[name]??=new Promise((resolve,reject)=>{
    const s=doc.createElement('script');s.src=lib.src;s.integrity=lib.integrity;s.crossOrigin='anonymous';s.referrerPolicy='no-referrer';
    const t=setTimeout(()=>{s.remove();reject(Error(name+' library timed out'))},15000);
    s.onload=()=>{clearTimeout(t);root[lib.global]?resolve(root[lib.global]):reject(Error(name+' library missing'))};
    s.onerror=()=>{clearTimeout(t);s.remove();reject(Error(name+' library unavailable'))};
    doc.head.append(s);
  }).catch(e=>{delete loading[name];throw e});
}
const ENGINE_LABELS={native:'Native',hlsjs:'HLS.js',mpegts:'MPEG-TS',canvas:'Canvas',compatible:'Compatible'};
const store={get(k,d){try{const v=root.localStorage.getItem(k);return v==null?d:v}catch{return d}},set(k,v){try{root.localStorage.setItem(k,v)}catch{}}};
const settings={get engine(){return store.get('ant-engine','auto')},set engine(v){store.set('ant-engine',v)}};
const hasMSE=()=>!!(root.MediaSource||root.ManagedMediaSource);
const isTesla=()=>/Tesla\//.test(root.navigator?.userAgent||'')||!!doc?.body?.classList.contains('tesla-lite');

// ---------- audio: one volume/mute state for every engine ----------
// Volume and mute persist. Browsers (Tesla's Chromium included) block sound until the page gets a tap,
// so a stream that could only start muted is marked autoMuted and the next tap anywhere turns sound on.
// The canvas engine plays through one shared AudioContext that is resumed inside that tap.
const clamp01=v=>Math.min(1,Math.max(0,v));
const audio={
  ctx:null,autoMuted:false,listeners:new Set(),
  get volume(){const v=parseFloat(store.get('ant-volume','1'));return isFinite(v)?clamp01(v):1},
  get muted(){return store.get('ant-muted','0')==='1'},
  get silent(){return this.muted||this.autoMuted},
  context(){
    if(!this.ctx){const C=root.AudioContext||root.webkitAudioContext;if(!C)return null;try{this.ctx=new C({latencyHint:'playback'})}catch{return null}}
    return this.ctx;
  },
  // Call only from inside a user gesture (tap, click, key).
  unlock(create){
    const ctx=create?this.context():this.ctx;
    if(ctx&&ctx.state!=='running'&&ctx.state!=='closed')try{ctx.resume().catch(()=>{})}catch{}
    if(this.autoMuted){this.autoMuted=false;this.emit()}
  },
  setVolume(v){v=clamp01(Number(v)||0);store.set('ant-volume',String(v));if(v>0&&this.muted)store.set('ant-muted','0');this.autoMuted=false;this.emit()},
  setMuted(m){store.set('ant-muted',m?'1':'0');if(!m&&this.volume===0)store.set('ant-volume','0.5');this.autoMuted=false;this.emit()},
  applyTo(video){if(!video)return;try{video.volume=this.volume}catch{}video.muted=this.silent},
  on(f){this.listeners.add(f);return()=>this.listeners.delete(f)},
  emit(){for(const f of this.listeners)try{f()}catch{}}
};

// ---------- <video> engines ----------
function waitForPlaying(video,ms,signal){
  return new Promise((resolve,reject)=>{
    const done=(fn,v)=>{clearTimeout(t);video.removeEventListener('playing',ok);video.removeEventListener('error',bad);signal?.removeEventListener('abort',ab);fn(v)};
    const ok=()=>done(resolve),bad=()=>done(reject,Error('Media error '+(video.error?.code||'')+'.'));
    const ab=()=>done(reject,Object.assign(Error('aborted'),{aborted:true}));
    const t=setTimeout(()=>done(reject,Error('No video after '+Math.round(ms/1000)+' seconds.')),ms);
    video.addEventListener('playing',ok);video.addEventListener('error',bad);signal?.addEventListener('abort',ab);
  });
}
function resetVideo(video){try{video.pause();video.removeAttribute('src');video.load()}catch{}}
class VideoEngine{
  constructor(video,name){this.video=video;this.name=name;this.abort=new AbortController()}
  get paused(){return this.video.paused}get currentTime(){return this.video.currentTime}get duration(){return this.video.duration}
  get videoHeight(){return this.video.videoHeight}
  play(){return this.video.play()}pause(){this.video.pause()}setMuted(m){this.video.muted=m}setVolume(v){try{this.video.volume=v}catch{}}
  seek(t){this.video.currentTime=t}
  async start(ms){
    const v=this.video,p=waitForPlaying(v,ms,this.abort.signal);audio.applyTo(v);
    // Sound blocked (no tap yet): start muted instead of failing, and let the next tap unmute.
    v.play().catch(e=>{if(e?.name==='NotAllowedError'&&!v.muted&&!this.abort.signal.aborted){audio.autoMuted=true;audio.applyTo(v);audio.emit();v.play().catch(()=>{})}});
    return p;
  }
  destroy(){this.abort.abort();resetVideo(this.video)}
}
class NativeEngine extends VideoEngine{
  constructor(v){super(v,'native')}
  async load(src,ms){this.video.src=src.hls;this.video.load();return this.start(ms)}
}
class HlsEngine extends VideoEngine{
  constructor(v){super(v,'hlsjs')}
  async load(src,ms){
    const Hls=await loadLib('hls');if(!Hls.isSupported())throw Error('hls.js is not supported here');
    const hls=this.hls=new Hls({enableWorker:true,lowLatencyMode:false,backBufferLength:30,maxBufferLength:20,maxMaxBufferLength:30,liveSyncDurationCount:3});
    const fatal=new Promise((_r,reject)=>hls.on(Hls.Events.ERROR,(_e,d)=>{if(d.fatal)reject(Error('hls.js: '+(d.details||'stream failed')+(d.response?.code?' (HTTP '+d.response.code+')':'')))}));
    hls.loadSource(src.hls);hls.attachMedia(this.video);
    return Promise.race([this.start(ms),fatal]);
  }
  get videoHeight(){return this.hls?.levels?.[this.hls.currentLevel]?.height||this.video.videoHeight}
  destroy(){try{this.hls?.destroy()}catch{}super.destroy()}
}
class MpegtsEngine extends VideoEngine{
  constructor(v){super(v,'mpegts')}
  async load(src,ms){
    const mpegts=await loadLib('mpegts');
    if(!mpegts.isSupported()||!mpegts.getFeatureList().mseLivePlayback)throw Error('MPEG-TS playback is not supported here');
    const p=this.player=mpegts.createPlayer({type:'mpegts',isLive:true,url:src.ts},{enableWorker:true,lazyLoad:false,liveBufferLatencyChasing:true,liveBufferLatencyMaxLatency:6,liveBufferLatencyMinRemain:1.5,autoCleanupSourceBuffer:true});
    const fatal=new Promise((_r,reject)=>p.on(mpegts.Events.ERROR,(type,detail)=>reject(Error('mpegts.js: '+type+' '+(detail||'')))));
    p.attachMediaElement(this.video);p.load();
    return Promise.race([this.start(ms),fatal]);
  }
  destroy(){try{this.player?.pause();this.player?.unload();this.player?.detachMediaElement();this.player?.destroy()}catch{}super.destroy()}
}
class CanvasWrap{
  constructor(stage,video){this.name='canvas';this.video=video;this.inner=new root.AntCanvasEngine.CanvasEngine(stage,{live:true,audio:{context:()=>audio.context(),volume:audio.volume,muted:audio.silent}});this.handlers=[]}
  get paused(){return this.inner.paused}get currentTime(){return this.inner.currentTime}get duration(){return Infinity}get videoHeight(){return this.inner.videoHeight}
  play(){return this.inner.play()}pause(){this.inner.pause()}setMuted(m){this.inner.setMuted(m)}setVolume(v){this.inner.setVolume(v)}seek(){}
  get audioBlocked(){return this.inner.audioBlocked}get audioIssue(){return this.inner.audioIssue}
  async load(src,ms){
    resetVideo(this.video);this.video.classList.add('ant-hidden');
    let t;const timeout=new Promise((_r,reject)=>{t=setTimeout(()=>reject(Error('No video after '+Math.round(ms/1000)+' seconds.')),ms)});
    try{await Promise.race([this.inner.load(src.fmp4),timeout])}finally{clearTimeout(t)}
  }
  on(e,f){this.inner.on(e,f)}
  destroy(){this.inner.destroy();this.video.classList.remove('ant-hidden')}
}

// ---------- ladder ----------
function ladder({video,sources,forced=settings.engine,tesla=isTesla()}){
  const can={
    native:!!sources.hls&&!!video.canPlayType?.('application/vnd.apple.mpegurl'),
    hlsjs:!!sources.hls&&hasMSE(),
    mpegts:!!sources.ts&&hasMSE(),
    canvas:!!sources.fmp4&&!!root.AntCanvasEngine?.supported()
  };
  const base=tesla?['canvas','native','hlsjs','mpegts']:['native','hlsjs','mpegts','canvas'];
  const order=forced&&forced!=='auto'&&can[forced]?[forced,...base.filter(x=>x!==forced)]:base;
  return order.filter(x=>can[x]);
}
function sourcesFor(url,iptv,hevc){
  const out={hls:url};
  if(iptv&&iptv.origin&&iptv.id){
    const m=String(url).match(/\/media\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)$/);
    if(m&&m[1]===iptv.id){const base=iptv.origin+'/iptv/stream/'+m[1]+'/'+m[2];out.ts=base+'?mode=ts';out.fmp4=base+'?mode=fmp4&video=auto'+(hevc?'&hevc=1':'')}
  }
  return out;
}

// ---------- progress (Continue watching) ----------
const PROGRESS_KEY='ant-progress',RECENT_KEY='ant-recent-live';
const readJSON=(k,d)=>{try{return JSON.parse(store.get(k,''))||d}catch{return d}};
function saveProgress(item,t,d){
  if(!item||!(d>0)||!isFinite(d))return;
  const all=readJSON(PROGRESS_KEY,{});const id=(item.kind==='movie'?'movie:':'episode:')+item.stream_id;
  if(t<30||t>d*0.95){delete all[id]}else all[id]={t:Math.floor(t),d:Math.floor(d),at:Date.now(),kind:item.kind,stream_id:String(item.stream_id),name:String(item.name||'').slice(0,200),container_extension:item.container_extension||'mp4',stream_icon:item.stream_icon||'',series:item.series||null};
  const entries=Object.entries(all).sort((a,b)=>b[1].at-a[1].at).slice(0,40);
  store.set(PROGRESS_KEY,JSON.stringify(Object.fromEntries(entries)));
}
function rememberLive(c){const list=readJSON(RECENT_KEY,[]).filter(x=>x!==String(c.stream_id));list.unshift(String(c.stream_id));store.set(RECENT_KEY,JSON.stringify(list.slice(0,20)))}

// ---------- overlay ----------
const ui={};let engine=null,attempt=0,current=null,hideTimer=null,isLive=false,lastSave=0,lastPointer='',unlockedAt=0;
const fmt=s=>{if(!isFinite(s)||s<0)return '0:00';s=Math.floor(s);const h=Math.floor(s/3600),m=Math.floor(s/60)%60,x=String(s%60).padStart(2,'0');return h?h+':'+String(m).padStart(2,'0')+':'+x:m+':'+x};
const el=(tag,cls,html)=>{const e=doc.createElement(tag);if(cls)e.className=cls;if(html!=null)e.innerHTML=html;return e};
const ICON={play:'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13l11-6.5z" fill="currentColor"/></svg>',pause:'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z" fill="currentColor"/></svg>',
  back10:'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5V2L7 6l5 4V7a6 6 0 1 1-6 6H4a8 8 0 1 0 8-8z" fill="currentColor"/><text x="12" y="16.5" font-size="6.5" text-anchor="middle" fill="currentColor" font-family="sans-serif" font-weight="700">10</text></svg>',
  fwd10:'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5V2l5 4-5 4V7a6 6 0 1 0 6 6h2a8 8 0 1 1-8-8z" fill="currentColor"/><text x="12" y="16.5" font-size="6.5" text-anchor="middle" fill="currentColor" font-family="sans-serif" font-weight="700">10</text></svg>',
  vol:'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9v6h4l5 4V5L8 9zm12.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z" fill="currentColor"/></svg>',
  mute:'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9v6h4l5 4V5L8 9zm12 0 5 6m0-6-5 6" stroke="currentColor" stroke-width="2" fill="currentColor"/></svg>'};
function media(){return engine||ui.video}
function init(){
  if(ui.ready||!doc)return;const watch=doc.getElementById('watch'),video=doc.getElementById('video');if(!watch||!video)return;
  ui.ready=true;ui.watch=watch;ui.video=video;video.removeAttribute('controls');video.controls=false;
  let stage=doc.getElementById('stage');if(!stage){stage=el('div','ant-stage');stage.id='stage';video.before(stage);stage.append(video)}
  ui.stage=stage;const bar=doc.getElementById('watchbar');if(bar&&bar.parentNode!==stage)stage.append(bar);
  const status=doc.getElementById('playstatus');if(status&&status.parentNode!==stage)stage.append(status);
  ui.center=el('div','ant-center');
  ui.back=el('button','ant-round','');ui.back.innerHTML=ICON.back10;ui.back.setAttribute('aria-label','Back 10 seconds');
  ui.toggle=el('button','ant-play','');ui.toggle.innerHTML=ICON.pause;ui.toggle.setAttribute('aria-label','Pause');
  ui.fwd=el('button','ant-round','');ui.fwd.innerHTML=ICON.fwd10;ui.fwd.setAttribute('aria-label','Forward 10 seconds');
  ui.center.append(ui.back,ui.toggle,ui.fwd);
  ui.bottom=el('div','ant-bottom');
  ui.time=el('span','ant-time','0:00');ui.seek=el('input','ant-seek');ui.seek.type='range';ui.seek.min='0';ui.seek.max='1000';ui.seek.value='0';ui.seek.setAttribute('aria-label','Seek');
  ui.dur=el('span','ant-time','0:00');ui.live=el('span','ant-live','● LIVE');
  ui.chips=el('div','ant-chips');ui.quality=el('span','ant-chip','');ui.engine=el('button','ant-chip ant-engine','');ui.engine.title='Player engine';
  ui.sound=el('button','ant-chip ant-sound','Tap for sound');ui.sound.hidden=true;
  ui.mute=el('button','ant-chip ant-icon','');ui.mute.innerHTML=ICON.vol;ui.mute.setAttribute('aria-label','Mute');
  ui.vol=el('input','ant-vol');ui.vol.type='range';ui.vol.min='0';ui.vol.max='100';ui.vol.step='1';ui.vol.setAttribute('aria-label','Volume');
  ui.volwrap=el('div','ant-volwrap');ui.volwrap.append(ui.mute,ui.vol);
  ui.chips.append(ui.sound,ui.quality,ui.engine,ui.volwrap);
  ui.bottom.append(ui.time,ui.seek,ui.dur,ui.live,ui.chips);
  stage.append(ui.center,ui.bottom);
  ui.toggle.onclick=e=>{e.stopPropagation();togglePlay()};
  ui.back.onclick=e=>{e.stopPropagation();skip(-10)};ui.fwd.onclick=e=>{e.stopPropagation();skip(10)};
  ui.mute.onclick=e=>{e.stopPropagation();const off=audio.silent||audio.volume===0;audio.unlock(true);audio.setMuted(!off);wake()};
  ui.sound.onclick=e=>{e.stopPropagation();audio.unlock(true);if(audio.muted)audio.setMuted(false);applyAudio();wake()};
  ui.vol.oninput=()=>{audio.unlock(true);audio.setVolume(Number(ui.vol.value)/100);wake()};
  ui.vol.addEventListener('click',e=>e.stopPropagation());
  audio.on(applyAudio);applyAudio();
  ui.engine.onclick=e=>{e.stopPropagation();openEngineMenu()};
  ui.seek.oninput=()=>{const m=media();const d=m.duration;if(isFinite(d)&&d>0)ui.time.textContent=fmt(d*ui.seek.value/1000)};
  ui.seek.onchange=()=>{const m=media();const d=m.duration;if(isFinite(d)&&d>0){if(engine)engine.seek(d*ui.seek.value/1000);else ui.video.currentTime=d*ui.seek.value/1000}};
  // A tap on the picture only shows/hides the controls. It never pauses: pausing is the pause button (or Space).
  stage.addEventListener('pointermove',e=>{if(e.pointerType==='mouse')wake()});
  stage.addEventListener('pointerdown',e=>{lastPointer=e.pointerType||''});
  stage.addEventListener('click',onStageTap);
  // Any tap or key while the page is open lets sound start (autoplay unlock). Capture phase, so it runs inside the gesture.
  for(const ev of ['pointerup','touchend','click','keydown'])doc.addEventListener(ev,e=>{if(e.target?.closest?.('.ant-volwrap,.ant-sound'))return;if(!ui.sound.hidden)unlockedAt=Date.now();audio.unlock(!ui.watch.classList.contains('hide')||isTesla()||settings.engine==='canvas')},true);
  const fs=doc.getElementById('fullscreen');if(fs)fs.onclick=()=>{if(doc.fullscreenElement)doc.exitFullscreen?.();else if(stage.requestFullscreen)stage.requestFullscreen().catch(()=>ui.video.webkitEnterFullscreen?.());else ui.video.webkitEnterFullscreen?.()};
  for(const ev of ['play','pause','playing','timeupdate','durationchange','loadedmetadata','waiting'])video.addEventListener(ev,sync);
  video.addEventListener('loadedmetadata',resume);video.addEventListener('timeupdate',track);
  doc.addEventListener('keydown',e=>{if(ui.watch.classList.contains('hide')||/INPUT|SELECT|TEXTAREA/.test(e.target?.tagName||''))return;if(e.key===' '||e.key==='k'){e.preventDefault();togglePlay()}else if(e.key==='ArrowLeft')skip(-10);else if(e.key==='ArrowRight')skip(10);else if(e.key==='Escape'&&!doc.fullscreenElement)doc.getElementById('close')?.click()});
  setInterval(()=>{if(!ui.watch.classList.contains('hide'))sync()},1000);
}
function controlTarget(t){return !!t?.closest?.('button,input,select,textarea,a,label,.ant-menu')}
// Touch: a tap toggles the controls. Mouse: hovering already shows them, so a click just keeps them up.
function onStageTap(e){if(controlTarget(e.target))return;if(lastPointer==='mouse'||Date.now()-unlockedAt<1000||ui.stage.classList.contains('ant-idle'))wake();else hideControls()}
function hideControls(){clearTimeout(hideTimer);ui.stage.classList.add('ant-idle')}
function applyAudio(){
  if(!ui.ready)return;const v=audio.volume,off=audio.silent||v===0;
  audio.applyTo(ui.video);try{engine?.setVolume?.(v);engine?.setMuted?.(audio.silent)}catch{}
  ui.mute.innerHTML=off?ICON.mute:ICON.vol;ui.mute.setAttribute('aria-label',off?'Unmute':'Mute');ui.mute.setAttribute('aria-pressed',String(off));
  const shown=audio.muted?0:Math.round(v*100);if(doc.activeElement!==ui.vol)ui.vol.value=String(shown);ui.vol.style.setProperty('--p',shown+'%');
  setNeedsTap(!!(audio.autoMuted||engine?.audioBlocked));
}
const TAP_NOTE=' · Tap the screen for sound';
function setNeedsTap(on){
  ui.sound.hidden=!on;ui.stage.classList.toggle('ant-needs-tap',on);
  if(on)wake();else{const s=doc.getElementById('playstatus');if(s&&s.textContent.endsWith(TAP_NOTE))s.textContent=s.textContent.slice(0,-TAP_NOTE.length)}
}
function wake(){ui.stage.classList.remove('ant-idle');clearTimeout(hideTimer);hideTimer=setTimeout(()=>{if(!media().paused&&ui.sound.hidden)ui.stage.classList.add('ant-idle')},3000)}
function togglePlay(){const m=media();if(m.paused)Promise.resolve(m.play()).catch(()=>{});else m.pause();setTimeout(sync,50);wake()}
function skip(s){if(isLive)return;const m=media();const d=m.duration;if(!isFinite(d))return;const t=Math.max(0,Math.min(d-1,m.currentTime+s));if(engine)engine.seek(t);else ui.video.currentTime=t;wake()}
function sync(){
  if(!ui.ready)return;const m=media();const paused=m.paused;
  ui.toggle.innerHTML=paused?ICON.play:ICON.pause;ui.toggle.setAttribute('aria-label',paused?'Play':'Pause');
  const d=m.duration,t=m.currentTime;const vod=!isLive&&isFinite(d)&&d>0;
  ui.stage.classList.toggle('ant-is-live',!vod);
  ui.time.textContent=fmt(t);ui.dur.textContent=vod?fmt(d):'';if(vod&&doc.activeElement!==ui.seek)ui.seek.value=String(Math.round(t/d*1000));
  ui.seek.style.setProperty('--p',(vod?t/d*100:100)+'%');
  const h=m.videoHeight||0;ui.quality.textContent=h?(h>=2000?'4K':h+'p'):'';ui.quality.hidden=!h;
  ui.engine.textContent=engine?ENGINE_LABELS[engine.name]:ui.mode||'Native';
  const needsTap=!!(audio.autoMuted||engine?.audioBlocked);if(ui.sound.hidden===needsTap)setNeedsTap(needsTap);
}
function track(){if(!current||isLive||current.kind==='live')return;const now=Date.now();if(now-lastSave<5000)return;lastSave=now;saveProgress(current,ui.video.currentTime,ui.video.duration)}
function resume(){
  if(!current||isLive||current.resumed)return;current.resumed=true;
  const saved=readJSON(PROGRESS_KEY,{})[(current.kind==='movie'?'movie:':'episode:')+current.stream_id];
  if(saved&&saved.t>30&&isFinite(ui.video.duration)&&saved.t<ui.video.duration*0.95)try{ui.video.currentTime=saved.t}catch{}
}
function openEngineMenu(){
  const menu=el('div','ant-menu');menu.setAttribute('role','menu');
  const opts=[['auto','Auto (recommended)'],['native','Native'],['hlsjs','HLS.js'],['mpegts','MPEG-TS'],['canvas','Canvas (WebCodecs)']];
  for(const [v,label] of opts){const b=el('button',settings.engine===v?'active':'',label);b.onclick=e=>{e.stopPropagation();settings.engine=v;menu.remove();if(current&&isLive&&ui.retry)ui.retry()};menu.append(b)}
  const close=()=>{menu.remove();doc.removeEventListener('click',close,true)};setTimeout(()=>doc.addEventListener('click',close,true));
  ui.stage.append(menu);
}
function status(text){const s=doc.getElementById('playstatus');if(s)s.textContent=text}

// ---------- public API ----------
const api={
  settings,ladder,sourcesFor,loadLib,ENGINE_LABELS,saveProgress,audio,
  __test:{VideoEngine,CanvasWrap},get engine(){return engine},
  progress(){return readJSON(PROGRESS_KEY,{})},recentLive(){return readJSON(RECENT_KEY,[])},
  handles(){return settings.engine!=='legacy'},
  track(c,mode){init();current=c?{...c,resumed:false}:null;isLive=!c||!c.kind||c.kind==='live';engine&&api.stop();ui.mode=mode||null;if(ui.ready){ui.stage.classList.toggle('ant-is-live',isLive);ui.back.hidden=ui.fwd.hidden=isLive;wake();sync()}},
  stop(){attempt++;const e=engine;engine=null;if(e)try{e.destroy()}catch{};if(ui.video)ui.video.classList.remove('ant-hidden')},
  async playLive({c,url,iptv,legacy,hevc}){
    init();
    if(hevc===undefined)hevc=await (root.AntCanvasEngine?.canDecodeHevc?.()||Promise.resolve(false));
    legacy?.stop?.();api.track(c);rememberLive(c);
    const watch=doc.getElementById('watch');watch?.classList.remove('hide');
    const title=doc.getElementById('playing');if(title)title.textContent=(root.AntTitles?.clean(c.name)||c.name||'Live TV');
    const sources=sourcesFor(url,iptv,hevc);const order=ladder({video:ui.video,sources});
    const my=++attempt;const errors=[];
    ui.retry=()=>api.playLive({c,url,iptv,legacy,hevc});
    for(const name of order){
      if(my!==attempt)return;
      status('Connecting with '+ENGINE_LABELS[name]+'…');ui.mode=ENGINE_LABELS[name];sync();
      const e=name==='native'?new NativeEngine(ui.video):name==='hlsjs'?new HlsEngine(ui.video):name==='mpegts'?new MpegtsEngine(ui.video):new CanvasWrap(ui.stage,ui.video);
      engine=e;applyAudio();
      try{
        await e.load(sources,name==='canvas'?25000:15000);
        if(my!==attempt){e.destroy();return}
        const note=e.audioIssue?' · No sound: '+e.audioIssue:(audio.autoMuted||e.audioBlocked)?TAP_NOTE:'';
        status('Now playing · '+ENGINE_LABELS[name]+(errors.length?' (after '+errors.map(x=>x.name).join(', ')+')':'')+note);applyAudio();
        e.on?.('audiostate',()=>{if(engine===e)applyAudio()});e.on?.('waiting',()=>status('Buffering live stream…'));e.on?.('playing',()=>status('Now playing · '+ENGINE_LABELS[name]));
        e.on?.('error',()=>{if(my===attempt&&engine===e)status('Playback stopped · '+ENGINE_LABELS[name]+'. Tap the engine chip to try another.')});
        sync();wake();return name;
      }catch(err){
        if(err?.aborted||my!==attempt){try{e.destroy()}catch{};return}
        errors.push({name:ENGINE_LABELS[name],message:String(err?.message||err)});
        try{e.destroy()}catch{};if(engine===e)engine=null;
      }
    }
    if(my!==attempt)return;
    const why=errors.map(x=>x.name+': '+x.message).join(' · ');
    if(legacy?.compatible&&/\/media\//.test(url)){status('Trying compatible playback… '+why);ui.mode='Compatible';sync();legacy.compatible();return 'compatible'}
    status(errors.length?'This channel would not play. '+why:'No playback engine is available in this browser.');
    return null;
  }
};
root.AntPlayer=api;root.AntAudio=audio;
if(doc){if(doc.readyState==='loading')doc.addEventListener('DOMContentLoaded',init);else init()}
})(typeof globalThis!=='undefined'?globalThis:window);
