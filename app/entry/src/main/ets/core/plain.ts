/**
 * 把模型输出转成「能朗读的纯文本」。
 *
 * 为什么要它：回答要交给端侧 TTS 朗读（D19/9d），Markdown 符号会被念出来
 * （实测出现过 `**译文**` 被整段读出）。提示词已经要求纯文本，这里只是兜底。
 */

export function toPlainText(raw: string): string {
  let s: string = raw;
  // 代码块与行内代码
  s = s.replace(/```[a-zA-Z]*\n?/g, '');
  s = s.replace(/`([^`]*)`/g, '$1');
  // 粗体/斜体
  s = s.replace(/\*\*([^*]+)\*\*/g, '$1');
  s = s.replace(/__([^_]+)__/g, '$1');
  s = s.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,，。]|$)/g, '$1$2');
  // 标题
  s = s.replace(/^\s{0,3}#{1,6}\s*/gm, '');
  // 列表符号（保留内容）
  s = s.replace(/^\s{0,3}[-*+]\s+/gm, '');
  s = s.replace(/^\s{0,3}\d+[.)]\s+/gm, '');
  // 链接 [文字](地址) → 文字
  s = s.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
  // 表格分隔线与竖线
  s = s.replace(/^\s*\|?[\s:|-]{4,}\|?\s*$/gm, '');
  s = s.replace(/\s*\|\s*/g, '，');
  // 多余空行
  s = s.replace(/\n{3,}/g, '\n\n');
  return s.trim();
}
