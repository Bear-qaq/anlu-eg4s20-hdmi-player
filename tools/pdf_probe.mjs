#!/usr/bin/env node
// PDF 文本探测：把 PDF 里所有可 inflate 的流解出来，抓文本显示算子里的字符串。
// 目的：先判断"能不能抽出可读文本"，再决定要不要写完整的字体/编码映射。
// 用法： node tools/pdf_probe.mjs <file.pdf> [关键词1,关键词2,...]

import { readFileSync } from 'node:fs';
import { inflateSync, inflateRawSync } from 'node:zlib';

const file = process.argv[2];
if (!file) {
  console.error('用法: node tools/pdf_probe.mjs <file.pdf> [关键词,...]');
  process.exit(2);
}
const keywords = (process.argv[3] || '').split(',').map((s) => s.trim()).filter(Boolean);

const buf = readFileSync(file);
console.log(`文件: ${file}`);
console.log(`大小: ${buf.length} 字节`);
console.log(`头部: ${buf.subarray(0, 8).toString('latin1').trim()}`);

// 扫描所有 stream ... endstream 段
const raw = buf.toString('latin1');
const re = /stream\r?\n?/g;
let m;
let streamCount = 0;
let inflated = 0;
const texts = [];

while ((m = re.exec(raw)) !== null) {
  const start = m.index + m[0].length;
  const end = raw.indexOf('endstream', start);
  if (end < 0) continue;
  streamCount++;
  // 取该 stream 之前最多 400 字节的字典，判断过滤器
  const dictStart = Math.max(0, m.index - 400);
  const dict = raw.slice(dictStart, m.index);
  if (!/FlateDecode/.test(dict)) continue;

  let body = buf.subarray(start, end);
  // 去掉尾随换行
  while (body.length && (body[body.length - 1] === 0x0a || body[body.length - 1] === 0x0d)) {
    body = body.subarray(0, body.length - 1);
  }
  let out = null;
  try {
    out = inflateSync(body);
  } catch {
    try {
      out = inflateRawSync(body);
    } catch {
      continue;
    }
  }
  inflated++;
  const s = out.toString('latin1');
  // 只关心含文本显示算子的内容流
  if (/\bTj\b|\bTJ\b/.test(s)) {
    texts.push(s);
  }
}

console.log(`stream 总数: ${streamCount}, 成功 inflate: ${inflated}, 含文本算子的内容流: ${texts.length}`);

// 从内容流里抓 ( ... ) 字符串，以及 [ ... ] TJ 数组
function decodePdfString(src) {
  let out = '';
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (c === '\\') {
      const n = src[++i];
      if (n === 'n') out += '\n';
      else if (n === 'r') out += '\r';
      else if (n === 't') out += '\t';
      else if (n === 'b') out += '\b';
      else if (n === 'f') out += '\f';
      else if (n >= '0' && n <= '7') {
        let oct = n;
        while (oct.length < 3 && src[i + 1] >= '0' && src[i + 1] <= '7') oct += src[++i];
        out += String.fromCharCode(parseInt(oct, 8));
      } else out += n;
    } else {
      out += c;
    }
  }
  return out;
}

const lines = [];
for (const s of texts) {
  // 逐个 BT...ET 块
  const btRe = /BT([\s\S]*?)ET/g;
  let b;
  while ((b = btRe.exec(s)) !== null) {
    const block = b[1];
    const strRe = /\((?:\\.|[^\\()])*\)/g;
    let t;
    let line = '';
    while ((t = strRe.exec(block)) !== null) {
      line += decodePdfString(t[0].slice(1, -1));
    }
    line = line.trim();
    if (line) lines.push(line);
  }
}

console.log(`抽出文本行: ${lines.length}`);
console.log('--- 前 60 行 ---');
for (const l of lines.slice(0, 60)) console.log(JSON.stringify(l));

if (keywords.length) {
  console.log(`--- 命中关键词 ${keywords.join('/')} 的行 ---`);
  let hits = 0;
  for (const l of lines) {
    if (keywords.some((k) => l.toUpperCase().includes(k.toUpperCase()))) {
      console.log(JSON.stringify(l));
      if (++hits >= 120) break;
    }
  }
  console.log(`命中 ${hits} 行`);
}
