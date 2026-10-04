// tools/lib/zip.mjs
// 最小 ZIP 读取器（基于文件描述符，不把整个 zip 读进内存）。
// 只支持常规 zip；不支持 zip64 和加密条目。
import fs from 'node:fs';
import zlib from 'node:zlib';

/** zip 条目的文件名编码：优先 UTF-8 标志位，否则按 GB18030（中文 Windows 常见） */
const GBK_DECODER = (() => {
  try { return new TextDecoder('gb18030'); } catch { return null; }
})();

function decodeName(buf, flags) {
  if (flags & 0x0800) return buf.toString('utf8');   // EFS: 明确声明 UTF-8
  // 先试 UTF-8，若出现替换字符则回退 GB18030
  const utf8 = buf.toString('utf8');
  if (!utf8.includes('\uFFFD')) return utf8;
  if (GBK_DECODER) {
    const gbk = GBK_DECODER.decode(buf);
    if (!gbk.includes('\uFFFD')) return gbk;
  }
  return utf8;
}

function readFully(fd, buf, position) {
  let done = 0;
  while (done < buf.length) {
    const n = fs.readSync(fd, buf, done, buf.length - done, position + done);
    if (n <= 0) break;
    done += n;
  }
  return done;
}

export function openZip(filePath) {
  const fd = fs.openSync(filePath, 'r');
  const size = fs.fstatSync(fd).size;

  // 从尾部找 EOCD（可能带注释）
  const tailLen = Math.min(size, 22 + 65536);
  const tail = Buffer.alloc(tailLen);
  readFully(fd, tail, size - tailLen);

  let eocd = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (tail.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) { fs.closeSync(fd); throw new Error('不是有效的 zip: ' + filePath); }

  const count = tail.readUInt16LE(eocd + 10);
  const cdSize = tail.readUInt32LE(eocd + 12);
  const cdOffset = tail.readUInt32LE(eocd + 16);

  const cd = Buffer.alloc(cdSize);
  readFully(fd, cd, cdOffset);

  const entries = [];
  let p = 0;
  for (let i = 0; i < count && p + 46 <= cd.length; i++) {
    if (cd.readUInt32LE(p) !== 0x02014b50) break;
    const flags = cd.readUInt16LE(p + 8);
    const method = cd.readUInt16LE(p + 10);
    const compSize = cd.readUInt32LE(p + 20);
    const uncompSize = cd.readUInt32LE(p + 24);
    const nameLen = cd.readUInt16LE(p + 28);
    const extraLen = cd.readUInt16LE(p + 30);
    const commentLen = cd.readUInt16LE(p + 32);
    const localOffset = cd.readUInt32LE(p + 42);
    const name = decodeName(cd.subarray(p + 46, p + 46 + nameLen), flags);
    entries.push({
      name, method, compSize, uncompSize, localOffset,
      isDir: name.endsWith('/'),
    });
    p += 46 + nameLen + extraLen + commentLen;
  }

  function read(entryOrName) {
    const e = typeof entryOrName === 'string'
      ? entries.find(x => x.name === entryOrName)
      : entryOrName;
    if (!e) throw new Error('zip 里没有该条目');
    if (e.isDir) return Buffer.alloc(0);

    const lh = Buffer.alloc(30);
    readFully(fd, lh, e.localOffset);
    if (lh.readUInt32LE(0) !== 0x04034b50) {
      throw new Error('本地文件头损坏: ' + e.name);
    }
    const nameLen = lh.readUInt16LE(26);
    const extraLen = lh.readUInt16LE(28);
    const start = e.localOffset + 30 + nameLen + extraLen;

    const comp = Buffer.alloc(e.compSize);
    readFully(fd, comp, start);

    if (e.method === 0) return comp;
    if (e.method === 8) return zlib.inflateRawSync(comp);
    throw new Error('不支持的压缩方式 ' + e.method + ': ' + e.name);
  }

  return { path: filePath, entries, read, close: () => fs.closeSync(fd) };
}

export function zipGlobMatch(name, glob) {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp('^' + esc.replace(/\*\*/g, '\u0000').replace(/\*/g, '[^/]*')
    .replace(/\u0000/g, '.*').replace(/\?/g, '.') + '$', 'i');
  return re.test(name);
}

/* ------------------------------------------------------------------ */
/* ZIP 写入                                                            */
/* ------------------------------------------------------------------ */
function dosDateTime(d) {
  const time = ((d.getHours() & 31) << 11) | ((d.getMinutes() & 63) << 5)
    | (Math.floor(d.getSeconds() / 2) & 31);
  const date = (((d.getFullYear() - 1980) & 127) << 9)
    | (((d.getMonth() + 1) & 15) << 5) | (d.getDate() & 31);
  return { time, date };
}

/* zlib.crc32 需要 Node >= 20.15；低版本退回查表实现 */
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  if (typeof zlib.crc32 === 'function') return zlib.crc32(buf) >>> 0;
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

/**
 * 创建 zip 文件。
 * @param {string} outPath 输出路径
 * @param {Array<{name: string, source?: string, data?: Buffer}>} entries
 *        name 用 '/' 分隔；source 是磁盘路径，或直接给 data
 * @param {{level?: number, onProgress?: Function}} [opts]
 * @returns {{files: number, bytesIn: number, bytesOut: number}}
 */
export function createZip(outPath, entries, opts = {}) {
  const level = opts.level != null ? opts.level : 9;
  const fd = fs.openSync(outPath, 'w');
  const central = [];
  let offset = 0;
  let bytesIn = 0;
  let count = 0;

  const write = buf => { fs.writeSync(fd, buf); offset += buf.length; };

  try {
    for (const e of entries) {
      const data = e.data != null ? e.data : fs.readFileSync(e.source);
      const nameBuf = Buffer.from(e.name.replace(/\\/g, '/'), 'utf8');
      const crc = crc32(data);
      const { time, date } = dosDateTime(new Date());

      let method = 8, body = zlib.deflateRawSync(data, { level });
      if (body.length >= data.length) { method = 0; body = data; }  // 压不动就存原文

      const localOffset = offset;
      const lh = Buffer.alloc(30);
      lh.writeUInt32LE(0x04034b50, 0);
      lh.writeUInt16LE(20, 4);
      lh.writeUInt16LE(0x0800, 6);           // 文件名是 UTF-8
      lh.writeUInt16LE(method, 8);
      lh.writeUInt16LE(time, 10);
      lh.writeUInt16LE(date, 12);
      lh.writeUInt32LE(crc, 14);
      lh.writeUInt32LE(body.length, 18);
      lh.writeUInt32LE(data.length, 22);
      lh.writeUInt16LE(nameBuf.length, 26);
      lh.writeUInt16LE(0, 28);
      write(lh);
      write(nameBuf);
      write(body);

      central.push({ nameBuf, method, time, date, crc, comp: body.length, raw: data.length, localOffset });
      bytesIn += data.length;
      count++;
      if (opts.onProgress && count % 200 === 0) opts.onProgress(count);
    }

    const cdStart = offset;
    for (const c of central) {
      const ch = Buffer.alloc(46);
      ch.writeUInt32LE(0x02014b50, 0);
      ch.writeUInt16LE(20, 4);
      ch.writeUInt16LE(20, 6);
      ch.writeUInt16LE(0x0800, 8);
      ch.writeUInt16LE(c.method, 10);
      ch.writeUInt16LE(c.time, 12);
      ch.writeUInt16LE(c.date, 14);
      ch.writeUInt32LE(c.crc, 16);
      ch.writeUInt32LE(c.comp, 20);
      ch.writeUInt32LE(c.raw, 24);
      ch.writeUInt16LE(c.nameBuf.length, 28);
      ch.writeUInt16LE(0, 30);
      ch.writeUInt16LE(0, 32);
      ch.writeUInt16LE(0, 34);
      ch.writeUInt16LE(0, 36);
      ch.writeUInt32LE(0, 38);
      ch.writeUInt32LE(c.localOffset, 42);
      write(ch);
      write(c.nameBuf);
    }
    const cdSize = offset - cdStart;

    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0);
    eocd.writeUInt16LE(0, 4);
    eocd.writeUInt16LE(0, 6);
    eocd.writeUInt16LE(count, 8);
    eocd.writeUInt16LE(count, 10);
    eocd.writeUInt32LE(cdSize, 12);
    eocd.writeUInt32LE(cdStart, 16);
    eocd.writeUInt16LE(0, 20);
    write(eocd);

    return { files: count, bytesIn, bytesOut: offset };
  } finally {
    fs.closeSync(fd);
  }
}
