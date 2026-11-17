import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
class Element{
 constructor(tag='div'){this.tag=tag;this.children=[];this.className='';this.textContent='';this.value='';this.style={};this.attributes={};this.classList={add(){},remove(){},toggle(){}}}
 append(...nodes){for(const n of nodes){n.parent=this;this.children.push(n)}}
 prepend(n){n.parent=this;this.children.unshift(n)}
 replaceChildren(...nodes){this.children=[];this.append(...nodes)}
 remove(){this.parent.children=this.parent.children.filter(n=>n!==this)}
 setAttribute(k,v){this.attributes[k]=v}
 removeAttribute(k){delete this.attributes[k]}
 pause(){} load(){} async play(){} scrollIntoView(){}
}
const elements=new Map(),get=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id)};
const document={getElementById:get,querySelectorAll:()=>[],querySelector:()=>null,createElement:tag=>new Element(tag),documentElement:{setAttribute(){},getAttribute:()=>'dark'}};
const scripts=[...fs.readFileSync(new URL('../xtream.html',import.meta.url),'utf8').matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const code=scripts[1];
const writes=[],window={scrollTo(){}};
const context=vm.createContext({document,window,localStorage:{getItem:()=>null,setItem:(...args)=>writes.push(args)},URL,setTimeout,clearTimeout,confirm:()=>true,location:{protocol:'https:',port:''}});
vm.runInContext(code,context);
vm.runInContext(`
channels=Array.from({length:100000},(_,i)=>({stream_id:i+1,name:'Test channel '+(i+1),category_id:String(Math.floor(i/100)+1),stream_icon:''}));
categories=Array.from({length:1000},(_,i)=>({category_id:String(i+1),category_name:'Group '+(i+1)}));
credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};
showTab('live');
`,context);
const descendants=e=>e.children.flatMap(n=>[n,...descendants(n)]);
const cards=()=>descendants(get('rows')).filter(n=>n.className==='tile');
const sections=()=>get('rows').children.filter(n=>n.tag==='section');
const next=e=>e.children.at(-1).children.at(-1);
const errText=()=>{const e=get('rows').children.find(n=>n.className==='empty');return e?e.textContent:''};
assert.equal(cards().length,168);assert.equal(sections().length,7);assert.match(get('count').textContent,/100000/);
next({children:get('rows').children}).onclick();
assert.equal(cards().length,168);assert.equal(sections()[1].children[0].children[0].textContent,'Group 7');
next(sections()[0]).onclick();
assert.equal(cards().length,168);assert.equal(sections()[0].children[1].children[0].children[1].textContent,'Test channel 25');
get('search').value='Test channel 100000';get('search').oninput();await new Promise(r=>setTimeout(r,250));
assert.equal(cards().length,1);cards()[0].children.at(-1).onclick({stopPropagation(){}});
vm.runInContext("showTab('favorites')",context);
assert.equal(cards().length,1);assert.equal(cards()[0].children[1].textContent,'Test channel 100000');
get('search').value='';vm.runInContext("showTab('home')",context);assert.ok(cards().length<=192);
vm.runInContext("gatewayStreams={'100000':'https://homepi.test.ts.net/media/session/resource'}",context);
await cards()[0].onclick();assert.match(get('video').src,/homepi.test.ts.net\/media/);assert.equal(get('playing').textContent,'Test channel 100000');
window.__rigatoniClearProvider();assert.equal(cards().length,0);assert.equal(get('pass').value,'');
assert.ok(writes.every(([key])=>key==='rigatoni-favorites'));
console.log('PASS 100,000 channels/1,000 categories: bounded cards, category/rail paging, full-catalog search, favorites, gateway player selection and cleanup');

let movieRequests=0;
context.AbortSignal=AbortSignal;
context.fetch=async(url,options)=>{movieRequests++;assert.equal(options.cache,'no-store');return new Response(JSON.stringify({categories:Array.from({length:500},(_,i)=>({category_id:String(i+1),category_name:'Movie group '+(i+1)})),movies:Array.from({length:50000},(_,i)=>({stream_id:i+1,name:'Film '+(i+1),kind:'movie',category_id:String(Math.floor(i/100)+1),container_extension:'mp4',stream_icon:''})),streams:Object.fromEntries(Array.from({length:50000},(_,i)=>[i+1,'/media/movie-session/resource'+(i+1)]))}),{headers:{'content-type':'application/json'}})};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'};moviesPath='https://homepi.test.ts.net/api/movies/movie-session';showTab('movies')",context);
await vm.runInContext('loadMovies()',context);assert.equal(movieRequests,1);assert.equal(cards().length,168);assert.match(get('count').textContent,/50000 matching movies/);
get('search').value='Film 50000';get('search').oninput();await new Promise(r=>setTimeout(r,250));assert.equal(cards().length,1);
cards()[0].children.at(-1).onclick({stopPropagation(){}});assert.ok(writes.at(-1)[1].includes('movie:50000'));
await cards()[0].onclick();assert.equal(get('video').src,'https://homepi.test.ts.net/media/movie-session/resource50000');assert.equal(get('playing').textContent,'Film 50000');
vm.runInContext("showTab('live');showTab('movies')",context);assert.equal(movieRequests,1);
vm.runInContext("moviesLoaded=false;moviesPath=null;movieError='';moviesLoading=null;showTab('movies')",context);await vm.runInContext('loadMovies()',context);assert.match(errText(),/Update the Pi/);assert.equal(vm.runInContext('moviesLoading',context),null);
window.__rigatoniClearProvider();assert.equal(vm.runInContext('movies.length',context),0);
console.log('PASS 50,000 movies: lazy load/cache, bounded cards, search, namespaced favorites, opaque MP4 playback, unavailable gateway retry and delete cleanup');

for(const [error,expected] of [['catalog_too_large',/item limit/],['response_too_large',/response-size limit/],['session_resource_limit',/resource limit/],['provider_connection_failed',/provider rejected/],['not_found',/Update the Pi/],['secret provider credentials must never be echoed',/could not load/]]){
 context.fetch=async()=>new Response(JSON.stringify({error}),{status:502});
 vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};moviesPath='https://homepi.test.ts.net/api/movies/test';moviesLoading=null;moviesLoaded=false;tab='movies'",context);
 await vm.runInContext('loadMovies()',context);
 assert.match(errText(),expected);assert.match(errText(),/HTTP 502/);assert.ok(!errText().includes('secret provider credentials'));assert.equal(vm.runInContext('moviesLoading',context),null);
}
console.log('PASS movie failure reasons distinguish limits, provider failures and outdated gateways without reflecting untrusted error strings');

window.__rigatoniClearProvider();
get('search').value='';
const categoryRequests=[];
context.fetch=async input=>{const url=new URL(input);categoryRequests.push(url.search);const category=url.searchParams.get('category_id');return new Response(JSON.stringify({browse_by_category:true,categories:[{category_id:'9',category_name:'Action'},{category_id:'10',category_name:'Drama'}],movies:category?[{stream_id:category,name:'Movie in '+category,container_extension:'mp4',category_id:category}]:[],streams:category?{[category]:'/media/test/resource'+category}:{},...(category?{category_id:category}:{})}))};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};moviesPath='https://homepi.test.ts.net/api/movies/test';tab='movies'",context);
await vm.runInContext('loadMovies()',context);assert.deepEqual(categoryRequests,['','?category_id=9']);assert.equal(cards().length,1);
const categorySelect=()=>get('rows').children.find(n=>n.tag==='select');assert.equal(categorySelect().value,'9');assert.equal(categorySelect().children.length,2);assert.ok(get('rows').children.some(n=>n.textContent.includes('every category')));
categorySelect().value='10';categorySelect().onchange();await vm.runInContext('loadMovies()',context);assert.equal(categoryRequests.at(-1),'?category_id=10');assert.equal(cards()[0].children[1].textContent,'Movie in 10');await cards()[0].onclick();assert.equal(get('video').src,'https://homepi.test.ts.net/media/test/resource10');
window.__rigatoniClearProvider();assert.equal(vm.runInContext('movieCategoryMode',context),false);
console.log('PASS large-movie category fallback, automatic first category, selector switching, scoped search explanation, movie playback and reset');

vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};moviesLoaded=true;showTab('movies')",context);
assert.equal(get('heroTitle').textContent,'Movie night, made yours.');assert.equal(get('browse').textContent,'▶ Browse Movies');assert.equal(get('search').placeholder,'Search movies…');
get('browse').onclick();assert.equal(vm.runInContext('tab',context),'movies');
vm.runInContext("showTab('live')",context);assert.equal(get('heroTitle').textContent,'Live TV, made yours.');assert.equal(get('search').placeholder,'Search channels…');
vm.runInContext("showTab('favorites')",context);assert.equal(get('heroTitle').textContent,'Your list, your favorites.');
console.log('PASS Movies, Live TV and My List headings, descriptions, browse buttons and search prompts match their tabs');

// --- Series (gateway mode): list, search, favorites, detail, episode playback ---
window.__rigatoniClearProvider();
get('search').value='';
context.fetch=async input=>{const url=new URL(input);if(url.pathname.endsWith('/info'))return new Response(JSON.stringify({info:{name:'Dummy series',cover:'/media/test/cover',plot:'A test plot.',cast:'Actor One',genre:'Drama',releaseDate:'2024-01-01',rating:'8.5'},seasons:[{season_number:1,episode_count:2,name:'Season 1'},{season_number:2,episode_count:1,name:'Season 2'}],episodes:{'1':[{id:101,episode_num:1,title:'Pilot',container_extension:'mp4',season:1,stream_icon:'/media/test/ep101',plot:'Pilot plot.'},{id:102,episode_num:2,title:'Second',container_extension:'mkv',season:1}],'2':[{id:201,episode_num:1,title:'Return',container_extension:'mp4',season:2}]},streams:{101:'/media/test/ep101',102:'/media/test/ep102',201:'/media/test/ep201'}}),{headers:{'content-type':'application/json'}});return new Response(JSON.stringify({categories:[{category_id:'9',category_name:'Test Series'}],series:[{stream_id:5,series_id:5,kind:'series',name:'Dummy series',category_id:'9',stream_icon:'/media/test/cover',rating:'8.5'}]}),{headers:{'content-type':'application/json'}})};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'};seriesPath='https://homepi.test.ts.net/api/series/series-session';showTab('series')",context);
await vm.runInContext('loadSeries()',context);
assert.equal(cards().length,2);assert.match(get('count').textContent,/1 matching series/);
assert.equal(get('heroTitle').textContent,'TV shows, made yours.');assert.equal(get('search').placeholder,'Search series…');
get('search').value='Dummy';get('search').oninput();await new Promise(r=>setTimeout(r,250));assert.equal(cards().length,1);
get('search').value='Nope';get('search').oninput();await new Promise(r=>setTimeout(r,250));assert.equal(cards().length,0);
get('search').value='';get('search').oninput();await new Promise(r=>setTimeout(r,250));assert.equal(cards().length,2);
cards()[0].children.at(-1).onclick({stopPropagation(){}});assert.ok(writes.at(-1)[1].includes('series:5'));
vm.runInContext("showTab('favorites')",context);assert.equal(cards().length,1);assert.equal(cards()[0].children[1].textContent,'Dummy series');
vm.runInContext("showTab('series')",context);
await cards()[0].onclick();
const episodeRows=()=>descendants(get('rows')).filter(n=>n.className==='episode-row');
assert.equal(episodeRows().length,2);
const seasonSelect=()=>get('rows').children.find(n=>n.tag==='select');assert.equal(seasonSelect().children.length,2);
seasonSelect().value='2';seasonSelect().onchange();assert.equal(episodeRows().length,1);
seasonSelect().value='1';seasonSelect().onchange();assert.equal(episodeRows().length,2);
await episodeRows()[0].onclick();assert.equal(get('video').src,'https://homepi.test.ts.net/media/test/ep101');assert.equal(get('playing').textContent,'Dummy series S1E1 — Pilot');
vm.runInContext('stopVideo()',context);
get('rows').children[0].onclick();assert.equal(cards().length,2);
console.log('PASS series tab: gateway list/search, namespaced favorites, detail with seasons, episode playback and back navigation');

// --- Series (direct mode): list and detail without a gateway ---
window.__rigatoniClearProvider();
get('search').value='';
context.fetch=async input=>{const url=new URL(input);const action=url.searchParams.get('action');if(action==='get_series_categories')return new Response(JSON.stringify([{category_id:'9',category_name:'Direct Series'}]));if(action==='get_series')return new Response(JSON.stringify([{series_id:9,name:'Direct show',category_id:'9',cover:'https://provider.example.invalid/cover.jpg',rating:'7'}]));if(action==='get_series_info')return new Response(JSON.stringify({info:{name:'Direct show',cover:'https://provider.example.invalid/cover.jpg',plot:'Direct plot.'},seasons:[{season_number:1,episode_count:1,name:'Season 1'}],episodes:{'1':[{id:301,episode_num:1,title:'One',container_extension:'mp4',season:1,info:{movie_image:'',plot:''}}]}}));throw new Error('unexpected '+action)};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams=null;seriesPath=null;showTab('series')",context);
await vm.runInContext('loadSeries()',context);
assert.equal(cards().length,2);assert.equal(cards()[0].children[1].textContent,'Direct show');
await cards()[0].onclick();
assert.equal(episodeRows().length,1);
await episodeRows()[0].onclick();assert.equal(get('video').src,'https://provider.example.invalid/series/dummy/dummy/301.mp4');
vm.runInContext('stopVideo()',context);
console.log('PASS direct series load and episode playback without a gateway');

// --- Series without a gateway series endpoint: clear guidance, no crash ---
window.__rigatoniClearProvider();
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};seriesPath=null;seriesLoading=null;seriesLoaded=false;tab='series'",context);
await vm.runInContext('loadSeries()',context);
assert.match(errText(),/Update the Pi/);assert.equal(vm.runInContext('seriesLoading',context),null);
window.__rigatoniClearProvider();assert.equal(vm.runInContext('series.length',context),0);
console.log('PASS series on an outdated gateway explains the Pi update and resets cleanly');

// --- US / English only filter: live TV categories ---
window.__rigatoniClearProvider();
get('search').value='';
vm.runInContext(`
categories=[{category_id:'1',category_name:'USA Movies'},{category_id:'2',category_name:'UK Sports'},{category_id:'3',category_name:'English News'},{category_id:'4',category_name:'Hindi Movies'},{category_id:'5',category_name:'EN Kids'},{category_id:'6',category_name:'French Cinema'}];
channels=[
 {stream_id:1,name:'US Channel One',category_id:'1',stream_icon:''},
 {stream_id:2,name:'UK Channel',category_id:'2',stream_icon:''},
 {stream_id:3,name:'News EN',category_id:'3',stream_icon:''},
 {stream_id:4,name:'Hindi Channel',category_id:'4',stream_icon:''},
 {stream_id:5,name:'Kids EN',category_id:'5',stream_icon:''},
 {stream_id:6,name:'French Channel',category_id:'6',stream_icon:''}
];
credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};
usOnly=false;showTab('live');
`,context);
assert.match(get('count').textContent,/6 matching titles/);
assert.equal(sections().length,7);
const filterBox=()=>descendants(get('rows')).find(n=>n.tag==='input');
assert.ok(filterBox());assert.equal(filterBox().checked,false);
filterBox().checked=true;filterBox().onchange();
assert.match(get('count').textContent,/3 matching titles/);
assert.equal(sections().length,4);
assert.equal(sections()[1].children[0].children[0].textContent,'USA Movies');
assert.equal(sections()[2].children[0].children[0].textContent,'English News');
assert.equal(sections()[3].children[0].children[0].textContent,'EN Kids');
assert.deepEqual(writes.at(-1),['ant-us-only','1']);
filterBox().checked=false;filterBox().onchange();
assert.match(get('count').textContent,/6 matching titles/);
assert.deepEqual(writes.at(-1),['ant-us-only','0']);
console.log('PASS US/English filter: live TV categories, rail titles, persistence, toggle off restores all');

// --- Movie version grouping: one tile, version picker, last-chosen memory, group favorites ---
window.__rigatoniClearProvider();
get('search').value='';
context.fetch=async()=>new Response(JSON.stringify({categories:[{category_id:'1',category_name:'USA Movies'},{category_id:'2',category_name:'Bollywood'}],movies:[
 {stream_id:1,name:'Dune (2021)',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:2,name:'Dune (2021) [1080p]',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:3,name:'Dune (2021) 4K',kind:'movie',category_id:'1',container_extension:'mkv',stream_icon:''},
 {stream_id:4,name:'Dune (1984)',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:5,name:'Dune',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:6,name:'Other Film',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:7,name:'Bollywood Film',kind:'movie',category_id:'2',container_extension:'mp4',stream_icon:''}
],streams:{1:'/media/movie-session/resource1',2:'/media/movie-session/resource2',3:'/media/movie-session/resource3',4:'/media/movie-session/resource4',5:'/media/movie-session/resource5',6:'/media/movie-session/resource6',7:'/media/movie-session/resource7'}}),{headers:{'content-type':'application/json'}});
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'};moviesPath='https://homepi.test.ts.net/api/movies/movie-session';usOnly=false;showTab('movies')",context);
await vm.runInContext('loadMovies()',context);
assert.match(get('count').textContent,/5 matching movies/);
assert.equal(cards().length,10);
assert.equal(cards()[0].children[1].textContent,'Dune (2021)');
assert.equal(cards()[0].children[2].textContent,'3 versions');
assert.equal(cards()[0].children[2].className,'versions');
vm.runInContext('usOnly=true;render()',context);
assert.match(get('count').textContent,/4 matching movies/);
assert.equal(cards().length,8);
vm.runInContext('usOnly=false;render()',context);
assert.match(get('count').textContent,/5 matching movies/);
await cards()[0].onclick();
const versionRows=()=>descendants(get('rows')).filter(n=>n.className==='episode-row');
assert.equal(versionRows().length,3);
assert.match(versionRows()[1].children[0].textContent,/Dune \(2021\) \[1080p\]/);
await versionRows()[2].onclick();
assert.equal(get('video').src,'https://homepi.test.ts.net/media/movie-session/resource3');
assert.equal(get('playing').textContent,'Dune (2021) 4K');
assert.equal(vm.runInContext("lastVersions['movie|dune|2021']",context),'3');
vm.runInContext('stopVideo()',context);
await cards()[0].onclick();
assert.match(versionRows()[2].children[0].textContent,/Last chosen/);
get('rows').children[0].onclick();
assert.equal(cards().length,10);
cards()[0].children.at(-1).onclick({stopPropagation(){}});
assert.ok(writes.at(-1)[1].includes('movie:1'));
vm.runInContext("showTab('favorites')",context);
assert.equal(cards().length,1);
assert.equal(cards()[0].children[2].textContent,'3 versions');
await cards()[0].onclick();
assert.equal(versionRows().length,3);
get('rows').children[0].onclick();
cards()[0].children.at(-1).onclick({stopPropagation(){}});
assert.equal(cards().length,0);
console.log('PASS movie version grouping: one tile per title, version picker, last-chosen memory, grouped favorites, US/EN category filter');

// --- Series version grouping (direct mode) and US/EN category filter ---
window.__rigatoniClearProvider();
get('search').value='';
context.fetch=async input=>{const url=new URL(input);const action=url.searchParams.get('action');if(action==='get_series_categories')return new Response(JSON.stringify([{category_id:'9',category_name:'US Drama'},{category_id:'10',category_name:'Hindi Series'}]));if(action==='get_series')return new Response(JSON.stringify([{series_id:11,name:'Breaking Bad',category_id:'9',cover:''},{series_id:12,name:'Breaking Bad [Hindi]',category_id:'9',cover:''},{series_id:13,name:'Breaking Bad (2010)',category_id:'9',cover:''},{series_id:14,name:'Hindi Show',category_id:'10',cover:''}]));if(action==='get_series_info')return new Response(JSON.stringify({info:{name:'Breaking Bad',cover:'',plot:'A show.'},seasons:[{season_number:1,episode_count:1,name:'Season 1'}],episodes:{'1':[{id:301,episode_num:1,title:'Pilot',container_extension:'mp4',season:1,info:{movie_image:'',plot:''}}]}}));throw new Error('unexpected '+action)};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams=null;seriesPath=null;usOnly=false;showTab('series')",context);
await vm.runInContext('loadSeries()',context);
assert.match(get('count').textContent,/3 matching series/);
assert.equal(cards().length,6);
assert.equal(cards()[0].children[1].textContent,'Breaking Bad');
assert.equal(cards()[0].children[2].textContent,'2 versions');
vm.runInContext('usOnly=true;render()',context);
assert.match(get('count').textContent,/2 matching series/);
assert.equal(cards().length,4);
vm.runInContext('usOnly=false;render()',context);
assert.match(get('count').textContent,/3 matching series/);
await cards()[0].onclick();
assert.equal(versionRows().length,2);
await versionRows()[1].onclick();
assert.equal(episodeRows().length,1);
await episodeRows()[0].onclick();
assert.equal(get('video').src,'https://provider.example.invalid/series/dummy/dummy/301.mp4');
vm.runInContext('stopVideo()',context);
get('rows').children[0].onclick();
assert.equal(cards().length,6);
console.log('PASS series version grouping: one tile per title, version picker, US/EN category filter, direct-mode detail and episode playback');

// --- US/EN filter in large-library category mode: auto-switches to first matching category ---
window.__rigatoniClearProvider();
get('search').value='';
const usCatRequests=[];
context.fetch=async input=>{const url=new URL(input);usCatRequests.push(url.search);const category=url.searchParams.get('category_id');return new Response(JSON.stringify({browse_by_category:true,categories:[{category_id:'9',category_name:'Action'},{category_id:'10',category_name:'USA Drama'}],movies:category?[{stream_id:category,name:'Movie in '+category,container_extension:'mp4',category_id:category}]:[],streams:category?{[category]:'/media/test/resource'+category}:{},...(category?{category_id:category}:{})}))};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};moviesPath='https://homepi.test.ts.net/api/movies/test';tab='movies';usOnly=true",context);
await vm.runInContext('loadMovies()',context);
await vm.runInContext('moviesLoading',context);
assert.deepEqual(usCatRequests,['','?category_id=9','?category_id=10']);
const usSelect=()=>get('rows').children.find(n=>n.tag==='select');
assert.equal(usSelect().value,'10');assert.equal(usSelect().children.length,1);
assert.equal(filterBox().checked,true);
assert.match(get('count').textContent,/1 matching movies/);
assert.equal(cards().length,1);
window.__rigatoniClearProvider();
vm.runInContext('usOnly=false',context);
console.log('PASS US/EN filter in category mode: auto-switches to the first matching category, selector lists only matching categories');

// --- Category-mode series search sweeps every category, with live progress ---
window.__rigatoniClearProvider();
get('search').value='';
const sweepRequests=[];
let releaseCat11=null;
const seriesCategoriesMock=[{category_id:'9',category_name:'ENGLISH SERIES 4K 3840P'},{category_id:'10',category_name:'USA Drama'},{category_id:'11',category_name:'Hindi Series'}];
const sweepSeriesItems={'9':[{stream_id:91,series_id:91,name:'From',category_id:'9',cover:''}],'10':[{stream_id:101,series_id:101,name:'From Scratch',category_id:'10',cover:''}],'11':[{stream_id:111,series_id:111,name:'From Hindi',category_id:'11',cover:''}]};
context.fetch=async input=>{const url=new URL(input);const category=url.searchParams.get('category_id');sweepRequests.push(url.search);if(!category)return new Response(JSON.stringify({browse_by_category:true,categories:seriesCategoriesMock,series:[]}));if(category==='11')await new Promise(res=>{releaseCat11=res});return new Response(JSON.stringify({browse_by_category:true,categories:seriesCategoriesMock,series:sweepSeriesItems[category]||[],category_id:category}))};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};seriesPath='https://homepi.test.ts.net/api/series/test';tab='series';usOnly=false",context);
await vm.runInContext('loadSeries()',context);
assert.equal(cards().length,1);
assert.equal(cards()[0].children[1].textContent,'From');
get('search').value='From';get('search').oninput();
await new Promise(r=>setTimeout(r,250));
assert.match(get('count').textContent,/Searching all categories/);
assert.match(get('count').textContent,/2 found so far/);
assert.equal(cards().length,2);
releaseCat11();
for(let i=0;i<50&&!vm.runInContext('searchSweep&&searchSweep.done',context);i++)await new Promise(r=>setTimeout(r,20));
assert.ok(vm.runInContext('searchSweep&&searchSweep.done',context));
assert.equal(vm.runInContext('searchSweep.items.length',context),3);
assert.match(get('count').textContent,/2 matching series/);
assert.equal(cards().length,2);
assert.equal(cards()[0].children[1].textContent,'From');
assert.equal(cards()[0].children[2].textContent,'2 versions');
assert.ok(sweepRequests.includes('?category_id=10'));
assert.ok(sweepRequests.includes('?category_id=11'));
console.log('PASS series category search sweeps all categories with live progress');

// --- US/EN sweep covers only matching categories; repeat searches reuse the cache ---
window.__rigatoniClearProvider();
get('search').value='';
const usSweepRequests=[];
context.fetch=async input=>{const url=new URL(input);const category=url.searchParams.get('category_id');usSweepRequests.push(url.search);if(!category)return new Response(JSON.stringify({browse_by_category:true,categories:seriesCategoriesMock,series:[]}));return new Response(JSON.stringify({browse_by_category:true,categories:seriesCategoriesMock,series:sweepSeriesItems[category]||[],category_id:category}))};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};seriesPath='https://homepi.test.ts.net/api/series/test';tab='series';usOnly=true",context);
await vm.runInContext('loadSeries()',context);
get('search').value='From';get('search').oninput();
for(let i=0;i<100&&!vm.runInContext('searchSweep&&searchSweep.done',context);i++)await new Promise(r=>setTimeout(r,20));
assert.ok(vm.runInContext('searchSweep&&searchSweep.done',context));
assert.ok(usSweepRequests.includes('?category_id=10'));
assert.ok(!usSweepRequests.includes('?category_id=11'));
assert.equal(cards().length,2);
assert.match(get('count').textContent,/2 matching series/);
const requestsBeforeRepeat=usSweepRequests.length;
get('search').value='';get('search').oninput();await new Promise(r=>setTimeout(r,250));
get('search').value='From';get('search').oninput();
for(let i=0;i<100&&!vm.runInContext('searchSweep&&searchSweep.done',context);i++)await new Promise(r=>setTimeout(r,20));
assert.ok(vm.runInContext('searchSweep&&searchSweep.done',context));
assert.equal(usSweepRequests.length,requestsBeforeRepeat);
assert.equal(cards().length,2);
assert.match(get('count').textContent,/2 matching series/);
console.log('PASS US/EN sweep covers only matching categories and the repeat search reuses cached categories');

// --- Sweep abort: changing the query mid-sweep drops stale results ---
window.__rigatoniClearProvider();
get('search').value='';
const abortWaiters=[];
const abortSeriesItems={'9':[{stream_id:91,series_id:91,name:'From',category_id:'9',cover:''}],'10':[{stream_id:101,series_id:101,name:'From Scratch',category_id:'10',cover:''},{stream_id:102,series_id:102,name:'Other Show',category_id:'10',cover:''}],'11':[{stream_id:111,series_id:111,name:'From Hindi',category_id:'11',cover:''}]};
context.fetch=async input=>{const url=new URL(input);const category=url.searchParams.get('category_id');if(!category)return new Response(JSON.stringify({browse_by_category:true,categories:seriesCategoriesMock,series:[]}));if(category==='10'||category==='11')await new Promise(res=>{abortWaiters.push(res)});return new Response(JSON.stringify({browse_by_category:true,categories:seriesCategoriesMock,series:abortSeriesItems[category]||[],category_id:category}))};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};seriesPath='https://homepi.test.ts.net/api/series/test';tab='series';usOnly=false",context);
await vm.runInContext('loadSeries()',context);
assert.equal(cards().length,1);
get('search').value='From';get('search').oninput();
await new Promise(r=>setTimeout(r,250));
assert.match(get('count').textContent,/Searching all categories/);
assert.equal(cards().length,1);
get('search').value='Scratch';get('search').oninput();
await new Promise(r=>setTimeout(r,250));
abortWaiters.splice(0).forEach(res=>res());
for(let i=0;i<100&&!vm.runInContext('searchSweep&&searchSweep.done',context);i++)await new Promise(r=>setTimeout(r,20));
assert.ok(vm.runInContext('searchSweep&&searchSweep.done',context));
assert.equal(vm.runInContext('searchSweep.query',context),'scratch');
assert.equal(cards().length,1);
assert.equal(cards()[0].children[1].textContent,'From Scratch');
assert.match(get('count').textContent,/1 matching series/);
console.log('PASS sweep abort: query change drops stale category results');

// --- Movie category search sweeps all categories, groups versions, retries a 429 ---
window.__rigatoniClearProvider();
get('search').value='';
const movieSweepRequests=[];
let cat10Attempts=0;
const movieCategoriesMock=[{category_id:'9',category_name:'USA Movies'},{category_id:'10',category_name:'Action'}];
context.fetch=async input=>{const url=new URL(input);const category=url.searchParams.get('category_id');movieSweepRequests.push(url.search);if(!category)return new Response(JSON.stringify({browse_by_category:true,categories:movieCategoriesMock,movies:[],streams:{}}));if(category==='10'){cat10Attempts++;if(cat10Attempts===1)return new Response(JSON.stringify({error:'movie_catalog_busy'}),{status:429})}const data={'9':{movies:[{stream_id:91,name:'Dune (2021)',kind:'movie',category_id:'9',container_extension:'mp4',stream_icon:''}],streams:{91:'/media/test/resource91'}},'10':{movies:[{stream_id:101,name:'Dune (2021) 4K',kind:'movie',category_id:'10',container_extension:'mkv',stream_icon:''}],streams:{101:'/media/test/resource101'}}}[category];return new Response(JSON.stringify({browse_by_category:true,categories:movieCategoriesMock,movies:data.movies,streams:data.streams,category_id:category}))};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};moviesPath='https://homepi.test.ts.net/api/movies/test';tab='movies';usOnly=false",context);
await vm.runInContext('loadMovies()',context);
assert.equal(cards().length,1);
assert.equal(cards()[0].children[1].textContent,'Dune (2021)');
get('search').value='Dune';get('search').oninput();
for(let i=0;i<100&&!vm.runInContext('searchSweep&&searchSweep.done',context);i++)await new Promise(r=>setTimeout(r,50));
assert.ok(vm.runInContext('searchSweep&&searchSweep.done',context));
assert.equal(movieSweepRequests.filter(s=>s==='?category_id=10').length,2);
assert.equal(cards().length,1);
assert.equal(cards()[0].children[1].textContent,'Dune (2021)');
assert.equal(cards()[0].children[2].textContent,'2 versions');
assert.match(get('count').textContent,/1 matching movies/);
await cards()[0].onclick();
assert.equal(versionRows().length,2);
await versionRows()[1].onclick();
assert.equal(get('video').src,'https://homepi.test.ts.net/media/test/resource101');
assert.equal(get('playing').textContent,'Dune (2021) 4K');
vm.runInContext('stopVideo()',context);
console.log('PASS movie category search sweeps all categories, groups versions, retries a 429 and plays the swept version');

// --- Download filenames: Jellyfin-friendly movie/episode names ---
assert.equal(vm.runInContext("movieFilename({name:'Dune (2021) [1080p]',container_extension:'mkv'},null)",context),'Dune (2021).mkv');
assert.equal(vm.runInContext("movieFilename({name:'Dune (2021) [1080p]',container_extension:'mp4'},{versions:[{stream_id:1},{stream_id:2}]})",context),'Dune (2021) [1080p].mp4');
assert.equal(vm.runInContext("movieFilename({name:'Dune (2021) 4K',container_extension:'mkv'},{versions:[{stream_id:1},{stream_id:2}]})",context),'Dune (2021) [4K].mkv');
assert.equal(vm.runInContext("episodeFilename('From',1,2,'Pilot','mp4')",context),'From - S01E02 - Pilot.mp4');
assert.equal(vm.runInContext("episodeFilename('From',1,1,'','mkv')",context),'From - S01E01 - Episode 01.mkv');
assert.equal(vm.runInContext("sanitizeFilename('a/b:c?.mp4')",context),'a b c .mp4');
assert.ok(vm.runInContext("downloadFilename('x'.repeat(200),'mp4').length",context)<=150);
assert.equal(vm.runInContext("versionTag('Dune (2021) 4K','Dune (2021)')",context),'4K');
assert.equal(vm.runInContext("downloadUrlForTicket('https://homepi.test.ts.net/media/s/k','Dune (2021).mp4')",context),'https://homepi.test.ts.net/download/s/k?filename=Dune%20(2021).mp4');
assert.equal(vm.runInContext("downloadUrlForTicket(null,'Dune.mp4')",context),null);
console.log('PASS download filenames: Jellyfin movie/episode names, version tags, sanitizing and length cap');

// --- Download: movie tile link, version picker link, HEAD probe, hidden cases ---
window.__rigatoniClearProvider();
get('search').value='';
context.AbortSignal=AbortSignal;
context.fetch=async()=>new Response(JSON.stringify({categories:[{category_id:'1',category_name:'USA Movies'}],movies:[
 {stream_id:1,name:'Dune (2021)',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:2,name:'Dune (2021) [1080p]',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:3,name:'Dune (2021) 4K',kind:'movie',category_id:'1',container_extension:'mkv',stream_icon:''},
 {stream_id:4,name:'Dune (1984)',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:5,name:'Other Film',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
 {stream_id:6,name:'HLS Film',kind:'movie',category_id:'1',container_extension:'m3u8',stream_icon:''}
],streams:{1:'/media/movie-session/resource1',2:'/media/movie-session/resource2',3:'/media/movie-session/resource3',4:'/media/movie-session/resource4',5:'/media/movie-session/resource5',6:'/media/movie-session/resource6'}}),{headers:{'content-type':'application/json'}});
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'};moviesPath='https://homepi.test.ts.net/api/movies/movie-session';usOnly=false;gatewayDownloads=true;showTab('movies')",context);
await vm.runInContext('loadMovies()',context);
assert.equal(cards().length,8);
const dlOf=c=>c.children.find(n=>n.className==='dl');
assert.equal(dlOf(cards()[0]),undefined);
assert.ok(dlOf(cards()[1]));
assert.equal(dlOf(cards()[1]).tag,'a');
assert.equal(dlOf(cards()[1]).href,'https://homepi.test.ts.net/download/movie-session/resource4?filename=Dune%20(1984).mp4');
assert.ok(dlOf(cards()[2]));
assert.equal(dlOf(cards()[3]),undefined);
vm.runInContext("location.assign=u=>{window.__dlNav=u}",context);
context.fetch=async(url,options)=>{assert.equal(options.method,'HEAD');return new Response(null,{status:200})};
dlOf(cards()[1]).onclick({preventDefault(){},stopPropagation(){}});
await new Promise(r=>setTimeout(r,50));
assert.equal(vm.runInContext('window.__dlNav',context),'https://homepi.test.ts.net/download/movie-session/resource4?filename=Dune%20(1984).mp4');
context.fetch=async()=>new Response(null,{status:401});
dlOf(cards()[1]).onclick({preventDefault(){},stopPropagation(){}});
await new Promise(r=>setTimeout(r,50));
assert.match(get('count').textContent,/Reconnect to download/);
await cards()[0].onclick();
assert.equal(versionRows().length,3);
assert.equal(dlOf(versionRows()[1]).href,'https://homepi.test.ts.net/download/movie-session/resource2?filename=Dune%20(2021)%20%5B1080p%5D.mp4');
assert.equal(dlOf(versionRows()[2]).href,'https://homepi.test.ts.net/download/movie-session/resource3?filename=Dune%20(2021)%20%5B4K%5D.mkv');
context.fetch=async(url,options)=>{assert.equal(options.method,'HEAD');return new Response(null,{status:200})};
dlOf(versionRows()[1]).onclick({preventDefault(){},stopPropagation(){}});
await new Promise(r=>setTimeout(r,50));
assert.equal(vm.runInContext('window.__dlNav',context),'https://homepi.test.ts.net/download/movie-session/resource2?filename=Dune%20(2021)%20%5B1080p%5D.mp4');
get('rows').children[0].onclick();
assert.equal(cards().length,8);
vm.runInContext('gatewayDownloads=false;render()',context);
assert.equal(descendants(get('rows')).filter(n=>n.className==='dl').length,0);
vm.runInContext('gatewayDownloads=true;gatewayStreams=null;render()',context);
assert.equal(descendants(get('rows')).filter(n=>n.className==='dl').length,0);
console.log('PASS download links: movie tile and version picker, Jellyfin filenames, HEAD probe navigation, expired-session notice, hidden on old gateways, direct mode and playlists');

// --- Download: episode rows in series detail ---
window.__rigatoniClearProvider();
get('search').value='';
context.fetch=async input=>{const url=new URL(input);if(url.pathname.endsWith('/info'))return new Response(JSON.stringify({info:{name:'Dummy series',cover:'/media/test/cover',plot:'A test plot.',cast:'Actor One',genre:'Drama',releaseDate:'2024-01-01',rating:'8.5'},seasons:[{season_number:1,episode_count:2,name:'Season 1'},{season_number:2,episode_count:1,name:'Season 2'}],episodes:{'1':[{id:101,episode_num:1,title:'Pilot',container_extension:'mp4',season:1,stream_icon:'/media/test/ep101',plot:'Pilot plot.'},{id:102,episode_num:2,title:'Second',container_extension:'mkv',season:1}],'2':[{id:201,episode_num:1,title:'Return',container_extension:'mp4',season:2}]},streams:{101:'/media/test/ep101',102:'/media/test/ep102',201:'/media/test/ep201'}}),{headers:{'content-type':'application/json'}});return new Response(JSON.stringify({categories:[{category_id:'9',category_name:'Test Series'}],series:[{stream_id:5,series_id:5,kind:'series',name:'Dummy series',category_id:'9',stream_icon:'/media/test/cover',rating:'8.5'}]}),{headers:{'content-type':'application/json'}})};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'};seriesPath='https://homepi.test.ts.net/api/series/series-session';gatewayDownloads=true;showTab('series')",context);
await vm.runInContext('loadSeries()',context);
await cards()[0].onclick();
assert.equal(episodeRows().length,2);
assert.equal(episodeRows()[0].children.find(n=>n.className==='dl').href,'https://homepi.test.ts.net/download/test/ep101?filename=Dummy%20series%20-%20S01E01%20-%20Pilot.mp4');
assert.equal(episodeRows()[1].children.find(n=>n.className==='dl').href,'https://homepi.test.ts.net/download/test/ep102?filename=Dummy%20series%20-%20S01E02%20-%20Second.mkv');
context.fetch=async(url,options)=>{assert.equal(options.method,'HEAD');return new Response(null,{status:200})};
episodeRows()[0].children.find(n=>n.className==='dl').onclick({preventDefault(){},stopPropagation(){}});
await new Promise(r=>setTimeout(r,50));
assert.equal(vm.runInContext('window.__dlNav',context),'https://homepi.test.ts.net/download/test/ep101?filename=Dummy%20series%20-%20S01E01%20-%20Pilot.mp4');
await episodeRows()[0].onclick();assert.equal(get('video').src,'https://homepi.test.ts.net/media/test/ep101');assert.equal(get('playing').textContent,'Dummy series S1E1 — Pilot');
vm.runInContext('stopVideo()',context);
console.log('PASS download links: episode rows with Jellyfin names, HEAD probe navigation, row tap still plays');

// --- Server downloads: button states, polling, Downloads tab, fallback ---
window.__rigatoniClearProvider();
get('search').value='';
context.AbortSignal=AbortSignal;
let dlJob={job_id:'job1',kind:'movie',stream_id:'1',filename:'Dune (2021).mp4',status:'queued',bytes:0,total_bytes:100,error:null};
let dlPosts=[];
context.fetch=async(url,options)=>{
  const u=new URL(url);
  if(u.pathname==='/api/downloads/dl-session'){
    if(options?.method==='POST'){dlPosts.push(JSON.parse(options.body));return new Response(JSON.stringify({job_id:'job1',status:'queued',filename:'Dune (2021).mp4'}),{status:202,headers:{'content-type':'application/json'}})}
    return new Response(JSON.stringify({jobs:[dlJob]}),{headers:{'content-type':'application/json'}});
  }
  return new Response(JSON.stringify({categories:[],movies:[
    {stream_id:1,name:'Dune (2021)',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
    {stream_id:4,name:'Dune (1984)',kind:'movie',category_id:'1',container_extension:'mp4',stream_icon:''},
  ],streams:{1:'/media/movie-session/resource1',4:'/media/movie-session/resource4'}}),{headers:{'content-type':'application/json'}});
};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'};moviesPath='https://homepi.test.ts.net/api/movies/movie-session';downloadsPath='https://homepi.test.ts.net/api/downloads/dl-session';usOnly=false;gatewayDownloads=true;gatewayServerDownloads=true;showTab('movies')",context);
await vm.runInContext('loadMovies()',context);
assert.equal(cards().length,2);
const serverBtn=dlOf(cards()[0]);
assert.ok(serverBtn);
assert.equal(serverBtn.tag,'button');
assert.equal(serverBtn.textContent,'⬇');
serverBtn.onclick({preventDefault(){},stopPropagation(){}});
await new Promise(r=>setTimeout(r,50));
assert.equal(dlPosts.length,1);
assert.deepEqual(dlPosts[0],{kind:'movie',stream_id:'1',container_extension:'mp4',filename:'Dune (2021).mp4'});
assert.equal(serverBtn.textContent,'…');
dlJob={...dlJob,status:'downloading',bytes:50};
await vm.runInContext('pollServerDownloads()',context);
assert.equal(serverBtn.textContent,'50%');
dlJob={...dlJob,status:'done',bytes:100};
await vm.runInContext('pollServerDownloads()',context);
assert.equal(serverBtn.textContent,'✓');
assert.equal(serverBtn.title,'Saved to Jellyfin');
vm.runInContext("showTab('downloads')",context);
const dlRows=()=>descendants(get('rows')).filter(n=>n.className==='download-row');
assert.equal(dlRows().length,1);
assert.equal(dlRows()[0].children[0].textContent,'Dune (2021).mp4');
assert.equal(dlRows()[0].children[1].textContent,'✓ Saved to Jellyfin');
vm.runInContext("gatewayServerDownloads=false;render()",context);
assert.match(errText(),/latest Pi gateway/);
vm.runInContext("gatewayServerDownloads=true;showTab('movies')",context);
assert.equal(dlOf(cards()[0]).tag,'button');
vm.runInContext("gatewayServerDownloads=false;render()",context);
assert.equal(dlOf(cards()[0]).tag,'a');
assert.equal(dlOf(cards()[0]).href,'https://homepi.test.ts.net/download/movie-session/resource1?filename=Dune%20(2021).mp4');
vm.runInContext('stopDownloadsPolling()',context);
console.log('PASS server downloads: movie tile button states, polling progress, Downloads tab, old-gateway notice and Phase 1 fallback');

// --- Server downloads: episode rows post to the Pi with show/season ---
window.__rigatoniClearProvider();
get('search').value='';
let epJob={job_id:'job2',kind:'episode',stream_id:'101',filename:'Dummy series - S01E01 - Pilot.mp4',status:'queued',bytes:0,total_bytes:10,error:null};
let epPosts=[];
context.fetch=async(url,options)=>{
  const u=new URL(url);
  if(u.pathname==='/api/downloads/dl-session'){
    if(options?.method==='POST'){epPosts.push(JSON.parse(options.body));return new Response(JSON.stringify({job_id:'job2',status:'queued',filename:'Dummy series - S01E01 - Pilot.mp4'}),{status:202,headers:{'content-type':'application/json'}})}
    return new Response(JSON.stringify({jobs:[epJob]}),{headers:{'content-type':'application/json'}});
  }
  if(u.pathname.endsWith('/info'))return new Response(JSON.stringify({info:{name:'Dummy series',cover:'/media/test/cover',plot:'A test plot.',cast:'Actor One',genre:'Drama',releaseDate:'2024-01-01',rating:'8.5'},seasons:[{season_number:1,episode_count:2,name:'Season 1'}],episodes:{'1':[{id:101,episode_num:1,title:'Pilot',container_extension:'mp4',season:1,stream_icon:'/media/test/ep101',plot:'Pilot plot.'},{id:102,episode_num:2,title:'Second',container_extension:'mkv',season:1}]},streams:{101:'/media/test/ep101',102:'/media/test/ep102'}}),{headers:{'content-type':'application/json'}});
  return new Response(JSON.stringify({categories:[],series:[{stream_id:5,series_id:5,kind:'series',name:'Dummy series',category_id:'9',stream_icon:'/media/test/cover',rating:'8.5'}]}),{headers:{'content-type':'application/json'}});
};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={7:'https://homepi.test.ts.net/media/session/resource'};seriesPath='https://homepi.test.ts.net/api/series/series-session';downloadsPath='https://homepi.test.ts.net/api/downloads/dl-session';gatewayDownloads=true;gatewayServerDownloads=true;showTab('series')",context);
await vm.runInContext('loadSeries()',context);
await cards()[0].onclick();
assert.equal(episodeRows().length,2);
const epBtn=episodeRows()[0].children.find(n=>n.className==='dl');
assert.ok(epBtn);
assert.equal(epBtn.tag,'button');
epBtn.onclick({preventDefault(){},stopPropagation(){}});
await new Promise(r=>setTimeout(r,50));
assert.equal(epPosts.length,1);
assert.deepEqual(epPosts[0],{kind:'episode',stream_id:'101',container_extension:'mp4',filename:'Dummy series - S01E01 - Pilot.mp4',show:'Dummy series',season:'1'});
epJob={...epJob,status:'done',bytes:10};
await vm.runInContext('pollServerDownloads()',context);
assert.equal(epBtn.textContent,'✓');
vm.runInContext("showTab('downloads')",context);
assert.equal(dlRows().length,1);
assert.equal(dlRows()[0].children[0].textContent,'Dummy series - S01E01 - Pilot.mp4');
vm.runInContext('stopDownloadsPolling()',context);
console.log('PASS server downloads: episode rows post show/season to the Pi and finish in the Downloads tab');

// Leave no polling timer behind so the process can exit.
vm.runInContext("tab='movies';downloadsPath=null;stopDownloadsPolling()",context);
