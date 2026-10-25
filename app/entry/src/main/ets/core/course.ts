/**
 * 课程（一篇课文）的纯逻辑：类型、默认标题、文本指纹、文案格式化。
 *
 * 这里不碰文件系统，方便在 Node 里单测；落盘在 adapters/courseStore.ts。
 */

export interface CourseMeta {
  id: string;
  title: string;
  /** 毫秒时间戳 */
  createdAt: number;
  updatedAt: number;
  /** 合成用的音色 id */
  voice: string;
  /** 文本 + 音色的指纹，用于判断缓存是否还有效 */
  textHash: string;
  pageCount: number;
  /** 音频时长（毫秒），0 表示还没合成 */
  audioMs: number;
  wordCount: number;
  /** 上次播放到哪里（毫秒），进入朗读页时恢复 */
  lastPositionMs: number;
  /** 数据结构版本（只由迁移逻辑使用，与 versionCode 无关）；0 = 迁移前的老数据 */
  schemaVersion: number;
}

/** 当前数据结构版本。改结构就 +1，并在 courseStore.migrateAll 里加一步。 */
export const CURRENT_SCHEMA: number = 1;

/** 默认标题：未命名 2026-10-21 14:30 */
export function defaultTitle(now: number): string {
  const d: Date = new Date(now);
  const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return '未命名 ' + d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
    ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

/** FNV-1a 32 位，够用来判「文本/音色有没有变」 */
export function hashText(text: string, voice: string): string {
  const s: string = voice + '\u0000' + text;
  let h: number = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = (h * 0x01000193) >>> 0;
  }
  return h.toString(16);
}

/** 副标题：4 页 · 3 分 34 秒 · 昨天 */
export function subtitle(meta: CourseMeta, now: number): string {
  const parts: string[] = [];
  if (meta.pageCount > 0) {
    parts.push(meta.pageCount + ' 页');
  }
  if (meta.audioMs > 0) {
    const total: number = Math.floor(meta.audioMs / 1000);
    const m: number = Math.floor(total / 60);
    const s: number = total % 60;
    parts.push(m > 0 ? m + ' 分 ' + s + ' 秒' : s + ' 秒');
  }
  parts.push(relativeTime(meta.updatedAt, now));
  return parts.join(' · ');
}

/** 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 / 10-20 */
export function relativeTime(ts: number, now: number): string {
  const diff: number = now - ts;
  if (diff < 60 * 1000) {
    return '刚刚';
  }
  if (diff < 60 * 60 * 1000) {
    return Math.floor(diff / 60000) + ' 分钟前';
  }
  if (diff < 24 * 60 * 60 * 1000) {
    return Math.floor(diff / 3600000) + ' 小时前';
  }
  if (diff < 48 * 60 * 60 * 1000) {
    return '昨天';
  }
  const d: Date = new Date(ts);
  const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
  return p(d.getMonth() + 1) + '-' + p(d.getDate());
}

/** 生成一个目录安全的 id：c_<时间36进制>_<随机4位> */
export function newCourseId(now: number): string {
  const rand: number = Math.floor(Math.random() * 0x10000);
  return 'c_' + now.toString(36) + '_' + rand.toString(36);
}
