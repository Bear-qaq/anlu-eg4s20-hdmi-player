#!/usr/bin/env node
// tools/bundle.mjs
// 生成给其他 AI / agent 的交接包（三档）。
//
// 用法：
//   node tools/bundle.mjs                     # 默认 agent 档
//   node tools/bundle.mjs context             # 最小档，贴给网页版 AI
//   node tools/bundle.mjs full                # 全量，含 raw/
//   node tools/bundle.mjs agent -o D:\share\anlu.zip
//   node tools/bundle.mjs agent --no-refresh  # 不重跑 pack.mjs

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createZip } from './lib/zip.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

const argv = process.argv.slice(2);
const positional = argv.filter(a => !a.startsWith('-'));
const flag = n => argv.includes('--' + n);
const opt = n => {
  const i = argv.findIndex(a => a === '-' + n || a === '--' + n);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : null;
};

const TIER = positional[0] || 'agent';
if (!['context', 'agent', 'full'].includes(TIER)) {
  console.error('档位必须是 context / agent / full 之一，收到: ' + TIER);
  process.exit(1);
}

/* ---------------- 刷新索引 ---------------- */
if (!flag('no-refresh') && fs.existsSync(path.join(ROOT, 'tools', 'pack.mjs'))) {
  process.stdout.write('刷新索引...\n');
  const r = spawnSync(process.execPath, [path.join(ROOT, 'tools', 'pack.mjs')], {
    cwd: ROOT, stdio: 'inherit',
  });
  if (r.error || r.status !== 0) {
    console.error('pack.mjs 失败，继续用现有索引打包。');
  }
}

/* ---------------- 各档内容 ---------------- */
const CONTEXT = [
  'AGENTS.md', 'AI_GUIDE.md', 'PACKAGING.md', 'HANDOFF.md', 'PROGRESS.md',
  '调研_HX4S20C供货与竞赛规则.md',
  'ai/00_START_HERE.md', 'ai/01_INDEX.md', 'ai/02_MODULE_MAP.md',
  'ai/03_HIERARCHY.md', 'ai/04_CONSTRAINTS.md', 'ai/05_DOCS.md',
  'ai/06_REPORTS.md', 'ai/MANIFEST.json', 'ai/packs',
];
const AGENT = [
  ...CONTEXT,
  'ai/files',                    // 源码镜像
  'src', 'constr', 'sim',        // 自己的设计 / 约束 / 仿真
  'prj',                         // prj.json —— td_build.mjs 的构建清单，缺了就不能构建
  'docs',                        // ARCH_DIFF / BOARD_SWAP / BOARD_DAMUZHI
  'analysis',
  'tools',
  '.dsh/skills',                 // 项目级技能
  '.gitignore',
];
// build/ 刻意不含：TD 中间产物 58 MB，有 TD 就能重建
const FULL = [...AGENT, 'raw'];

const ITEMS = { context: CONTEXT, agent: AGENT, full: FULL }[TIER];

/* ---------------- 展开成条目 ---------------- */
const entries = [];
const missing = [];
let dirs = 0, files = 0;

for (const item of ITEMS) {
  const abs = path.join(ROOT, item);
  if (!fs.existsSync(abs)) { missing.push(item); continue; }
  const st = fs.statSync(abs);

  if (st.isDirectory()) {
    dirs++;
    const prefix = item.replace(/\\/g, '/').replace(/\/+$/, '');
    const walk = (dir, rel) => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const a = path.join(dir, e.name);
        const r = rel ? rel + '/' + e.name : e.name;
        if (e.isDirectory()) walk(a, r);
        else if (e.isFile()) {
          entries.push({ name: prefix + '/' + r, source: a });
          files++;
        }
      }
    };
    walk(abs, '');
  } else {
    entries.push({ name: item.replace(/\\/g, '/'), source: abs });
    files++;
  }
}

if (missing.length) {
  console.log('跳过不存在的路径: ' + missing.join(', '));
}
if (!entries.length) {
  console.error('没有任何可打包的内容。');
  process.exit(1);
}

/* ---------------- 输出 ---------------- */
const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 13);
const outArg = opt('o');
const outPath = path.resolve(ROOT, outArg || ('handoff_' + TIER + '_' + stamp + '.zip'));
fs.mkdirSync(path.dirname(outPath), { recursive: true });
if (fs.existsSync(outPath)) fs.rmSync(outPath);

console.log('打包 ' + files + ' 个文件（' + dirs + ' 个目录）...');
const t0 = Date.now();
const res = createZip(outPath, entries, {
  onProgress: n => process.stdout.write('  ...' + n + ' 个文件\n'),
});
const ms = Date.now() - t0;

const mb = n => (n / 1024 / 1024).toFixed(2) + ' MB';
console.log('');
console.log('交接包已生成 (档位: ' + TIER + ')');
console.log('  路径     : ' + outPath);
console.log('  文件数   : ' + res.files);
console.log('  原始体积 : ' + mb(res.bytesIn));
console.log('  压缩后   : ' + mb(res.bytesOut));
console.log('  耗时     : ' + ms + ' ms');
console.log('');
console.log('包含的顶层条目:');
for (const i of ITEMS) if (!missing.includes(i)) console.log('  - ' + i);
console.log('');
console.log({
  context: '用途: 直接把 zip 里的 md 贴/传给网页版 AI。',
  agent: '用途: 解压到目标机器，在该目录启动 DSH 或 Codex（会自动读 AGENTS.md）。',
  full: '用途: 跨机器完整迁移，含 raw/ 官方原件与 PDF。',
}[TIER]);
