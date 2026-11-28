import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const ctx=vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../web/titles.js',import.meta.url),'utf8'),ctx);
const {clean,normalize}=ctx.AntTitles;
// Same samples as ios/RigatoniStreamTests/CatalogPresentationTests.swift testCleanNamesMatchProviderSamples
const samples=[
 ['US| TUBI RAW 60fps','Tubi'],['US| SPECTRUM NETWORK HD/RAW','Spectrum Network'],['AT&T: 365BLK RAW','365BLK'],
 ['US| NETFLIX ON AIR RAW 60fps','Netflix On Air'],['US| NETFLIX ON AIR RAW 60 FPS','Netflix On Air'],['##### AT&T #####','AT&T'],
 ['===== ESPN =====','ESPN'],['US| PEACOCK RAW','Peacock'],['US: HBO HD','HBO'],['(US) ESPN','ESPN'],['USA | CNN HD','CNN'],
 ['UK| BBC ONE FHD','BBC One'],['EN| DISNEY PLUS HD','Disney Plus'],['US| PRIME RAW','Prime'],['AT&T: 5-MINUTE CRAFTS RAW','5-Minute Crafts'],
 ['AT&T RAW','AT&T'],['USA Network','USA Network'],['US OPEN','US Open'],['Movie (1080p)','Movie'],['Channel (HD)','Channel'],
 ['The Batman (2022)','The Batman (2022)'],['News HEVC H.265','News'],['Sports 4K UHD','Sports'],['Doc ᴴᴰ','Doc'],['Clip ᴿᴬᵂ','Clip'],
 ['Feed ⁶⁰fps','Feed'],['IN| BOLLYWOOD HD','Bollywood'],['LATINO | NOVELAS FHD','Novelas'],['US| TV LAND HD','TV Land'],
 ['##### AT&T RAW #####','AT&T'],['XFINITY: USA NETWORK HD','USA Network'],['Home · US| TUBI RAW','Home · Tubi']
];
for(const [raw,expected] of samples)assert.equal(clean(raw),expected,raw);
assert.equal(clean(''),'');assert.equal(clean(null),'');assert.equal(clean('#####'),'#####');
assert.equal(clean('ＵＳ｜ＨＢＯ ＨＤ'),'HBO');
assert.equal(normalize('Dune: Part Two (2024)'),'dune part two');
assert.equal(normalize('Amélie 2001'),'amelie');
console.log('PASS titles.js clean() matches every iOS NameCleaner sample ('+samples.length+'), fullwidth folding, empty input and trending normalize');
