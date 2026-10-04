// tools/lib/hdl.mjs
// 从 Verilog / SystemVerilog / VHDL 中提取模块接口，生成"模块地图"。
// 目标：让 AI 不读全部源码就能知道每个模块的端口、参数、例化关系。

/* ------------------------------------------------------------------ */
/* 注释剥离（保留换行，以便行号准确）                                    */
/* ------------------------------------------------------------------ */
export function stripComments(src, lang) {
  let out = '';
  let i = 0;
  const n = src.length;
  const lineComment = lang === 'vhdl' ? '--' : '//';
  const blockComment = lang === 'vhdl'; // VHDL 用 -- 行注释，另有 (* *)

  while (i < n) {
    const c = src[i];

    // 行注释
    if (src.startsWith(lineComment, i)) {
      while (i < n && src[i] !== '\n') { out += ' '; i++; }
      continue;
    }
    // 块注释 /* */ (Verilog)
    if (!blockComment && c === '/' && src[i + 1] === '*') {
      out += '  '; i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) {
        out += (src[i] === '\n' ? '\n' : ' '); i++;
      }
      out += '  '; i += 2;
      continue;
    }
    // VHDL (* *)
    if (blockComment && c === '(' && src[i + 1] === '*') {
      out += '  '; i += 2;
      let depth = 1;
      while (i < n && depth > 0) {
        if (src[i] === '(' && src[i + 1] === '*') { depth++; out += '  '; i += 2; continue; }
        if (src[i] === '*' && src[i + 1] === ')') { depth--; out += '  '; i += 2; continue; }
        out += (src[i] === '\n' ? '\n' : ' '); i++;
      }
      continue;
    }
    // 字符串
    if (c === '"' && !blockComment) {
      out += ' '; i++;
      while (i < n && src[i] !== '"') {
        if (src[i] === '\\') { out += '  '; i += 2; continue; }
        out += (src[i] === '\n' ? '\n' : ' '); i++;
      }
      out += ' '; i++;
      continue;
    }
    out += c; i++;
  }
  return out;
}

function lineOf(s, idx) {
  let n = 1;
  for (let i = 0; i < idx && i < s.length; i++) if (s[i] === '\n') n++;
  return n;
}

/** s[start] === '(' → 返回匹配的 ')' 下标 */
function matchParen(s, start) {
  let d = 0;
  for (let i = start; i < s.length; i++) {
    if (s[i] === '(') d++;
    else if (s[i] === ')') { d--; if (d === 0) return i; }
  }
  return -1;
}

/** 按顶层分隔符切分（忽略括号内） */
function splitTop(s, sep = ',') {
  const parts = [];
  let d = 0, cur = '';
  for (const ch of s) {
    if (ch === '(' || ch === '[' || ch === '{') d++;
    else if (ch === ')' || ch === ']' || ch === '}') d--;
    if (ch === sep && d === 0) { parts.push(cur); cur = ''; continue; }
    cur += ch;
  }
  parts.push(cur);
  return parts;
}

/** 按顶层 ';' 切分成语句 */
function splitStatements(s) {
  return splitTop(s, ';');
}

/* ------------------------------------------------------------------ */
/* Verilog / SystemVerilog                                             */
/* ------------------------------------------------------------------ */
function parseVerilogParams(raw) {
  const out = [];
  if (!raw) return out;
  for (const chunk of splitTop(raw)) {
    const c = chunk.trim();
    if (!c) continue;
    let m = /^(?:parameter|localparam)\s+(?:type\s+)?(?:integer\s+|int\s+|signed\s+|unsigned\s+|\[[^\]]*\]\s*)*([A-Za-z_]\w*)\s*=\s*([\s\S]+)$/.exec(c);
    if (!m) m = /^([A-Za-z_]\w*)\s*=\s*([\s\S]+)$/.exec(c);
    if (m) out.push({ name: m[1], value: m[2].trim().replace(/\s+/g, ' ').slice(0, 80) });
  }
  return out;
}

function parseVerilogPortsAnsi(raw) {
  const ports = [];
  let dir = null, width = null, type = null, signed = false;
  for (const chunk of splitTop(raw)) {
    let c = chunk.trim();
    if (!c) continue;
    const dm = /^(input|output|inout|ref)\b/.exec(c);
    if (dm) {
      dir = dm[1] === 'ref' ? 'inout' : dm[1];
      c = c.slice(dm[1].length).trim();
      width = null; type = null; signed = false;
    }
    if (!dir) continue;
    const wm = /(\[[^\]]*\])/.exec(c);
    if (wm) { width = wm[1].replace(/\s+/g, ''); c = c.replace(wm[1], ' ').trim(); }
    let tm;
    while ((tm = /^(wire|reg|logic|bit|var|signed|unsigned|static|automatic)\b/.exec(c))) {
      const kw = tm[1];
      if (kw === 'signed') signed = true;
      else if (kw === 'unsigned') signed = false;
      else type = kw;
      c = c.slice(kw.length).trim();
    }
    const nm = /^([A-Za-z_]\w*)\s*((?:\[[^\]]*\]\s*)*)/.exec(c);
    if (!nm) continue;
    ports.push({
      dir, width, signed,
      type: type || 'wire',
      name: nm[1],
      dims: (nm[2] || '').replace(/\s+/g, '') || null,
    });
  }
  return ports;
}

function parseVerilogPortsNonAnsi(namesRaw, body) {
  const names = splitTop(namesRaw)
    .map(x => x.trim())
    .filter(Boolean)
    .map(x => { const m = /^([A-Za-z_]\w*)/.exec(x); return m ? m[1] : null; })
    .filter(Boolean);

  const map = new Map(names.map(n => [n, { dir: null, width: null, type: null, signed: false, name: n, dims: null }]));

  for (const stmt of splitStatements(body)) {
    const m = /^\s*(input|output|inout)\b([\s\S]*)$/.exec(stmt);
    if (!m) continue;
    const dir = m[1];
    let rest = m[2];
    let width = null, type = null;
    const wm = /(\[[^\]]*\])/.exec(rest);
    if (wm) { width = wm[1].replace(/\s+/g, ''); rest = rest.replace(wm[1], ' '); }
    let tm;
    while ((tm = /^\s*(wire|reg|logic|bit|var)\b/.exec(rest))) {
      type = tm[1]; rest = rest.slice(tm[0].length);
    }
    for (const piece of rest.split(',')) {
      const id = /^\s*([A-Za-z_]\w*)/.exec(piece);
      if (!id) continue;
      const p = map.get(id[1]);
      if (p) { p.dir = dir; p.width = width; p.type = type || 'wire'; }
    }
  }

  // body 里单独的 reg 声明，用于补全 output 的类型
  for (const stmt of splitStatements(body)) {
    const m = /^\s*reg\b([\s\S]*)$/.exec(stmt);
    if (!m) continue;
    let rest = m[1];
    const wm = /(\[[^\]]*\])/.exec(rest);
    const width = wm ? wm[1].replace(/\s+/g, '') : null;
    if (wm) rest = rest.replace(wm[1], ' ');
    for (const piece of rest.split(',')) {
      const id = /^\s*([A-Za-z_]\w*)/.exec(piece);
      if (!id) continue;
      const p = map.get(id[1]);
      if (p && p.dir === 'output') { p.type = 'reg'; if (!p.width) p.width = width; }
    }
  }

  // 保留顺序，未声明的方向标为 '?'
  return names.map(n => {
    const p = map.get(n);
    return p.dir ? p : { ...p, dir: '?' };
  });
}

export function parseVerilog(src, file) {
  const s = stripComments(src, 'sv');
  const mods = [];
  const re = /\bmodule\b/g;
  let m;
  while ((m = re.exec(s))) {
    let i = m.index + 6;
    while (i < s.length && /\s/.test(s[i])) i++;
    const nm = /^([A-Za-z_]\w*)/.exec(s.slice(i, i + 256));
    if (!nm) continue;
    const name = nm[1];
    i += nm[1].length;

    let j = i;
    while (j < s.length && /\s/.test(s[j])) j++;

    // 可选 #( parameter ... )
    let paramsRaw = '';
    if (s[j] === '#') {
      j++;
      while (j < s.length && /\s/.test(s[j])) j++;
      if (s[j] === '(') {
        const e = matchParen(s, j);
        if (e > 0) { paramsRaw = s.slice(j + 1, e); j = e + 1; }
      }
    }

    while (j < s.length && /\s/.test(s[j])) j++;

    // 可选端口表 ( ... )
    let portsRaw = null;
    if (s[j] === '(') {
      const e = matchParen(s, j);
      if (e > 0) { portsRaw = s.slice(j + 1, e); j = e + 1; }
    }

    const semi = s.indexOf(';', j);
    const bodyStart = semi >= 0 ? semi + 1 : j;
    const endIdx = s.indexOf('endmodule', bodyStart);
    const bodyEnd = endIdx > 0 ? endIdx : s.length;
    const body = s.slice(bodyStart, bodyEnd);

    const header = portsRaw || '';
    const isAnsi = /(^|[\s(,])(input|output|inout)\b/.test(header);
    const ports = !header.trim()
      ? []
      : (isAnsi ? parseVerilogPortsAnsi(header) : parseVerilogPortsNonAnsi(header, body));

    mods.push({
      lang: 'verilog',
      name,
      file,
      line: lineOf(s, m.index),
      params: parseVerilogParams(paramsRaw),
      ports,
      ansi: isAnsi,
      bodyStart,
      bodyEnd,
      instantiations: [],
    });
  }
  return mods;
}

/* ------------------------------------------------------------------ */
/* VHDL                                                                */
/* ------------------------------------------------------------------ */
function vhdlWidth(typeStr) {
  const m = /std_logic_vector\s*\(\s*([^)]+?)\s+(?:downto|to)\s+([^)]+?)\s*\)/i.exec(typeStr);
  if (m) return '[' + m[1].trim() + ':' + m[2].trim() + ']';
  if (/std_logic\b/i.test(typeStr)) return null;
  const m2 = /(?:unsigned|signed)\s*\(\s*([^)]+?)\s+(?:downto|to)\s+([^)]+?)\s*\)/i.exec(typeStr);
  if (m2) return '[' + m2[1].trim() + ':' + m2[2].trim() + ']';
  return null;
}

export function parseVhdl(src, file) {
  const s = stripComments(src, 'vhdl');
  const ents = [];
  const re = /\bentity\s+([A-Za-z_]\w*)\s+is\b/gi;
  let m;
  while ((m = re.exec(s))) {
    const name = m[1];
    const rest = s.slice(m.index);
    const generics = [];
    const ports = [];

    const gm = /\bgeneric\s*\(/i.exec(rest);
    if (gm && gm.index < 2000) {
      const open = rest.indexOf('(', gm.index);
      const close = matchParen(rest, open);
      if (close > 0) {
        for (const decl of splitStatements(rest.slice(open + 1, close))) {
          const d = /^\s*([\w\s,]+?)\s*:\s*([\w.]+)\s*(?::=\s*([\s\S]+))?$/.exec(decl);
          if (!d) continue;
          const val = (d[3] || '').trim().replace(/\s+/g, ' ').slice(0, 60) || '-';
          for (const n of d[1].split(',')) generics.push({ name: n.trim(), type: d[2], value: val });
        }
      }
    }

    const pm = /\bport\s*\(/i.exec(rest);
    if (pm && pm.index < 4000) {
      const open = rest.indexOf('(', pm.index);
      const close = matchParen(rest, open);
      if (close > 0) {
        for (const decl of splitStatements(rest.slice(open + 1, close))) {
          const d = /^\s*([\w\s,]+?)\s*:\s*(in|out|inout|buffer|linkage)\s+([\s\S]+)$/i.exec(decl);
          if (!d) continue;
          const dir = d[2].toLowerCase() === 'in' ? 'input'
            : d[2].toLowerCase() === 'out' ? 'output' : 'inout';
          const typeStr = d[3].trim().replace(/\s+/g, ' ');
          // 基础类型名去掉范围部分，避免和 width 列重复
          const baseType = typeStr.replace(/\s*\(.*$/, '').trim();
          for (const n of d[1].split(',')) {
            ports.push({
              dir, name: n.trim(), width: vhdlWidth(typeStr),
              type: baseType, signed: false, dims: null,
            });
          }
        }
      }
    }

    ents.push({
      lang: 'vhdl', name, file, line: lineOf(s, m.index),
      params: generics, ports, ansi: true, instantiations: [],
    });
  }
  return ents;
}

/* ------------------------------------------------------------------ */
/* 统一入口                                                            */
/* ------------------------------------------------------------------ */
export function parseHdl(src, file) {
  const ext = (file.split('.').pop() || '').toLowerCase();
  if (ext === 'vhd' || ext === 'vhdl') return parseVhdl(src, file);
  return parseVerilog(src, file);
}

/* ------------------------------------------------------------------ */
/* 例化关系提取                                                        */
/* ------------------------------------------------------------------ */
const KEYWORDS = new Set([
  'module', 'endmodule', 'input', 'output', 'inout', 'wire', 'reg', 'logic',
  'assign', 'always', 'always_ff', 'always_comb', 'always_latch', 'initial',
  'begin', 'end', 'if', 'else', 'case', 'casex', 'casez', 'endcase', 'for',
  'while', 'repeat', 'forever', 'generate', 'endgenerate', 'genvar', 'localparam',
  'parameter', 'defparam', 'function', 'endfunction', 'task', 'endtask', 'posedge',
  'negedge', 'or', 'and', 'not', 'xor', 'nand', 'nor', 'xnor', 'buf', 'default',
  'signed', 'unsigned', 'integer', 'real', 'time', 'return', 'break', 'continue',
  'typedef', 'enum', 'struct', 'union', 'packed', 'interface', 'endinterface',
  'package', 'endpackage', 'import', 'export', 'class', 'endclass', 'new', 'this',
  'super', 'extends', 'virtual', 'pure', 'extern', 'static', 'automatic', 'const',
  'ref', 'bit', 'byte', 'shortint', 'int', 'longint', 'string', 'void', 'type',
  'wait', 'disable', 'fork', 'join', 'join_any', 'join_none', 'specify', 'endspecify',
  'primitive', 'endprimitive', 'table', 'endtable', 'config', 'endconfig',
  'property', 'endproperty', 'sequence', 'endsequence', 'assert', 'assume', 'cover',
  'library', 'use', 'entity', 'architecture', 'signal', 'constant', 'process',
  'component', 'port', 'map', 'generic', 'is', 'of', 'others', 'downto', 'to',
]);

/** VHDL 关键字（单独一套，避免污染 Verilog 的模块名判断） */
const VHDL_KEYWORDS = new Set([
  'in', 'out', 'inout', 'buffer', 'linkage', 'signal', 'variable', 'constant',
  'type', 'subtype', 'architecture', 'begin', 'end', 'process', 'if', 'then',
  'else', 'elsif', 'when', 'case', 'is', 'of', 'others', 'downto', 'to',
  'and', 'or', 'not', 'xor', 'nand', 'nor', 'xnor', 'mod', 'rem', 'abs',
  'after', 'wait', 'until', 'for', 'loop', 'generate', 'generic', 'map',
  'port', 'component', 'entity', 'function', 'procedure', 'return', 'package',
  'body', 'use', 'library', 'all', 'std_logic', 'std_logic_vector', 'integer',
  'natural', 'positive', 'boolean', 'bit', 'bit_vector', 'signed', 'unsigned',
  'rising_edge', 'falling_edge', 'null', 'open', 'report', 'severity',
  'assert', 'with', 'select', 'attribute', 'alias', 'array', 'record',
  'access', 'file', 'shared', 'pure', 'impure', 'protected', 'new', 'next',
  'exit', 'range', 'reverse_range', 'work', 'std', 'ieee', 'numeric_std',
]);

/** 返回 { internal: [{name, inst, file, index}], external: [{name, count}] } */
export function findInstantiations(source, file, knownModules) {
  const ext = (file.split('.').pop() || '').toLowerCase();
  const isVhdl = ext === 'vhd' || ext === 'vhdl';
  const s = stripComments(source, isVhdl ? 'vhdl' : 'sv');

  const internal = [];
  const externalCount = new Map();

  if (isVhdl) {
    // VHDL 例化必须带 port map / generic map，否则就是信号声明
    const re = /\b([A-Za-z_]\w*)\s*:\s*(?:entity\s+)?([A-Za-z_][\w.]*)\s*(?:generic\s+map|port\s+map)\b/gi;
    let m;
    while ((m = re.exec(s))) {
      const label = m[1];
      const comp = m[2].split('.').pop(); // 去掉 work. / ieee. 前缀
      if (VHDL_KEYWORDS.has(label.toLowerCase()) || VHDL_KEYWORDS.has(comp.toLowerCase())) continue;
      if (knownModules.has(comp)) {
        internal.push({ name: comp, inst: label, file, index: m.index });
      } else if (/^[A-Za-z]/.test(comp)) {
        externalCount.set(comp, (externalCount.get(comp) || 0) + 1);
      }
    }
  } else {
    // 模块名与实例名之间必须有空白，否则 "refclk (" 会被误拆成 "refcl" + "k" + "("
    const re = /\b([A-Za-z_]\w*)(\s*#\s*\([^;]*?\))?\s+([A-Za-z_]\w*)\s*\(/g;
    let m;
    while ((m = re.exec(s))) {
      const mod = m[1], inst = m[3];
      if (KEYWORDS.has(mod) || KEYWORDS.has(inst)) continue;
      const before = s.slice(Math.max(0, m.index - 24), m.index);
      if (/\bmodule\s*$/.test(before)) continue;
      if (knownModules.has(mod)) {
        internal.push({ name: mod, inst, file, index: m.index });
      } else if (/^[A-Z]/.test(mod)) {
        // 大写开头的未知模块 → 很可能是厂商原语 / IP
        externalCount.set(mod, (externalCount.get(mod) || 0) + 1);
      }
    }
  }

  return {
    internal,
    external: [...externalCount.entries()].map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count),
  };
}

/* ------------------------------------------------------------------ */
/* 渲染：模块接口紧凑表（省 token 且好读）                              */
/* ------------------------------------------------------------------ */
export function renderPorts(mod) {
  if (!mod.ports.length) return '  (无端口)';
  const dirs = mod.ports.map(p => p.dir || '?');
  const types = mod.ports.map(p => p.type || '');
  const widths = mod.ports.map(p => p.width || '');
  const longest = arr => arr.reduce((a, s) => Math.max(a, s.length), 0);
  const wd = Math.max(3, longest(dirs));
  const wt = longest(types);
  const ww = longest(widths);
  const rows = mod.ports.map((p, i) => {
    let line = dirs[i].padEnd(wd);
    if (wt) line += ' ' + types[i].padEnd(wt);
    if (ww) line += ' ' + widths[i].padEnd(ww);
    return (line + ' ' + p.name + (p.dims || '')).replace(/\s+$/, '');
  });
  return '```\n' + rows.join('\n') + '\n```';
}

export { KEYWORDS, VHDL_KEYWORDS };
