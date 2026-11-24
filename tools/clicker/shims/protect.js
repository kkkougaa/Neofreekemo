'use strict';
/* Stand-in for protect.js. The .cvclk lock is opened beforehand (asynchronously, with
   WebCrypto, in entry.js) and the result handed over here, because importer.js asks for it
   synchronously. Pictures are never written anywhere outside this page's memory, so the
   desktop's per-PC "rest" lock has nothing to do: sealRest/openRest pass the bytes through. */
const KINDS = {
  clk: 'BCVCLK2\n',
  part: 'BCVPART1'
};
const opened = new WeakMap();

function kindOf(buf) {
  if (!Buffer.isBuffer(buf)) return null;
  for (const k of Object.keys(KINDS)) {
    const m = KINDS[k];
    if (buf.length > m.length + 4 && buf.toString('latin1', 0, m.length) === m) return k;
  }
  return null;
}
module.exports = {
  kindOf,
  isPacked: (b) => kindOf(b) === 'clk',
  isPartPacked: (b) => kindOf(b) === 'part',
  unpack(buf) {
    const u = opened.get(buf);
    if (!u) throw new Error('읽을 수 없는 파일입니다. 사이트에서 내보낸 .cvclk 가 맞는지 확인해 주세요.');
    return u;
  },
  __remember(buf, u) {
    opened.set(buf, u);
  },
  pack() {
    throw new Error('not available');
  },
  init() {},
  sealRest: (b) => b,
  openRest: (b) => b,
  mode: () => 'ios',
  status: () => ({ mode: 'ios' }),
  ownerOk: () => false
};
