/* Ant Streams — channel title cleaner.
   Port of NameCleaner.clean() from ios/RigatoniStream/CatalogPresentation.swift so the
   web player shows "Tubi" for "US| TUBI RAW 60fps", like the iPhone and Apple TV apps.
   Classic script: attaches globalThis.AntTitles (no build step, loads in Node tests too). */
(function(root){
'use strict';
const QUALITY=new Set(['RAW','HD','FHD','UHD','SD','HQ','HDR','HDR10','HEVC','H265','H264','X265','X264','AVC','4K','8K','2160P','1080P','720P','480P','60FPS','50FPS','30FPS','25FPS','24FPS','120FPS','SHD','FPS']);
const GROUPS=['AT&T','SPECTRUM','XFINITY','DIRECTV','DISH','VERIZON','FIOS','COX','OPTIMUM','FRONTIER','MEDIACOM'];
const BRANDS={'AT&T':'AT&T','A&E':'A&E',ESPN:'ESPN',HBO:'HBO',BBC:'BBC',CNN:'CNN',NBC:'NBC',CBS:'CBS',ABC:'ABC',AMC:'AMC',TNT:'TNT',TBS:'TBS',FX:'FX',MTV:'MTV',VH1:'VH1',NFL:'NFL',NBA:'NBA',MLB:'MLB',NHL:'NHL',TLC:'TLC',HGTV:'HGTV',SYFY:'Syfy',STARZ:'Starz',PBS:'PBS',BET:'BET',IFC:'IFC',TCM:'TCM',FS1:'FS1',FS2:'FS2',CNBC:'CNBC',MSNBC:'MSNBC',HLN:'HLN',USA:'USA',CW:'CW',QVC:'QVC',HSN:'HSN',TV:'TV',US:'US','E!':'E!',HBOMAX:'HBO Max',NETFLIX:'Netflix',TUBI:'Tubi',PEACOCK:'Peacock',DISNEY:'Disney',HULU:'Hulu',PRIME:'Prime',SPECTRUM:'Spectrum',XFINITY:'Xfinity',ROKU:'Roku',PLUTO:'Pluto',YOUTUBE:'YouTube',PARAMOUNT:'Paramount',SHOWTIME:'Showtime',FREEFORM:'Freeform',HALLMARK:'Hallmark',LIFETIME:'Lifetime',HISTORY:'History',NATGEO:'Nat Geo',DAZN:'DAZN',PPV:'PPV',SKY:'Sky',ITV:'ITV',SUNDANCE:'Sundance',BRAVO:'Bravo',OXYGEN:'Oxygen',CARTOON:'Cartoon',NICK:'Nick',NICKELODEON:'Nickelodeon',COMEDY:'Comedy',FOOD:'Food',DISCOVERY:'Discovery',ANIMAL:'Animal',SCIENCE:'Science',APPLE:'Apple',MAX:'Max',DIRECTV:'DirecTV',FIOS:'Fios',COX:'Cox',OPTIMUM:'Optimum',FRONTIER:'Frontier','365BLK':'365BLK'};
// CategoryRegion.separatedCodes
const REGION_CODES=['ENGLISH','CANADA','MEXICO','BRAZIL','BRASIL','ARGENTINA','LATINO','LATINA','LATAM','SPANISH','FRENCH','GERMAN','ITALIAN','PORTUGUESE','ARABIC','U.S.A.','U.S.','USA','ENG','UK','GB','CA','CAN','MX','AR','BR','DE','FR','ES','IT','PT','NL','AU','NZ','IN','PK','TR','RU','PL','RO','SE','NO','DK','FI','JP','KR','CN','ZA','IE','BE','CH','AT','HU','CZ','SK','UA','IL','SA','AE','PH','VN','TH','MY','SG','HK','TW','CO','CL','PE','QC','GR','EN','US'];
const FOLDED={};
'ᴬA ᴮB ᴰD ᴱE ᴳG ᴴH ᴵI ᴶJ ᴷK ᴸL ᴹM ᴺN ᴼO ᴾP ᴿR ᵀT ᵁU ᵂW ᴀA ʙB ᴄC ᴅD ᴇE ꜰF ɢG ʜH ɪI ᴊJ ᴋK ʟL ᴍM ɴN ᴏO ᴘP ʀR ꜱS ᴛT ᴜU ᴠV ᴡW ʏY ᴢZ ⁰0 ¹1 ²2 ³3 ⁴4 ⁵5 ⁶6 ⁷7 ⁸8 ⁹9'.split(' ').forEach(p=>{const c=[...p];FOLDED[c[0]]=c[1]});
const escape=s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
const regexCache=new Map();
function separatedRegex(codes){
  const key=codes.join('\n');if(regexCache.has(key))return regexCache.get(key);
  const alt=[...codes].sort((a,b)=>b.length-a.length).map(escape).join('|');
  const re=new RegExp('(?:^|(?<=[|·]))\\s*(?:[\\[\\(]\\s*(?:'+alt+')\\s*[\\]\\)]\\s*|(?:'+alt+')\\s*[:|/\\\\\\-]+\\s*)','giu');
  regexCache.set(key,re);return re;
}
function fold(raw){
  let out='';
  for(const ch of String(raw??'')){
    if(FOLDED[ch]){out+=FOLDED[ch];continue}
    const code=ch.codePointAt(0);
    if(code>=0xFF01&&code<=0xFF5E){out+=String.fromCodePoint(code-0xFEE0);continue}
    if(code===0x3000){out+=' ';continue}
    out+=ch;
  }
  return out.replace(/\u00A0/g,' ');
}
function hasSeparatedTag(name,codes){const re=separatedRegex(codes);re.lastIndex=0;return re.test(name)}
function stripRegionPrefixes(text){
  const re=separatedRegex(REGION_CODES);let value=text;
  for(let i=0;i<4;i++){re.lastIndex=0;const next=value.replace(re,'');if(next===value)break;value=next.trim()}
  return value;
}
function unwrapBanner(text){
  const m=text.match(/^[\s#*=\-_~·.•|]+(.+?)[\s#*=\-_~·.•|]+$/u);
  if(!m)return text;const core=m[1].trim();
  if(!core||/[#*=]/.test(core))return text;return core;
}
function stripGroupPrefix(text){
  const m=text.match(new RegExp('^(?:'+GROUPS.map(escape).join('|')+')\\s*[:|]\\s+(.+)$','iu'));
  if(!m)return text;const rest=m[1].trim();return rest||text;
}
const isQuality=t=>QUALITY.has(t.toUpperCase().replace(/[^\p{L}\p{N}]/gu,''));
const isFrameRate=t=>['24','25','30','50','60','120'].includes(t);
function stripQuality(text){
  let value=text.replace(/\(([^)]*)\)/g,(m,inner)=>{const parts=inner.split(/[ /]/).filter(Boolean);return parts.length&&parts.every(isQuality)?' ':m});
  const tokens=value.split(' ').filter(Boolean),kept=[];
  for(let i=0;i<tokens.length;i++){
    const t=tokens[i];
    if(t.toUpperCase()==='FULL'&&i+1<tokens.length&&isQuality(tokens[i+1])){i++;continue}
    if(isFrameRate(t)&&i+1<tokens.length&&tokens[i+1].toUpperCase()==='FPS'){i++;continue}
    const parts=t.split('/').filter(Boolean);
    if(parts.length>1){const remain=parts.filter(p=>!isQuality(p));if(!remain.length)continue;if(remain.length!==parts.length){kept.push(remain.join(' '));continue}}
    if(isQuality(t))continue;
    kept.push(t);
  }
  return kept.join(' ');
}
function collapse(text){
  return text.replace(/·/g,' · ').replace(/^[\s|:\-]+|[\s|:\-]+$/g,'').split(/\s+/).filter(Boolean).join(' ');
}
function titleCase(text){
  return text.split(' ').filter(Boolean).map(word=>{
    const key=word.toUpperCase();
    if(BRANDS[key])return BRANDS[key];
    if(/\p{N}/u.test(word)&&!word.includes('-'))return key;
    return word.split('-').map(piece=>{
      if(piece&&/^\p{N}+$/u.test(piece))return piece;
      if(BRANDS[piece.toUpperCase()])return BRANDS[piece.toUpperCase()];
      return piece.split("'").map(a=>a?a[0].toUpperCase()+a.slice(1).toLowerCase():'').join("'");
    }).join('-');
  }).join(' ');
}
function clean(raw){
  const folded=fold(raw).trim();
  if(!folded)return String(raw??'').trim();
  let text=unwrapBanner(folded);
  text=stripRegionPrefixes(text);
  text=stripGroupPrefix(text);
  text=stripQuality(text);
  text=collapse(text);
  if(!/[\p{L}\p{N}]/u.test(text)){const fb=titleCase(collapse(unwrapBanner(folded)));return fb||folded}
  return titleCase(text);
}
// ShelfRanking.normalize: used to match TMDB trending titles to catalog items.
function normalize(name){
  let t=String(name??'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim();
  return t.replace(/ (?:19|20)\d{2}$/,'').trim();
}
const api={clean,fold,normalize,stripQuality,stripRegionPrefixes,hasSeparatedTag};
root.AntTitles=api;
if(typeof module==='object'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:window);
