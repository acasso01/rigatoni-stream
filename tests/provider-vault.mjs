import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../xtream.html',import.meta.url),'utf8');
const scripts=[...html.matchAll(/<script(?: type="module")?>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const makeEl=()=>({value:'',textContent:'',disabled:false,type:'',className:'',children:[],classList:{add(){},remove(){},toggle(){}},style:{},append(...kids){this.children.push(...kids)},replaceChildren(){this.children=[]},setAttribute(){},addEventListener(){},onclick:null,onchange:null,pause(){},load(){},removeAttribute(){},scrollIntoView(){},requestSubmit(){throw Error('Unexpected automatic connection')}});
async function setup({saved=null,providers=null,protocol='https:',port='',failure=0,gatewayResponse=null,gateway='',metadataFailure=false,healthResponse={ok:true,multi_provider:true}}={}){
 const elements=new Map(); const element=id=>{if(!elements.has(id))elements.set(id,makeEl());return elements.get(id)};
 const writes=[]; const store=new Map();
 const storage={getItem:k=>store.has(k)?store.get(k):null,setItem:(k,v)=>{store.set(String(k),String(v));writes.push([k,v])},removeItem:k=>{store.delete(k)}};
 const document={getElementById:element,querySelectorAll:()=>[],querySelector:()=>null,createElement:()=>makeEl(),documentElement:{setAttribute(){},getAttribute:()=>'dark'}};
 const window={scrollTo(){}}; const location={protocol,port,assign(){}};
 const ctx={document,window,location,localStorage:storage,URL,Set,setTimeout,clearTimeout,confirm:()=>true,fetch:()=>{throw Error('Unexpected provider request')}};
 vm.runInNewContext(scripts[0],ctx);
 vm.runInNewContext(scripts[1],ctx);
 const requests=[]; const rows=new Map();
 if(Array.isArray(providers))for(const p of providers)rows.set(p.id,{...p});
 const fetch=async(url,options)=>{requests.push({url,...options});const u=String(url);
  if(u.endsWith('/health'))return{ok:true,json:async()=>healthResponse};
  if(u.endsWith('/api/connect'))return{ok:true,json:async()=>gatewayResponse};
  if(u.includes('/functions/v1/provider-vault')){
   if(failure)return{ok:false,status:failure,json:async()=>({error:'vault_failure'})};
   const idq=new URL(u).searchParams.get('id');
   if(options.method==='POST'){const b=JSON.parse(options.body);const id=b.id||('mock-id-'+(rows.size+1));rows.set(id,{id,...b});return{ok:true,json:async()=>({saved:true,id})}}
   if(options.method==='DELETE'){if(idq)rows.delete(idq);else rows.clear();if(saved&&typeof saved==='object')saved=null;return{ok:true,json:async()=>({deleted:true})}}
   if(idq){const row=rows.get(idq);return{ok:true,json:async()=>row?{saved:true,id:idq,label:row.label,server_url:row.server_url,username:row.username,password:row.password}:{saved:false}}}
   if(saved&&typeof saved==='object')return{ok:true,json:async()=>saved};
   return{ok:true,json:async()=>({providers:[...rows.values()].map(({password,...r})=>r)})};
  }
  throw Error('Unexpected fetch '+u)};
 const session={access_token:'test-session',user:{id:'test-user',email:'test@example.invalid'}};
 const metadataWrites=[];const client={auth:{getSession:async()=>({data:{session}}),getUser:async()=>({data:{user:{user_metadata:{rigatoni_gateway_url:gateway}}}}),updateUser:async arg=>{metadataWrites.push(arg);return{error:metadataFailure?Error('metadata failed'):null}}},from:()=>({select:async()=>({data:[]})})};
 await new AsyncFunction('document','window','location','localStorage','URL','createClient','SUPABASE_URL','SUPABASE_ANON_KEY','fetch','confirm',scripts[2].replace(/^import .*;$/gm,''))(document,window,location,storage,URL,()=>client,'https://vault.example.invalid','public-key',fetch,()=>true);
 return{element,window,requests,writes,metadataWrites,store};
}
const P1='11111111-1111-4111-8111-111111111111',P2='22222222-2222-4222-8222-222222222222';
const twoProviders=[{id:P1,label:'Alpha',server_url:'http://alpha.invalid',username:'u1',password:'p1'},{id:P2,label:'Beta',server_url:'http://beta.invalid',username:'u2',password:'p2'}];
const a=await setup();a.element('server').value='http://provider.example.invalid:8080/';a.element('user').value='test-user';a.element('pass').value='dummy-test-password';a.element('providerLabel').value='Home';a.element('gateway').value='https://homepi.test.ts.net:8443/';await a.element('saveProvider').onclick();const aPost=a.requests.find(r=>r.method==='POST'&&String(r.url).includes('provider-vault'));assert.equal(JSON.parse(aPost.body).server_url,'http://provider.example.invalid:8080');assert.equal(JSON.parse(aPost.body).label,'Home');assert.match(a.element('acctStatus').textContent,/saved securely/i);assert.equal(a.requests.length,3);assert.ok(a.requests.every(r=>r.cache==='no-store'));
const b=await setup({saved:{saved:true,server_url:'http://provider.example.invalid:8080',username:'test-user',password:'dummy-test-password'},gateway:'https://homepi.test.ts.net:8443'});assert.equal(b.element('pass').value,'dummy-test-password');assert.equal(b.element('gateway').value,'https://homepi.test.ts.net:8443');assert.match(b.element('status').textContent,/HTTPS gateway/);assert.equal(b.requests.length,1);await b.element('deleteProvider').onclick();assert.equal(b.element('pass').value,'');assert.match(b.element('acctStatus').textContent,/deleted/);assert.equal(b.element('gateway').value,'');assert.equal(b.metadataWrites.at(-1).data.rigatoni_gateway_url,null);
const c=await setup({failure:404});assert.match(c.element('acctStatus').textContent,/unavailable/);c.element('server').value='https://provider.example.invalid';c.element('user').value='x';c.element('pass').value='x';await c.element('saveProvider').onclick();assert.match(c.element('acctStatus').textContent,/Could not save/);
const d=await setup({protocol:'http:',port:'8090',saved:{saved:true,server_url:'http://provider.example.invalid',username:'x',password:'x'}});assert.match(d.element('status').textContent,/Choose Connect/);
assert.ok([...a.writes,...b.writes].every(([key,value])=>['rigatoni-favorites','ant-active-provider'].includes(key)&&!String(value).includes('dummy-test-password')));
console.log('PASS save without connecting, HTTP reload without provider request, delete clears form, vault 404 reports failure, Pi mode, no credential storage');

const g=await setup({gatewayResponse:{categories:[],channels:[],streams:{7:'/media/dummy-session/dummy-resource'}}});g.element('gateway').value='https://homepi.test.ts.net:8443';const reply=await g.window.__rigatoniGatewayConnect();assert.equal(reply.streams[7],'https://homepi.test.ts.net:8443/media/dummy-session/dummy-resource');assert.equal(g.requests.at(-1).headers.Authorization,'Bearer test-session');assert.equal(g.requests.at(-1).body,undefined);g.element('gateway').value='https://untrusted.example.invalid';await assert.rejects(()=>g.window.__rigatoniGatewayConnect(),/HTTPS Tailscale gateway/);
console.log('PASS gateway client sends only account token, validates private HTTPS host and rewrites opaque playback paths');

assert.deepEqual(a.metadataWrites.at(-1),{data:{rigatoni_gateway_url:'https://homepi.test.ts.net:8443'}});assert.ok(!JSON.stringify(a.metadataWrites).includes('dummy-test-password'));
const failed=await setup({metadataFailure:true});failed.element('server').value='http://provider.example.invalid';failed.element('user').value='dummy';failed.element('pass').value='dummy';await failed.element('saveProvider').onclick();assert.match(failed.element('acctStatus').textContent,/gateway settings could not be saved/);
console.log('PASS account gateway save/reload/delete, validation, metadata failure reporting and credential-free preferences');

const convenience=await setup();
convenience.element('server').value='http://provider.example.invalid';convenience.element('user').value='dummy';convenience.element('pass').value='dummy-test-password';convenience.element('gateway').value='https://homepi.test.ts.net:8443/';
await convenience.window.__rigatoniSaveSettings();
const persisted=JSON.parse(convenience.requests.find(r=>r.method==='POST'&&String(r.url).includes('provider-vault')).body);
const restored=await setup({saved:{saved:true,...persisted},gateway:convenience.metadataWrites.at(-1).data.rigatoni_gateway_url});
assert.equal(restored.element('server').value,persisted.server_url);assert.equal(restored.element('user').value,persisted.username);assert.equal(restored.element('pass').value,persisted.password);assert.equal(restored.element('gateway').value,'https://homepi.test.ts.net:8443');assert.equal(restored.requests.length,1);
restored.element('gateway').value='https://homepi.other.ts.net:8443/';await restored.element('gateway').onchange();assert.equal(restored.metadataWrites.at(-1).data.rigatoni_gateway_url,'https://homepi.other.ts.net:8443');assert.equal(restored.requests.length,1);
restored.element('gateway').value='http://unsafe.example.invalid';await restored.element('gateway').onchange();assert.equal(restored.metadataWrites.length,1);assert.match(restored.element('acctStatus').textContent,/Could not save gateway/);
assert.ok(html.indexOf('await window.__rigatoniSaveSettings()')<html.indexOf('await window.__rigatoniGatewayConnect()'));
assert.ok(!html.includes("channels=streams;$('pass').value='';"));
console.log('PASS connect saves settings first, complete account restore without connecting, automatic gateway save and invalid gateway rejection');

// Multi-provider: list renders, Use switches the active provider, Save carries the id, row Delete targets the id.
const mp=await setup({providers:twoProviders});
assert.equal(mp.element('user').value,'u1');
assert.equal(mp.element('providerLabel').value,'Alpha');
assert.equal(mp.element('providerList').children.length,2);
assert.equal(mp.store.get('ant-active-provider'),P1);
const betaRow=mp.element('providerList').children[1];
await betaRow.children[1].children[0].onclick();
assert.equal(mp.element('user').value,'u2');
assert.equal(mp.element('providerLabel').value,'Beta');
assert.equal(mp.store.get('ant-active-provider'),P2);
mp.element('pass').value='p2x';
await mp.element('saveProvider').onclick();
const mpPost=mp.requests.filter(r=>r.method==='POST'&&String(r.url).includes('provider-vault')).at(-1);
assert.equal(JSON.parse(mpPost.body).id,P2);
assert.equal(JSON.parse(mpPost.body).label,'Beta');
await betaRow.children[1].children[1].onclick();
const mpDel=mp.requests.filter(r=>r.method==='DELETE').at(-1);
assert.ok(String(mpDel.url).includes('id='+P2));
assert.equal(mp.element('providerList').children.length,1);
console.log('PASS multi-provider list render, Use switches active provider, Save carries provider id, row Delete targets the id');

// Multi-provider gateway: old gateway (no multi_provider flag) aborts; new gateway receives provider_id.
const mh=await setup({providers:twoProviders,healthResponse:{ok:true},gatewayResponse:{categories:[],channels:[],streams:{}}});
mh.element('gateway').value='https://homepi.test.ts.net:8443';
await assert.rejects(()=>mh.window.__rigatoniGatewayConnect(),/needs an update for multiple providers/);
assert.ok(!mh.requests.some(r=>String(r.url).endsWith('/api/connect')));
console.log('PASS gateway health gate aborts multi-provider connect on old gateway');
const mh2=await setup({providers:twoProviders,healthResponse:{ok:true,multi_provider:true},gatewayResponse:{categories:[],channels:[],streams:{7:'/media/x/y'}}});
mh2.element('gateway').value='https://homepi.test.ts.net:8443';
const mh2Reply=await mh2.window.__rigatoniGatewayConnect();
const mh2Post=mh2.requests.filter(r=>String(r.url).endsWith('/api/connect')).at(-1);
assert.equal(JSON.parse(mh2Post.body).provider_id,P1);
assert.equal(mh2Reply.streams[7],'https://homepi.test.ts.net:8443/media/x/y');
console.log('PASS gateway multi-provider connect sends provider_id on new gateway');
