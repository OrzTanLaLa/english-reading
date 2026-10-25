/**
 * 课程落盘：一门课 = files/course/<id>/ 一个目录。
 *
 *   meta.json     课程信息
 *   text.txt      课文正文
 *   images/       原图 img_01.jpg …
 *   audio.pcm     合成音频（只保留当前音色）
 *   words.json    词级时间戳
 *   glossary.yaml 本课生语汇（YAML 序列）
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { CourseMeta, defaultTitle, newCourseId, CURRENT_SCHEMA } from '../core/course';
import { parseLegacyTxt, entryBlock } from '../core/glossary';

const ROOT_NAME: string = 'course';
const META: string = 'meta.json';
const TEXT: string = 'text.txt';
const AUDIO: string = 'audio.pcm';
const WORDS: string = 'words.json';
const SENTENCES: string = 'sentences.json';
const IMAGES: string = 'images';
const GLOSSARY: string = 'glossary.yaml';

export interface WordTiming {
  text: string;
  begin: number;
  end: number;
}

export class CourseStore {
  private ctx: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  private root(): string {
    return this.ctx.filesDir + '/' + ROOT_NAME;
  }

  private dir(id: string): string {
    return this.root() + '/' + id;
  }

  dirPath(id: string): string {
    return this.dir(id);
  }

  /** 课程根目录（导出打包用） */
  rootPath(): string {
    return this.root();
  }

  private ensureRoot(): void {
    if (!fs.accessSync(this.root())) {
      fs.mkdirSync(this.root(), true);
    }
  }

  /** 列出全部课程，按更新时间倒序 */
  list(): CourseMeta[] {
    this.ensureRoot();
    const out: CourseMeta[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.root());
    } catch (err) {
      return out;
    }
    for (const name of names) {
      const meta = this.meta(name);
      if (meta !== undefined) {
        out.push(meta);
      }
    }
    out.sort((a: CourseMeta, b: CourseMeta): number => b.updatedAt - a.updatedAt);
    return out;
  }

  meta(id: string): CourseMeta | undefined {
    const path: string = this.dir(id) + '/' + META;
    if (!fs.accessSync(path)) {
      return undefined;
    }
    try {
      const text: string = fs.readTextSync(path);
      const m: CourseMeta = JSON.parse(text) as CourseMeta;
      if (m.schemaVersion === undefined) {
        m.schemaVersion = 0;   // 迁移前的老数据
      }
      return m;
    } catch (err) {
      return undefined;
    }
  }

  saveMeta(meta: CourseMeta): void {
    const dir: string = this.dir(meta.id);
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const file = fs.openSync(dir + '/' + META, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(meta));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 新建课程（标题留空则用默认名） */
  create(title: string, voice: string): CourseMeta {
    const now: number = Date.now();
    const meta: CourseMeta = {
      id: newCourseId(now),
      title: title.trim().length > 0 ? title.trim() : defaultTitle(now),
      createdAt: now,
      updatedAt: now,
      voice: voice,
      textHash: '',
      pageCount: 0,
      audioMs: 0,
      wordCount: 0,
      lastPositionMs: 0,
      schemaVersion: CURRENT_SCHEMA
    };
    fs.mkdirSync(this.dir(meta.id), true);
    fs.mkdirSync(this.dir(meta.id) + '/' + IMAGES, true);
    this.saveMeta(meta);
    return meta;
  }

  rename(id: string, title: string): void {
    const meta = this.meta(id);
    if (meta === undefined) {
      return;
    }
    meta.title = title.trim().length > 0 ? title.trim() : meta.title;
    meta.updatedAt = Date.now();
    this.saveMeta(meta);
  }

  /** 删除整门课（文本、原图、音频、生语汇一起删） */
  remove(id: string): void {
    const dir: string = this.dir(id);
    if (fs.accessSync(dir)) {
      fs.rmdirSync(dir);
    }
  }

  // ---- 文本 ----

  writeText(id: string, text: string, textHash: string): void {
    const dir: string = this.dir(id);
    const file = fs.openSync(dir + '/' + TEXT, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    const meta = this.meta(id);
    if (meta !== undefined) {
      meta.textHash = textHash;
      meta.updatedAt = Date.now();
      this.saveMeta(meta);
    }
  }

  readText(id: string): string {
    const path: string = this.dir(id) + '/' + TEXT;
    if (!fs.accessSync(path)) {
      return '';
    }
    try {
      return fs.readTextSync(path);
    } catch (err) {
      return '';
    }
  }

  // ---- 音频与时间戳 ----

  hasAudio(id: string): boolean {
    return fs.accessSync(this.dir(id) + '/' + AUDIO) && fs.accessSync(this.dir(id) + '/' + WORDS);
  }

  writeAudio(id: string, pcm: ArrayBuffer): void {
    const file = fs.openSync(this.dir(id) + '/' + AUDIO,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, pcm);
    } finally {
      fs.closeSync(file);
    }
  }

  readAudio(id: string): ArrayBuffer {
    const path: string = this.dir(id) + '/' + AUDIO;
    const stat = fs.statSync(path);
    const buf = new ArrayBuffer(stat.size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buf);
    } finally {
      fs.closeSync(file);
    }
    return buf;
  }

  writeSentences(id: string, rows: Object[]): void {
    const file = fs.openSync(this.dir(id) + '/' + SENTENCES,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(rows));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 读句级区间；不存在时返回空数组（旧课程没有这个文件） */
  readSentences(id: string): Object[] {
    const path: string = this.dir(id) + '/' + SENTENCES;
    try {
      if (!fs.accessSync(path)) {
        return [];
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const size: number = fs.statSync(path).size;
        const buf: ArrayBuffer = new ArrayBuffer(size);
        fs.readSync(file.fd, buf);
        const raw: string = buffer.from(buf).toString('utf8');
        return raw.length > 0 ? (JSON.parse(raw) as Object[]) : [];
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (err) {
      return [];
    }
  }

  writeWords(id: string, words: WordTiming[]): void {
    const file = fs.openSync(this.dir(id) + '/' + WORDS,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(words));
    } finally {
      fs.closeSync(file);
    }
  }

  readWords(id: string): WordTiming[] {
    const path: string = this.dir(id) + '/' + WORDS;
    if (!fs.accessSync(path)) {
      return [];
    }
    try {
      return JSON.parse(fs.readTextSync(path)) as WordTiming[];
    } catch (err) {
      return [];
    }
  }

  /** 文本或音色变了就删掉旧音频 */
  dropAudio(id: string): void {
    const a: string = this.dir(id) + '/' + AUDIO;
    const w: string = this.dir(id) + '/' + WORDS;
    if (fs.accessSync(a)) {
      fs.unlinkSync(a);
    }
    if (fs.accessSync(w)) {
      fs.unlinkSync(w);
    }
  }

  // ---- 原图 ----

  /**
   * 复制外部 uri 到沙箱。
   * 媒体库给的 `file://media/...` 直接 copyFileSync 往往失败（权限/URI 形态），
   * 所以退一步用 open 拿 fd 再拷。
   */
  private copyInto(src: string, dst: string): void {
    try {
      fs.copyFileSync(src, dst);
      return;
    } catch (err) {
      // 继续尝试 fd 方式
    }
    const file = fs.openSync(src, fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(file.fd, dst);
    } finally {
      fs.closeSync(file);
    }
  }  /** 把外部 uri（相册/相机临时文件）复制进课程目录，返回新的张数 */
  addImages(id: string, uris: string[]): number {
    const dir: string = this.dir(id) + '/' + IMAGES;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    let count: number = this.listImages(id).length;
    for (const uri of uris) {
      count++;
      const name: string = 'img_' + (count < 10 ? '0' + count : '' + count) + '.jpg';
      try {
        this.copyInto(uri, dir + '/' + name);
      } catch (err) {
        count--;
      }
    }
    const meta = this.meta(id);
    if (meta !== undefined) {
      meta.pageCount = count;
      meta.updatedAt = Date.now();
      this.saveMeta(meta);
    }
    return count;
  }

  listImages(id: string): string[] {
    const dir: string = this.dir(id) + '/' + IMAGES;
    if (!fs.accessSync(dir)) {
      return [];
    }
    const out: string[] = [];
    try {
      for (const name of fs.listFileSync(dir)) {
        out.push(dir + '/' + name);
      }
    } catch (err) {
      return out;
    }
    out.sort();
    return out;
  }

  // ---- 数据结构迁移 ----

  /**
   * 把低于 `CURRENT_SCHEMA` 的课程数据迁移到当前版本。**幂等**：已迁移的课程直接跳过。
   *
   * 迁移前先把 `meta.json` 与 `glossary.txt` 备份到 `files/backup_v<旧版本>_<时间戳>/<课程id>/`，
   * 再写新数据；**只迁移不删除**（旧的 glossary.txt 留在原地）。
   *
   * @returns 摘要（也追加写入 `files/migration.log`）；无事可做时返回 ''
   */
  migrateAll(): string {
    this.ensureRoot();
    const stamp: number = Date.now();
    const summary: string[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.root());
    } catch (err) {
      return '';
    }
    for (const name of names) {
      const meta: CourseMeta | undefined = this.meta(name);
      if (meta === undefined || meta.schemaVersion >= CURRENT_SCHEMA) {
        continue;
      }
      const from: number = meta.schemaVersion;
      const backupDir: string = this.ctx.filesDir + '/backup_v' + from + '_' + stamp + '/' + name;
      fs.mkdirSync(backupDir, true);
      // 备份要改动的文件（存在才备份）
      this.copyIfExists(this.dir(name) + '/' + META, backupDir + '/' + META);
      this.copyIfExists(this.dir(name) + '/glossary.txt', backupDir + '/glossary.txt');

      const steps: string[] = [];
      // v0 → v1：旧块式 glossary.txt → glossary.yaml
      if (from < 1) {
        const txtPath: string = this.dir(name) + '/glossary.txt';
        const yamlPath: string = this.glossaryPath(name);
        const yamlExists: boolean = fs.accessSync(yamlPath);
        const yamlEmpty: boolean = yamlExists ? fs.readTextSync(yamlPath).trim().length === 0 : true;
        if (fs.accessSync(txtPath) && yamlEmpty) {
          try {
            const entries = parseLegacyTxt(fs.readTextSync(txtPath));
            let out: string = '';
            for (let i = 0; i < entries.length; i++) {
              out += entryBlock(entries[i]);
            }
            if (out.length > 0) {
              this.writeGlossary(name, out);
            }
            steps.push('glossary.txt→yaml ' + entries.length + ' 条');
          } catch (err) {
            steps.push('glossary 迁移失败: ' + String(err).substring(0, 60));
          }
        } else if (fs.accessSync(txtPath)) {
          steps.push('glossary.yaml 已存在，跳过');
        }
      }

      meta.schemaVersion = CURRENT_SCHEMA;
      this.saveMeta(meta);
      steps.push('schema ' + from + '→' + CURRENT_SCHEMA);
      summary.push(name + ': ' + steps.join('；'));
    }
    if (summary.length === 0) {
      return '';
    }
    const logPath: string = this.ctx.filesDir + '/migration.log';
    const line: string = '[' + new Date(stamp).toISOString() + '] ' + summary.join(' | ') + '\n';
    try {
      const file = fs.openSync(logPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(file.fd, line);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      // 日志失败不影响迁移
    }
    return summary.join(' | ');
  }

  private copyIfExists(from: string, to: string): void {
    if (!fs.accessSync(from)) {
      return;
    }
    try {
      fs.copyFileSync(from, to);
    } catch (err) {
      // 备份失败不阻断（下次启动还会重试迁移）
    }
  }

  // ---- 生语汇（按课） ----

  glossaryPath(id: string): string {
    return this.dir(id) + '/' + GLOSSARY;
  }

  writeGlossary(id: string, yaml: string): void {
    const file = fs.openSync(this.glossaryPath(id),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, yaml);
    } finally {
      fs.closeSync(file);
    }
  }

  readGlossary(id: string): string {
    const path: string = this.glossaryPath(id);
    if (!fs.accessSync(path)) {
      return '';
    }
    try {
      return fs.readTextSync(path);
    } catch (err) {
      return '';
    }
  }
}
