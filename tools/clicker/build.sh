#!/bin/sh
# Rebuilds BHTwitter.bundle/Clicker/ios-import.js. Needs Node.
set -e
cd "$(dirname "$0")"
[ -d node_modules/esbuild ] || npm install --no-audit --no-fund
node build.mjs
