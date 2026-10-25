/**
 * 版面分析：把 OCR 的逐行结果恢复成正确阅读顺序，并丢掉对页残留。
 *
 * 纯 TS，零平台依赖 —— App 里编译、Node 里用真机导出的 JSON 跑对拍都行。
 * 算法原型见 scripts/layout_probe.py（先在真实照片上验证过）。
 *
 * 流程：
 *   1. 按 x 区间聚类成「文字列」
 *   2. 贴图像边缘、且明显窄于主列的列 → 判为对页残片，整列丢弃
 *   3. 剩下的做 XY-cut：先横向空白带切段，再段内纵向空白带切栏
 */

export interface LayoutLine {
  text: string;
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

export interface LayoutOptions {
  imageWidth: number;
  imageHeight: number;
}

export interface LayoutResult {
  /** 恢复阅读顺序后的行 */
  ordered: LayoutLine[];
  /** 被判为对页残片而丢弃的行 */
  dropped: LayoutLine[];
  /** 丢弃前聚类出的列数 */
  columnCount: number;
  /** 丢弃后剩余的有效列数；>1 说明可能有跨页/多栏，需要用户选 */
  substantialColumns: number;
  /** 需要用户选择保留哪一列（当前只做判定，交互留给 UI） */
  needsPageChoice: boolean;
}

function lineWidth(line: LayoutLine): number {
  return line.x1 - line.x0;
}

function lineHeight(line: LayoutLine): number {
  return line.y1 - line.y0;
}

function medianLineHeight(lines: LayoutLine[]): number {
  if (lines.length === 0) {
    return 20;
  }
  const heights: number[] = [];
  for (const line of lines) {
    heights.push(lineHeight(line));
  }
  heights.sort((a: number, b: number) => a - b);
  return heights[Math.floor(heights.length / 2)];
}

interface Cluster {
  lines: LayoutLine[];
  x0: number;
  x1: number;
}

function makeCluster(lines: LayoutLine[]): Cluster {
  let x0 = Number.MAX_SAFE_INTEGER;
  let x1 = 0;
  for (const line of lines) {
    x0 = Math.min(x0, line.x0);
    x1 = Math.max(x1, line.x1);
  }
  return { lines: lines, x0: x0, x1: x1 };
}

/** 按 x 区间重叠把行聚成列；两个列一旦区间相交就合并，直到稳定 */
function clusterColumns(lines: LayoutLine[], tol: number): Cluster[] {
  const clusters: Cluster[] = [];
  const sorted: LayoutLine[] = lines.slice();
  sorted.sort((a: LayoutLine, b: LayoutLine) => a.x0 - b.x0);

  for (const line of sorted) {
    let target: Cluster | undefined = undefined;
    for (const cluster of clusters) {
      if (line.x0 <= cluster.x1 + tol) {
        target = cluster;
        break;
      }
    }
    if (target === undefined) {
      clusters.push(makeCluster([line]));
    } else {
      target.lines.push(line);
      target.x0 = Math.min(target.x0, line.x0);
      target.x1 = Math.max(target.x1, line.x1);
    }
  }

  let merged = true;
  while (merged) {
    merged = false;
    for (let i = 0; i < clusters.length && !merged; i++) {
      for (let j = i + 1; j < clusters.length; j++) {
        const a = clusters[i];
        const b = clusters[j];
        if (a.x0 <= b.x1 + tol && b.x0 <= a.x1 + tol) {
          a.lines = a.lines.concat(b.lines);
          a.x0 = Math.min(a.x0, b.x0);
          a.x1 = Math.max(a.x1, b.x1);
          clusters.splice(j, 1);
          merged = true;
          break;
        }
      }
    }
  }
  return clusters;
}

interface SliverSplit {
  kept: LayoutLine[];
  dropped: LayoutLine[];
  substantial: number;
}

/**
 * 丢弃「贴边 + 窄 + 纵向覆盖大」的列。
 * 三条同时成立才丢：对页残片是行尾碎片，误杀正文的代价比漏判高得多。
 */
export function dropEdgeSlivers(clusters: Cluster[], options: LayoutOptions): SliverSplit {
  const kept: LayoutLine[] = [];
  const dropped: LayoutLine[] = [];
  let substantial = 0;

  let mainWidth = 0;
  for (const cluster of clusters) {
    mainWidth = Math.max(mainWidth, cluster.x1 - cluster.x0);
  }

  for (const cluster of clusters) {
    let y0 = Number.MAX_SAFE_INTEGER;
    let y1 = 0;
    for (const line of cluster.lines) {
      y0 = Math.min(y0, line.y0);
      y1 = Math.max(y1, line.y1);
    }
    const width = cluster.x1 - cluster.x0;
    const touchesLeft = cluster.x0 <= options.imageWidth * 0.02;
    const touchesRight = cluster.x1 >= options.imageWidth * 0.98;
    const narrow = width < mainWidth * 0.3;
    const coversHeight = (y1 - y0) > options.imageHeight * 0.15;

    if ((touchesLeft || touchesRight) && narrow && coversHeight) {
      for (const line of cluster.lines) {
        dropped.push(line);
      }
    } else {
      for (const line of cluster.lines) {
        kept.push(line);
      }
      substantial++;
    }
  }
  return { kept: kept, dropped: dropped, substantial: substantial };
}

/** 按 y 方向空白带切段 */
function horizontalBands(lines: LayoutLine[], gap: number): LayoutLine[][] {
  const bands: LayoutLine[][] = [];
  const sorted: LayoutLine[] = lines.slice();
  sorted.sort((a: LayoutLine, b: LayoutLine) => a.y0 - b.y0);
  for (const line of sorted) {
    if (bands.length === 0) {
      bands.push([line]);
      continue;
    }
    const last = bands[bands.length - 1];
    let bottom = 0;
    for (const item of last) {
      bottom = Math.max(bottom, item.y1);
    }
    if (line.y0 - bottom <= gap) {
      last.push(line);
    } else {
      bands.push([line]);
    }
  }
  return bands;
}

function sortByPosition(lines: LayoutLine[]): LayoutLine[] {
  const out: LayoutLine[] = lines.slice();
  out.sort((a: LayoutLine, b: LayoutLine) => {
    if (a.y0 !== b.y0) {
      return a.y0 - b.y0;
    }
    return a.x0 - b.x0;
  });
  return out;
}

interface Gutter {
  start: number;
  end: number;
}

/**
 * 在 x 方向找一条「没有任何行覆盖」的竖带（栏间沟 / 书脊）。
 * 用 4px 柱状投影，返回最宽的那条；太窄的不算。
 */
function findGutter(lines: LayoutLine[], minWidth: number): Gutter | undefined {
  let minX = Number.MAX_SAFE_INTEGER;
  let maxX = 0;
  for (const line of lines) {
    minX = Math.min(minX, line.x0);
    maxX = Math.max(maxX, line.x1);
  }
  if (maxX - minX < minWidth * 2) {
    return undefined;
  }

  const step = 4;
  const bins: number = Math.floor((maxX - minX) / step) + 1;
  const cover: number[] = new Array<number>(bins).fill(0);
  for (const line of lines) {
    const start = Math.max(0, Math.floor((line.x0 - minX) / step));
    const end = Math.min(bins - 1, Math.floor((line.x1 - minX) / step));
    for (let i = start; i <= end; i++) {
      cover[i] = cover[i] + 1;
    }
  }

  let bestStart = -1;
  let bestEnd = -1;
  let runStart = -1;
  for (let i = 0; i < bins; i++) {
    if (cover[i] === 0) {
      if (runStart < 0) {
        runStart = i;
      }
    } else if (runStart >= 0) {
      if (bestStart < 0 || (i - runStart) > (bestEnd - bestStart)) {
        bestStart = runStart;
        bestEnd = i;
      }
      runStart = -1;
    }
  }
  if (runStart >= 0 && (bins - runStart) > (bestEnd - bestStart)) {
    bestStart = runStart;
    bestEnd = bins;
  }
  if (bestStart < 0) {
    return undefined;
  }

  const start = minX + bestStart * step;
  const end = minX + bestEnd * step;
  if (end - start < minWidth) {
    return undefined;
  }
  return { start: start, end: end };
}

interface Segment {
  lines: LayoutLine[];
  isCross: boolean;
  crossLine?: LayoutLine;
}

/**
 * 把跨沟的行（全宽标题之类）按 y 切开，返回「一段文字 / 一条跨沟行」交替的片段，
 * 这样标题落在它真正的位置上，而不是被甩到最前面或最后面。
 */
function splitByCross(lines: LayoutLine[], cross: LayoutLine[]): Segment[] {
  const sortedCross: LayoutLine[] = cross.slice();
  sortedCross.sort((a: LayoutLine, b: LayoutLine) => a.y0 - b.y0);

  const segments: Segment[] = [];
  let current: LayoutLine[] = [];
  let idx = 0;
  const sortedAll: LayoutLine[] = lines.slice();
  sortedAll.sort((a: LayoutLine, b: LayoutLine) => a.y0 - b.y0);

  for (const line of sortedAll) {
    if (idx < sortedCross.length && line === sortedCross[idx]) {
      if (current.length > 0) {
        segments.push({ lines: current, isCross: false });
        current = [];
      }
      segments.push({ lines: [line], isCross: true, crossLine: line });
      idx++;
    } else {
      current.push(line);
    }
  }
  if (current.length > 0) {
    segments.push({ lines: current, isCross: false });
  }
  return segments;
}

function spansGutter(line: LayoutLine, gutter: Gutter): boolean {
  return line.x0 < gutter.start && line.x1 > gutter.end;
}

interface ColumnSplit {
  left: LayoutLine[];
  right: LayoutLine[];
  cross: LayoutLine[];
}

/**
 * 把「有些行完全在边界左边、有些完全在右边、少数行横跨」的情况切成两列。
 * gutter 的 start/end 相同表示用「单点边界」而不是「空白带」。
 */
function splitColumns(lines: LayoutLine[], boundary: number): ColumnSplit {
  const left: LayoutLine[] = [];
  const right: LayoutLine[] = [];
  const cross: LayoutLine[] = [];
  for (const line of lines) {
    if (line.x1 <= boundary + 2) {
      left.push(line);
    } else if (line.x0 >= boundary - 2) {
      right.push(line);
    } else {
      cross.push(line);
    }
  }
  return { left: left, right: right, cross: cross };
}

/**
 * 没有足够宽的空白带时，用「列边界」找两列：
 * 候选边界取各行的左右端点，评分偏好「两侧行数均衡、横跨行少」。
 * 实测摊开的书里书脊沟可能只有 15px，空白带判据完全失效，但边界判据仍很稳。
 */
function findColumnBoundary(lines: LayoutLine[], imageWidth: number): number {
  const candidates: number[] = [];
  for (const line of lines) {
    candidates.push(line.x1);
    candidates.push(line.x0);
  }
  candidates.sort((a: number, b: number) => a - b);

  let bestScore = 0;
  let best = -1;
  const minX = imageWidth * 0.25;
  const maxX = imageWidth * 0.75;
  for (const boundary of candidates) {
    if (boundary < minX || boundary > maxX) {
      continue;
    }
    let left = 0;
    let right = 0;
    let cross = 0;
    for (const line of lines) {
      if (line.x1 <= boundary + 2) {
        left++;
      } else if (line.x0 >= boundary - 2) {
        right++;
      } else {
        cross++;
      }
    }
    const balance = Math.min(left, right);
    if (balance < 3) {
      continue;
    }
    const score = balance * 3 - cross * 2;
    if (score > bestScore) {
      bestScore = score;
      best = boundary;
    }
  }
  return best;
}

/**
 * 先找贯穿全高的竖向空白带切栏，切不动再横切段。
 *
 * 顺序很关键：双栏页每一行都同时有左右两栏的文字，若先横切，行会被切成一个个
 * 独立段，栏就再也分不开了（实测两栏图会退化成 L1,R1,L2,R2 的串行）。
 * 另外全宽标题会横跨栏间沟，必须单独拎出来按 y 定位，否则它会把两栏粘成一列。
 */
export function xyCut(lines: LayoutLine[], lineH: number, imageWidth: number, depth: number = 0): LayoutLine[] {
  if (lines.length <= 1 || depth > 6) {
    return sortByPosition(lines);
  }

  const vGap = Math.max(Math.floor(lineH * 2.5), Math.floor(imageWidth * 0.03));
  const split = tryColumnSplit(lines, vGap, imageWidth);
  if (split !== undefined) {
    const plain: LayoutLine[] = split.left.concat(split.right);
    if (plain.length > 0 && split.cross.length > 0) {
      const segments = splitByCross(lines, split.cross);
      let out: LayoutLine[] = [];
      for (const segment of segments) {
        if (segment.isCross) {
          out.push(segment.lines[0]);
        } else {
          out = out.concat(xyCut(segment.lines, lineH, imageWidth, depth + 1));
        }
      }
      return out;
    }
    if (split.left.length > 0 && split.right.length > 0) {
      return xyCut(split.left, lineH, imageWidth, depth + 1)
        .concat(xyCut(split.right, lineH, imageWidth, depth + 1));
    }
  }

  const hBands = horizontalBands(lines, Math.max(6, Math.floor(lineH / 2)));
  if (hBands.length > 1) {
    let out: LayoutLine[] = [];
    for (const band of hBands) {
      out = out.concat(xyCut(band, lineH, imageWidth, depth + 1));
    }
    return out;
  }

  return sortByPosition(lines);
}

/** 先试空白带（宽沟），再试列边界（窄沟） */
function tryColumnSplit(lines: LayoutLine[], vGap: number, imageWidth: number): ColumnSplit | undefined {
  const gutter = findGutter(lines, vGap);
  if (gutter !== undefined) {
    const crossing: LayoutLine[] = [];
    const rest: LayoutLine[] = [];
    for (const line of lines) {
      if (spansGutter(line, gutter)) {
        crossing.push(line);
      } else {
        rest.push(line);
      }
    }
    if (rest.length > 0 && crossing.length > 0) {
      const split = splitColumns(lines, (gutter.start + gutter.end) / 2);
      if (split.left.length > 0 && split.right.length > 0) {
        return split;
      }
    }
    if (crossing.length === 0) {
      const split = splitColumns(lines, (gutter.start + gutter.end) / 2);
      if (split.left.length > 0 && split.right.length > 0) {
        return split;
      }
    }
  }

  // 空白带不够宽：改用列边界
  const boundary = findColumnBoundary(lines, imageWidth);
  if (boundary > 0) {
    const split = splitColumns(lines, boundary);
    if (split.left.length > 0 && split.right.length > 0) {
      return split;
    }
  }
  return undefined;
}

/** 入口：给 OCR 的逐行结果，拿回可用的阅读顺序 */
export function analyzeLayout(lines: LayoutLine[], options: LayoutOptions): LayoutResult {
  if (lines.length === 0) {
    return { ordered: [], dropped: [], columnCount: 0, substantialColumns: 0, needsPageChoice: false };
  }

  const lineH = medianLineHeight(lines);
  const tol = Math.max(8, Math.floor(options.imageWidth * 0.01));
  const clusters = clusterColumns(lines, tol);
  const split = dropEdgeSlivers(clusters, options);
  const ordered = xyCut(split.kept, lineH, options.imageWidth);

  return {
    ordered: ordered,
    dropped: split.dropped,
    columnCount: clusters.length,
    substantialColumns: split.substantial,
    needsPageChoice: split.substantial > 1
  };
}

/** 把有序行拼回文本：行内接空格，段间空一行 */
export function joinText(lines: LayoutLine[], lineH: number): string {
  const rows: string[] = [];
  let prevBottom = -1;
  for (const line of lines) {
    if (prevBottom >= 0 && line.y0 - prevBottom > lineH * 1.6) {
      rows.push('');
    }
    rows.push(line.text);
    prevBottom = line.y1;
  }
  return rows.join('\n');
}

/** 便捷：算一行文本的宽度占用（调试用） */
export function totalWidth(lines: LayoutLine[]): number {
  let sum = 0;
  for (const line of lines) {
    sum += lineWidth(line);
  }
  return sum;
}
