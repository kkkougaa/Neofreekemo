'use strict';
/* window.ClickerImport — reads a BUG Clicker .cvclk inside the X character page.

   The desktop app's own importer.js, parts.js and characters.js (1.19.7, in upstream/) do
   the work, unchanged, on an in-memory file system (shims/fs.js). Only two things differ
   from the desktop:
     · the .cvclk lock (HKDF-SHA256 + AES-256-GCM over a gzip of the JSON, protect.js
       unpack()) is opened here with WebCrypto, before importer.js asks for it;
     · nothing is written to disk. The page keeps the imported characters in memory and
       the app keeps only the original, still locked, file.
   The "locked" flag in the file header (no re-export) is kept on the character as the
   desktop keeps it; this port has no export at all.

   Built into BHTwitter.bundle/Clicker/ios-import.js by build.sh. */

const fs = require('fs');
const protect = require('./shims/protect');
const importer = require('./upstream/importer');
const { Characters } = require('./upstream/characters');

/* protect.js TRANSPORT key and KINDS info strings */
const TRANSPORT = Buffer.from('73ca62079026ebb61663058e0d16e32be688bc36a8677299b75251a27d6ea2ba', 'hex');
const INFO = { clk: 'cvclk-v2', part: 'cvpart-v1' };
const MAX_FILE = 200 * 1024 * 1024;
const BAD = '읽을 수 없는 파일입니다. 사이트에서 내보낸 .cvclk 가 맞는지 확인해 주세요.';

async function gunzip(bytes) {
  if (typeof DecompressionStream !== 'function') throw new Error('이 iOS 에서는 압축을 풀 수 없습니다 (iOS 16.4 이상 필요).');
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
  return Buffer.from(await new Response(stream).arrayBuffer());
}

/* protect.js unpack(), asynchronous */
async function unpack(buf) {
  const kind = protect.kindOf(buf) || 'clk';
  const magicLen = kind === 'part' ? 8 : 8;
  let o = magicLen;
  const hl = buf.readUInt32BE(o);
  o += 4;
  if (hl > 4096) throw new Error(BAD);
  const header = buf.subarray(o, o + hl);
  o += hl;
  const salt = buf.subarray(o, o + 16);
  o += 16;
  const body = buf.subarray(o);
  const subtle = globalThis.crypto && globalThis.crypto.subtle;
  if (!subtle) throw new Error('이 화면에서는 암호 풀기를 쓸 수 없습니다.');
  let plain;
  try {
    const ikm = await subtle.importKey('raw', TRANSPORT, 'HKDF', false, ['deriveBits']);
    const bits = await subtle.deriveBits(
      { name: 'HKDF', hash: 'SHA-256', salt, info: Buffer.from(INFO[kind]) },
      ikm,
      256
    );
    const key = await subtle.importKey('raw', bits, 'AES-GCM', false, ['decrypt']);
    /* protect.js lays it out iv(12) · tag(16) · ciphertext; WebCrypto wants ciphertext · tag */
    const iv = body.subarray(0, 12);
    const tag = body.subarray(12, 28);
    const sealed = Buffer.concat([body.subarray(28), tag]);
    const gz = await subtle.decrypt({ name: 'AES-GCM', iv, additionalData: header, tagLength: 128 }, key, sealed);
    plain = await gunzip(new Uint8Array(gz));
  } catch (e) {
    if (e && /iOS/.test(e.message)) throw e;
    throw new Error(BAD);
  }
  return { kind, header: JSON.parse(header.toString('utf8')), text: plain.toString('utf8') };
}

/* One file → its characters, resolved the way main.js petPayload() resolves them. */
async function load(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(String(input || ''), 'base64');
  if (!buf.length || buf.length > MAX_FILE) throw new Error(BAD);
  if (protect.isPartPacked(buf)) throw new Error('파츠만 담긴 파일(.cvpart)입니다. 캐릭터 파일(.cvclk)을 골라 주세요.');
  let header = null;
  if (protect.isPacked(buf)) {
    const u = await unpack(buf);
    header = u.header;
    protect.__remember(buf, u);
  }
  fs.__reset();
  fs.writeFileSync('/in/file.cvclk', buf);
  const chars = new Characters('/data', '/none');
  const result = await importer.importFile('/in/file.cvclk', chars, () => Promise.reject(new Error('offline')), {});
  if (!result.added.length) {
    const why = result.skipped && result.skipped[0] ? result.skipped[0].reason : '';
    throw new Error(why || '파일에 캐릭터가 들어 있지 않습니다.');
  }
  /* The virtual disk is reused by the next file; keep what this one needs in memory. */
  const keep = new Map();
  const ids = result.added.slice();
  const snapshot = (id) => {
    if (!keep.has(id)) keep.set(id, new Map());
    return keep.get(id);
  };
  ids.forEach((id) => {
    const dir = '/data/characters/' + id;
    const m = snapshot(id);
    fs.readdirSync(dir).forEach((name) => m.set(name, fs.readFileSync(dir + '/' + name)));
  });
  const restore = (id) => {
    fs.__reset();
    const m = keep.get(id);
    if (!m) return null;
    m.forEach((b, name) => fs.writeFileSync('/data/characters/' + id + '/' + name, b));
    return new Characters('/data', '/none');
  };
  const names = ids.map((id) => chars.read(id).name || id);
  return {
    ids,
    names,
    locked: !!(header && header.locked),
    missing: result.missing || 0,
    resolve(index, side) {
      const id = ids[Math.max(0, Math.min(ids.length - 1, index | 0))];
      const c = restore(id);
      if (!c) return null;
      const s = Math.max(48, Math.round(side || 160));
      return c.resolve(id, s, Math.min(2048, 2 * s));
    },
    lineSoundUrl(id, name) {
      const c = restore(id);
      return c && c.lineSoundUrl ? c.lineSoundUrl(id, name) || '' : '';
    }
  };
}

/* The built-in character comes from the app as character.json plus <slot>Url data URLs.
   characters.js read() fills in the desktop defaults (petting, breathing, bubble style...)
   the file leaves out; the pictures stay as given. */
function normalizeBuiltIn(c) {
  if (!c || typeof c !== 'object') return c;
  const raw = {};
  Object.keys(c).forEach((k) => {
    if (!/Url$/.test(k) && k !== 'id') raw[k] = c[k];
  });
  if (Array.isArray(c.rig)) raw.rig = c.rig.map((r) => Object.assign({}, r, { url: undefined }));
  fs.__reset();
  fs.writeFileSync('/data/characters/default/character.json', JSON.stringify(raw));
  const n = new Characters('/data', '/none').read('default');
  const out = Object.assign({}, n, { id: c.id || 'default' });
  Object.keys(c).forEach((k) => {
    if (/Url$/.test(k)) out[k] = c[k];
  });
  out.rig = (n.rig || []).map((r, i) => Object.assign({}, r, { url: (c.rig && c.rig[i] && c.rig[i].url) || '' }));
  return out;
}

globalThis.ClickerImport = { load, unpack, normalizeBuiltIn };
