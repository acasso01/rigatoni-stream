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
const document={getElementById:get,querySelectorAll:()=>[],createElement:tag=>new Element(tag)};
const code=fs.readFileSync(new URL('../xtream.html',import.meta.url),'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
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
vm.runInContext("moviesLoaded=false;moviesPath=null;movieError='';moviesLoading=null;showTab('movies')",context);await vm.runInContext('loadMovies()',context);assert.match(get('rows').children[0].textContent,/Update the Pi/);assert.equal(vm.runInContext('moviesLoading',context),null);
window.__rigatoniClearProvider();assert.equal(vm.runInContext('movies.length',context),0);
console.log('PASS 50,000 movies: lazy load/cache, bounded cards, search, namespaced favorites, opaque MP4 playback, unavailable gateway retry and delete cleanup');

for(const [error,expected] of [['catalog_too_large',/item limit/],['response_too_large',/response-size limit/],['session_resource_limit',/resource limit/],['provider_connection_failed',/provider rejected/],['not_found',/Update the Pi/],['secret provider credentials must never be echoed',/could not load/]]){
 context.fetch=async()=>new Response(JSON.stringify({error}),{status:502});
 vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};moviesPath='https://homepi.test.ts.net/api/movies/test';moviesLoading=null;moviesLoaded=false;tab='movies'",context);
 await vm.runInContext('loadMovies()',context);
 assert.match(get('rows').children[0].textContent,expected);assert.match(get('rows').children[0].textContent,/HTTP 502/);assert.ok(!get('rows').children[0].textContent.includes('secret provider credentials'));assert.equal(vm.runInContext('moviesLoading',context),null);
}
console.log('PASS movie failure reasons distinguish limits, provider failures and outdated gateways without reflecting untrusted error strings');

window.__rigatoniClearProvider();
get('search').value='';
const categoryRequests=[];
context.fetch=async input=>{const url=new URL(input);categoryRequests.push(url.search);const category=url.searchParams.get('category_id');return new Response(JSON.stringify({browse_by_category:true,categories:[{category_id:'9',category_name:'Action'},{category_id:'10',category_name:'Drama'}],movies:category?[{stream_id:category,name:'Movie in '+category,container_extension:'mp4',category_id:category}]:[],streams:category?{[category]:'/media/test/resource'+category}:{},...(category?{category_id:category}:{})}))};
vm.runInContext("credentials={base:'https://provider.example.invalid',user:'dummy',pass:'dummy'};gatewayStreams={};moviesPath='https://homepi.test.ts.net/api/movies/test';tab='movies'",context);
await vm.runInContext('loadMovies()',context);assert.deepEqual(categoryRequests,['','?category_id=9']);assert.equal(cards().length,1);
const categorySelect=()=>get('rows').children.find(n=>n.tag==='select');assert.equal(categorySelect().value,'9');assert.equal(categorySelect().children.length,2);assert.ok(get('rows').children.some(n=>n.textContent.includes('selected category')));
categorySelect().value='10';categorySelect().onchange();await vm.runInContext('loadMovies()',context);assert.equal(categoryRequests.at(-1),'?category_id=10');assert.equal(cards()[0].children[1].textContent,'Movie in 10');await cards()[0].onclick();assert.equal(get('video').src,'https://homepi.test.ts.net/media/test/resource10');
window.__rigatoniClearProvider();assert.equal(vm.runInContext('movieCategoryMode',context),false);
console.log('PASS large-movie category fallback, automatic first category, selector switching, scoped search explanation, movie playback and reset');
