import {spawn} from 'node:child_process';
import {mkdtemp,readFile,rm,readdir,stat} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
const delay=ms=>new Promise(r=>setTimeout(r,ms));
export function remuxArguments(input,dir,options=[],codec='h264'){
 const url=new URL(input);
 if(url.protocol!=='http:'||url.hostname!=='127.0.0.1'||!/^\/media\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/.test(url.pathname)||url.search||url.hash||url.username||url.password)throw Error('unsafe_target');
 return ['-nostdin','-v','quiet','-protocol_whitelist','http,tcp,crypto',...options,'-rw_timeout','15000000','-fflags','+genpts+discardcorrupt','-i',input,'-map','0:v:0','-map','0:a:0?','-c:v','copy','-c:a','copy','-bsf:a','aac_adtstoasc',...(codec==='hevc'?['-tag:v','hvc1']:[]),'-map_metadata','-1','-avoid_negative_ts','make_zero','-f','hls','-hls_segment_type','fmp4','-hls_time','4','-hls_list_size','4','-hls_delete_threshold','1','-hls_flags','delete_segments+temp_file','-hls_fmp4_init_filename','init.mp4','-hls_segment_filename',join(dir,'segment-%06d.m4s'),join(dir,'index.m3u8')];
}
export function createRemuxManager({options=async()=>[],now=Date.now,maxJobs=1,maxBytes=160*1024*1024,idleMs=45000}={}){
 const jobs=new Map();
 const stop=async key=>{const job=jobs.get(key);if(!job)return;jobs.delete(key);job.stopped=true;job.child?.kill('SIGKILL');await job.ready.catch(()=>{});if(job.dir)await rm(job.dir,{recursive:true,force:true})};
 const ensure=async(key,input,codec)=>{
  let job=jobs.get(key);
  if(!job){
   if(jobs.size>=maxJobs)throw Error('compatibility_busy');
   job={last:now(),stopped:false};jobs.set(key,job);
   job.ready=(async()=>{
    job.dir=await mkdtemp(join(tmpdir(),'rigatoni-remux-'));
    if(job.stopped)throw Error('compatibility_failed');
    const args=remuxArguments(input,job.dir,await options(),codec);
    if(job.stopped)throw Error('compatibility_failed');
    job.child=spawn('ffmpeg',args,{stdio:'ignore'});job.child.on('error',()=>{job.failed=true});job.child.on('exit',code=>{if(code!==0)job.failed=true});
   })();
  }
  job.last=now();
  try{await job.ready;return job}catch(error){await stop(key);throw error}
 };
 const sweep=async()=>{
  for(const [key,job] of jobs){
   if(now()-job.last>idleMs){await stop(key);continue}
   if(!job.dir)continue;
   const names=await readdir(job.dir).catch(()=>[]);
   let size=0;for(const name of names)size+=(await stat(join(job.dir,name)).catch(()=>({size:0}))).size;
   if(size>maxBytes)await stop(key);
  }
 };
 const timer=setInterval(()=>{void sweep()},5000);timer.unref();
 return{
  async read(key,input,codec,file){
   if(!/^(index\.m3u8|init\.mp4|segment-\d{6,}\.m4s)$/.test(file))throw Error('compatibility_file');
   const job=await ensure(key,input,codec);
   const deadline=Date.now()+25000;
   do{
    if(job.stopped||job.failed)throw Error('compatibility_failed');
    try{return await readFile(join(job.dir,file))}catch(error){if(error.code!=='ENOENT')throw Error('compatibility_failed');if(file!=='index.m3u8')throw Error('compatibility_segment_expired')}
    await delay(200);
   }while(Date.now()<deadline);
   await stop(key);throw Error('compatibility_timeout');
  },
  stop,sweep,
  async close(){clearInterval(timer);await Promise.all([...jobs.keys()].map(stop))},
  count:()=>jobs.size
 };
}
