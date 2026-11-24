'use strict';
module.exports = {
  randomBytes(n) {
    const b = Buffer.alloc(n);
    globalThis.crypto.getRandomValues(b);
    return b;
  }
};
