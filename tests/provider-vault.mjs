import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../xtream.html',import.meta.url),'utf8');
const scripts=[...html.matchAll(/<script(?: type="module")?>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
async function setup({saved=null,protocol='https:',port='',failure=0,gatewayResponse=null,gateway='',metadataFailure=false}={}){
 const elements=new Map(); const element=id=>{if(!elements.has(id))elements.set(id,{value:'',textContent:'',disabled:false,classList:{add(){},remove(){},toggle(){}},pause(){},load(){},removeAttribute(){},replaceChildren(){},scrollIntoView(){},requestSubmit(){throw Error('Unexpected automatic connection')}});return elements.get(id)};
 const writes=[]; const document={getElementById:element,querySelectorAll:()=>[]};
 const window={scrollTo(){}}; const location={protocol,port,assign(){}};
 const storage={getItem:()=>null,setItem:(...args)=>writes.push(args)};
 vm.runInNewContext(scripts[0],{document,window,location,localStorage:storage,URL,Set,setTimeout,clearTimeout,confirm:()=>true,fetch:()=>{throw Error('Unexpected provider request')}});
 const requests=[]; const fetch=async(url,options)=>{requests.push({url,...options});if(url.endsWith('/api/connect'))return{ok:true,json:async()=>gatewayResponse};if(failure)return{ok:false,status:failure,json:async()=>({error:'vault_failure'})};if(options.method==='POST'){const b=JSON.parse(options.body);saved={saved:true,...b};return{ok:true,json:async()=>({saved:true})}}if(options.method==='DELETE'){saved=null;return{ok:true,json:async()=>({deleted:true})}}return{ok:true,json:async()=>saved||{saved:false}}};
 const session={access_token:'test-session',user:{id:'test-user',email:'test@example.invalid'}};
 const metadataWrites=[];const client={auth:{getSession:async()=>({data:{session}}),getUser:async()=>({data:{user:{user_metadata:{rigatoni_gateway_url:gateway}}}}),updateUser:async arg=>{metadataWrites.push(arg);return{error:metadataFailure?Error('metadata failed'):null}}},from:()=>({select:async()=>({data:[]})})};
 await new AsyncFunction('document','window','location','localStorage','URL','createClient','SUPABASE_URL','SUPABASE_ANON_KEY','fetch','confirm',scripts[1].replace(/^import .*;$/gm,''))(document,window,location,storage,URL,()=>client,'https://vault.example.invalid','public-key',fetch,()=>true);
 return{element,window,requests,writes,metadataWrites};
}
const a=await setup();a.element('server').value='http://provider.example.invalid:8080/';a.element('user').value='test-user';a.element('pass').value='dummy-test-password';a.element('gateway').value='https://homepi.test.ts.net:8443/';await a.element('saveProvider').onclick();assert.equal(JSON.parse(a.requests.at(-1).body).server_url,'http://provider.example.invalid:8080');assert.match(a.element('acctStatus').textContent,/saved securely/i);assert.equal(a.requests.length,2);assert.ok(a.requests.every(r=>r.cache==='no-store'));
const b=await setup({saved:{saved:true,server_url:'http://provider.example.invalid:8080',username:'test-user',password:'dummy-test-password'},gateway:'https://homepi.test.ts.net:8443'});assert.equal(b.element('pass').value,'dummy-test-password');assert.equal(b.element('gateway').value,'https://homepi.test.ts.net:8443');assert.match(b.element('status').textContent,/HTTPS gateway/);assert.equal(b.requests.length,1);await b.element('deleteProvider').onclick();assert.equal(b.element('pass').value,'');assert.match(b.element('acctStatus').textContent,/deleted/);assert.equal(b.element('gateway').value,'');assert.equal(b.metadataWrites.at(-1).data.rigatoni_gateway_url,null);
const c=await setup({failure:404});assert.match(c.element('acctStatus').textContent,/unavailable/);c.element('server').value='https://provider.example.invalid';c.element('user').value='x';c.element('pass').value='x';await c.element('saveProvider').onclick();assert.match(c.element('acctStatus').textContent,/Could not save/);
const d=await setup({protocol:'http:',port:'8090',saved:{saved:true,server_url:'http://provider.example.invalid',username:'x',password:'x'}});assert.match(d.element('status').textContent,/Choose Connect/);
assert.ok([...a.writes,...b.writes].every(([key,value])=>key==='rigatoni-favorites'&&!value.includes('dummy-test-password')));
console.log('PASS save without connecting, HTTP reload without provider request, delete clears form, vault 404 reports failure, Pi mode, no credential storage');

const g=await setup({gatewayResponse:{categories:[],channels:[],streams:{7:'/media/dummy-session/dummy-resource'}}});g.element('gateway').value='https://homepi.test.ts.net:8443';const reply=await g.window.__rigatoniGatewayConnect();assert.equal(reply.streams[7],'https://homepi.test.ts.net:8443/media/dummy-session/dummy-resource');assert.equal(g.requests.at(-1).headers.Authorization,'Bearer test-session');assert.equal(g.requests.at(-1).body,undefined);g.element('gateway').value='https://untrusted.example.invalid';await assert.rejects(()=>g.window.__rigatoniGatewayConnect(),/HTTPS Tailscale gateway/);
console.log('PASS gateway client sends only account token, validates private HTTPS host and rewrites opaque playback paths');

assert.deepEqual(a.metadataWrites.at(-1),{data:{rigatoni_gateway_url:'https://homepi.test.ts.net:8443'}});assert.ok(!JSON.stringify(a.metadataWrites).includes('dummy-test-password'));
const failed=await setup({metadataFailure:true});failed.element('server').value='http://provider.example.invalid';failed.element('user').value='dummy';failed.element('pass').value='dummy';await failed.element('saveProvider').onclick();assert.match(failed.element('acctStatus').textContent,/gateway settings could not be saved/);
console.log('PASS account gateway save/reload/delete, validation, metadata failure reporting and credential-free preferences');

const convenience=await setup();
convenience.element('server').value='http://provider.example.invalid';convenience.element('user').value='dummy';convenience.element('pass').value='dummy-test-password';convenience.element('gateway').value='https://homepi.test.ts.net:8443/';
await convenience.window.__rigatoniSaveSettings();
const persisted=JSON.parse(convenience.requests.at(-1).body);
const restored=await setup({saved:{saved:true,...persisted},gateway:convenience.metadataWrites.at(-1).data.rigatoni_gateway_url});
assert.equal(restored.element('server').value,persisted.server_url);assert.equal(restored.element('user').value,persisted.username);assert.equal(restored.element('pass').value,persisted.password);assert.equal(restored.element('gateway').value,'https://homepi.test.ts.net:8443');assert.equal(restored.requests.length,1);
restored.element('gateway').value='https://homepi.other.ts.net:8443/';await restored.element('gateway').onchange();assert.equal(restored.metadataWrites.at(-1).data.rigatoni_gateway_url,'https://homepi.other.ts.net:8443');assert.equal(restored.requests.length,1);
restored.element('gateway').value='http://unsafe.example.invalid';await restored.element('gateway').onchange();assert.equal(restored.metadataWrites.length,1);assert.match(restored.element('acctStatus').textContent,/Could not save gateway/);
assert.ok(html.indexOf('await window.__rigatoniSaveSettings()')<html.indexOf('await window.__rigatoniGatewayConnect()'));
assert.ok(!html.includes("channels=streams;$('pass').value='';"));
console.log('PASS connect saves settings first, complete account restore without connecting, automatic gateway save and invalid gateway rejection');
