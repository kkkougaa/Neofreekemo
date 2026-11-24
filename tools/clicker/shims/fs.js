'use strict';
/* In-memory stand-in for Node's fs, enough for characters.js, importer.js and parts.js.
   Paths are POSIX. Files hold Buffers; directories are implied by their entries. */
const files = new Map();
const dirs = new Set(['/']);

function norm(p) {
  const out = [];
  String(p).split('/').forEach((s) => {
    if (!s || s === '.') return;
    if (s === '..') out.pop();
    else out.push(s);
  });
  return '/' + out.join('/');
}
function parentOf(p) {
  const i = p.lastIndexOf('/');
  return i <= 0 ? '/' : p.slice(0, i);
}
function enoent(p) {
  const e = new Error('ENOENT: ' + p);
  e.code = 'ENOENT';
  return e;
}
function mkdirSync(p) {
  let cur = norm(p);
  const chain = [];
  while (cur !== '/' && !dirs.has(cur)) {
    chain.push(cur);
    cur = parentOf(cur);
  }
  chain.forEach((d) => dirs.add(d));
}
function existsSync(p) {
  const n = norm(p);
  return files.has(n) || dirs.has(n);
}
function toBuffer(data, enc) {
  if (Buffer.isBuffer(data)) return data;
  if (data instanceof Uint8Array) return Buffer.from(data);
  return Buffer.from(String(data), typeof enc === 'string' ? enc : 'utf8');
}
function writeFileSync(p, data, opt) {
  const n = norm(p);
  mkdirSync(parentOf(n));
  files.set(n, toBuffer(data, opt && opt.encoding ? opt.encoding : opt));
}
function readFileSync(p, opt) {
  const n = norm(p);
  if (!files.has(n)) throw enoent(n);
  const b = files.get(n);
  const enc = typeof opt === 'string' ? opt : opt && opt.encoding;
  return enc ? b.toString(enc) : b;
}
function readdirSync(p) {
  const n = norm(p);
  if (!dirs.has(n)) throw enoent(n);
  const pre = n === '/' ? '/' : n + '/';
  const names = new Set();
  files.forEach((v, k) => {
    if (k.startsWith(pre)) names.add(k.slice(pre.length).split('/')[0]);
  });
  dirs.forEach((k) => {
    if (k !== n && k.startsWith(pre)) names.add(k.slice(pre.length).split('/')[0]);
  });
  return Array.from(names).sort();
}
function statSync(p) {
  const n = norm(p);
  if (files.has(n)) {
    const b = files.get(n);
    return { size: b.length, mtimeMs: 0, isDirectory: () => false, isFile: () => true };
  }
  if (dirs.has(n)) return { size: 0, mtimeMs: 0, isDirectory: () => true, isFile: () => false };
  throw enoent(n);
}
function rmSync(p) {
  const n = norm(p);
  files.delete(n);
  const pre = n + '/';
  Array.from(files.keys()).forEach((k) => k.startsWith(pre) && files.delete(k));
  Array.from(dirs).forEach((k) => (k === n || k.startsWith(pre)) && dirs.delete(k));
}
function unlinkSync(p) {
  files.delete(norm(p));
}
function copyFileSync(a, b) {
  writeFileSync(b, readFileSync(a));
}
function renameSync(a, b) {
  const buf = readFileSync(a);
  unlinkSync(a);
  writeFileSync(b, buf);
}
function reset() {
  files.clear();
  dirs.clear();
  dirs.add('/');
}

module.exports = {
  mkdirSync,
  existsSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  statSync,
  rmSync,
  unlinkSync,
  copyFileSync,
  renameSync,
  promises: {},
  __reset: reset
};
