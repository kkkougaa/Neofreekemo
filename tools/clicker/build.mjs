// Bundles entry.js (the desktop importer + shims) into the tweak bundle.
import * as esbuild from 'esbuild';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const shim = (n) => path.join(here, 'shims', n + '.js');
const map = { fs: shim('fs'), path: shim('path'), crypto: shim('crypto'), electron: shim('electron'), './protect': shim('protect') };

await esbuild.build({
  entryPoints: [path.join(here, 'entry.js')],
  outfile: path.join(here, '../../layout/Library/Application Support/BHT/BHTwitter.bundle/Clicker/ios-import.js'),
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'safari15',
  minify: true,
  legalComments: 'none',
  inject: [shim('buffer-inject')],
  plugins: [
    {
      name: 'node-shims',
      setup(build) {
        build.onResolve({ filter: /^(fs|path|crypto|electron|\.\/protect)$/ }, (args) => ({ path: map[args.path] }));
      }
    }
  ],
  logLevel: 'info'
});
