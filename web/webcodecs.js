/* Ant Streams — WebCodecs canvas engine (Gigaplay-style).
   Streams fragmented MP4 from the Pi gateway (/iptv/stream/...?mode=fmp4), decodes it with
   VideoDecoder/AudioDecoder and paints frames to a <canvas>, with audio through Web Audio.
   Drawing the frames ourselves keeps playback going where a browser pauses <video>
   (Tesla's browser pauses <video> once the car leaves Park). Needs a secure context. */
(function(root){
'use strict';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function supported(){return !!(root.isSecureContext&&typeof root.VideoDecoder==='function'&&typeof root.EncodedVideoChunk==='function')}
async function canDecode(codec='avc1.64001f',width=1280,height=720){
  if(!supported())return false;
  try{return !!(await VideoDecoder.isConfigSupported({codec,codedWidth:width,codedHeight:height})).supported}catch{return false}
}
async function canDecodeHevc(){return canDecode('hev1.1.6.L120.90',1920,1080)}
class Emitter{constructor(){this.handlers={}}on(e,f){(this.handlers[e]??=[]).push(f);return this}emit(e,d){for(const f of this.handlers[e]||[])try{f(d)}catch{}}}
class CanvasEngine extends Emitter{
  constructor(stage,{live=true,onStats}={}){
    super();this.name='canvas';this.label='Canvas (WebCodecs)';this.stage=stage;this.live=live;this.onStats=onStats;
    this.canvas=document.createElement('canvas');this.canvas.className='ant-canvas';this.canvas.setAttribute('aria-label','Video');
    this.ctx=this.canvas.getContext('2d',{alpha:false,desynchronized:true});stage.append(this.canvas);
    this.frames=[];this.paused=false;this.muted=false;this.volume=1;this.destroyed=false;this.offset=0;this.duration=0;this.videoHeight=0;
    this.drawn=0;this.dropped=0;this._raf=this._raf.bind(this);
  }
  get currentTime(){return this.offset+Math.max(0,this.lastPts||0)}
  async load(url,{start=0}={}){
    if(!supported())throw Object.assign(Error('WebCodecs is not available in this browser'),{code:'CODEC_UNSUPPORTED'});
    if(!root.AntFmp4)throw Error('fMP4 demuxer missing');
    this.url=url;this.offset=start;this.abort=new AbortController();const gen=this.gen=(this.gen||0)+1;const stale=()=>this.destroyed||gen!==this.gen;
    const response=await fetch(url,{signal:this.abort.signal,cache:'no-store',credentials:'omit'});
    if(!response.ok){let msg='The stream didn’t start (HTTP '+response.status+')';try{const j=await response.json();if(j.error)msg+=' · '+j.error}catch{}throw Object.assign(Error(msg),{status:response.status})}
    let ready_,fail_;const ready=new Promise((resolve,reject)=>{ready_=resolve;fail_=reject});this._ready=()=>{if(!stale())ready_()};this._fail=e=>{if(!stale())fail_(e)};const fail=this._fail;
    const demux=new root.AntFmp4.Demuxer({onInit:init=>{if(!stale())this._init(init).catch(fail)},onSamples:s=>{if(!stale())this._samples(s)}});
    const reader=this.reader=response.body.getReader();
    (async()=>{
      try{for(;;){const {value,done}=await reader.read();if(done||stale())break;demux.push(value);
        // Back-pressure: keep about two seconds of decoded/queued video
        while(!stale()&&(this.frames.length>50||(this.vdec?.decodeQueueSize||0)>40))await sleep(20);}
        if(!stale()){this.ended=true;if(!this.drawn)fail(Error('The stream ended before any video arrived'));else this.emit('ended')}
      }catch(e){if(!stale()){fail(e);this.emit('error',e)}}
    })();
    if(!this.rafStarted){this.rafStarted=true;requestAnimationFrame(this._raf)}
    return ready;
  }
  async _init(init){
    const tracks=[...init.tracks.values()];const v=tracks.find(t=>t.kind==='video'),a=tracks.find(t=>t.kind==='audio');
    if(!v||!v.codec)throw Object.assign(Error('No decodable video track'),{code:'CODEC_UNSUPPORTED'});
    this.vtrack=v;this.atrack=a;this.videoHeight=v.height;
    const vconfig={codec:v.codec,codedWidth:v.width,codedHeight:v.height,description:v.description,hardwareAcceleration:'no-preference',optimizeForLatency:this.live};
    const sup=await VideoDecoder.isConfigSupported(vconfig).catch(()=>({supported:false}));
    if(!sup.supported)throw Object.assign(Error('This browser cannot decode '+v.codec+' with WebCodecs'),{code:'CODEC_UNSUPPORTED'});
    this.vdec=new VideoDecoder({output:f=>{if(this.destroyed){f.close();return}this.frames.push(f)},error:e=>{this.emit('error',e);this._fail?.(e)}});
    this.vdec.configure(vconfig);
    if(a&&a.codec&&typeof root.AudioDecoder==='function'){
      const aconfig={codec:a.codec,sampleRate:a.sampleRate,numberOfChannels:a.channels,...(a.description?{description:a.description}:{})};
      const ok=await AudioDecoder.isConfigSupported(aconfig).then(r=>r.supported).catch(()=>false);
      if(ok){
        const AC=root.AudioContext||root.webkitAudioContext;
        this.actx=new AC({latencyHint:'playback',sampleRate:a.sampleRate});
        this.gain=this.actx.createGain();this.gain.gain.value=this.muted?0:this.volume;this.gain.connect(this.actx.destination);
        this.adec=new AudioDecoder({output:d=>this._audio(d),error:()=>{this.adec=null}});this.adec.configure(aconfig);
        if(this.actx.state==='suspended')this.actx.resume().catch(()=>{});
      }
    }
    this.emit('loadedmetadata',{width:v.width,height:v.height,codec:v.codec,audio:a?.codec||null});
  }
  _samples(samples){
    if(this.destroyed||!this.vdec)return;
    for(const s of samples){
      const ts=Math.round(s.pts/s.timescale*1e6),dur=Math.round(s.duration/s.timescale*1e6);
      if(s.kind==='video'){
        if(!this.gotKey&&!s.key)continue;this.gotKey=true;
        if(this.vdec.state!=='configured')continue;
        this.vdec.decode(new EncodedVideoChunk({type:s.key?'key':'delta',timestamp:ts,duration:dur,data:s.data}));
      }else if(s.kind==='audio'&&this.adec&&this.adec.state==='configured'){
        this.adec.decode(new EncodedAudioChunk({type:'key',timestamp:ts,duration:dur,data:s.data}));
      }
    }
  }
  _clock(){
    // Media time in seconds. Audio clock when audio runs, otherwise a wall clock.
    if(this.base==null)return null;
    if(this.actx&&this.actx.state==='running'&&this.audioBase!=null)return this.audioBase.media+(this.actx.currentTime-this.audioBase.ctx);
    return this.base.media+(performance.now()-this.base.wall)/1000;
  }
  _audio(d){
    if(this.destroyed||!this.actx){d.close();return}
    const t=d.timestamp/1e6;
    try{
      const buf=this.actx.createBuffer(d.numberOfChannels,d.numberOfFrames,d.sampleRate);
      for(let c=0;c<d.numberOfChannels;c++){const plane=new Float32Array(d.numberOfFrames);d.copyTo(plane,{planeIndex:c,format:'f32-planar'});buf.copyToChannel(plane,c)}
      if(this.audioBase==null&&this.base!=null){this.audioBase={media:this._clock(),ctx:this.actx.currentTime}}
      if(this.audioBase!=null&&!this.paused){
        const when=this.audioBase.ctx+(t-this.audioBase.media);
        if(when>=this.actx.currentTime-0.02){const src=this.actx.createBufferSource();src.buffer=buf;src.connect(this.gain);src.start(Math.max(when,this.actx.currentTime))}
      }
    }catch{}
    d.close();
  }
  _raf(){
    if(this.destroyed)return;
    requestAnimationFrame(this._raf);
    if(this.paused||!this.frames.length){if(!this.paused&&this.drawn&&performance.now()-(this.lastPaint||0)>1500&&!this.waiting){this.waiting=true;this.emit('waiting')}return}
    if(this.base==null){const f=this.frames[0];this.base={media:f.timestamp/1e6,wall:performance.now()+(this.live?250:0)};}
    const now=this._clock();
    let frame=null;
    while(this.frames.length&&this.frames[0].timestamp/1e6<=now+0.008){if(frame){frame.close();this.dropped++}frame=this.frames.shift()}
    if(!frame){
      // Far behind (e.g. a stall): resync the clock to the next frame instead of waiting.
      if(this.frames[0].timestamp/1e6-now>2){this.base=null;this.audioBase=null}
      return;
    }
    if(this.canvas.width!==frame.displayWidth||this.canvas.height!==frame.displayHeight){this.canvas.width=frame.displayWidth;this.canvas.height=frame.displayHeight}
    this.ctx.drawImage(frame,0,0,this.canvas.width,this.canvas.height);
    this.lastPts=frame.timestamp/1e6;frame.close();this.drawn++;this.lastPaint=performance.now();
    if(this.waiting){this.waiting=false;this.emit('playing')}
    if(this.drawn===1){this._ready?.();this.emit('playing')}
    if(this.drawn%60===0)this.emit('timeupdate');
  }
  play(){if(!this.paused)return Promise.resolve();this.paused=false;
    if(this.live&&this.url){// Live: pausing drops behind, so jump back to live.
      const url=this.url;this._teardown(false);this.paused=false;return this.load(url).then(()=>this.emit('play'))}
    this.base=null;this.audioBase=null;this.actx?.resume().catch(()=>{});this.emit('play');return Promise.resolve()}
  pause(){this.paused=true;this.actx?.suspend().catch(()=>{});this.emit('pause')}
  setMuted(m){this.muted=m;if(this.gain)this.gain.gain.value=m?0:this.volume;if(!m)this.actx?.resume().catch(()=>{})}
  _teardown(removeCanvas){
    try{this.abort?.abort()}catch{}
    try{this.reader?.cancel().catch(()=>{})}catch{}
    for(const f of this.frames)try{f.close()}catch{};this.frames=[];
    try{this.vdec&&this.vdec.state!=='closed'&&this.vdec.close()}catch{}
    try{this.adec&&this.adec.state!=='closed'&&this.adec.close()}catch{}
    try{this.actx?.close()}catch{}
    this.vdec=this.adec=this.actx=null;this.base=this.audioBase=null;this.gotKey=false;this.drawn=0;
    if(removeCanvas)this.canvas.remove();
  }
  destroy(){this.destroyed=true;this._teardown(true)}
}
root.AntCanvasEngine={CanvasEngine,supported,canDecode,canDecodeHevc};
})(typeof globalThis!=='undefined'?globalThis:window);
