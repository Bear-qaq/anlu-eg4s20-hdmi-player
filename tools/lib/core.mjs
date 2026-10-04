// tools/lib/core.mjs
// 通用工具：token 估算、glob、编码识别、目录遍历、文件分类
import fs from 'node:fs';
import path from 'node:path';

/* ------------------------------------------------------------------ */
/* token 估算（中英混排的粗略估计，够用来做预算告警）                    */
/* ------------------------------------------------------------------ */
const CJK_RE = /[\u2E80-\u9FFF\u3000-\u303F\uFF00-\uFFEF]/;

export function estTokens(str) {
  let cjk = 0, other = 0;
  for (const ch of str) {
    if (CJK_RE.test(ch)) cjk++; else other++;
  }
  return Math.round(cjk / 1.1 + other / 3.7);
}

export function fmtTokens(n) {
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(n);
}

/* ------------------------------------------------------------------ */
/* glob                                                                */
/* ------------------------------------------------------------------ */
export function globToRe(glob) {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  return new RegExp('^' + esc.replace(/\*/g, '.*').replace(/\?/g, '.') + '$', 'i');
}

export function anyGlobMatch(name, globs) {
  for (const g of globs || []) {
    if (globToRe(g).test(name)) return true;
  }
  return false;
}

/* ------------------------------------------------------------------ */
/* 编码识别                                                            */
/* ------------------------------------------------------------------ */
export function looksBinary(buf) {
  const n = Math.min(buf.length, 8192);
  for (let i = 0; i < n; i++) if (buf[i] === 0) return true;
  return false;
}

export function decodeBuffer(buf) {
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) {
    return { text: buf.subarray(2).toString('utf16le'), enc: 'utf16le' };
  }
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) {
    const sw = Buffer.from(buf.subarray(2));
    if (sw.length % 2 === 0) sw.swap16();
    return { text: sw.toString('utf16le'), enc: 'utf16be' };
  }
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    return { text: buf.subarray(3).toString('utf8'), enc: 'utf8-bom' };
  }
  const text = buf.toString('utf8');
  const bad = (text.match(/\uFFFD/g) || []).length;
  // 少量替换字符可能只是个别脏字节；大量出现说明是 GBK/GB2312 等本地编码
  if (bad > 2 && bad > text.length * 0.001) {
    return { text: null, enc: 'non-utf8' };
  }
  return { text: text.replace(/\uFFFD/g, ''), enc: 'utf8' };
}

export function readTextFile(abs) {
  let buf;
  try { buf = fs.readFileSync(abs); }
  catch { return { text: null, enc: 'unreadable', bytes: 0 }; }
  if (looksBinary(buf)) return { text: null, enc: 'binary', bytes: buf.length };
  const d = decodeBuffer(buf);
  return { text: d.text, enc: d.enc, bytes: buf.length };
}

/* ------------------------------------------------------------------ */
/* 目录遍历                                                            */
/* ------------------------------------------------------------------ */
export function walk(root, cfg) {
  const files = [];
  const dropped = [];
  const dropDirs = new Set((cfg.dropDirNames || []).map(s => s.toLowerCase()));
  const dropGlobs = cfg.dropDirGlobs || [];
  const dropFileGlobs = cfg.dropFileGlobs || [];

  (function rec(abs, rel) {
    let entries;
    try { entries = fs.readdirSync(abs, { withFileTypes: true }); }
    catch { return; }
    for (const e of entries) {
      const r = rel ? rel + '/' + e.name : e.name;
      const a = path.join(abs, e.name);
      if (e.isDirectory()) {
        const low = e.name.toLowerCase();
        if (dropDirs.has(low)) { dropped.push({ path: r, reason: '构建产物目录/' + e.name }); continue; }
        if (anyGlobMatch(e.name, dropGlobs)) { dropped.push({ path: r, reason: '构建产物目录/' + e.name }); continue; }
        rec(a, r);
      } else if (e.isFile()) {
        if (e.name === '.DS_Store' || e.name.toLowerCase() === 'thumbs.db') {
          dropped.push({ path: r, reason: '系统垃圾文件' }); continue;
        }
        if (anyGlobMatch(e.name, dropFileGlobs)) {
          dropped.push({ path: r, reason: '加密/不可读文件 (' + e.name + ')' }); continue;
        }
        let st;
        try { st = fs.statSync(a); } catch { continue; }
        files.push({ abs: a, rel: r, size: st.size, mtime: st.mtimeMs });
      }
    }
  })(root, '');

  return { files, dropped };
}

/* ------------------------------------------------------------------ */
/* 分类                                                                */
/* ------------------------------------------------------------------ */
export function classify(rel, size, cfg) {
  const ext = path.extname(rel).toLowerCase();
  const text = new Set(cfg.textExtensions || []);
  const hdl = new Set(cfg.hdlExtensions || []);
  const con = new Set(cfg.constraintExtensions || []);
  const rep = new Set(cfg.reportExtensions || []);
  const listOnly = new Set(cfg.listOnlyExtensions || []);
  const images = new Set(cfg.imageExtensions || []);
  const drop = new Set(cfg.dropExtensions || []);

  if (drop.has(ext)) return { cat: 'dropped', keep: false, why: '二进制/构建产物 (' + ext + ')' };
  if (hdl.has(ext)) return { cat: 'hdl', keep: true };
  if (con.has(ext)) return { cat: 'constraint', keep: true };
  if (rep.has(ext)) return { cat: 'report', keep: true };
  if (listOnly.has(ext)) return { cat: 'binary-doc', keep: true, digest: false };
  if (images.has(ext)) return { cat: 'image', keep: true, digest: false };
  if (text.has(ext)) return { cat: 'text', keep: true };
  if (ext === '') return { cat: 'noext', keep: size < 512 * 1024, digest: size < 256 * 1024 };
  return { cat: 'other', keep: false, why: '未知扩展名 (' + (ext || '无') + ')' };
}

export function extOf(rel) { return path.extname(rel).toLowerCase() || '(无扩展名)'; }

/* ------------------------------------------------------------------ */
/* 杂项                                                                */
/* ------------------------------------------------------------------ */
export function ensureDir(dir) { fs.mkdirSync(dir, { recursive: true }); }

export function writeFileSafe(abs, content) {
  ensureDir(path.dirname(abs));
  fs.writeFileSync(abs, content, 'utf8');
}

export function lineCount(text) { return text ? text.split('\n').length : 0; }

export function humanSize(bytes) {
  if (bytes < 1024) return bytes + 'B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + 'K';
  return (bytes / 1024 / 1024).toFixed(1) + 'M';
}

/** 抽取文件开头的注释/标题，作为一句话说明 */
export function headerComment(text) {
  if (!text) return '';
  const lines = text.split('\n').slice(0, 40);
  const out = [];
  for (const raw of lines) {
    const l = raw.trim();
    if (!l) { if (out.length) break; else continue; }
    let m;
    if ((m = /^(?:\/\/|--|#|;|\*)\s?(.*)$/.exec(l))) { out.push(m[1].trim()); continue; }
    if ((m = /^\/\*(.*?)\*\/$/.exec(l))) { out.push(m[1].trim()); continue; }
    if (/^(?:module|entity|library|`|\/\/)/i.test(l)) break;
    break;
  }
  const s = out.filter(Boolean).join(' / ').trim();
  if (s.length > 160) return s.slice(0, 160) + '…';
  return s;
}

/** 截断到 n 行，附带说明 */
export function truncateLines(text, n) {
  if (!text) return { text: '', cut: 0 };
  const lines = text.split('\n');
  if (lines.length <= n) return { text, cut: 0 };
  return { text: lines.slice(0, n).join('\n'), cut: lines.length - n };
}

/** 报告类文件取头尾 */
export function headTail(text, head, tail) {
  if (!text) return '';
  const lines = text.split('\n');
  if (lines.length <= head + tail + 5) return text;
  return lines.slice(0, head).join('\n')
    + '\n\n... [中间省略 ' + (lines.length - head - tail) + ' 行] ...\n\n'
    + lines.slice(-tail).join('\n');
}
