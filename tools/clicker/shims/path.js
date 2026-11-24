'use strict';
/* POSIX path, the parts the import modules use. */
function normalize(p) {
  const abs = String(p).startsWith('/');
  const out = [];
  String(p).split('/').forEach((s) => {
    if (!s || s === '.') return;
    if (s === '..') out.pop();
    else out.push(s);
  });
  return (abs ? '/' : '') + out.join('/');
}
function join(...parts) {
  return normalize(parts.filter((x) => x !== '' && x != null).join('/'));
}
function basename(p, ext) {
  let b = String(p).split('/').filter(Boolean).pop() || '';
  if (ext && b.endsWith(ext)) b = b.slice(0, -ext.length);
  return b;
}
function dirname(p) {
  const n = normalize(p);
  const i = n.lastIndexOf('/');
  return i <= 0 ? (n.startsWith('/') ? '/' : '.') : n.slice(0, i);
}
function extname(p) {
  const b = basename(p);
  const i = b.lastIndexOf('.');
  return i <= 0 ? '' : b.slice(i);
}
module.exports = { join, basename, dirname, extname, normalize, resolve: join, sep: '/' };
