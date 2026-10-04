#!/usr/bin/env node
// tools/unzip.mjs
// 选择性解压：只取出需要的条目，跳过视频/构建产物等大文件。
//
// 用法：
//   node tools/unzip.mjs <zip> <目标目录> --include="a/**,b/**" --exclude="**/*.mp4" [--max-mb=5] [--dry]
//
// --include / --exclude 用逗号分隔多个 glob；** 匹配任意层级，* 不跨目录。

import fs from 'node:fs';
import path from 'node:path';
import { openZip, zipGlobMatch } from './lib/zip.mjs';

const argv = process.argv.slice(2);
const positional = argv.filter(a => !a.startsWith('--'));
const opt = name => {
  const hit = argv.find(a => a.startsWith('--' + name + '='));
  return hit ? hit.slice(name.length + 3) : null;
};
const DRY = argv.includes('--dry');
const maxMb = parseFloat(opt('max-mb') || '50');

const [zipPath, destRoot] = positional;
if (!zipPath || !destRoot) {
  console.error('用法: node tools/unzip.mjs <zip> <目标目录> --include="..." --exclude="..." [--max-mb=5] [--dry]');
  process.exit(1);
}

const includes = (opt('include') || '').split(',').map(s => s.trim()).filter(Boolean);
const excludes = (opt('exclude') || '').split(',').map(s => s.trim()).filter(Boolean);

const absZip = path.resolve(zipPath);
if (!fs.existsSync(absZip)) { console.error('找不到 zip: ' + zipPath); process.exit(1); }
const absDest = path.resolve(destRoot);

const z = openZip(absZip);
console.log('压缩包: ' + path.basename(absZip));
console.log('条目总数: ' + z.entries.length);

const picked = [];
const skipped = { notIncluded: 0, excluded: 0, tooBig: 0, dir: 0, unsafe: 0 };

for (const e of z.entries) {
  if (e.isDir) { skipped.dir++; continue; }
  const name = e.name;
  if (includes.length && !includes.some(g => zipGlobMatch(name, g))) { skipped.notIncluded++; continue; }
  if (excludes.some(g => zipGlobMatch(name, g))) { skipped.excluded++; continue; }
  if (e.uncompSize > maxMb * 1024 * 1024) { skipped.tooBig++; continue; }
  // 防目录穿越
  const rel = name.replace(/\\/g, '/');
  if (rel.split('/').includes('..') || /^[A-Za-z]:/.test(rel)) { skipped.unsafe++; continue; }
  picked.push(e);
}

const totalBytes = picked.reduce((a, e) => a + e.uncompSize, 0);
console.log('\n命中 ' + picked.length + ' 个条目, 解压后 ' + (totalBytes / 1024 / 1024).toFixed(2) + ' MB');
console.log('跳过: 未命中 ' + skipped.notIncluded + ', 排除 ' + skipped.excluded
  + ', 超过 ' + maxMb + 'MB ' + skipped.tooBig + ', 目录 ' + skipped.dir
  + (skipped.unsafe ? ', 路径不安全 ' + skipped.unsafe : ''));

console.log('\n前 40 个:');
for (const e of picked.slice(0, 40)) {
  console.log('  ' + (e.uncompSize / 1024).toFixed(1).padStart(9) + ' KB  ' + e.name);
}
if (picked.length > 40) console.log('  ... 其余 ' + (picked.length - 40) + ' 个');

if (DRY) { console.log('\n(--dry 模式，未写入)'); z.close(); process.exit(0); }

let ok = 0, fail = 0;
for (const e of picked) {
  const out = path.join(absDest, e.name);
  try {
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, z.read(e));
    ok++;
  } catch (err) {
    console.error('失败 ' + e.name + ': ' + err.message);
    fail++;
  }
}
z.close();
console.log('\n解压完成: 成功 ' + ok + ', 失败 ' + fail);
console.log('输出到: ' + absDest);
