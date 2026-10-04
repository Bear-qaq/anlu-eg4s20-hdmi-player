#!/usr/bin/env node
/**
 * sim/run.mjs —— ModelSim 仿真驱动
 *
 * 为什么要这个：例程**没有提供任何 testbench**，全部要自己写；而 ModelSim 的
 * vlib/vlog/vsim 三步在 Windows 上手工敲很容易因为编码和路径踩坑。这里固化成一条命令。
 *
 * 用法：
 *   node sim/run.mjs                    # 跑全部 tb_*.v
 *   node sim/run.mjs tb_pack_unpack     # 只跑指定的一个
 *   node sim/run.mjs --list             # 只列出会跑哪些
 *   node sim/run.mjs --keep             # 保留 work 库（默认每次重建，避免脏库）
 *
 * 约定：
 *   - RTL 源从 src/rtl 与 src/vendor 收集（与 tools/td_build.mjs 一致，但排除 .enc.v：
 *     加密黑盒 ModelSim 解不开，凡是要例化黑盒的 tb 都必须在 tb 里自己打桩）
 *   - 判定标准：输出里出现 "RESULT: PASS" 且没有 "Errors: N"（N>0）/ "TIMEOUT"
 */

import { readFileSync, readdirSync, existsSync, mkdirSync, rmSync, statSync } from 'node:fs';
import { join, dirname, resolve, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SIM_DIR = join(ROOT, 'sim');
const WORK = join(SIM_DIR, 'work');

const MODELTECH = process.env.MODELTECH || 'D:/modeltech64_10.6e';
const BIN64 = join(MODELTECH, 'win64');
const BIN32 = join(MODELTECH, 'win32');

const argv = process.argv.slice(2);
const hasFlag = (f) => argv.includes(f);
const filter = argv.find((a) => !a.startsWith('--'));

const log = (...a) => console.log(...a);
const die = (m) => { console.error(`\n[错误] ${m}\n`); process.exit(1); };

// ---------------------------------------------------------------- 收集源文件

function collect(dir, exts, out = [], skip = () => false) {
  const abs = join(ROOT, dir);
  if (!existsSync(abs)) return out;
  for (const name of readdirSync(abs)) {
    const p = join(abs, name);
    if (statSync(p).isDirectory()) collect(join(dir, name), exts, out, skip);
    else if (exts.some((e) => name.toLowerCase().endsWith(e)) && !skip(name)) {
      out.push(join(dir, name).split(sep).join('/'));
    }
  }
  return out;
}

// 加密黑盒 ModelSim 解析不了（是密文），排除
const rtl = [
  ...collect('src/rtl', ['.v']),
  ...collect('src/vendor', ['.v'], [], (n) => n.endsWith('.enc.v')),
];

const tbs = readdirSync(SIM_DIR)
  .filter((f) => f.startsWith('tb_') && f.endsWith('.v'))
  .map((f) => f.replace(/\.v$/, ''))
  .sort();

if (hasFlag('--list')) {
  log('RTL 源：');
  for (const f of rtl) log('  ' + f);
  log('testbench：');
  for (const f of tbs) log('  ' + f);
  process.exit(0);
}

const runList = filter ? tbs.filter((t) => t === filter) : tbs;
if (!runList.length) die(filter ? `找不到 testbench ${filter}` : 'sim/ 下没有 tb_*.v');

// ---------------------------------------------------------------- 环境

if (!existsSync(join(BIN64, 'vsim.exe'))) die(`找不到 ModelSim：${join(BIN64, 'vsim.exe')}`);
// Windows 上 PATH 的键名大小写不固定，两个都兜住
const basePath = process.env.Path || process.env.PATH || '';
const env = { ...process.env, Path: `${BIN64};${BIN32};${basePath}`, PATH: `${BIN64};${BIN32};${basePath}` };
const exe = (n) => join(BIN64, n);

// ⚠️ 沙箱约束：本环境下 Node 用**管道**捕获子进程输出会 EPERM（named pipe 不可用）。
//    所以这里一律 stdio:'ignore'，让 ModelSim 把日志写进文件，再由 Node 读文件。
//    PowerShell 里直接敲 vlog/vsim 不受影响（它自己的管道不算命名管道）——这也是
//    为什么手工跑能过、脚本跑会挂。
function sh(cmd, args, cwd) {
  const r = spawnSync(cmd, args, {
    cwd, env, windowsHide: true,
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  if (r.error) die(`启动 ${cmd} 失败：${r.error.message}\n  args: ${args.join(' ')}\n  cwd : ${cwd}`);
  return r;
}

function readLog(p) {
  try { return readFileSync(p, 'utf8'); } catch { return ''; }
}

// 重建 work 库
if (!hasFlag('--keep')) rmSync(WORK, { recursive: true, force: true });
mkdirSync(SIM_DIR, { recursive: true });

let lib = sh(exe('vlib.exe'), ['work'], SIM_DIR);
if (lib.status !== 0) {
  rmSync(WORK, { recursive: true, force: true });
  lib = sh(exe('vlib.exe'), ['work'], SIM_DIR);
  if (lib.status !== 0) die(`vlib work 失败（退出码 ${lib.status}）`);
}

let pass = 0;
let fail = 0;
const failed = [];

for (const tb of runList) {
  log(`\n================ ${tb} ================`);
  const files = [...rtl.map((f) => join(ROOT, f)), join(SIM_DIR, `${tb}.v`)];
  const vlogLog = join(SIM_DIR, `${tb}.vlog.log`);
  const vsimLog = join(SIM_DIR, `${tb}.vsim.log`);

  // 注意：不能加 -sv。厂商 PLL 包装文件里有 `.do(...)` 这个端口名，
  // 在 SystemVerilog 模式下 "do" 是关键字，会直接语法报错。全工程按 Verilog-2001 编译。
  const v = sh(exe('vlog.exe'),
    ['-quiet', '-work', 'work', '-l', vlogLog, ...files], SIM_DIR);
  const vout = readLog(vlogLog);
  if (v.status !== 0 || /\*\*\s*Error/.test(vout)) {
    log(vout.split(/\r?\n/).filter((l) => /\*\*\s*Error/.test(l)).slice(0, 20).join('\n') || vout);
    fail += 1;
    failed.push(`${tb}（编译失败）`);
    continue;
  }

  const r = sh(exe('vsim.exe'),
    ['-c', '-quiet', '-work', 'work', '-l', vsimLog, tb, '-do', 'run -all; quit -f'], SIM_DIR);
  const out = readLog(vsimLog);
  const keep = out.split(/\r?\n/).filter((l) => /RESULT|PASS|FAIL|TIMEOUT|Error|error/.test(l));
  for (const l of keep.slice(0, 40)) log(l);

  const ok = /RESULT:\s*PASS/.test(out) && !/TIMEOUT/.test(out) && !/Errors:\s*[1-9]/.test(out);
  if (ok) { pass += 1; log(`--> ${tb} PASS`); }
  else { fail += 1; failed.push(`${tb}（结果不通过，日志 ${relative(ROOT, vsimLog)}）`); log(`--> ${tb} FAIL`); }
}

log('\n================================================');
log(`通过 ${pass} / 失败 ${fail}`);
if (failed.length) for (const f of failed) log(`  FAIL: ${f}`);
process.exit(fail ? 1 : 0);
