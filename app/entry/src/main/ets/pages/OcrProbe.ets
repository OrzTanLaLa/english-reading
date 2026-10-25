/**
 * B2 版面探针：对 rawfile 里的三张测试图跑 textRecognition，打印
 *   - 整体 value（看行序是否串栏）
 *   - blocks 数量与每块的行数、包围盒
 * 结论用于决定「App 要不要自己做裁剪」。
 */
import { textRecognition } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { analyzeLayout, joinText, LayoutLine, LayoutResult } from '../core/layout';

interface Box {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

interface CropRect {
  x: number;
  width: number;
}

interface DumpLine {
  b: number;
  v: string;
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

interface DumpFile {
  image: string;
  w: number;
  h: number;
  ms: number;
  blocks: number;
  value: string;
  lines: DumpLine[];
}

@Entry
@Component
struct OcrProbe {
  @State log: string = '准备中…';
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.runAll();
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private append(text: string): void {
    this.log = this.log + '\n' + text;
  }

  /** 用块内所有行的角点算包围盒 */
  private blockBox(block: textRecognition.TextBlock): Box {
    let x0: number = Number.MAX_VALUE;
    let y0: number = Number.MAX_VALUE;
    let x1: number = 0;
    let y1: number = 0;
    for (const line of block.lines) {
      for (const p of line.cornerPoints) {
        x0 = Math.min(x0, p.x);
        y0 = Math.min(y0, p.y);
        x1 = Math.max(x1, p.x);
        y1 = Math.max(y1, p.y);
      }
    }
    return { x0: Math.round(x0), y0: Math.round(y0), x1: Math.round(x1), y1: Math.round(y1) };
  }

  private async runOne(name: string): Promise<void> {
    const t0: number = Date.now();
    const data: Uint8Array = await this.ctx().resourceManager.getRawFileContent(name);
    const source: image.ImageSource = image.createImageSource(data.buffer as ArrayBuffer);
    const opts: image.DecodingOptions = {
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    };
    const pixelMap: image.PixelMap = await source.createPixelMap(opts);
    const info = pixelMap.getImageInfoSync();

    let result: textRecognition.TextRecognitionResult;
    try {
      result = await textRecognition.recognizeText({ pixelMap: pixelMap }, { isDirectionDetectionSupported: true });
    } finally {
      pixelMap.release();
      source.release();
    }
    const ms: number = Date.now() - t0;

    this.append('===== ' + name + '  ' + info.size.width + 'x' + info.size.height + '  ' + ms + 'ms');
    this.append('blocks=' + result.blocks.length + '  chars=' + result.value.length);
    this.append('--- value 原文 ---');
    this.append(result.value.length > 0 ? result.value : '(空)');

    const raw: LayoutLine[] = this.layoutLinesFrom(result);
    const layout: LayoutResult = analyzeLayout(raw, {
      imageWidth: info.size.width,
      imageHeight: info.size.height
    });
    this.append('--- layout ---');
    this.append('columns=' + layout.columnCount + ' substantial=' + layout.substantialColumns +
      ' needsChoice=' + layout.needsPageChoice + ' dropped=' + layout.dropped.length +
      ' kept=' + layout.ordered.length);
    for (let i = 0; i < layout.ordered.length; i++) {
      const t: string = layout.ordered[i].text;
      this.append((i + 1) + '. ' + (t.length > 60 ? t.substring(0, 60) + '…' : t));
    }
    if (layout.dropped.length > 0) {
      this.append('丢弃样本: ' + layout.dropped.slice(0, 6).map((l: LayoutLine) => l.text).join(' | '));
    }
    this.append('');
  }

  /** 单行的包围盒 */
  private boxOfLine(line: textRecognition.TextLine): Box {
    let x0: number = Number.MAX_VALUE;
    let y0: number = Number.MAX_VALUE;
    let x1: number = 0;
    let y1: number = 0;
    for (const p of line.cornerPoints) {
      x0 = Math.min(x0, p.x);
      y0 = Math.min(y0, p.y);
      x1 = Math.max(x1, p.x);
      y1 = Math.max(y1, p.y);
    }
    return { x0: Math.round(x0), y0: Math.round(y0), x1: Math.round(x1), y1: Math.round(y1) };
  }

  private async runAll(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.log = 'OCR 版面探针';
    try {
      await this.runOne('two_col.png');
      await this.runOne('two_blocks.png');
      await this.runOne('single_col.png');
      this.append('完成');
    } catch (err) {
      this.append('失败: ' + String(err));
    } finally {
      this.busy = false;
    }
  }

  /** 从相册多选照片，逐张跑 OCR + 版面分析，结果按序号写到 filesDir */
  private async pickAndDump(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 9;
      const picker = new photoAccessHelper.PhotoViewPicker();
      const picked = await picker.select(options);
      if (picked.photoUris.length === 0) {
        this.append('没有选图');
        return;
      }
      this.append('本次选了 ' + picked.photoUris.length + ' 张');
      for (let i = 0; i < picked.photoUris.length; i++) {
        this.append('');
        this.append('########## 第 ' + (i + 1) + '/' + picked.photoUris.length + ' 张');
        await this.processUri(picked.photoUris[i], i + 1);
      }
      this.append('');
      this.append('全部完成，文件已写入 ' + this.ctx().filesDir);
    } catch (err) {
      this.append('选图/识别失败: ' + String(err));
    } finally {
      this.busy = false;
    }
  }

  /** OCR 的一行 → LayoutLine（取行包围盒） */
  private toLayoutLine(line: textRecognition.TextLine): LayoutLine {
    const box = this.boxOfLine(line);
    return { text: line.value, x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1 };
  }

  /**
   * 把「被 OCR 合并了一行」的行按词间距切开。
   * 对页紧贴主页时，OCR 会把两页同一基线上的文字识别成一行（实测中间只隔 ~57px），
   * 这种行会让列边界判据失效。词间距是 3 倍中位数以上的位置就切。
   */
  private splitLineByGaps(line: textRecognition.TextLine): LayoutLine[] {
    const whole: LayoutLine = this.toLayoutLine(line);
    const words = line.words;
    if (words.length < 2) {
      return [whole];
    }

    const wx0: number[] = [];
    const wx1: number[] = [];
    for (const w of words) {
      let x0: number = Number.MAX_VALUE;
      let x1: number = 0;
      for (const p of w.cornerPoints) {
        x0 = Math.min(x0, p.x);
        x1 = Math.max(x1, p.x);
      }
      wx0.push(x0);
      wx1.push(x1);
    }

    const gaps: number[] = [];
    for (let i = 1; i < words.length; i++) {
      gaps.push(Math.max(0, wx0[i] - wx1[i - 1]));
    }
    const sorted: number[] = gaps.slice();
    sorted.sort((a: number, b: number) => a - b);
    const median: number = sorted[Math.floor(sorted.length / 2)];
    const threshold: number = Math.max(median * 3, 24);

    const segments: LayoutLine[] = [];
    let hasBigGap: boolean = false;
    for (const g of gaps) {
      if (g > threshold) {
        hasBigGap = true;
        break;
      }
    }
    if (!hasBigGap) {
      return [whole];
    }

    let start: number = 0;
    for (let i = 1; i <= words.length; i++) {
      const bigGap: boolean = i === words.length || gaps[i - 1] > threshold;
      if (!bigGap) {
        continue;
      }
      let text: string = words[start].value;
      let sx0: number = wx0[start];
      let sx1: number = wx1[start];
      for (let k = start + 1; k < i; k++) {
        // 词间距极小说明是标点，直接拼接，不要凭空加空格
        const gap: number = wx0[k] - wx1[k - 1];
        text = text + (gap > 2 ? ' ' : '') + words[k].value;
        sx0 = Math.min(sx0, wx0[k]);
        sx1 = Math.max(sx1, wx1[k]);
      }
      segments.push({
        text: text,
        x0: Math.round(sx0),
        y0: whole.y0,
        x1: Math.round(sx1),
        y1: whole.y1
      });
      start = i;
    }
    return segments;
  }

  /** OCR 结果 → 版面分析输入（含合并行拆分） */
  private layoutLinesFrom(result: textRecognition.TextRecognitionResult): LayoutLine[] {
    const out: LayoutLine[] = [];
    for (const block of result.blocks) {
      for (const line of block.lines) {
        for (const seg of this.splitLineByGaps(line)) {
          out.push(seg);
        }
      }
    }
    return out;
  }

  /** 单张：OCR → 倾斜矫正 → 版面分析 → 写 ocr_probe_<n>.json / ocr_layout_<n>.txt / thumb_<n>.jpg */
  private async processUri(uri: string, index: number): Promise<void> {
    this.append('已选: ' + uri);

    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    let result: textRecognition.TextRecognitionResult | undefined = undefined;
    let info: image.ImageInfo;
    let finalLayout: LayoutResult | undefined = undefined;
    const t0: number = Date.now();
    try {
      const source: image.ImageSource = image.createImageSource(file.fd);
      const pixelMap: image.PixelMap = await source.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      info = pixelMap.getImageInfoSync();

      // 先按 EXIF 方向把图摆正：相机横竖拍会写 Orientation，而解码不会自动应用。
      // 用行角点反推 90° 会丢掉方向（±90 归一化后分不开），所以这里以 EXIF 为准。
      const exifDeg: number = await this.exifRotation(source);
      if (exifDeg !== 0) {
        await pixelMap.applyRotate(exifDeg);
        info = pixelMap.getImageInfoSync();
        this.append('EXIF 方向: 旋转 ' + exifDeg + '° → ' + info.size.width + 'x' + info.size.height);
      }

      result = await textRecognition.recognizeText({ pixelMap: pixelMap }, { isDirectionDetectionSupported: true });

      // 再处理倾斜：|角|≥3° 就旋正（含横竖反的 ±90 情形）
      const skew: number = this.estimateSkew(result);
      if (Math.abs(skew) >= 3) {
        await pixelMap.applyRotate(-skew);
        info = pixelMap.getImageInfoSync();
        result = await textRecognition.recognizeText({ pixelMap: pixelMap }, { isDirectionDetectionSupported: true });
        this.append('检测到倾斜 ' + skew.toFixed(1) + '°，已旋正后重识别');
      }

      // 旋 90° 有两个方向，转反了就成倒置页面；用 OCR 自己的块顺序和 y 坐标对一下
      if (this.looksUpsideDown(result)) {
        await pixelMap.applyRotate(180);
        info = pixelMap.getImageInfoSync();
        result = await textRecognition.recognizeText({ pixelMap: pixelMap }, { isDirectionDetectionSupported: true });
        this.append('检测到页面倒置，已再转 180°');
      }

      // 对页紧贴时，OCR 会把两页文字在字符级粘在一起（实测 forondnone），词间距也切不开。
      // 这时只能把残片所在的那条边裁掉，再识别一遍。
      let pass: LayoutResult = analyzeLayout(this.layoutLinesFrom(result), {
        imageWidth: info.size.width,
        imageHeight: info.size.height
      });
      if (pass.dropped.length >= 3) {
        const cut = this.sliverCut(pass.dropped, pass.ordered, info.size.width);
        if (cut !== undefined) {
          await pixelMap.crop({ x: cut.x, y: 0, size: { width: cut.width, height: info.size.height } });
          info = pixelMap.getImageInfoSync();
          result = await textRecognition.recognizeText({ pixelMap: pixelMap }, { isDirectionDetectionSupported: true });
          pass = analyzeLayout(this.layoutLinesFrom(result), {
            imageWidth: info.size.width,
            imageHeight: info.size.height
          });
          this.append('已裁掉对页残片（x=' + cut.x + ', w=' + cut.width + '）后重识别');
        }
      }
      finalLayout = pass;

      // 存一张缩略图，便于事后核对照片本身（也留给校对页用）
      try {
        const scale: number = Math.min(1, 720 / Math.max(info.size.width, info.size.height));
        if (scale < 1) {
          await pixelMap.scale(scale, scale);
        }
        const packer: image.ImagePacker = image.createImagePacker();
        const jpeg: ArrayBuffer = await packer.packing(pixelMap, { format: 'image/jpeg', quality: 60 });
        const thumbPath: string = this.ctx().filesDir + '/thumb_' + index + '.jpg';
        const tf = fs.openSync(thumbPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(tf.fd, jpeg);
          fs.fsyncSync(tf.fd);
        } finally {
          fs.closeSync(tf);
        }
        packer.release();
      } catch (err) {
        this.append('缩略图失败: ' + String(err));
      }

      pixelMap.release();
      source.release();
    } finally {
      fs.closeSync(file);
    }
    if (result === undefined) {
      this.append('OCR 没有返回结果');
      return;
    }

    const ms: number = Date.now() - t0;
    const lines: DumpLine[] = [];
    for (let b = 0; b < result.blocks.length; b++) {
      const block = result.blocks[b];
      for (const line of block.lines) {
        const box = this.boxOfLine(line);
        lines.push({ b: b, v: line.value, x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1 });
      }
    }

    const layoutLines: LayoutLine[] = this.layoutLinesFrom(result);
    const layout: LayoutResult = finalLayout !== undefined ? finalLayout : analyzeLayout(layoutLines, {
      imageWidth: info.size.width,
      imageHeight: info.size.height
    });
    let sumH: number = 0;
    for (const line of layout.ordered) {
      sumH += line.y1 - line.y0;
    }
    const lineH: number = layout.ordered.length > 0 ? sumH / layout.ordered.length : 20;

    const dump: DumpFile = {
      image: uri,
      w: info.size.width,
      h: info.size.height,
      ms: ms,
      blocks: result.blocks.length,
      value: result.value,
      lines: lines
    };

    const path: string = this.ctx().filesDir + '/ocr_probe_' + index + '.json';
    const out = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(out.fd, JSON.stringify(dump));
      fs.fsyncSync(out.fd);
    } finally {
      fs.closeSync(out);
    }

    const layoutPath: string = this.ctx().filesDir + '/ocr_layout_' + index + '.txt';
    const out2 = fs.openSync(layoutPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(out2.fd, joinText(layout.ordered, lineH));
      fs.fsyncSync(out2.fd);
    } finally {
      fs.closeSync(out2);
    }

    this.append('图片 ' + info.size.width + 'x' + info.size.height + '  ' + ms + 'ms  blocks=' +
      result.blocks.length + '  lines=' + lines.length);
    this.append('layout: columns=' + layout.columnCount + ' substantial=' + layout.substantialColumns +
      ' needsChoice=' + layout.needsPageChoice + ' dropped=' + layout.dropped.length +
      ' kept=' + layout.ordered.length);
    this.append('已写: ' + path);
    this.append('--- 前 6 行（恢复顺序后） ---');
    for (let i = 0; i < Math.min(6, layout.ordered.length); i++) {
      const t: string = layout.ordered[i].text;
      this.append((i + 1) + '. ' + (t.length > 60 ? t.substring(0, 60) + '…' : t));
    }
  }

  /**
   * 残片在左还是右；返回「裁掉残片后要保留的区域」。
   * 两道保险：裁完不能少于一半宽度；**保留的行不能越过裁剪线**（否则会把正文切掉）。
   */
  private sliverCut(dropped: LayoutLine[], kept: LayoutLine[], width: number): CropRect | undefined {
    if (dropped.length === 0 || kept.length === 0) {
      return undefined;
    }
    let maxKeptX1: number = 0;
    let minKeptX0: number = width;
    for (const line of kept) {
      maxKeptX1 = Math.max(maxKeptX1, line.x1);
      minKeptX0 = Math.min(minKeptX0, line.x0);
    }

    let sum: number = 0;
    for (const line of dropped) {
      sum += (line.x0 + line.x1) / 2;
    }
    const center: number = sum / dropped.length;

    if (center > width / 2) {
      let minX: number = Number.MAX_VALUE;
      for (const line of dropped) {
        minX = Math.min(minX, line.x0);
      }
      const w: number = Math.floor(minX) - 8;
      if (w < width * 0.5 || maxKeptX1 > w) {
        return undefined;
      }
      return { x: 0, width: w };
    }

    let maxX: number = 0;
    for (const line of dropped) {
      maxX = Math.max(maxX, line.x1);
    }
    const x: number = Math.ceil(maxX) + 8;
    if (width - x < width * 0.5 || minKeptX0 < x) {
      return undefined;
    }
    return { x: x, width: width - x };
  }

  /** 页面是否倒置：正常页面的 OCR 块顺序自上而下（y 递增），明显递减说明上下颠倒 */
  private looksUpsideDown(result: textRecognition.TextRecognitionResult): boolean {
    const ys: number[] = [];
    for (const block of result.blocks) {
      let top: number = Number.MAX_VALUE;
      for (const line of block.lines) {
        top = Math.min(top, this.boxOfLine(line).y0);
      }
      if (top < Number.MAX_VALUE) {
        ys.push(top);
      }
    }
    if (ys.length < 3) {
      return false;
    }
    let down: number = 0;
    let up: number = 0;
    for (let i = 1; i < ys.length; i++) {
      if (ys[i] < ys[i - 1] - 4) {
        down++;
      } else if (ys[i] > ys[i - 1] + 4) {
        up++;
      }
    }
    return down >= 3 && down >= up * 3;
  }

  /** 读 EXIF Orientation，返回需要顺时针旋转的角度（只看 90 的整数倍）。读不到算 0。 */
  private async exifRotation(source: image.ImageSource): Promise<number> {
    try {
      const raw: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
      const v: number = Number.parseInt(raw, 10);
      if (v === 3) {
        return 180;
      }
      if (v === 6) {
        return 90;
      }
      if (v === 8) {
        return -90;
      }
    } catch (err) {
      // 没有 EXIF 字段很常见，不当作错误
    }
    return 0;
  }

  /** 用行角点估文字倾斜角（度）。角点顺时针，p0→p1 是行的上边。 */
  private estimateSkew(result: textRecognition.TextRecognitionResult): number {
    const angles: number[] = [];
    for (const block of result.blocks) {
      for (const line of block.lines) {
        const pts = line.cornerPoints;
        if (pts.length < 2) {
          continue;
        }
        const dx: number = pts[1].x - pts[0].x;
        const dy: number = pts[1].y - pts[0].y;
        if (Math.abs(dx) + Math.abs(dy) < 30) {
          continue;
        }
        let a: number = Math.atan2(dy, dx) * 180 / Math.PI;
        // 归一到 [-90, 90)：文字方向反过来（180°）时也能正确合并
        a = ((a + 90) % 180 + 180) % 180 - 90;
        angles.push(a);
      }
    }
    if (angles.length === 0) {
      return 0;
    }
    angles.sort((p: number, q: number) => p - q);
    let med: number = angles[Math.floor(angles.length / 2)];
    // 接近整 90° 的直接吸到 90，避免留下几度残差
    if (Math.abs(med) > 75) {
      med = med > 0 ? 90 : -90;
    }
    return med;
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text('OCR 版面探针' + (this.busy ? '（运行中…）' : ''))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('选照片跑 OCR（可多选）')
          .height(40)
          .enabled(!this.busy)
          .onClick(() => {
            this.pickAndDump();
          })
      }
      .width('100%')
      Scroll() {
        Text(this.log)
          .fontSize(11)
          .fontFamily('monospace')
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .padding(10)
      .backgroundColor('#F5F5F5')
      .align(Alignment.TopStart)
    }
    .padding(12)
    .width('100%')
    .height('100%')
  }
}
