#!/usr/bin/env node
/**
 * tools/td_build.mjs —— 用 Tang Dynasty 6.2.1 的命令行流程构建本工程
 *
 * 背景：TD 的 GUI 会为每个 Run 生成 settings.cfg，然后用
 *       `<TD>/doc/scripts/DefaultFlow.tcl` 驱动整个流程。
 *       本脚本复刻这件事：生成 .al / .prj / settings.cfg，再调用同一个 DefaultFlow.tcl。
 *       不依赖 GUI，可重复、可 CI。
 *
 * 用法：
 *   node tools/td_build.mjs                  # 综合 + 布局布线 + 位流（全部）
 *   node tools/td_build.mjs --step syn       # 只做综合（到 opt_gate）
 *   node tools/td_build.mjs --dry            # 只生成工程文件，不调用 TD
 *   node tools/td_build.mjs --clean          # 清掉 build/<name>/
 *
 * 目录布局（刻意镜像官方例程，因为厂商黑盒里写死了 include 路径）：
 *   build/<name>/
 *     user_source/hdl_source/include/global_def.v   ← 兼容 shim
 *     td_project/
 *       <name>.al
 *       <name>_Runs/syn_1/{<name>.prj, settings.cfg}
 *       <name>_Runs/phy_1/{<name>.prj, settings.cfg}
 *
 * 配置文件：prj/prj.json
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, readdirSync, statSync, copyFileSync } from 'node:fs';
import { join, dirname, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const TD_HOME = process.env.TD_HOME || 'D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116';
const TD_BIN = join(TD_HOME, 'bin', 'td_commands_prompt.exe');
const TD_FLOW = join(TD_HOME, 'doc', 'scripts', 'DefaultFlow.tcl');

const argv = process.argv.slice(2);
const hasFlag = (f) => argv.includes(f);
const getOpt = (f, d) => {
  const i = argv.indexOf(f);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : d;
};

const log = (...a) => console.log(...a);
const die = (msg) => {
  console.error(`\n[错误] ${msg}\n`);
  process.exit(1);
};

// ---------------------------------------------------------------- 配置读取

const cfgPath = join(ROOT, 'prj', 'prj.json');
if (!existsSync(cfgPath)) die(`找不到工程配置 ${cfgPath}`);
const cfg = JSON.parse(readFileSync(cfgPath, 'utf8'));

const NAME = getOpt('--name', cfg.name);
if (!NAME) die('prj.json 里必须给 name');

const BUILD_ROOT = join(ROOT, 'build', NAME);
const PROJ_DIR = join(BUILD_ROOT, 'td_project');
const RUNS_DIR = join(PROJ_DIR, `${NAME}_Runs`);

if (hasFlag('--clean')) {
  if (existsSync(BUILD_ROOT)) {
    rmSync(BUILD_ROOT, { recursive: true, force: true });
    log(`已删除 ${relative(ROOT, BUILD_ROOT)}`);
  } else {
    log('没有可删除的构建目录');
  }
  process.exit(0);
}

// ---------------------------------------------------------------- 工具函数

/** 递归收集某目录下的指定扩展名文件（返回仓库相对路径，正斜杠） */
function collect(dir, exts, out = []) {
  const abs = join(ROOT, dir);
  if (!existsSync(abs)) return out;
  for (const name of readdirSync(abs)) {
    const p = join(abs, name);
    const st = statSync(p);
    if (st.isDirectory()) collect(join(dir, name), exts, out);
    else if (exts.some((e) => name.toLowerCase().endsWith(e))) {
      out.push(join(dir, name).split(sep).join('/'));
    }
  }
  return out;
}

const xmlEscape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/**
 * 生成 .al / .prj 共用的 XML。
 * relBase: 源文件路径相对于「该 XML 文件所在目录」的前缀，例如 '../../../'
 */
function projectXml({ relBase, runtime }) {
  const verilog = [
    ...collect(cfg.sourcesRtl || 'src/rtl', ['.v', '.sv']),
    ...collect(cfg.sourcesVendor || 'src/vendor', ['.v', '.sv', '.enc.v']),
    ...(cfg.sourcesExtra || []),
  ];
  // 去重 + 保序
  const files = [...new Set(verilog)];
  if (!files.length) die('没有收集到任何 Verilog 源文件');

  const missing = files.filter((f) => !existsSync(join(ROOT, f)));
  if (missing.length) die(`以下源文件不存在：\n  ${missing.join('\n  ')}`);

  const constr = [...(cfg.adc || []), ...(cfg.sdc || [])];
  const missingC = constr.filter((f) => !existsSync(join(ROOT, f)));
  if (missingC.length) die(`以下约束文件不存在：\n  ${missingC.join('\n  ')}`);

  let order = 0;
  const vBlocks = files
    .map((f) => {
      order += 1;
      return `            <File Path="${xmlEscape(relBase + f)}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&amp;R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="${order * 10}"/>
                </FileInfo>
            </File>`;
    })
    .join('\n');

  let cOrder = 0;
  const adcBlocks = (cfg.adc || [])
    .map((f) => {
      cOrder += 1;
      return `            <File Path="${xmlEscape(relBase + f)}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&amp;R" Val="true"/>
                    <Attr Name="BelongTo" Val="constraint_1"/>
                    <Attr Name="CompileOrder" Val="${cOrder}"/>
                </FileInfo>
            </File>`;
    })
    .join('\n');
  const sdcBlocks = (cfg.sdc || [])
    .map((f) => {
      cOrder += 1;
      return `            <File Path="${xmlEscape(relBase + f)}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&amp;R" Val="true"/>
                    <Attr Name="BelongTo" Val="constraint_1"/>
                    <Attr Name="CompileOrder" Val="${cOrder}"/>
                </FileInfo>
            </File>`;
    })
    .join('\n');

  const runtimeAttr = runtime ? ` RunTime="${runtime}"` : '';

  return `<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2"${runtimeAttr}>
    <Project_Created_Time></Project_Created_Time>
    <TD_Version>6.2.168116</TD_Version>
    <Name>${xmlEscape(NAME)}</Name>
    <HardWare>
        <Family>EG4</Family>
        <Device>${xmlEscape(cfg.deviceChip || 'EG4S20BG256')}</Device>
        <Speed></Speed>
    </HardWare>
    <Source_Files>
        <Verilog>
${vBlocks}
        </Verilog>
        <ADC_FILE>
${adcBlocks}
        </ADC_FILE>
        <SDC_FILE>
${sdcBlocks}
        </SDC_FILE>
    </Source_Files>
    <FileSets>
        <FileSet Name="design_1" Type="DesignFiles">
        </FileSet>
        <FileSet Name="constraint_1" Type="ConstrainFiles">
        </FileSet>
    </FileSets>
    <TOP_MODULE>
        <LABEL>${xmlEscape(cfg.top || 'top')}</LABEL>
        <MODULE>${xmlEscape(cfg.top || 'top')}</MODULE>
        <CREATEINDEX>user</CREATEINDEX>
    </TOP_MODULE>
    <Property>
    </Property>
    <Device_Settings>
    </Device_Settings>
    <Configurations>
    </Configurations>
    <Runs>
        <Run Name="syn_1" Type="Synthesis" ConstraintSet="constraint_1" Description="" Active="true">
            <Strategy Name="Default_Synthesis_Strategy">
            </Strategy>
            <UserParams>
            </UserParams>
        </Run>
        <Run Name="phy_1" Type="PhysicalDesign" ConstraintSet="constraint_1" Description="" SynRun="syn_1" Active="true">
            <Strategy Name="Default_PhysicalDesign_Strategy">
                <RouteProperty>
                    <fix_hold>on</fix_hold>
                </RouteProperty>
            </Strategy>
            <UserParams>
            </UserParams>
        </Run>
    </Runs>
    <Project_Settings>
    </Project_Settings>
</Project>
`;
}

function settingsCfg(stage) {
  // run 目录是 build/<name>/td_project/<name>_Runs/<stage>/ —— 回到仓库根要上 5 层
  const base = '../../../../../';
  const adcList = (cfg.adc || []).map((f) => `"${base}${f}"`).join(' ');
  const sdcList = (cfg.sdc || []).map((f) => `"${base}${f}"`).join(' ');
  const common = `# 由 tools/td_build.mjs 生成，勿手改
set ADCList {${adcList}}
set SDCList {${sdcList}}
set area_option -packarea
set device_name ${cfg.device || 'eagle_s20.db'}
set package_name ${cfg.package || 'EG4S20BG256'}
set prj_name {${NAME}}
set run_type ${stage === 'syn' ? 'syn' : 'phy'}
set top_model_name {${cfg.top || 'top'}}
`;
  if (stage === 'syn') {
    return common + `set start_step read_design\nset end_step opt_gate\n`;
  }
  return (
    common +
    `set parent ../syn_1
set arr_filter false
set drHoldFix on
set start_step opt_place
set end_step bitgen
`
  );
}

function runStage(stage, dry) {
  const runDir = join(RUNS_DIR, stage === 'syn' ? 'syn_1' : 'phy_1');
  mkdirSync(runDir, { recursive: true });

  // .prj：源文件路径相对 run 目录（syn_1 -> _Runs -> td_project -> <name> -> build -> 仓库根 = 5 层）
  const relBase = `${'../'.repeat(5)}`;

  // 自检：拼出来的路径必须真的存在，否则 TD 只会给一句 "Can't find this file"
  for (const f of [
    ...collect(cfg.sourcesRtl || 'src/rtl', ['.v', '.sv']),
    ...collect(cfg.sourcesVendor || 'src/vendor', ['.v', '.sv', '.enc.v']),
    ...(cfg.sourcesExtra || []),
    ...(cfg.adc || []),
    ...(cfg.sdc || []),
  ]) {
    const resolved = resolve(runDir, relBase + f);
    if (!existsSync(resolved)) {
      die(`路径自检失败：run 目录 ${relative(ROOT, runDir)}\n  拼出 ${relBase + f}\n  解析到 ${resolved}\n  该文件不存在。检查 prj.json 与 td_build.mjs 的相对层级。`);
    }
  }

  const prjXml = projectXml({ relBase, runtime: new Date().toISOString().slice(0, 19) });
  writeFileSync(join(runDir, `${NAME}.prj`), prjXml, 'utf8');
  writeFileSync(join(runDir, 'settings.cfg'), settingsCfg(stage), 'utf8');

  if (dry) {
    log(`[dry] 已生成 ${relative(ROOT, runDir)}`);
    return true;
  }

  log(`\n=== ${stage === 'syn' ? '综合' : '布局布线+位流'} @ ${relative(ROOT, runDir)} ===`);
  const r = spawnSync(TD_BIN, [TD_FLOW.split(sep).join('/')], {
    cwd: runDir,
    stdio: 'inherit',
    windowsHide: true,
  });
  if (r.error) die(`调用 TD 失败：${r.error.message}`);
  if (r.status !== 0) {
    log(`\n[失败] ${stage} 退出码 ${r.status}`);
    return false;
  }

  // TD 在部分 Tcl 错误（例如 ADC 语法错误）后会返回 0，必须按实际产物判定。
  const produced = stage === 'syn'
    ? existsSync(join(runDir, `${NAME}_gate.db`))
    : readdirSync(runDir).some((f) => f.endsWith('.bit'));
  if (!produced) {
    log(`\n[失败] ${stage} 已结束，但没有生成预期产物`);
    return false;
  }

  log(`[完成] ${stage}`);
  return true;
}

// ---------------------------------------------------------------- 主流程

log(`工程：${NAME}`);
log(`器件：${cfg.deviceChip || 'EG4S20BG256'}  顶层：${cfg.top || 'top'}`);
log(`TD  ：${TD_HOME}`);

if (!existsSync(TD_BIN)) die(`找不到 ${TD_BIN}`);
if (!existsSync(TD_FLOW)) die(`找不到 ${TD_FLOW}`);

// 兼容 shim：厂商加密黑盒里的 `include 有两种写法，必须同时满足：
//   sdr_as_ram.enc.v(10) : `include "global_def.v"                              <- 裸文件名
//   sdr_init_ref.enc.v(11): `include "../user_source/hdl_source/include/global_def.v"  <- 相对「工程目录」
// 实测 TD 对裸文件名的搜索路径不稳定（依赖别的源文件是否先解析过同名目录），
// 因此直接两处都放：build/<name>/<dst> 与 build/<name>/td_project/<basename>。
mkdirSync(PROJ_DIR, { recursive: true });
if (cfg.shim) {
  for (const [dst, src] of Object.entries(cfg.shim)) {
    const srcAbs = join(ROOT, src);
    const dstAbs = join(BUILD_ROOT, dst);
    mkdirSync(dirname(dstAbs), { recursive: true });
    copyFileSync(srcAbs, dstAbs);
    const bare = join(PROJ_DIR, dst.split('/').pop());
    copyFileSync(srcAbs, bare);
  }
  log(`shim：${Object.keys(cfg.shim).join(', ')}  ->  build/${NAME}/ 与 build/${NAME}/td_project/`);
}

// .al：路径相对 td_project/（两级回到 build/<name>/，再上到仓库根）
writeFileSync(join(PROJ_DIR, `${NAME}.al`), projectXml({ relBase: `${'../'.repeat(3)}` }), 'utf8');
log(`已生成 ${relative(ROOT, join(PROJ_DIR, NAME + '.al'))}`);

const dry = hasFlag('--dry');
const step = getOpt('--step', 'all');

if (dry) {
  runStage('syn', true);
  if (step === 'all') runStage('phy', true);
  log('\n[dry] 未调用 TD。去掉 --dry 才真正构建。');
  process.exit(0);
}

if (!runStage('syn', false)) process.exit(1);
if (step !== 'syn') {
  if (!runStage('phy', false)) process.exit(1);
}

// 汇报产物
const find = (dir, ext) => {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(ext))
    .map((f) => join(dir, f));
};
const bits = find(join(RUNS_DIR, 'phy_1'), '.bit');
log('\n=== 产物 ===');
if (bits.length) for (const b of bits) log(`位流：${relative(ROOT, b)}`);
else log('（本次没有跑到 bitgen，未产生位流）');
for (const rpt of ['gate.qor', 'place.qor', 'route.qor']) {
  const p = join(RUNS_DIR, 'phy_1', rpt);
  const q = join(RUNS_DIR, 'syn_1', rpt);
  const use = existsSync(p) ? p : existsSync(q) ? q : null;
  if (use) log(`报告：${relative(ROOT, use)}`);
}
