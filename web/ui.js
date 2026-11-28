/* Ant Streams — Gigaplay-style screens for the web player:
   Home shelves (Trending this week, Continue watching, Favorites, Recently watched),
   the TV guide grid with a red "now" line, the category show/hide sheet, and M3U sign-in.
   Talks to the main player script only through window.__antApi. Classic script. */
(function(root){
'use strict';
const doc=root.document;const api=()=>root.__antApi;
const $=id=>doc.getElementById(id);
const el=(tag,cls,text)=>{const e=doc.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e};
const store={get(k,d){try{const v=localStorage.getItem(k);return v==null?d:JSON.parse(v)}catch{return d}},set(k,v){try{localStorage.setItem(k,JSON.stringify(v))}catch{}}};
const clean=n=>root.AntTitles?root.AntTitles.clean(n):String(n||'');
const norm=n=>root.AntTitles?root.AntTitles.normalize(n):String(n||'').toLowerCase();

// ================= Categories (show / hide) =================
const HIDDEN_KEY='ant-hidden-categories';
const hidden=()=>{const h=store.get(HIDDEN_KEY,{});return {live:new Set(h.live||[]),movies:new Set(h.movies||[]),series:new Set(h.series||[])}};
let hiddenCache=hidden();
const saveHidden=()=>store.set(HIDDEN_KEY,{live:[...hiddenCache.live],movies:[...hiddenCache.movies],series:[...hiddenCache.series]});
const sectionForTab=t=>t==='movies'?'movies':t==='series'?'series':'live';
const catsFor=section=>{const a=api();return section==='movies'?a.movieCategories:section==='series'?a.seriesCategories:a.categories};
const AntCategories={
  visible(section,id){return !hiddenCache[section]?.has(String(id))},
  hiddenCount(section){return hiddenCache[section]?.size||0},
  decorate(bar){
    const a=api();if(!a||!['home','live','movies','series','favorites','guide'].includes(a.tab))return;
    const section=sectionForTab(a.tab),n=AntCategories.hiddenCount(section);
    const b=el('button','btn ghost chip-btn',n?'Categories · '+n+' hidden':'Categories');b.type='button';b.onclick=()=>openSheet(section);bar.append(b);
  }
};
function openSheet(section){
  closeSheet();
  const shade=el('div','sheet-shade');shade.id='catSheet';shade.onclick=e=>{if(e.target===shade)closeSheet()};
  const sheet=el('div','sheet');sheet.setAttribute('role','dialog');sheet.setAttribute('aria-modal','true');sheet.setAttribute('aria-label','Show or hide categories');
  const head=el('div','sheet-head');head.append(el('h2',null,'Categories'));const x=el('button','btn ghost','Done');x.onclick=closeSheet;head.append(x);sheet.append(head);
  const seg=el('div','segmented');
  for(const [key,label] of [['live','Live TV'],['movies','Movies'],['series','Series']]){const b=el('button',key===section?'active':'',label);b.onclick=()=>openSheet(key);seg.append(b)}
  sheet.append(seg);
  // US-only lives in the main script; mirror it by clicking the real checkbox.
  const us=el('label','sheet-row');const box=el('input');box.type='checkbox';box.checked=!!api().usOnly;box.onchange=()=>{const real=doc.querySelector('.filterbar .us-only input');if(real){real.checked=box.checked;real.onchange?.()}else{try{localStorage.setItem('ant-us-only',box.checked?'1':'0')}catch{}}setTimeout(()=>openSheet(section),0)};
  us.append(el('span',null,'US / English only'),box);sheet.append(us);
  const eng=el('label','sheet-row');const sel=el('select');for(const [v,l] of [['auto','Auto (recommended)'],['native','Native'],['hlsjs','HLS.js'],['mpegts','MPEG-TS'],['canvas','Canvas (WebCodecs)'],['legacy','Classic player']]){const o=el('option',null,l);o.value=v;sel.append(o)}
  sel.value=root.AntPlayer?.settings.engine||'auto';sel.onchange=()=>{if(root.AntPlayer)root.AntPlayer.settings.engine=sel.value};eng.append(el('span',null,'Player engine'),sel);sheet.append(eng);
  const all=(catsFor(section)||[]).filter(c=>!api().usOnly||api().isUsEnCategory(c));
  const tools=el('div','sheet-tools');const q=el('input','searchbar');q.type='search';q.placeholder='Filter categories…';
  const showAll=el('button','btn ghost','Show all'),hideAll=el('button','btn ghost','Hide all');tools.append(q,showAll,hideAll);sheet.append(tools);
  const list=el('div','sheet-list');sheet.append(list);
  const draw=()=>{
    list.replaceChildren();const term=q.value.trim().toLowerCase();
    const shown=all.filter(c=>!term||String(c.category_name||'').toLowerCase().includes(term));
    if(!all.length)list.append(el('p','empty',section==='live'?'Connect a provider to manage categories.':'Open '+(section==='movies'?'Movies':'Series')+' once to load its categories.'));
    for(const c of shown.slice(0,600)){
      const id=String(c.category_id),row=el('label','sheet-row');const t=el('input');t.type='checkbox';t.className='switch';t.checked=!hiddenCache[section].has(id);
      t.onchange=()=>{if(t.checked)hiddenCache[section].delete(id);else hiddenCache[section].add(id);saveHidden();api().render()};
      row.append(el('span',null,c.category_name||'Untitled'),t);list.append(row);
    }
    if(shown.length>600)list.append(el('p','empty','Showing 600 of '+shown.length+'. Filter to find more.'));
  };
  q.oninput=draw;
  showAll.onclick=()=>{for(const c of all)hiddenCache[section].delete(String(c.category_id));saveHidden();draw();api().render()};
  hideAll.onclick=()=>{for(const c of all)hiddenCache[section].add(String(c.category_id));saveHidden();draw();api().render()};
  draw();shade.append(sheet);doc.body.append(shade);q.focus({preventScroll:true});
  doc.addEventListener('keydown',escClose);
}
function escClose(e){if(e.key==='Escape')closeSheet()}
function closeSheet(){$('catSheet')?.remove();doc.removeEventListener('keydown',escClose)}

// ================= Home =================
const trending={key:null,movie:null,tv:null,loading:false,failed:false};
async function loadTrending(){
  const a=api(),iptv=a?.iptv;if(!iptv)return;const key=iptv.origin+'|'+iptv.id;
  if(trending.key===key&&(trending.movie||trending.loading||trending.failed))return;
  Object.assign(trending,{key,loading:true,failed:false,movie:null,tv:null});
  try{
    const get=async m=>{const r=await fetch(iptv.origin+'/iptv/trending/'+iptv.id+'?media='+m,{cache:'no-store'});if(!r.ok)throw Error(String(r.status));return (await r.json()).results||[]};
    const [movie,tv]=await Promise.all([get('movie'),get('tv').catch(()=>[])]);trending.movie=movie;trending.tv=tv;
  }catch{trending.failed=true}finally{trending.loading=false}
  if(api().tab==='home')api().render();
}
let moviesRequested=false;
function matchCatalog(items,catalog){
  const index=new Map();for(const c of catalog||[]){const k=norm(c.name);if(k&&!index.has(k))index.set(k,c)}
  return items.map(t=>{const k=norm(t.title);let hit=index.get(k);if(!hit&&k.length>=4){for(const [name,c] of index){if(name.startsWith(k+' ')){hit=c;break}}}return {...t,item:hit||null}});
}
function posterCard(t,kind){
  const card=el('button','poster');card.type='button';card.setAttribute('aria-label',t.title+(t.item?'':' — search your provider'));
  if(t.poster){const img=el('img');img.src=t.poster;img.alt='';img.loading='lazy';img.referrerPolicy='no-referrer';img.onerror=()=>img.remove();card.append(img)}
  else card.append(el('div','poster-fallback',t.title.slice(0,1)));
  const meta=el('div','poster-meta');meta.append(el('span','poster-title',t.title));meta.append(el('span','poster-sub',(t.year?t.year+' · ':'')+(kind==='tv'?'Series':'Movie')));card.append(meta);
  if(t.item)card.append(el('span','poster-badge','▶ On your provider'));
  card.onclick=()=>{const a=api();if(t.item){if(t.item.kind==='series'){a.showTab('series');a.showSeriesDetail(t.item)}else a.play(t.item)}else a.search(kind==='tv'?'series':'movies',t.title)};
  return card;
}
function shelf(root,title,cards,{note,poster}={}){
  if(!cards.length)return;
  const sec=el('section','shelf');const head=el('div','rowhead');head.append(el('h2',null,title));if(note)head.append(el('span','shelf-note',note));sec.append(head);
  const rail=el('div','rail'+(poster?' poster-rail':''));for(const c of cards)rail.append(c);sec.append(rail);root.append(sec);
}
function setHero(t){
  const hero=doc.querySelector('.hero');if(!hero)return;
  const b0=$('browse');if(b0&&!b0.__antOriginal)b0.__antOriginal=b0.onclick;
  if(!t){hero.style.removeProperty('--hero-image');hero.classList.remove('has-art');const eb=hero.querySelector('.eyebrow');if(eb)eb.textContent='YOUR ENTERTAINMENT. YOUR WAY.';if(b0&&b0.__antOriginal)b0.onclick=b0.__antOriginal;return}
  if(t.backdrop)hero.style.setProperty('--hero-image','url("'+t.backdrop.replace(/"/g,'')+'")');hero.classList.toggle('has-art',!!t.backdrop);
  const eyebrow=hero.querySelector('.eyebrow');if(eyebrow)eyebrow.textContent='TRENDING THIS WEEK';
  $('heroTitle').textContent=t.title;$('heroDescription').textContent=t.overview||'Welcome back. Here’s what everyone is watching this week.';
  const b=$('browse');if(b){b.textContent=t.item?'▶ Play now':'Find it on your provider';b.onclick=()=>{const a=api();if(t.item){if(t.item.kind==='series'){a.showTab('series');a.showSeriesDetail(t.item)}else a.play(t.item)}else a.search('movies',t.title)}}
}
const AntHome={
  render(root){
    const a=api();if(!a)return;
    const wrap=el('div','home-shelves');root.append(wrap);
    // Welcome
    const hour=new Date().getHours();const hi=el('p','welcome',(hour<12?'Good morning':hour<18?'Good afternoon':'Good evening')+'. Pick up where you left off, or see what’s trending.');wrap.append(hi);
    // Trending this week
    if(a.iptv){
      void loadTrending();
      if(trending.movie){
        if(!a.moviesLoaded&&!moviesRequested){moviesRequested=true;void a.loadMovies().catch(()=>{})}
        const movies=matchCatalog(trending.movie,a.movies),tv=matchCatalog(trending.tv||[],a.series);
        const mixed=[];for(let i=0;i<Math.max(movies.length,tv.length);i++){if(movies[i])mixed.push([movies[i],'movie']);if(tv[i])mixed.push([tv[i],'tv'])}
        mixed.sort((x,y)=>(y[0].item?1:0)-(x[0].item?1:0));
        shelf(wrap,'Trending this week',mixed.slice(0,24).map(([t,k])=>posterCard(t,k)),{poster:true,note:'From TMDB'});
        setHero(mixed[0]?.[0]||null);
      }else if(trending.loading)wrap.append(el('p','empty','Loading what’s trending this week…'));
    }
    // Continue watching
    const progress=Object.values(root.AntPlayer?.progress()||{}).sort((x,y)=>y.at-x.at).slice(0,18);
    const cw=progress.map(p=>{const item=p.kind==='movie'?(a.movies||[]).find(m=>String(m.stream_id)===p.stream_id):null;const c=item||{kind:p.kind,stream_id:p.stream_id,name:p.name,container_extension:p.container_extension,stream_icon:p.stream_icon};
      const tile=el('button','continue');tile.type='button';if(c.stream_icon){const img=el('img');img.src=c.stream_icon;img.alt='';img.loading='lazy';img.onerror=()=>img.remove();tile.append(img)}
      tile.append(el('span','name',c.name||'Untitled'));const bar=el('span','progress');bar.style.setProperty('--p',Math.round(p.t/p.d*100)+'%');tile.append(bar);tile.append(el('span','left',Math.max(1,Math.round((p.d-p.t)/60))+' min left'));
      tile.onclick=async()=>{if(p.kind==='movie'&&!item){await a.loadMovies().catch(()=>{});const m=(a.movies||[]).find(x=>String(x.stream_id)===p.stream_id);a.play(m||c)}else a.play(c)};return tile});
    shelf(wrap,'Continue watching',cw);
    // Favorites (channels, movies and series)
    const favs=[...a.channels,...a.movies,...a.series].filter(c=>a.favorites.has(a.favoriteId(c))).slice(0,48);
    shelf(wrap,'Favorites',favs.map(c=>a.makeTile(c)),{note:favs.length?'':undefined});
    if(!favs.length&&!cw.length)wrap.append(el('p','empty','Tap ♡ on any channel or movie to add it to your Favorites.'));
    // Recently watched channels
    const byId=new Map(a.channels.map(c=>[String(c.stream_id),c]));
    const recent=(root.AntPlayer?.recentLive()||[]).map(id=>byId.get(id)).filter(Boolean).slice(0,18);
    shelf(wrap,'Recently watched',recent.map(c=>a.makeTile(c)));
  }
};

// ================= Guide =================
const GUIDE={page:0,category:'',cache:new Map(),pending:new Set(),timer:null};
const PER_PAGE=25,PX_PER_MIN=4,SPAN_MIN=210;
const b64=s=>{try{return decodeURIComponent(escape(atob(String(s||''))))}catch{return String(s||'')}};
async function fetchEpg(ids){
  const a=api(),need=ids.filter(id=>{const h=GUIDE.cache.get(id);return !(h&&Date.now()-h.at<10*60*1000)&&!GUIDE.pending.has(id)});
  if(!need.length)return false;need.forEach(id=>GUIDE.pending.add(id));
  try{
    if(a.iptv){
      for(let i=0;i<need.length;i+=40){const batch=need.slice(i,i+40);const r=await fetch(a.iptv.origin+'/iptv/epg/'+a.iptv.id+'?ids='+batch.join(','),{cache:'no-store'});const j=r.ok?await r.json():{epg:{}};for(const id of batch)GUIDE.cache.set(id,{at:Date.now(),list:j.epg?.[id]||[]})}
    }else{
      const queue=[...need];await Promise.all(Array.from({length:4},async()=>{while(queue.length){const id=queue.shift();try{const j=await a.load('get_short_epg',{stream_id:id,limit:8});const list=(j.epg_listings||[]).map(e=>({title:b64(e.title),description:b64(e.description),start:Number(e.start_timestamp),end:Number(e.stop_timestamp)})).filter(e=>e.start&&e.end>e.start);GUIDE.cache.set(id,{at:Date.now(),list})}catch{GUIDE.cache.set(id,{at:Date.now(),list:[]})}}}));
    }
  }finally{need.forEach(id=>GUIDE.pending.delete(id))}
  return true;
}
const clock=t=>new Date(t*1000).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'});
const AntGuide={
  render(root){
    const a=api();clearInterval(GUIDE.timer);
    const catMap=new Map(a.categories.map(c=>[String(c.category_id),c]));
    const cats=a.categories.filter(c=>(!a.usOnly||a.isUsEnCategory(c))&&AntCategories.visible('live',c.category_id));
    const visibleIds=new Set(cats.map(c=>String(c.category_id)));
    let list=a.channels.filter(c=>visibleIds.has(String(c.category_id))||!catMap.has(String(c.category_id))&&!a.usOnly);
    if(GUIDE.category)list=list.filter(c=>String(c.category_id)===GUIDE.category);
    const q=($('search')?.value||'').trim().toLowerCase();if(q)list=list.filter(c=>String(c.name||'').toLowerCase().includes(q)||clean(c.name).toLowerCase().includes(q));
    const pages=Math.max(1,Math.ceil(list.length/PER_PAGE));GUIDE.page=Math.min(GUIDE.page,pages-1);
    const rows=list.slice(GUIDE.page*PER_PAGE,(GUIDE.page+1)*PER_PAGE);
    const bar=el('div','guide-bar');const sel=el('select');sel.setAttribute('aria-label','Guide category');const all=el('option',null,'All categories');all.value='';sel.append(all);
    for(const c of cats){const o=el('option',null,c.category_name||'Channels');o.value=String(c.category_id);sel.append(o)}sel.value=GUIDE.category;sel.onchange=()=>{GUIDE.category=sel.value;GUIDE.page=0;a.render()};
    bar.append(sel);
    const prev=el('button','btn ghost','← Previous'),next=el('button','btn ghost','Next →');prev.disabled=GUIDE.page===0;next.disabled=GUIDE.page+1>=pages;
    prev.onclick=()=>{GUIDE.page--;a.render()};next.onclick=()=>{GUIDE.page++;a.render()};
    bar.append(prev,el('span','guide-count',list.length?(GUIDE.page*PER_PAGE+1)+'–'+Math.min(list.length,(GUIDE.page+1)*PER_PAGE)+' of '+list.length+' channels':'No channels'),next);
    const cb=doc.createElement('div');AntCategories.decorate(cb);bar.append(...cb.children);
    root.append(bar);
    if(!rows.length){root.append(el('p','empty','No channels match. Check the category filters.'));return}
    const nowS=Date.now()/1000;const winStart=Math.floor(nowS/1800)*1800-1800,winEnd=winStart+SPAN_MIN*60;
    const grid=el('div','guide');grid.style.setProperty('--ppm',PX_PER_MIN+'px');grid.style.setProperty('--span',SPAN_MIN);
    const head=el('div','guide-head');head.append(el('div','guide-corner'));const times=el('div','guide-times');
    for(let t=winStart;t<winEnd;t+=1800){const s=el('span',null,clock(t));s.style.left=((t-winStart)/60*PX_PER_MIN)+'px';times.append(s)}
    head.append(times);grid.append(head);
    const body=el('div','guide-body');
    rows.forEach((c,i)=>{
      const r=el('div','guide-row');const ch=el('button','guide-ch');ch.type='button';ch.title=c.name||'';
      ch.append(el('span','guide-num',String(GUIDE.page*PER_PAGE+i+1)),el('span','guide-name',clean(c.name)||'Channel'));ch.onclick=()=>a.play(c);
      const lane=el('div','guide-lane');const id=String(c.stream_id);const hit=GUIDE.cache.get(id);
      const progs=(hit?.list||[]).filter(p=>p.end>winStart&&p.start<winEnd);
      if(!hit){lane.append(Object.assign(el('div','prog prog-loading','Loading guide…'),{style:'left:0;width:'+(SPAN_MIN*PX_PER_MIN-8)+'px'}))}
      else if(!progs.length){const p=el('button','prog prog-empty');p.type='button';p.append(el('strong',null,clean(c.name)||'Live'),el('small',null,'No guide data'));p.style.left='0px';p.style.width=(SPAN_MIN*PX_PER_MIN-8)+'px';p.onclick=()=>a.play(c);lane.append(p)}
      for(const p of progs){
        const s=Math.max(p.start,winStart),e=Math.min(p.end,winEnd);const b=el('button','prog'+(p.start<=nowS&&p.end>nowS?' prog-now':''));b.type='button';
        b.style.left=((s-winStart)/60*PX_PER_MIN)+'px';b.style.width=Math.max(24,(e-s)/60*PX_PER_MIN-6)+'px';
        b.append(el('strong',null,p.title||'Untitled'),el('small',null,clock(p.start)+' to '+clock(p.end)));
        if(p.start<=nowS&&p.end>nowS){const pr=el('span','prog-bar');pr.style.width=Math.round((nowS-s)/(e-s)*100)+'%';b.append(pr)}
        if(p.description)b.title=p.title+' — '+p.description;b.onclick=()=>a.play(c);lane.append(b);
      }
      r.append(ch,lane);body.append(r);
    });
    const line=el('div','now-line');const pill=el('span','now-pill',clock(nowS).replace(/\s?[AP]M$/i,''));line.append(pill);
    line.style.left='calc(var(--chw) + '+((nowS-winStart)/60*PX_PER_MIN)+'px)';body.append(line);
    grid.append(body);root.append(grid);
    const scroller=grid;requestAnimationFrame(()=>{scroller.scrollLeft=Math.max(0,(nowS-winStart)/60*PX_PER_MIN-120)});
    void fetchEpg(rows.map(c=>String(c.stream_id))).then(changed=>{if(changed&&api().tab==='guide')api().render()});
    GUIDE.timer=setInterval(()=>{if(api().tab!=='guide'){clearInterval(GUIDE.timer);return}const n=Date.now()/1000;line.style.left='calc(var(--chw) + '+((n-winStart)/60*PX_PER_MIN)+'px)';pill.textContent=clock(n).replace(/\s?[AP]M$/i,'');if(n>winStart+3600)api().render()},30000);
  }
};

// ================= M3U sign-in =================
function addM3uForm(){
  const login=$('login');if(!login||$('m3uCard'))return;
  const card=el('details','m3u-card');card.id='m3uCard';
  const sum=el('summary',null,'Have an M3U playlist link instead?');card.append(sum);
  const p=el('p','muted','Your Pi gateway loads the playlist, keeps the link private, and plays plain-HTTP channels over HTTPS. Live channels and the playlist’s guide are supported.');card.append(p);
  const label=el('label',null,'M3U link');label.htmlFor='m3u';const input=el('input');input.id='m3u';input.type='url';input.placeholder='http://provider.example/get.php?…';input.autocomplete='off';
  const btn=el('button','btn red','Connect M3U');btn.type='button';btn.id='connectM3u';
  btn.onclick=async()=>{const s=$('status');const url=input.value.trim();if(!url){s.textContent='Paste your M3U link first.';return}
    if(!root.__rigatoniM3uConnect){s.textContent='Sign in and save your gateway URL first, then connect the M3U link.';return}
    btn.disabled=true;s.textContent='Loading your playlist on the gateway…';
    try{const result=await root.__rigatoniM3uConnect(url);input.value='';api().applyM3u(result);s.textContent='Connected: '+result.channels.length+' channels'+(result.vod_skipped?' ('+result.vod_skipped+' movie/series entries skipped)':'')}catch(e){s.textContent='M3U connection failed: '+e.message}finally{btn.disabled=false}};
  card.append(label,input,btn);login.append(card);
}
function clearHeroOnTab(){doc.querySelectorAll('nav button').forEach(b=>b.addEventListener('click',()=>{if(b.dataset.tab!=='home')setHero(null)}))}

root.AntCategories=AntCategories;root.AntHome=AntHome;root.AntGuide=AntGuide;
const boot=()=>{addM3uForm();clearHeroOnTab()};
if(doc.readyState==='loading')doc.addEventListener('DOMContentLoaded',boot);else boot();
})(window);
