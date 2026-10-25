/**
 * 导出：`files/course/` → 一个 zip → **用户自选目录**（decisions D43）。
 *
 * 流程（全部是文档明确支持的）：
 *   1. `picker.select({ selectMode: FOLDER })` → 目录 URI（临时读写授权）；
 *   2. `new fileUri.FileUri(uri).path` → 目录路径（官方 URI→路径，内部会解百分号编码）；
 *   3. `zlib.compressFile(课程根目录, tempDir/xxx.zip)` → 一个 zip（inFile 可为目录）；
 *   4. `fs.copyFileSync(zipPath, 目录路径 + '/' + 文件名)` → 目标不存在时**由 copyFile 创建**。
 *
 * 不需要 fd、不需要 mkdir、不需要手写 URI 解码：`copyFile` 用**路径**就会自己建文件，
 * 父目录是 picker 选的那个（必然存在）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CourseStore } from './courseStore';
import { CourseMeta } from '../core/course';

export interface ExportResult {
  zipName: string;
  /** 导出后的完整路径（用户可见） */
  destPath: string;
  zipBytes: number;
  /** 打包进去的课程数 */
  ok: number;
  failed: string[];
}

const ZIP_PREFIX: string = '英语朗读-';

function stamp(): string {
  const d: Date = new Date();
  const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes());
}

export class Exporter {
  private ctx: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  async exportZip(): Promise<ExportResult> {
    const result: ExportResult = { zipName: '', destPath: '', zipBytes: 0, ok: 0, failed: [] };
    const store: CourseStore = new CourseStore(this.ctx);
    const courses: CourseMeta[] = store.list();
    const zipName: string = ZIP_PREFIX + stamp() + '.zip';
    const zipPath: string = this.ctx.tempDir + '/' + zipName;
    try {
      // 1) 先打包（前台完成；tempDir 里，应用退出自动清）
      const options: zlib.Options = {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION,
        memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
        strategy: zlib.CompressStrategy.COMPRESS_STRATEGY_DEFAULT_STRATEGY
      };
      const root: string = store.rootPath();
      console.info('[export] root=' + root + ' courses=' + courses.length);
      await zlib.compressFile(root, zipPath, options);
      const size: number = fs.statSync(zipPath).size;
      console.info('[export] zip=' + zipPath + ' size=' + size);
      if (size < 1024) {
        throw new Error('打包结果异常（' + size + ' 字节）');
      }
      result.zipBytes = size;

      // 2) 让用户选目录
      const selectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      selectOptions.selectMode = picker.DocumentSelectMode.FOLDER;
      selectOptions.maxSelectNumber = 1;
      const uris: string[] = await new picker.DocumentViewPicker(this.ctx).select(selectOptions);
      if (uris === undefined || uris.length === 0) {
        result.failed.push('未选择目录');
        return result;
      }

      // 3) URI → 路径（官方接口，自动解百分号），然后按路径拷过去
      const dirPath: string = new fileUri.FileUri(uris[0]).path;
      const destPath: string = dirPath + '/' + zipName;
      console.info('[export] uri=' + uris[0] + ' dir=' + dirPath + ' dest=' + destPath);
      fs.copyFileSync(zipPath, destPath);
      result.zipName = zipName;
      result.destPath = destPath;
      result.ok = courses.length;
    } catch (err) {
      const e = err as BusinessError;
      result.failed.push(String(err) + (e.code === undefined ? '' : ' (code=' + e.code + ')'));
      console.error('[export] failed: ' + String(err));
    } finally {
      try {
        if (fs.accessSync(zipPath)) {
          fs.unlinkSync(zipPath);
        }
      } catch (e) {
        // 清临时文件失败不影响导出
      }
    }
    return result;
  }
}
