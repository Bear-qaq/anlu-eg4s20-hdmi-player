#!/usr/bin/env node
// tools/pdftext.mjs
// 从 PDF 里提取文字（含中文），纯 Node 实现，无第三方依赖。
//
// 原理：解析对象 → 解 FlateDecode 内容流 → 按 Tj/TJ 取字符串 →
//       经字体的 ToUnicode CMap 把 CID 码位映射回 Unicode。
//
// 用法：
//   node tools/pdftext.mjs <输入.pdf> [输出.md]     # 输出 markdown
//   node tools/pdftext.mjs <输入.pdf> --pages=1-3   # 只要前 3 页
//   node tools/pdftext.mjs <输入.pdf> --probe       # 只看结构，不提取

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

/* ------------------------------------------------------------------ */
/* 对象解析                                                            */
/* ------------------------------------------------------------------ */
function parsePdf(buf) {
  const s = buf.toString('latin1');   // 1 字节 ↔ 1 字符，保偏移
  const objects = new Map();

  const re = /(\d+)\s+(\d+)\s+obj\b/g;
  let m;
  while ((m = re.exec(s))) {
    const num = parseInt(m[1], 10);
    const bodyStart = m.index + m[0].length;
    const endIdx = s.indexOf('endobj', bodyStart);
    if (endIdx < 0) continue;

    const chunk = s.slice(bodyStart, endIdx);
    const streamMark = /\bstream\r?\n/.exec(chunk);
    let dict = chunk, stream = null;

    if (streamMark) {
      dict = chunk.slice(0, streamMark.index);
      const dataStart = bodyStart + streamMark.index + streamMark[0].length;
      const endStream = s.indexOf('endstream', dataStart);
      let len = null;
      const lm = /\/Length\s+(\d+)(?:\s+(\d+)\s+R)?/.exec(dict);
      if (lm) {
        len = lm[2] ? null : parseInt(lm[1], 10);   // 间接长度稍后解析
        if (lm[2]) dict += `\u0000REFLEN:${lm[1]}`;
      }
      if (len != null && dataStart + len <= s.length) {
        stream = buf.subarray(dataStart, dataStart + len);
      } else {
        stream = buf.subarray(dataStart, endStream < 0 ? s.length : endStream);
      }
    }
    objects.set(num, { num, dict, stream, raw: chunk });
  }

  // 解析间接 /Length
  for (const o of objects.values()) {
    const rm = /\u0000REFLEN:(\d+)/.exec(o.dict);
    if (rm && o.stream) {
      const target = objects.get(parseInt(rm[1], 10));
      if (target) {
        const val = parseInt((target.raw.match(/^\s*(\d+)/) || [])[1], 10);
        if (!Number.isNaN(val) && val <= o.stream.length) o.stream = o.stream.subarray(0, val);
      }
      o.dict = o.dict.replace(/\u0000REFLEN:\d+/, '');
    }
  }
  return { objects, src: s };
}

function resolve(objects, ref) {
  const m = /^(\d+)\s+\d+\s+R$/.exec(String(ref).trim());
  if (m) return objects.get(parseInt(m[1], 10));
  return null;
}

function decodeStream(obj) {
  if (!obj || !obj.stream) return null;
  const d = obj.dict;
  try {
    if (/\/FlateDecode/.test(d)) {
      let data = zlib.inflateSync(obj.stream);
      // 有些 PDF 会套两层
      if (/\/FlateDecode/.test(d.slice(d.indexOf('/FlateDecode') + 12))) {
        try { data = zlib.inflateSync(data); } catch { /* 忽略 */ }
      }
      return data;
    }
    if (!/\/Filter/.test(d)) return obj.stream;
  } catch (e) {
    return null;
  }
  return null;   // DCTDecode 等图像流不解
}

/* ------------------------------------------------------------------ */
/* ToUnicode CMap                                                      */
/* ------------------------------------------------------------------ */
function hexToUnicode(h) {
  let out = '';
  for (let i = 0; i + 4 <= h.length; i += 4) {
    const code = parseInt(h.slice(i, i + 4), 16);
    if (!Number.isNaN(code)) out += String.fromCharCode(code);
  }
  // 处理落单的 2 位
  if (h.length % 4 === 2) {
    const code = parseInt(h.slice(-2), 16);
    if (!Number.isNaN(code)) out += String.fromCharCode(code);
  }
  return out;
}

function parseCMap(text) {
  const map = new Map();
  let m;
  const bfchar = /beginbfchar([\s\S]*?)endbfchar/g;
  while ((m = bfchar.exec(text))) {
    const re = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g;
    let x;
    while ((x = re.exec(m[1]))) {
      map.set(parseInt(x[1], 16), hexToUnicode(x[2]));
    }
  }
  const bfrange = /beginbfrange([\s\S]*?)endbfrange/g;
  while ((m = bfrange.exec(text))) {
    const re = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]+>|\[[^\]]*\])/g;
    let x;
    while ((x = re.exec(m[1]))) {
      const lo = parseInt(x[1], 16), hi = parseInt(x[2], 16);
      if (x[3][0] === '[') {
        [...x[3].matchAll(/<([0-9A-Fa-f]+)>/g)].forEach((y, i) => map.set(lo + i, hexToUnicode(y[1])));
      } else {
        const base = parseInt(x[3].slice(1, -1), 16);
        for (let i = 0; i <= hi - lo; i++) map.set(lo + i, String.fromCharCode(base + i));
      }
    }
  }
  return map;
}

/* ------------------------------------------------------------------ */
/* 页面 → 字体表                                                       */
/* ------------------------------------------------------------------ */
function buildFontMaps(pdf, resourcesDict) {
  const maps = new Map();   // 资源名 → { map, twoByte }
  const fm = /\/Font\s*<<([\s\S]*?)>>/.exec(resourcesDict);
  if (!fm) return maps;

  const re = /\/([A-Za-z0-9#+._-]+)\s+(\d+)\s+\d+\s+R/g;
  let m;
  while ((m = re.exec(fm[1]))) {
    const name = m[1];
    const font = pdf.objects.get(parseInt(m[2], 10));
    if (!font) continue;

    const twoByte = /\/Subtype\s*\/Type0/.test(font.dict);
    let map = new Map();
    const tu = /\/ToUnicode\s+(\d+)\s+\d+\s+R/.exec(font.dict);
    if (tu) {
      const cm = decodeStream(pdf.objects.get(parseInt(tu[1], 10)));
      if (cm) map = parseCMap(cm.toString('latin1'));
    }
    maps.set(name, { map, twoByte });
  }
  return maps;
}

/* ------------------------------------------------------------------ */
/* 内容流 → 文本                                                       */
/* ------------------------------------------------------------------ */
function unescapePdfString(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c !== '\\') { out += c; continue; }
    const n = s[++i];
    if (n === 'n') out += '\n';
    else if (n === 'r') out += '\r';
    else if (n === 't') out += '\t';
    else if (n === 'b') out += '\b';
    else if (n === 'f') out += '\f';
    else if (n === '(') out += '(';
    else if (n === ')') out += ')';
    else if (n === '\\') out += '\\';
    else if (n >= '0' && n <= '7') {
      let oct = n;
      while (oct.length < 3 && s[i + 1] >= '0' && s[i + 1] <= '7') oct += s[++i];
      out += String.fromCharCode(parseInt(oct, 8));
    } else out += n;
  }
  return out;
}

function mapBytes(bytes, font) {
  if (!font || !font.map || font.map.size === 0) {
    return bytes.toString('latin1');
  }
  let out = '';
  if (font.twoByte) {
    for (let i = 0; i + 1 < bytes.length; i += 2) {
      const code = (bytes[i] << 8) | bytes[i + 1];
      out += font.map.has(code) ? font.map.get(code) : '';
    }
  } else {
    for (let i = 0; i < bytes.length; i++) {
      const code = bytes[i];
      out += font.map.has(code) ? font.map.get(code) : String.fromCharCode(code);
    }
  }
  return out;
}

/** 估算显示宽度（em）：中日韩全角按 1.0，其余按 0.5 */
function estWidth(txt) {
  let w = 0;
  for (const ch of txt) {
    const c = ch.codePointAt(0);
    w += (c >= 0x1100 && (c <= 0x115f || (c >= 0x2e80 && c <= 0xa4cf)
      || (c >= 0xac00 && c <= 0xd7a3) || (c >= 0xf900 && c <= 0xfaff)
      || (c >= 0xfe30 && c <= 0xfe6f) || (c >= 0xff00 && c <= 0xff60)
      || (c >= 0xffe0 && c <= 0xffe6))) ? 1.0 : 0.5;
  }
  return w;
}

function decodeContent(content, fonts) {
  const s = content.toString('latin1');
  const lines = [];
  let line = '';
  let curFont = null;
  let fontSize = 12;
  let x = 0, y = 0, leading = 0, rise = 0;
  let lineY = null;
  let penX = 0;              // 上一段文字结束时的 x
  let pendingSpace = false;

  const flush = () => { lines.push(line); line = ''; lineY = null; };

  /** 落一段文字，按 Y 变化换行、按 X 间隙补空格 */
  const emit = (txt) => {
    if (!txt) return;
    if (lineY === null) { lineY = y; }
    else if (Math.abs(y - lineY) > 1.2) { flush(); lineY = y; }

    const w = estWidth(txt) * fontSize;
    if (line !== '') {
      const gap = x - penX;
      if (pendingSpace || gap > 0.22 * fontSize) line += ' ';
    }
    line += txt;
    penX = x + w;
    pendingSpace = false;
  };

  let i = 0;
  const n = s.length;
  while (i < n) {
    const c = s[i];

    // /Name size Tf
    if (c === '/') {
      const m = /^\/([A-Za-z0-9#+._-]+)\s+(-?[\d.]+)\s+Tf/.exec(s.slice(i, i + 64));
      if (m) {
        curFont = fonts.get(m[1]) || null;
        fontSize = parseFloat(m[2]) || fontSize;
        i += m[0].length;
        continue;
      }
      i++;
      continue;
    }

    // TL 行距
    if (c === 'T' && s.startsWith('TL', i)) {
      const m = /^TL\s+(-?[\d.]+)/.exec(s.slice(i, i + 40));
      if (m) { leading = parseFloat(m[1]); i += m[0].length; continue; }
      i += 2; continue;
    }

    // Tm: a b c d e f Tm  → 绝对定位
    if (c === 'T' && s.startsWith('Tm', i)) {
      const back = s.slice(Math.max(0, i - 80), i);
      const nums = back.match(/-?[\d.]+/g);
      if (nums && nums.length >= 6) {
        x = parseFloat(nums[nums.length - 2]);
        y = parseFloat(nums[nums.length - 1]);
      }
      penX = x;
      i += 2;
      continue;
    }

    // Td / TD: tx ty → 相对定位
    if (c === 'T' && (s.startsWith('Td', i) || s.startsWith('TD', i))) {
      const back = s.slice(Math.max(0, i - 60), i);
      const nums = back.match(/-?[\d.]+/g);
      if (nums && nums.length >= 2) {
        x += parseFloat(nums[nums.length - 2]);
        y += parseFloat(nums[nums.length - 1]);
      }
      penX = x;
      if (s.startsWith('TD', i) && nums && nums.length >= 2) leading = -parseFloat(nums[nums.length - 1]);
      i += 2;
      continue;
    }

    // T*: 下一行
    if (c === 'T' && s[i + 1] === '*') {
      y -= leading;
      penX = x;
      i += 2;
      continue;
    }

    // 字面字符串 ( ... )
    if (c === '(') {
      let j = i + 1, depth = 1, raw2 = '';
      while (j < n && depth > 0) {
        const ch = s[j];
        if (ch === '\\') { raw2 += ch + (s[j + 1] || ''); j += 2; continue; }
        if (ch === '(') depth++;
        else if (ch === ')') { depth--; if (depth === 0) break; }
        raw2 += ch; j++;
      }
      let k = j + 1;
      while (k < n && /\s/.test(s[k])) k++;
      const op = s.slice(k, k + 2);
      if (op === 'Tj' || op === "'") {
        emit(mapBytes(Buffer.from(unescapePdfString(raw2), 'latin1'), curFont));
        if (op === "'") { y -= leading; penX = x; }
        i = k + 2; continue;
      }
      i = j + 1; continue;
    }

    // 十六进制字符串 < ... >
    if (c === '<' && s[i + 1] !== '<') {
      const j = s.indexOf('>', i);
      if (j < 0) break;
      const hex = s.slice(i + 1, j).replace(/\s/g, '');
      let k = j + 1;
      while (k < n && /\s/.test(s[k])) k++;
      if (s.startsWith('Tj', k)) {
        emit(mapBytes(Buffer.from(hex.length % 2 ? hex + '0' : hex, 'hex'), curFont));
        i = k + 2; continue;
      }
      i = j + 1; continue;
    }

    // 数组 [ ... ] TJ —— 里面的数字是字距调整，负得越多间隙越大
    if (c === '[') {
      let j = i + 1, depth = 1;
      while (j < n && depth > 0) {
        if (s[j] === '[') depth++;
        else if (s[j] === ']') { depth--; if (depth === 0) break; }
        j++;
      }
      const inner = s.slice(i + 1, j);
      let k = j + 1;
      while (k < n && /\s/.test(s[k])) k++;
      if (s.startsWith('TJ', k)) {
        const re = /\((?:\\.|[^\\()])*\)|<[0-9A-Fa-f\s]+>|-?\d+(?:\.\d+)?/g;
        let tk;
        while ((tk = re.exec(inner))) {
          const t = tk[0];
          if (t[0] === '(') {
            emit(mapBytes(Buffer.from(unescapePdfString(t.slice(1, -1)), 'latin1'), curFont));
          } else if (t[0] === '<') {
            const hex = t.slice(1, -1).replace(/\s/g, '');
            emit(mapBytes(Buffer.from(hex.length % 2 ? hex + '0' : hex, 'hex'), curFont));
          } else {
            const adj = parseFloat(t);
            if (!Number.isNaN(adj)) {
              x -= adj / 1000 * fontSize;
              if (adj < -120) pendingSpace = true;
            }
          }
        }
        i = k + 2; continue;
      }
      i = j + 1; continue;
    }

    // BT/ET 只是文本块的起止，**不要在这里重置 lineY** ——
    // 本 PDF 是「一个 BT 块一行」，但同一视觉行也可能拆成多个 BT 块（如变色文字），
    // 所以换行只认 Y 坐标变化。
    if (c === 'E' && s.startsWith('ET', i)) { i += 2; continue; }
    if (c === 'B' && s.startsWith('BT', i)) { i += 2; continue; }
    i++;
  }
  flush();
  return lines;
}

/* ------------------------------------------------------------------ */
/* 主流程                                                              */
/* ------------------------------------------------------------------ */
const argv = process.argv.slice(2);
const input = argv.find(a => !a.startsWith('--'));
if (!input) {
  console.error('用法: node tools/pdftext.mjs <输入.pdf> [输出.md] [--pages=1-3] [--probe]');
  process.exit(1);
}
const PROBE = argv.includes('--probe');
const pagesArg = (argv.find(a => a.startsWith('--pages=')) || '').split('=')[1];
const positional = argv.filter(a => !a.startsWith('--'));
const outArg = positional[1];

const buf = fs.readFileSync(input);
const pdf = parsePdf(buf);

// 页面对象
const pageObjs = [];
for (const o of pdf.objects.values()) {
  if (/\/Type\s*\/Page[^s]/.test(o.dict) || /\/Type\s*\/Page\s*$/.test(o.dict.trim())) {
    pageObjs.push(o);
  }
}
pageObjs.sort((a, b) => a.num - b.num);

let range = null;
if (pagesArg) {
  const m = /^(\d+)(?:-(\d+))?$/.exec(pagesArg);
  if (m) range = [parseInt(m[1], 10), parseInt(m[2] || m[1], 10)];
}

if (PROBE) {
  console.log('对象数   :', pdf.objects.size);
  console.log('页数     :', pageObjs.length);
  for (const p of pageObjs.slice(0, 20)) {
    const res = /\/Resources\s+(\d+\s+\d+\s+R)/.exec(p.dict);
    const fonts = res ? buildFontMaps(pdf, resolve(pdf.objects, res[1])?.dict || '') : new Map();
    const fnames = [...fonts.keys()].join(',');
    console.log(`  页 obj#${p.num}  字体: ${fnames || '(内联/无)'}`);
  }
  process.exit(0);
}

const out = [];
out.push(`# ${path.basename(input, '.pdf')}`);
out.push('');
out.push(`> 由 \`tools/pdftext.mjs\` 从 PDF 提取。共 ${pageObjs.length} 页。`);
out.push('');

let pageNo = 0;
for (const p of pageObjs) {
  pageNo++;
  if (range && (pageNo < range[0] || pageNo > range[1])) continue;

  const resRef = /\/Resources\s+(\d+\s+\d+\s+R)/.exec(p.dict);
  const resDict = resRef ? (resolve(pdf.objects, resRef[1])?.dict || '') : p.dict;
  const fonts = buildFontMaps(pdf, resDict);

  // /Contents 可能是单个引用，也可能是数组
  const cRefs = [];
  const single = /\/Contents\s+(\d+)\s+\d+\s+R/.exec(p.dict);
  if (single) cRefs.push(parseInt(single[1], 10));
  const arr = /\/Contents\s*\[([^\]]*)\]/.exec(p.dict);
  if (arr) for (const x of arr[1].matchAll(/(\d+)\s+\d+\s+R/g)) cRefs.push(parseInt(x[1], 10));

  out.push(`\n---\n\n## 第 ${pageNo} 页\n`);

  for (const cRef of cRefs) {
    const data = decodeStream(pdf.objects.get(cRef));
    if (!data) continue;
    const lines = decodeContent(data, fonts);
    for (const l of lines) {
      const t = l.replace(/\s+$/, '');
      if (t.trim()) out.push(t);
    }
  }
}

const md = out.join('\n').replace(/\n{4,}/g, '\n\n\n') + '\n';

const outPath = outArg || input.replace(/\.pdf$/i, '.md');
fs.writeFileSync(outPath, md, 'utf8');

const chars = md.length;
const cjk = (md.match(/[\u4e00-\u9fff]/g) || []).length;
console.log('提取完成: ' + path.basename(outPath));
console.log('  字符数  : ' + chars);
console.log('  中文字数: ' + cjk);
console.log('  估算token: ~' + Math.round(chars / 3));
if (cjk === 0 && chars > 200) {
  console.log('  ⚠ 没提取到中文 —— 可能是扫描件（图片），或字体没有 ToUnicode 表');
}
