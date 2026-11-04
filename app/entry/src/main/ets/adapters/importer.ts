/**
 * 导入：用户选一个**导出过的 zip**，解压回 `files/course/`（decisions D47）。
 *
 * 三点约束（都来自文档/实测）：
 *   1. `zlib.decompressFile(inFile, outFile, options)` 只认**沙箱路径**，所以先把用户选的 URI
 *      拷到 `tempDir`（用 `copyFileSync(fd, path)`：src 可以是 fd，dest 是路径）；
 *   2. 导出 zip 的顶层条目就是 `<课程id>/…`，所以直接解压到临时目录，再把每个顶层目录搬进 `course/`；
 *   3. 搬迁用 `fs.renameSync`（同一文件系统内，秒完成，不复制大文件）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CourseStore } from './courseStore';

export interface ImportResult {
  /** 导入了多少门 */
  ok: number;
  /** 失败原因（空串表示成功） */
  error: string;
}

export class Importer {
  private ctx: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  /** 让用户选一个 zip；取消返回 '' */
  async pickZip(): Promise<string> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.selectMode = picker.DocumentSelectMode.FILE;
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['压缩包|.zip'];
    const uris: string[] = await new picker.DocumentViewPicker(this.ctx).select(options);
    return uris !== undefined && uris.length > 0 ? uris[0] : '';
  }

  async importZip(zipUri: string): Promise<ImportResult> {
    const result: ImportResult = { ok: 0, error: '' };
    const work: string = this.ctx.tempDir + '/import';
    const zipPath: string = work + '/in.zip';
    const unzDir: string = work + '/unz';
    try {
      this.resetDir(work);
      fs.mkdirSync(unzDir, true);
      // 1) 用户文件 URI → 沙箱内临时文件（copyFileSync 的 src 支持 fd）
      const src: fs.File = fs.openSync(zipUri, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(src.fd, zipPath);
      } finally {
        fs.closeSync(src);
      }
      // 2) 解压
      const options: zlib.Options = {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
        memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
        strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY
      };
      await zlib.decompressFile(zipPath, unzDir, options);
      // 3) 把解压出的每个顶层目录搬进 course/
      const store: CourseStore = new CourseStore(this.ctx);
      const root: string = store.rootPath();
      if (!fs.accessSync(root)) {
        fs.mkdirSync(root, true);
      }
      const names: string[] = fs.listFileSync(unzDir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        const from: string = unzDir + '/' + name;
        if (!fs.statSync(from).isDirectory()) {
          continue;   // 只看课程目录
        }
        const to: string = root + '/' + name;
        if (fs.accessSync(to)) {
          fs.rmdirSync(to);   // 已存在则覆盖（导出是完整目录，直接替换）
        }
        fs.renameSync(from, to);
        result.ok++;
      }
      if (result.ok === 0) {
        result.error = '压缩包里没有找到课程目录';
      }
    } catch (err) {
      const e = err as BusinessError;
      result.error = String(err) + (e.code === undefined ? '' : ' (code=' + e.code + ')');
      console.error('[import] failed: ' + String(err));
    } finally {
      try {
        this.resetDir(work);
      } catch (e) {
        // 清临时目录失败不影响导入
      }
    }
    return result;
  }

  /** 删除并重建一个沙箱目录 */
  private resetDir(dir: string): void {
    try {
      if (fs.accessSync(dir)) {
        fs.rmdirSync(dir);
      }
    } catch (e) {
      // 不存在就算了
    }
  }
}
