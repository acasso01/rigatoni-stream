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
