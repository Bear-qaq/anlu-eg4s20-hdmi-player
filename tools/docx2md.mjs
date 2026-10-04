#!/usr/bin/env node
// tools/docx2md.mjs
// 把 .docx 转成 markdown。docx 本质是 zip + word/document.xml，
// 这里内置一个最小 ZIP 读取器（只用 Node 内置 zlib，无第三方依赖）。
//
// 用法：
//   node tools/docx2md.mjs <输入.docx> [输出.md]
//   node tools/docx2md.mjs raw/docs/*.docx        # 批量（输出同名 .md）

import fs from 'node:fs';
import path from 'node:path';
import { openZip } from './lib/zip.mjs';

/* ---------------- XML → markdown ---------------- */
function decodeEntities(s) {
  return s
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(parseInt(d, 10)))
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/** 取出一段 XML 里所有 <w:t> 的文字 */
function paraText(xml) {
  let s = xml
    .replace(/<w:tab\b[^>]*\/?>/g, '\t')
    .replace(/<w:br\b[^>]*\/?>/g, '\n')
    .replace(/<w:drawing\b[\s\S]*?<\/w:drawing>/g, '〔图片〕')
    .replace(/<w:pict\b[\s\S]*?<\/w:pict>/g, '〔图片〕');

  const parts = [];
  const re = /<w:t(?:\s[^>]*)?>([\s\S]*?)<\/w:t>/g;
  let m;
  while ((m = re.exec(s))) parts.push(decodeEntities(m[1]));
  return parts.join('').replace(/[ \t]+$/gm, '').trim();
}

/** 判断段落级标题 */
function headingLevel(pXml) {
  let m = /<w:pStyle\s+w:val="([^"]+)"/.exec(pXml);
  const style = m ? m[1] : '';
  m = /<w:outlineLvl\s+w:val="(\d+)"/.exec(pXml);
  const outline = m ? parseInt(m[1], 10) + 1 : 0;

  let lvl = 0;
  let s = /heading\s*([1-9])/i.exec(style);
  if (s) lvl = parseInt(s[1], 10);
  if (!lvl) { s = /^(\d)$/.exec(style); if (s) lvl = parseInt(s[1], 10); }
  if (!lvl) { s = /(?:标题|標題)\s*([1-9])/.exec(style); if (s) lvl = parseInt(s[1], 10); }
  if (!lvl && /^(Title|标题|標題)$/i.test(style)) lvl = 1;
  if (!lvl) lvl = outline;
  return Math.min(lvl, 6);
}

function isListPara(pXml) {
  return /<w:numPr\b/.test(pXml);
}

function tableToMd(tblXml) {
  const rows = [];
  const trRe = /<w:tr\b[^>]*>([\s\S]*?)<\/w:tr>/g;
  let tr;
  while ((tr = trRe.exec(tblXml))) {
    const cells = [];
    const tcRe = /<w:tc\b[^>]*>([\s\S]*?)<\/w:tc>/g;
    let tc;
    while ((tc = tcRe.exec(tr[1]))) {
      const texts = [];
      const pRe = /<w:p\b[^>]*>([\s\S]*?)<\/w:p>/g;
      let pp;
      while ((pp = pRe.exec(tc[1]))) {
        const t = paraText(pp[1]);
        if (t) texts.push(t);
      }
      cells.push(texts.join(' ').replace(/\|/g, '\\|').replace(/\n/g, ' '));
    }
    if (cells.length) rows.push(cells);
  }
  if (!rows.length) return '';
  const width = rows.reduce((a, r) => Math.max(a, r.length), 0);
  const pad = r => { const c = r.slice(); while (c.length < width) c.push(''); return c; };
  const out = [];
  out.push('| ' + pad(rows[0]).join(' | ') + ' |');
  out.push('|' + Array(width).fill('---').join('|') + '|');
  for (const r of rows.slice(1)) out.push('| ' + pad(r).join(' | ') + ' |');
  return out.join('\n');
}

function convertDocument(xml) {
  const bodyM = /<w:body\b[^>]*>([\s\S]*)<\/w:body>/.exec(xml);
  const body = bodyM ? bodyM[1] : xml;

  const out = [];
  const blockRe = /<w:(p|tbl)\b[^>]*>([\s\S]*?)<\/w:\1>/g;
  let m;
  let lastWasEmpty = false;

  while ((m = blockRe.exec(body))) {
    if (m[1] === 'tbl') {
      const t = tableToMd(m[2]);
      if (t) { out.push('', t, ''); lastWasEmpty = false; }
      continue;
    }

    const pXml = m[0];
    const text = paraText(m[2]);
    if (!text) {
      if (!lastWasEmpty && out.length) { out.push(''); lastWasEmpty = true; }
      continue;
    }

    const lvl = headingLevel(pXml);
    if (lvl) {
      out.push('', '#'.repeat(lvl) + ' ' + text.replace(/\n/g, ' '), '');
    } else if (isListPara(pXml)) {
      const ind = /<w:ilvl\s+w:val="(\d+)"/.exec(pXml);
      const d = ind ? Math.min(parseInt(ind[1], 10), 3) : 0;
      out.push('  '.repeat(d) + '- ' + text.replace(/\n/g, ' '));
    } else {
      out.push(text, '');
    }
    lastWasEmpty = false;
  }

  let md = out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  return md + '\n';
}

/* ---------------- 主流程 ---------------- */
const args = process.argv.slice(2);
if (!args.length) {
  console.error('用法: node tools/docx2md.mjs <输入.docx> [输出.md]');
  process.exit(1);
}

let ok = 0, fail = 0;
for (const input of args) {
  const abs = path.resolve(input);
  if (!fs.existsSync(abs)) { console.error('找不到: ' + input); fail++; continue; }
  try {
    const z = openZip(abs);
    const entry = z.entries.find(e => e.name === 'word/document.xml');
    if (!entry) throw new Error('docx 里没有 word/document.xml');
    const md = convertDocument(z.read(entry).toString('utf8'));
    z.close();

    const outPath = args.length === 2 && !args[1].includes('*')
      ? path.resolve(args[1])
      : abs.replace(/\.docx$/i, '.md');

    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, md, 'utf8');

    const chars = md.length;
    console.log('OK  ' + path.basename(abs) + '  →  ' + path.basename(outPath)
      + '   (' + chars + ' 字符, 约 ' + Math.round(chars / 3) + ' token)');
    ok++;
  } catch (e) {
    console.error('失败 ' + path.basename(abs) + ': ' + e.message);
    fail++;
  }
}
console.log('\n完成: 成功 ' + ok + ', 失败 ' + fail);
