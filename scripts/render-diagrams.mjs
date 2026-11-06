import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Resvg } from '@resvg/resvg-js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fontDirectory = join(root, 'diagrams', 'fonts');
const fonts = ['NotoSans-Regular.ttf', 'NotoSans-Bold.ttf'].map(name =>
  join(fontDirectory, name)
);
for (const font of fonts) readFileSync(font);

export function renderDiagrams(directory, check = false) {
  const sources = readdirSync(directory).filter(name => name.endsWith('.svg')).sort();
  if (sources.length === 0) {
    throw new Error(`No SVG diagrams found in ${directory}`);
  }

  const stale = [];
  for (const name of sources) {
    const source = readFileSync(join(directory, name));
    const png = new Resvg(source, {
      font: {
        loadSystemFonts: false,
        fontFiles: fonts,
        defaultFontFamily: 'Noto Sans',
        sansSerifFamily: 'Noto Sans'
      }
    }).render().asPng();
    const destination = join(directory, name.replace(/\.svg$/, '.png'));
    if (check) {
      let existing;
      try {
        existing = readFileSync(destination);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      if (!existing || !existing.equals(png)) stale.push(name);
    } else {
      writeFileSync(destination, png);
    }
  }

  if (stale.length > 0) {
    throw new Error(`Missing or stale PNG exports: ${stale.join(', ')}. Run npm run diagrams.`);
  }
  return sources.length;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arguments_ = process.argv.slice(2);
  if (arguments_.some(argument => argument !== '--check') || arguments_.length > 1) {
    throw new Error('Usage: node scripts/render-diagrams.mjs [--check]');
  }
  const check = arguments_.includes('--check');
  const count = renderDiagrams(join(root, 'diagrams'), check);
  console.log(`${check ? 'Verified' : 'Rendered'} ${count} diagram exports.`);
}
