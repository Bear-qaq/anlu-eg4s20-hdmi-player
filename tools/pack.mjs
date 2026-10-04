#!/usr/bin/env node
// tools/pack.mjs
// FPGA 资料打包器：把 raw/ 里的一堆官方例程+手册，整理成 AI 能高效读取的结构化包。
//
// 用法：
//   node tools/pack.mjs            # 在项目根目录执行
//   node tools/pack.mjs D:\path    # 指定项目根目录
//   node tools/pack.mjs --dry      # 只分析不写文件

import fs from 'node:fs';
import path from 'node:path';
import {
  estTokens, fmtTokens, walk, classify, extOf, ensureDir, writeFileSafe,
  lineCount, humanSize, headerComment, truncateLines, headTail, readTextFile,
} from './lib/core.mjs';
import { parseHdl, findInstantiations, renderPorts } from './lib/hdl.mjs';

/* ------------------------------------------------------------------ */
/* 初始化                                                              */
/* ------------------------------------------------------------------ */
const args = process.argv.slice(2);
const DRY = args.includes('--dry');
const rootArg = args.find(a => !a.startsWith('--'));
const ROOT = path.resolve(rootArg || process.cwd());

const cfgPath = path.join(ROOT, 'tools', 'config.json');
if (!fs.existsSync(cfgPath)) {
  console.error('找不到配置文件: ' + cfgPath);
  process.exit(1);
}
const CFG = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
const OUT = path.join(ROOT, CFG.outDir);
const FILES_OUT = path.join(OUT, 'files');

const HDLEXT = new Set(CFG.hdlExtensions || []);
const CONEXT = new Set(CFG.constraintExtensions || []);
const REPEXT = new Set(CFG.reportExtensions || []);

const warnings = [];
const say = (...a) => console.log(...a);

/* ------------------------------------------------------------------ */
/* 1. 扫描 + 分类                                                       */
/* ------------------------------------------------------------------ */
say('扫描 ' + ROOT);
const records = [];
const dropped = [];

for (const input of CFG.inputs || []) {
  const abs = path.join(ROOT, input);
  if (!fs.existsSync(abs)) {
    warnings.push('输入目录不存在: ' + input + '（跳过）');
    continue;
  }
  const { files, dropped: d } = walk(abs, CFG);
  // 统一加输入目录前缀，否则清单里会出现「有的带 raw/ 有的不带」两种写法
  for (const x of d) x.path = input + '/' + x.path;
  dropped.push(...d);
  for (const f of files) {
    const c = classify(f.rel, f.size, CFG);
    if (!c.keep) { dropped.push({ path: input + '/' + f.rel, reason: c.why }); continue; }

    let text = null, enc = c.cat;
    if (c.digest !== false && c.cat !== 'binary-doc' && c.cat !== 'image') {
      const r = readTextFile(f.abs);
      text = r.text;
      enc = r.enc;
      if (enc === 'non-utf8') {
        warnings.push(f.rel + ' 不是 UTF-8（可能是 GBK），已保留文件但未提取内容');
      }
    }
    records.push({
      abs: f.abs, rel: f.rel, input, size: f.size, cat: c.cat,
      text, enc, lines: lineCount(text),
      big: f.size > (CFG.bigFileBytes || 81920),
    });
  }
}

const totalBytes = records.reduce((a, r) => a + r.size, 0);
const totalLines = records.reduce((a, r) => a + r.lines, 0);
say('  保留 ' + records.length + ' 个文件，剔除 ' + dropped.length + ' 个');

/* ------------------------------------------------------------------ */
/* 2. HDL 接口提取                                                      */
/* ------------------------------------------------------------------ */
const modules = [];
const knownModules = new Set();
const parseErrors = [];

for (const r of records) {
  if (!HDLEXT.has(extOf(r.rel)) || !r.text) continue;
  try {
    for (const m of parseHdl(r.text, r.rel)) {
      m.relPath = r.rel;
      modules.push(m);
      knownModules.add(m.name);
    }
  } catch (e) {
    parseErrors.push(r.rel + ': ' + e.message);
  }
}

const nameCount = new Map();
for (const m of modules) nameCount.set(m.name, (nameCount.get(m.name) || 0) + 1);
for (const m of modules) m.dup = nameCount.get(m.name) > 1;

say('  识别到 ' + modules.length + ' 个模块/实体');

/* ------------------------------------------------------------------ */
/* 3. 例化关系                                                          */
/* ------------------------------------------------------------------ */
const fileEdges = new Map();
const externalAgg = new Map();

for (const r of records) {
  if (!HDLEXT.has(extOf(r.rel)) || !r.text) continue;
  const res = findInstantiations(r.text, r.rel, knownModules);
  fileEdges.set(r.rel, res);
  for (const e of res.external) {
    externalAgg.set(e.name, (externalAgg.get(e.name) || 0) + e.count);
  }
}

for (const m of modules) {
  const e = fileEdges.get(m.relPath);
  let mine = [];
  if (e) {
    if (m.lang === 'verilog' && Number.isFinite(m.bodyStart)) {
      // 精确定位：只认落在本模块 body 范围内的例化
      mine = e.internal.filter(x => x.index >= m.bodyStart && x.index < m.bodyEnd);
    } else {
      // VHDL：实体与架构通常同文件，按文件归属
      mine = e.internal;
    }
  }
  m.instantiations = mine;
  m.childNames = [...new Set(mine.map(x => x.name))];
}

const TB_RE = /(^|[\/_.\-])(tb|testbench|stim|sim|stimulus|test)([\/_.\-]|$)/i;

// 只统计"被可综合代码例化"的关系：被 testbench 例化不算 —— 否则真正的顶层会被埋掉
const tbFiles = new Set();
for (const r of records) {
  const modsInFile = modules.filter(m => m.relPath === r.rel);
  if (TB_RE.test(r.rel) && modsInFile.length) tbFiles.add(r.rel);
  else if (modsInFile.length && modsInFile.every(m => TB_RE.test(m.name))) tbFiles.add(r.rel);
}
const instantiatedByRtl = new Set();
for (const [rel, v] of fileEdges) {
  if (tbFiles.has(rel)) continue;
  for (const e of v.internal) instantiatedByRtl.add(e.name);
}

const roots = modules.filter(m => !instantiatedByRtl.has(m.name));
const topCandidates = roots
  .slice()
  .sort((a, b) => score(b) - score(a))
  .slice(0, 12);

function score(m) {
  let s = 0;
  if (TB_RE.test(m.name) || TB_RE.test(m.relPath)) s -= 50;
  if (/top/i.test(m.name) || /top/i.test(m.relPath)) s += 20;
  if (m.ports.some(p => /clk|clock|sys_clk|clk_i/i.test(p.name))) s += 10;
  if (m.ports.some(p => /rst|reset/i.test(p.name))) s += 5;
  s += Math.min(m.ports.length, 40) / 4;
  s += m.childNames.length * 2;
  return s;
}

say('  顶层候选 ' + topCandidates.length + ' 个');

/* ------------------------------------------------------------------ */
/* 4. 输出目录清理与复制（推迟到渲染完成之后执行）                       */
/* ------------------------------------------------------------------ */
/** 只允许清理项目内、且不是项目根目录的路径 */
function safeClean(dir) {
  const rel = path.relative(ROOT, dir);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) {
    warnings.push('拒绝清理项目外的目录: ' + dir);
    return false;
  }
  if (path.resolve(dir) === path.resolve(ROOT)) {
    warnings.push('拒绝清理项目根目录');
    return false;
  }
  try { fs.rmSync(dir, { recursive: true, force: true }); return true; }
  catch (e) { warnings.push('清理失败 ' + dir + ': ' + e.message); return false; }
}

/**
 * 把清理和复制都推迟到所有内容渲染完毕之后再执行。
 * 否则中途被打断（EPIPE、Ctrl-C、磁盘满）会留下一个被清空一半的输出目录 ——
 * 上一个可用的资料包就没了。
 */
function materializeFiles() {
  if (DRY) return;
  safeClean(path.join(OUT, 'packs'));
  safeClean(FILES_OUT);

  let copied = 0, skippedCopy = 0;
  for (const r of records) {
    const skip = (r.cat === 'binary-doc' && !CFG.copyBinaryDocs)
      || (r.cat === 'image' && !CFG.copyImages);
    if (skip) { skippedCopy++; continue; }
    const dest = path.join(FILES_OUT, r.input, r.rel);
    ensureDir(path.dirname(dest));
    try { fs.copyFileSync(r.abs, dest); copied++; }
    catch (e) { warnings.push('复制失败 ' + r.rel + ': ' + e.message); }
  }
  if (skippedCopy) {
    say('  复制 ' + copied + ' 个文件（' + skippedCopy + ' 个二进制文档/图片只登记不复制，'
      + '原件仍在 raw/）');
  }
  ensureDir(OUT);
}

/* ------------------------------------------------------------------ */
/* 5. 生成文档                                                          */
/* ------------------------------------------------------------------ */
const md = {};
const now = new Date().toISOString().replace('T', ' ').slice(0, 16);

/* ---- 目录树 ---- */
function buildTree() {
  const rootNode = { name: '.', dirs: new Map(), files: [] };
  for (const r of records) {
    const parts = (r.input + '/' + r.rel).split('/');
    let node = rootNode;
    for (let i = 0; i < parts.length - 1; i++) {
      if (!node.dirs.has(parts[i])) node.dirs.set(parts[i], { name: parts[i], dirs: new Map(), files: [] });
      node = node.dirs.get(parts[i]);
    }
    node.files.push({ name: parts[parts.length - 1], rec: r });
  }
  const lines = [];
  let count = 0;
  (function render(node, prefix, depth) {
    if (count > (CFG.treeMaxEntries || 400) || depth > (CFG.treeMaxDepth || 3)) return;
    const dirs = [...node.dirs.values()].sort((a, b) => a.name.localeCompare(b.name));
    const files = node.files.slice().sort((a, b) => a.name.localeCompare(b.name));
    const items = [
      ...dirs.map(d => ({ kind: 'dir', name: d.name, node: d })),
      ...files.map(f => ({ kind: 'file', name: f.name, rec: f.rec })),
    ];
    items.forEach((it, idx) => {
      if (count++ > (CFG.treeMaxEntries || 400)) return;
      const last = idx === items.length - 1;
      const branch = last ? '└── ' : '├── ';
      if (it.kind === 'dir') {
        lines.push(prefix + branch + it.name + '/');
        render(it.node, prefix + (last ? '    ' : '│   '), depth + 1);
      } else {
        lines.push(prefix + branch + it.name
          + '  (' + it.rec.cat + ', ' + humanSize(it.rec.size) + ')');
      }
    });
  })(rootNode, '', 0);
  if (count > (CFG.treeMaxEntries || 400)) lines.push('... （目录过大，已截断）');
  return lines.join('\n');
}

/* ---- 00_START_HERE ---- */
function buildStartHere(packInfos) {
  const byCat = new Map();
  for (const r of records) byCat.set(r.cat, (byCat.get(r.cat) || 0) + 1);

  let guidance = '';
  for (const g of CFG.guidanceFiles || []) {
    const p = path.join(ROOT, g);
    if (fs.existsSync(p)) {
      guidance += '\n\n---\n\n# 项目说明（来自 ' + g + '）\n\n' + fs.readFileSync(p, 'utf8').trim() + '\n';
    }
  }

  const packList = packInfos;

  return `# 给 AI 的入口 · FPGA 项目资料包

> 由 tools/pack.mjs 于 ${now} 生成。**请先读完本文件，再决定读哪些其他文件。**

## 一句话说明

这是一个 FPGA 竞赛项目的资料包。原始例程与文档放在 \`raw/\`，本目录 \`ai/\` 是整理后的
AI 友好版本：\`ai/files/\` 是清理过的可读文本源码（PDF/Office 等二进制文档只登记不复制，
原件仍在 \`raw/\`），其余 \`.md\` 是从中提炼的索引与接口地图。

## 统计

| 项目 | 数值 |
|---|---|
| 保留文件 | ${records.length} |
| 剔除文件（构建产物/二进制） | ${dropped.length} |
| 源码总行数 | ${totalLines} |
| 原始体积 | ${humanSize(totalBytes)} |
| 文本内容估算 token | ${fmtTokens(estTokens(records.map(r => r.text || '').join('\n')))} |
| 识别模块/实体 | ${modules.length} |
| 顶层候选 | ${topCandidates.length} |

按类别：

${[...byCat.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => '- `' + k + '` × ' + v).join('\n')}

## 推荐阅读顺序（按需，不要一次全读）

| 顺序 | 文件 | 什么时候读 | 大概 token |
|---|---|---|---|
| 1 | \`00_START_HERE.md\` | 永远第一个读 | 本文件 |
| 2 | \`02_MODULE_MAP.md\` | 要改/接某个模块时——先看接口，**不要直接读源码** | ${fmtTokens(estTokens(md['02'] || ''))} |
| 3 | \`03_HIERARCHY.md\` | 要理解整体结构、找顶层时 | ${fmtTokens(estTokens(md['03'] || ''))} |
| 4 | \`04_CONSTRAINTS.md\` | 涉及引脚、时钟、时序约束时 | ${fmtTokens(estTokens(md['04'] || ''))} |
| 5 | \`01_INDEX.md\` | 想找"某个功能在哪个文件"时 | ${fmtTokens(estTokens(md['01'] || ''))} |
| 6 | \`05_DOCS.md\` | 需要查手册时 | ${fmtTokens(estTokens(md['05'] || ''))} |
| 7 | \`06_REPORTS.md\` | 综合/布局布线报错，或资源占用异常时 | ${fmtTokens(estTokens(md['06'] || ''))} |
| 8 | \`files/…\` | 只有确定要改哪个文件时，才读具体源码 | — |
| 9 | \`packs/*.md\` | 一次只做一个例程/模块时，读对应分卷 | 见下 |

## 分卷（按任务取用，避免污染上下文）

${packList.length
      ? packList.map(p => '- `packs/' + p.name + '`  —  ' + p.count + ' 个文件, 约 '
        + fmtTokens(p.tokens) + ' tokens').join('\n')
      : '（无）'}

## 目录树

\`\`\`
${buildTree()}
\`\`\`
${guidance}
`;
}

/* ---- 01_INDEX ---- */
function buildIndex() {
  const rows = records.slice().sort((a, b) => a.rel.localeCompare(b.rel)).map(r => {
    const desc = r.text
      ? (headerComment(r.text) || '')
      : (r.cat === 'binary-doc' ? '（二进制文档，需人工/OCR 处理）' : '');
    const flag = r.big ? '⚠️大文件 ' : '';
    return '| `' + r.input + '/' + r.rel + '` | ' + r.cat + ' | ' + (r.lines || '-')
      + ' | ' + humanSize(r.size) + ' | ' + flag + desc.replace(/\|/g, '\\|') + ' |';
  });
  return `# 文件索引

共 ${records.length} 个文件。\`说明\` 列取自文件头注释。

| 文件 | 类别 | 行数 | 大小 | 说明 |
|---|---|---|---|---|
${rows.join('\n')}

## 被剔除的文件（共 ${dropped.length}）

这些是构建产物、二进制或未知类型，对理解设计无价值，已排除。

| 路径 | 原因 |
|---|---|
${dropped.slice(0, 200).map(d => '| `' + d.path + '` | ' + d.reason + ' |').join('\n')}
${dropped.length > 200 ? '\n... 其余 ' + (dropped.length - 200) + ' 项省略\n' : ''}
`;
}

/* ---- 02_MODULE_MAP ---- */
function buildModuleMap() {
  if (!modules.length) return '# 模块地图\n\n（未识别到 HDL 模块）\n';
  const byFile = new Map();
  for (const m of modules) {
    if (!byFile.has(m.relPath)) byFile.set(m.relPath, []);
    byFile.get(m.relPath).push(m);
  }
  const parts = ['# 模块地图（所有 HDL 模块的接口）\n',
    '> **改代码前先看这里。** 拿到接口就能写例化和测试，不必先读实现。\n'];

  for (const file of [...byFile.keys()].sort()) {
    parts.push('\n## `' + file + '`\n');
    for (const m of byFile.get(file)) {
      parts.push('### `' + m.name + '`  ·  ' + m.lang + '  ·  L' + m.line
        + (m.dup ? '  ·  ⚠️ 同名模块出现多次' : ''));
      if (m.params.length) {
        parts.push('参数：' + m.params.map(p => '`' + p.name + ' = ' + p.value + '`').join(', '));
      }
      parts.push(renderPorts(m));
      if (m.childNames.length) {
        parts.push('例化：' + m.childNames.map(c => '`' + c + '`').join(', '));
      }
      parts.push('');
    }
  }
  return parts.join('\n');
}

/* ---- 03_HIERARCHY ---- */
function buildHierarchy() {
  const byName = new Map();
  for (const m of modules) {
    if (!byName.has(m.name)) byName.set(m.name, []);
    byName.get(m.name).push(m);
  }

  const out = ['# 层次结构\n', '## 顶层候选\n',
    '没有被任何模块例化的模块 = 顶层。按"像不像顶层"排序：\n',
    '| 模块 | 文件 | 端口数 | 例化子模块数 | 备注 |',
    '|---|---|---|---|---|'];
  for (const m of topCandidates) {
    const note = TB_RE.test(m.name) || TB_RE.test(m.relPath) ? '疑似 testbench' : '';
    out.push('| `' + m.name + '` | `' + m.relPath + '` | ' + m.ports.length
      + ' | ' + m.childNames.length + ' | ' + note + ' |');
  }

  out.push('\n## 例化树\n');
  /** 同名模块可能在多个工程里重复定义，选与父文件路径公共前缀最长的那个 */
  function resolveChild(name, parentPath) {
    const cands = byName.get(name);
    if (!cands || !cands.length) return null;
    if (cands.length === 1) return cands[0];
    const pd = parentPath.split('/');
    let best = cands[0], bestScore = -1;
    for (const c of cands) {
      const cd = c.relPath.split('/');
      let i = 0;
      while (i < pd.length && i < cd.length && pd[i] === cd[i]) i++;
      if (i > bestScore) { bestScore = i; best = c; }
    }
    return best;
  }
  function tree(mod, prefix, depth, seen) {
    if (depth > 6) { out.push(prefix + '└── ...（更深层省略）'); return; }
    const kids = [...new Set(mod.childNames)];
    kids.forEach((k, i) => {
      const last = i === kids.length - 1;
      const child = resolveChild(k, mod.relPath);
      const loc = child ? child.relPath : '未找到定义（可能是厂商原语/IP）';
      out.push(prefix + (last ? '└── ' : '├── ') + k + '   — ' + loc);
      if (child && !seen.has(k) && depth < 6) {
        const ns = new Set(seen); ns.add(k);
        tree(child, prefix + (last ? '    ' : '│   '), depth + 1, ns);
      } else if (child && seen.has(k)) {
        out.push(prefix + (last ? '    ' : '│   ') + '└── (已展开过，避免递归)');
      }
    });
  }
  for (const m of topCandidates.slice(0, 5)) {
    out.push('```\n' + m.name + '   — ' + m.relPath);
    tree(m, '', 0, new Set([m.name]));
    out.push('```\n');
  }

  const ext = [...externalAgg.entries()].sort((a, b) => b[1] - a[1]);
  if (ext.length) {
    out.push('\n## 外部引用（厂商原语 / IP / 未提供源码的模块）\n');
    out.push('这些名字被例化但源码里没有定义，通常是器件原语或 IP 核：\n');
    out.push('| 名称 | 出现次数 |');
    out.push('|---|---|');
    for (const [n, c] of ext.slice(0, 120)) out.push('| `' + n + '` | ' + c + ' |');
  }

  if (parseErrors.length) {
    out.push('\n## 解析告警\n');
    for (const e of parseErrors) out.push('- ' + e);
  }
  return out.join('\n') + '\n';
}

/* ---- 04_CONSTRAINTS ---- */
const PROJECT_EXT = new Set(['.al', '.prj', '.qpf']);

/** 解析 TD 的 .al 工程文件（XML）：拿到器件型号和综合源文件清单 */
function parseAlProject(text) {
  const info = { name: '', family: '', device: '', version: '', files: [] };
  let m;
  if ((m = /<Name>([^<]*)<\/Name>/.exec(text))) info.name = m[1];
  if ((m = /<TD_Version>([^<]*)<\/TD_Version>/.exec(text))) info.version = m[1];
  if ((m = /<Family>([^<]*)<\/Family>/.exec(text))) info.family = m[1];
  if ((m = /<Device>([^<]*)<\/Device>/.exec(text))) info.device = m[1];

  const re = /<File\s+Path="([^"]+)"\s*>([\s\S]*?)<\/File>/g;
  let f;
  while ((f = re.exec(text))) {
    const body = f[2];
    const attr = n => {
      const a = new RegExp('Name="' + n + '"\\s+Val="([^"]*)"').exec(body);
      return a ? a[1] : '';
    };
    info.files.push({
      path: f[1],
      order: parseInt(attr('CompileOrder') || '0', 10) || 0,
      usedInSyn: attr('UsedInSyn') !== 'false',
      usedInPnr: attr('UsedInP&R') !== 'false',
    });
  }
  info.files.sort((a, b) => a.order - b.order);
  return info;
}

function extractConstraints() {
  const clocks = [], pins = [];
  for (const r of records) {
    if (!CONEXT.has(extOf(r.rel)) || !r.text) continue;
    if (PROJECT_EXT.has(extOf(r.rel))) continue;   // 工程文件另行处理
    const lines = r.text.split('\n');
    lines.forEach((ln, i) => {
      // 行首 # 表示该约束已被注释掉（TD .adc / Tcl .sdc 都是），不能当作生效约束
      if (/^\s*#/.test(ln)) return;
      const cm = /create_clock\b/.exec(ln);
      if (cm) {
        const per = /-period\s+([\d.]+)/.exec(ln);
        const nm = /-name\s+(\S+)/.exec(ln);
        const port = /get_ports\s+\{?([^\}\]\s]+)/.exec(ln) || /get_clocks\s+\{?([^\}\]\s]+)/.exec(ln);
        const name = nm ? nm[1] : (port ? port[1] : '-');
        // 两边都取不到的行没有信息量，跳过
        if (name === '-' && !per) return;
        clocks.push({
          file: r.rel, line: i + 1, name,
          period: per ? per[1] : '-',
          freq: per ? (1000 / parseFloat(per[1])).toFixed(2) + ' MHz' : '-',
        });
      }
      let pm = /PACKAGE_PIN\s+(\S+)[^\n]*?get_ports\s+\{?([^\}\]\s]+)/.exec(ln);
      if (pm) { pins.push({ file: r.rel, line: i + 1, pin: pm[1], port: pm[2], std: (/IOSTANDARD\s+(\S+)/.exec(ln) || [, '-'])[1] }); }
      pm = /set_location_assignment\s+PIN_(\S+)\s+-to\s+(\S+)/.exec(ln);
      if (pm) { pins.push({ file: r.rel, line: i + 1, pin: pm[1], port: pm[2], std: '-' }); }
      pm = /LOCATION\s*=\s*([A-Za-z0-9_]+)/.exec(ln);
      if (pm) {
        const portM = /\{\s*([\w\[\]\s,]+?)\s*\}\s*\{/.exec(ln);
        const std = /IOSTANDARD\s*=\s*(\w+)/.exec(ln);
        pins.push({ file: r.rel, line: i + 1, pin: pm[1], port: portM ? portM[1].trim() : '-', std: std ? std[1] : '-' });
      }
    });
  }

  const out = ['# 约束（时钟 / 引脚 / 时序）\n'];
  if (clocks.length) {
    out.push('## 时钟\n', '| 时钟 | 周期(ns) | 频率 | 来源 |', '|---|---|---|---|');
    for (const c of clocks) out.push('| `' + c.name + '` | ' + c.period + ' | ' + c.freq + ' | `' + c.file + ':' + c.line + '` |');
    out.push('');
  }
  if (pins.length) {
    out.push('## 引脚分配\n', '| 端口 | 引脚 | 电平标准 | 来源 |', '|---|---|---|---|');
    for (const p of pins) out.push('| `' + p.port + '` | ' + p.pin + ' | ' + p.std + ' | `' + p.file + ':' + p.line + '` |');
    out.push('');
  }
  if (!clocks.length && !pins.length) out.push('（未从约束文件中自动提取到时钟/引脚，见下方原文）\n');

  out.push('\n## 工程文件（源文件清单 / 器件设置）\n');
  const projects = records.filter(r => PROJECT_EXT.has(extOf(r.rel)) && r.text);
  if (!projects.length) out.push('（没有发现工程文件）\n');
  for (const r of projects) {
    out.push('\n### `' + r.rel + '`\n');
    if (extOf(r.rel) !== '.al') {
      const t = truncateLines(r.text, CFG.maxConstraintLines || 250);
      out.push('```', t.text, '```');
      if (t.cut) out.push('（已截断 ' + t.cut + ' 行）');
      continue;
    }
    const info = parseAlProject(r.text);
    out.push('- 工程名：`' + (info.name || '-') + '`');
    out.push('- 器件：`' + (info.family || '') + ' ' + (info.device || '-') + '`');
    out.push('- TD 版本：`' + (info.version || '-') + '`');
    out.push('- 源文件 ' + info.files.length + ' 个（按编译顺序）：\n');
    out.push('| # | 文件 | 综合 | 布局布线 |');
    out.push('|---|---|---|---|');
    for (const f of info.files) {
      out.push('| ' + f.order + ' | `' + f.path + '` | '
        + (f.usedInSyn ? '✓' : '✗') + ' | ' + (f.usedInPnr ? '✓' : '✗') + ' |');
    }
  }

  out.push('\n## 约束文件原文\n');
  for (const r of records) {
    if (!CONEXT.has(extOf(r.rel)) || !r.text) continue;
    if (PROJECT_EXT.has(extOf(r.rel))) continue;
    const t = truncateLines(r.text, CFG.maxConstraintLines || 250);
    out.push('\n### `' + r.rel + '`\n', '```', t.text, '```');
    if (t.cut) out.push('（已截断 ' + t.cut + ' 行；完整内容见 `ai/files/' + r.input + '/' + r.rel + '`）');
  }
  return out.join('\n') + '\n';
}

/* ---- 05_DOCS ---- */
function buildDocs() {
  const docs = records.filter(r => r.cat === 'binary-doc' || r.cat === 'image');
  const out = ['# 文档清单（PDF / Office / 图片）\n',
    '这些文件**内容没有被提取**（AI 读不了二进制文档）。',
    '要做的是：对真正需要的，用下面的办法转成 markdown，或手写摘要填进本文件。\n',
    '## 转换建议\n',
    '1. 能拿到官方在线文档 URL 的，直接把 URL 写进对应条目的「摘要」里——最省事。',
    '2. 需要转 PDF 的，用 `marker` / `MinerU` / `markitdown` 转成 markdown 放进 `docs_md/`。',
    '3. 只关心寄存器/引脚/时序的，手抄成 `regmap.md` / `pinout.md` / `timing.md`，比整本手册有用得多。\n',
    '## 清单\n'];
  if (!docs.length) out.push('（没有发现文档类文件）\n');
  for (const d of docs.sort((a, b) => a.rel.localeCompare(b.rel))) {
    const outPath = 'docs_md/' + d.rel.replace(/\.[^.]+$/, '') + '.md';
    out.push('### `' + d.input + '/' + d.rel + '`  (' + d.cat + ', ' + humanSize(d.size) + ')\n');
    out.push('- 主题：');
    out.push('- 优先级：高 / 中 / 低');
    out.push('- 在线原文 URL：');
    out.push('- 已转 markdown：`' + outPath + '`（未完成就留空）');
    out.push('- 摘要 / 关键信息（引脚表、寄存器、时序、注意事项）：');
    out.push('');
  }
  return out.join('\n') + '\n';
}

/* ---- 06_REPORTS ---- */
function buildReports() {
  const minBytes = CFG.minReportBytes || 0;
  const all = records.filter(r => REPEXT.has(extOf(r.rel)) && r.text);
  const tiny = all.filter(r => r.size < minBytes);
  const reps = all.filter(r => r.size >= minBytes);
  const out = ['# 报告文件摘要（综合 / 布局布线 / 仿真日志）\n',
    '只保留头尾，中间省略。报错和资源占用通常在这里。\n'];
  if (!reps.length) out.push('（没有发现 .rpt / .log 报告）\n');
  for (const r of reps.sort((a, b) => a.rel.localeCompare(b.rel))) {
    out.push('\n## `' + r.rel + '`  (' + r.lines + ' 行, ' + humanSize(r.size) + ')\n');
    out.push('```');
    out.push(headTail(r.text, CFG.maxReportHead || 50, CFG.maxReportTail || 60));
    out.push('```');
  }
  if (tiny.length) {
    out.push('\n## 已略过的空/极小日志（' + tiny.length + ' 个，< ' + minBytes + 'B）\n');
    out.push(tiny.slice(0, 30).map(r => '- `' + r.rel + '`').join('\n'));
    if (tiny.length > 30) out.push('\n... 其余 ' + (tiny.length - 30) + ' 个');
  }
  return out.join('\n') + '\n';
}

/* ---- packs ---- */
function buildPacks() {
  // 自适应分组：先按第 1 层，太大就继续下钻
  function groupAt(depth) {
    const g = new Map();
    for (const r of records) {
      const parts = r.rel.split('/');
      const key = parts.slice(0, Math.min(depth, Math.max(1, parts.length - 1))).join('/') || '_root';
      if (!g.has(key)) g.set(key, []);
      g.get(key).push(r);
    }
    return g;
  }
  let depth = 1;
  let groups = groupAt(depth);
  while (depth < 4 && [...groups.values()].some(v => v.length > (CFG.packMaxFiles || 40))) {
    depth++;
    groups = groupAt(depth);
  }

  const packs = [];
  const usedNames = new Set();
  for (const [key, recs] of [...groups.entries()].sort()) {
    const out = ['# 分卷：`' + key + '`\n',
      '本卷共 ' + recs.length + ' 个文件。' + (depth > 1 ? '（按第 ' + depth + ' 层目录分组）' : '') + '\n',
      '## 文件清单\n'];
    for (const r of recs.sort((a, b) => a.rel.localeCompare(b.rel))) {
      out.push('- `' + r.input + '/' + r.rel + '` (' + r.cat + ', ' + r.lines + ' 行)');
    }
    out.push('\n## 内容\n');

    let budget = CFG.packMaxTokens || 45000;
    for (const r of recs.sort((a, b) => a.rel.localeCompare(b.rel))) {
      if (!r.text) {
        if (r.cat === 'binary-doc' || r.cat === 'image') {
          out.push('\n### `' + r.rel + '` — 二进制文档，内容未提取\n');
        }
        continue;
      }
      const isRep = REPEXT.has(extOf(r.rel));
      let body, note = '';
      if (isRep) {
        body = headTail(r.text, CFG.maxReportHead || 50, CFG.maxReportTail || 60);
        note = '（报告：仅头尾）';
      } else if (r.big) {
        const t = truncateLines(r.text, CFG.bigFilePreviewLines || 60);
        body = t.text;
        note = '（大文件 ' + humanSize(r.size) + '，仅预览开头 ' + (CFG.bigFilePreviewLines || 60)
          + ' 行；完整内容见 `ai/files/' + r.input + '/' + r.rel + '`）';
      } else {
        const t = truncateLines(r.text, CFG.maxFileLines || 1500);
        body = t.text;
        if (t.cut) note = '（已截断 ' + t.cut + ' 行）';
      }
      const tk = estTokens(body);
      if (tk > budget) {
        out.push('\n### `' + r.rel + '` — 因预算跳过（需单独读取 `ai/files/' + r.input + '/' + r.rel + '`）\n');
        continue;
      }
      budget -= tk;
      const lang = langOf(r.rel);
      out.push('\n### `' + r.rel + '` ' + note + '\n');
      out.push('```' + lang);
      out.push(body);
      out.push('```');
    }

    const name = makePackName(key, usedNames);
    packs.push({ name, content: out.join('\n') + '\n', key, count: recs.length });
  }
  return packs;
}

/** 生成分卷文件名：折叠重复路径段、限制长度、避免重名 */
function makePackName(key, usedNames) {
  const segs = key.split('/').filter(Boolean)
    .filter((s, i, a) => s !== a[i - 1]);        // 折叠相邻重复段（解压常见 pkg/pkg/）
  let base = segs.join('/').replace(/\.md$/i, '').replace(/[\\/:*?"<>|\s]+/g, '_');
  let hash = '';
  if (base.length > 60) {
    let h = 0;
    for (let i = 0; i < base.length; i++) h = (h * 31 + base.charCodeAt(i)) | 0;
    hash = '_' + Math.abs(h).toString(36).slice(0, 5);
    base = base.slice(0, 60);
  }
  let name = 'pack_' + base + hash + '.md';
  let n = 2;
  while (usedNames.has(name.toLowerCase())) {
    name = 'pack_' + base + hash + '_' + (n++) + '.md';
  }
  usedNames.add(name.toLowerCase());
  return name;
}

function langOf(rel) {
  const e = extOf(rel);
  if (['.v', '.sv', '.vh', '.svh'].includes(e)) return 'verilog';
  if (['.vhd', '.vhdl'].includes(e)) return 'vhdl';
  if (['.tcl'].includes(e)) return 'tcl';
  if (['.py'].includes(e)) return 'python';
  if (['.c', '.h', '.cpp', '.hpp'].includes(e)) return 'c';
  if (['.json'].includes(e)) return 'json';
  if (['.xml'].includes(e)) return 'xml';
  if (['.sh', '.bat', '.ps1'].includes(e)) return 'bash';
  return '';
}

/* ------------------------------------------------------------------ */
/* 6. 输出                                                              */
/* ------------------------------------------------------------------ */
md['01'] = buildIndex();
md['02'] = buildModuleMap();
md['03'] = buildHierarchy();
md['04'] = extractConstraints();
md['05'] = buildDocs();
md['06'] = buildReports();

// 分卷必须先于 00_START_HERE 生成：入口文件里要列出分卷清单，
// 而 packs/ 目录在前面的 safeClean 里刚被清空，读目录必然为空。
const packs = buildPacks();
const packInfos = packs.map(p => ({
  name: p.name, count: p.count, tokens: estTokens(p.content),
}));

md['00'] = buildStartHere(packInfos);

// 到这里所有内容都已经在内存里渲染完毕，才允许动磁盘。
materializeFiles();

const files = [
  ['00_START_HERE.md', md['00']],
  ['01_INDEX.md', md['01']],
  ['02_MODULE_MAP.md', md['02']],
  ['03_HIERARCHY.md', md['03']],
  ['04_CONSTRAINTS.md', md['04']],
  ['05_DOCS.md', md['05']],
  ['06_REPORTS.md', md['06']],
];

if (!DRY) {
  for (const [n, c] of files) writeFileSafe(path.join(OUT, n), c);
  for (const p of packs) writeFileSafe(path.join(OUT, 'packs', p.name), p.content);

  const manifest = {
    generatedAt: now,
    root: ROOT,
    stats: {
      keptFiles: records.length, droppedFiles: dropped.length,
      totalLines, totalBytes, modules: modules.length, topCandidates: topCandidates.length,
    },
    inputs: CFG.inputs,
    modules: modules.map(m => ({
      name: m.name, file: m.relPath, line: m.line, lang: m.lang,
      params: m.params, ports: m.ports, children: m.childNames,
    })),
    topCandidates: topCandidates.map(m => ({ name: m.name, file: m.relPath })),
    externalRefs: [...externalAgg.entries()].map(([name, count]) => ({ name, count })),
    files: records.map(r => ({
      path: r.input + '/' + r.rel, cat: r.cat, lines: r.lines, bytes: r.size, encoding: r.enc,
    })),
    dropped: dropped.map(d => ({ path: d.path, reason: d.reason })),
    warnings,
  };
  writeFileSafe(path.join(OUT, 'MANIFEST.json'), JSON.stringify(manifest, null, 2));
}

/* ------------------------------------------------------------------ */
/* 7. 报告                                                              */
/* ------------------------------------------------------------------ */
say('');
say('=== 生成的 AI 资料包 ===');
for (const [n, c] of files) {
  say('  ' + n.padEnd(20) + fmtTokens(estTokens(c)).padStart(8) + ' tokens');
}
for (const p of packs) {
  say('  packs/' + p.name.padEnd(14) + fmtTokens(estTokens(p.content)).padStart(8) + ' tokens  (' + p.count + ' 文件)');
}
if (!DRY) say('  MANIFEST.json');
say('');
say('总计 ' + files.length + ' 个索引文件 + ' + packs.length + ' 个分卷');
if (warnings.length) {
  say('');
  say('告警：');
  for (const w of warnings.slice(0, 20)) say('  - ' + w);
  if (warnings.length > 20) say('  ... 其余 ' + (warnings.length - 20) + ' 条');
}
if (DRY) say('\n(--dry 模式，未写入任何文件)');
else say('\n输出目录: ' + OUT);
