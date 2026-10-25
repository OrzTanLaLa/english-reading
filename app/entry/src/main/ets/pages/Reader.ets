/**
 * 朗读页（重写版）：按 docs/应用设计.md §4.4 实现。
 *
 * 布局：左 70% 正文，右 30%（按钮行 / 对话区 / 输入框）。
 * 视图：默认「读法」（words 拼接，可逐词高亮）；可切「原文」（不高亮）。
 *
 * 设计约束（见 reader-rewrite-spec.md）：
 *   1. 正文只有一个渲染入口 if (showWords) {...} else {...}，不嵌进别的 if 链；
 *   2. 高亮只有一种来源：读法视图的 wordOffsets；原文视图恒不显示；
 *   3. 按钮/对话/输入框放在分支之外，所有状态共用。
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, TextStyleMode } from '@kit.UIDesignKit';
import { text } from '@kit.ArkGraphics2D';
import { fileIo as fs } from '@kit.CoreFileKit';
import { CourseStore, WordTiming } from '../adapters/courseStore';
import { PcmPlayer } from '../adapters/player';
import { QwenTts, TtsResult } from '../adapters/tts';
import { SettingsStore } from '../adapters/storage';
import { CourseMeta, hashText } from '../core/course';
import { splitParagraphs, Paragraph } from '../core/reader';
import { splitSentences } from '../core/segment';
import { DEFAULT_VOICE } from '../core/voices';
import { CqrParser } from '../adapters/cqr';
import { Recorder } from '../adapters/recorder';
import { AnswerVoice } from '../adapters/answerVoice';
import { DeepSeekClient } from '../adapters/llm';
import { ANSWER_SYSTEM_PROMPT } from '../core/prompts';
import { parseReply, buildEntry, appendEntry, AnswerReply, VocabEntry } from '../core/glossary';
import { toPlainText } from '../core/plain';
import { LOCAL_DASHSCOPE_KEY, LOCAL_DEEPSEEK_KEY } from '../adapters/local_secret';

/** 一个高亮块（读法视图里词可能跨行，所以是数组） */
class HlRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

@Entry
@Component
struct Reader {
  @State title: string = '';
  @State text: string = '';
  @State showWords: boolean = true;
  @State displayText: string = '';
  @State hlRects: HlRect[] = [];
  @State synthesizing: boolean = false;
  @State synthError: string = '';
  @State playing: boolean = false;
  @State paused: boolean = false;
  @State positionMs: number = 0;
  @State totalMs: number = 0;
  @State dialog: string = '';
  @State question: string = '';
  @State recording: boolean = false;
  @State asking: boolean = false;
  @State statusText: string = '';

  private courseId: string = '';
  private voice: string = DEFAULT_VOICE;
  private store: CourseStore | undefined = undefined;
  private player: PcmPlayer | undefined = undefined;
  private recorder: Recorder = new Recorder();
  private answerVoice: AnswerVoice = new AnswerVoice();

  private words: WordTiming[] = [];
  private wordOffsets: number[] = [];
  private wordCtrl: TextController = new TextController();
  private paras: Paragraph[] = [];
  private controllers: Map<number, TextController> = new Map<number, TextController>();
  private activeIndex: number = 0;
  /** 当前词在原文里的检索游标（顺序前进，避免每次从头找） */
  private posCursor: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null && params['id'] !== undefined) {
      this.courseId = String(params['id']);
    }
    this.load();
  }

  aboutToDisappear(): void {
    this.player?.release();
    this.answerVoice.release();
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private getStore(): CourseStore {
    if (this.store === undefined) {
      this.store = new CourseStore(this.ctx());
    }
    return this.store!;
  }

  private async load(): Promise<void> {
    const s: CourseStore = this.getStore();
    const meta: CourseMeta | undefined = s.meta(this.courseId);
    if (meta === undefined) {
      this.synthError = '找不到这篇课文';
      return;
    }
    this.title = meta.title;
    this.text = s.readText(this.courseId);
    this.voice = meta.voice.length > 0 ? meta.voice : DEFAULT_VOICE;
    this.paras = splitParagraphs(this.text);

    const hash: string = hashText(this.text, this.voice);
    if (meta.textHash === hash && s.hasAudio(this.courseId)) {
      this.adopt(s.readAudio(this.courseId), s.readWords(this.courseId));
      return;
    }
    await this.synthesize();
  }

  private async synthesize(): Promise<void> {
    this.synthesizing = true;
    this.synthError = '';
    try {
      let key: string = await SettingsStore.loadDashScopeKey(this.ctx());
      if (key.length === 0) {
        key = LOCAL_DASHSCOPE_KEY;
      }
      const tts = new QwenTts(key, this.voice);
      const r: TtsResult = await tts.synthesize(this.text.trim(), {});
      const s: CourseStore = this.getStore();
      s.writeAudio(this.courseId, r.pcm);
      s.writeWords(this.courseId, r.words);
      s.writeSentences(this.courseId, r.sentences);
      const meta: CourseMeta | undefined = s.meta(this.courseId);
      if (meta !== undefined) {
        meta.textHash = hashText(this.text, this.voice);
        s.saveMeta(meta);
      }
      this.adopt(r.pcm, r.words);
    } catch (err) {
      this.synthError = '语音生成失败：' + String(err).substring(0, 120);
    } finally {
      this.synthesizing = false;
    }
  }

  /** 装入音频与词表：同时构造「读法」文本与词偏移（不依赖任何文本匹配） */
  private adopt(pcm: ArrayBuffer, ws: WordTiming[]): void {
    this.words = ws;
    let disp: string = '';
    const offs: number[] = [];
    for (let i = 0; i < ws.length; i++) {
      offs.push(disp.length);
      disp += ws[i].text;
    }
    this.displayText = disp.trim();
    this.wordOffsets = offs;
    this.totalMs = Math.floor(pcm.byteLength / 32);

    const player = new PcmPlayer({
      onWord: (i: number) => {
        this.activeIndex = i;
        this.positionMs = this.player !== undefined ? this.player.positionMs() : 0;
        this.highlight(i);
      },
      onEnded: () => {
        this.playing = false;
        this.paused = false;
        this.hlRects = [];
      }
    });
    player.setData(pcm, ws, 0);
    this.player = player;
    this.playing = false;
    this.paused = false;
    this.positionMs = 0;
  }

  /** 读法视图：用构造时算好的偏移取词矩形 */
  private highlight(wi: number, retry: number = 3): void {
    if (!this.showWords) {
      this.hlRects = [];
      return;
    }
    if (wi < 0 || wi >= this.wordOffsets.length) {
      this.hlRects = [];
      return;
    }
    const lm: LayoutManager | undefined = this.wordCtrl.getLayoutManager();
    if (lm === undefined) {
      if (retry > 0) {
        setTimeout(() => this.highlight(wi, retry - 1), 30);
      }
      return;
    }
    const from: number = this.wordOffsets[wi];
    const to: number = from + this.words[wi].text.length;
    const boxes: text.TextBox[] = lm.getRectsForRange(
      { start: from, end: to },
      text.RectWidthStyle.TIGHT, text.RectHeightStyle.TIGHT);
    const rects: HlRect[] = [];
    for (const b of boxes) {
      const it: HlRect = new HlRect();
      it.x = px2vp(b.rect.left);
      it.y = px2vp(b.rect.top);
      it.w = px2vp(b.rect.right - b.rect.left);
      it.h = px2vp(b.rect.bottom - b.rect.top);
      rects.push(it);
    }
    if (rects.length === 0) {
      if (retry > 0) {
        setTimeout(() => this.highlight(wi, retry - 1), 30);
      }
      return;
    }
    this.hlRects = rects;
  }

  /** 点正文任意位置 → 跳到该位置的词（仅读法视图） */
  private async onWordTap(xVp: number, yVp: number): Promise<void> {
    if (this.player === undefined || this.synthesizing) {
      return;
    }
    const lm: LayoutManager | undefined = this.wordCtrl.getLayoutManager();
    if (lm === undefined) {
      return;
    }
    const pos: PositionWithAffinity | undefined = lm.getCharacterPositionAtCoordinate(
      vp2px(xVp), vp2px(yVp), TextEncoding.TEXT_ENCODING_UTF16);
    if (pos === undefined) {
      return;
    }
    const wi: number = this.wordAt(pos.position);
    if (wi < 0) {
      return;
    }
    this.activeIndex = wi;
    await this.player.seekTo(this.words[wi].begin);
    // seekTo 只在「本来在播」时才继续；点击跳转后要显式开始播
    if (!this.player.isPlaying()) {
      await this.player.play();
    }
    this.syncState();
    setTimeout(() => this.highlight(wi), 40);
  }

  /** 字符偏移 → 词下标（offsets 有序，线性扫描即可） */
  private wordAt(charOffset: number): number {
    let best: number = -1;
    for (let i = 0; i < this.wordOffsets.length; i++) {
      if (this.wordOffsets[i] <= charOffset) {
        best = i;
      } else {
        break;
      }
    }
    return best;
  }

  /** 从播放器同步 UI 状态（唯一真源） */
  private syncState(): void {
    const p: boolean = this.player !== undefined ? this.player.isPlaying() : false;
    this.playing = p;
    this.paused = !p && this.totalMs > 0;
  }

  private toggleView(): void {
    this.showWords = !this.showWords;
    this.hlRects = [];
    if (this.showWords) {
      setTimeout(() => this.highlight(this.activeIndex), 40);
    }
  }

  private async onPlayPause(): Promise<void> {
    if (this.synthesizing || this.synthError.length > 0 || this.player === undefined) {
      return;
    }
    await this.player.toggle();
    this.syncState();
  }

  private controllerOf(i: number): TextController {
    let c: TextController | undefined = this.controllers.get(i);
    if (c === undefined) {
      c = new TextController();
      this.controllers.set(i, c);
    }
    return c;
  }

  private paraText(i: number): string {
    if (i < 0 || i >= this.paras.length) {
      return '';
    }
    return this.text.substring(this.paras[i].start, this.paras[i].end);
  }

  private indexArray(): number[] {
    const a: number[] = [];
    for (let i = 0; i < this.paras.length; i++) {
      a.push(i);
    }
    return a;
  }

  /**
   * 当前播放位置对应的句子序号（1 起）。
   * 内部用当前词的字符位置做定位，但**只返回句号**——「当前词」不再进任何模型提示词（D45）。
   */
  private currentSentenceIndex(): number {
    const list: string[] = splitSentences(this.text);
    if (list.length === 0 || this.words.length === 0) {
      return 1;
    }
    const wi: number = Math.max(0, Math.min(this.activeIndex, this.words.length - 1));
    const w: string = this.words[wi].text.trim();
    // ① 先用当前词在原文里定位（顺序游标，整体 O(n)）
    let target: number = -1;
    if (w.length > 0) {
      const pos: number = this.text.indexOf(w, this.posCursor);
      if (pos >= 0) {
        target = pos;
        this.posCursor = pos + w.length;
      }
    }
    // ② 找不到（数字/缩写被规范化）就退回按播放比例估算
    if (target < 0) {
      const ratio: number = Math.max(0, Math.min(1, wi / this.words.length));
      target = Math.floor(ratio * this.text.length);
    }
    let acc: number = 0;
    let idx: number = 1;
    for (let i = 0; i < list.length; i++) {
      acc += list[i].length;
      if (target <= acc) {
        idx = i + 1;
        break;
      }
      idx = list.length;
    }
    return idx;
  }

  /** 第 n 句原文（1 起） */
  private sentenceAt(n: number): string {
    const list: string[] = splitSentences(this.text);
    if (n < 1 || n > list.length) {
      return list.length > 0 ? list[0] : '';
    }
    return list[n - 1];
  }

  private contextLine(): string {
    if (this.words.length === 0) {
      return '';
    }
    const wi: number = Math.max(0, Math.min(this.activeIndex, this.words.length - 1));
    const w: string = this.words[wi].text.trim();
    const list: string[] = splitSentences(this.text);
    const t: number = this.positionMs;
    let acc: number = 0;
    let cur: string = '';
    for (let i = 0; i < list.length; i++) {
      const dur: number = list[i].length;
      acc += dur;
      if (acc / Math.max(1, this.text.length) * this.totalMs >= t) {
        cur = list[i];
        break;
      }
    }
    return '当前播放到第 ' + (wi + 1) + ' 个词「' + w + '」' +
      (cur.length > 0 ? '，所在句：' + cur : '') + '。';
  }

  private appendDialog(q: string, a: string): void {
    const head: string = this.dialog.length > 0 ? this.dialog + '\n\n' : '';
    this.dialog = head + '问：' + q + '\n答：' + a;
  }

  /**
   * 读法视图里的当前句（给 LLM 当语境）。
   *
   * 规则故意做得很笨，够用就行：
   *   左端：当前词首字符是句号 → 取它后面那个字符；否则向左找第一个句号，取其后一位；
   *   右端：向右找第一个句号（含句号本身）。
   * 感叹号/问号**不管**——多圈进来一点无害，漏掉半句才麻烦。
   */
  private currentSentenceRead(): string {
    const src: string = this.displayText;
    if (src.length === 0) {
      return '';
    }
    const wi: number = Math.max(0, Math.min(this.activeIndex, this.words.length - 1));
    let pos: number = this.wordOffsets.length > wi ? this.wordOffsets[wi] : 0;
    if (pos < 0) {
      pos = 0;
    }
    if (pos >= src.length) {
      pos = src.length - 1;
    }
    let start: number = 0;
    if (src.charAt(pos) === '.') {
      start = pos + 1;
    } else {
      const left: number = src.lastIndexOf('.', pos);
      start = left < 0 ? 0 : left + 1;
    }
    const right: number = src.indexOf('.', pos);
    const end: number = right < 0 ? src.length : right + 1;
    if (start >= end) {
      start = 0;
    }
    return src.substring(start, end).trim();
  }

  /**
   * 提问：一次 LLM 调用拿「类型 + 回答」，**代码自己写语汇文件**（不再有 agent 工具调用）。
   * 语境分两份（D44）：
   *   - **全文用原文**（`this.text` = text.txt）：保留括号/破折号等符号，数字是原样；
   *   - **当前句用读法**（`displayText` 的词偏移 → 按句号截取）：与高亮/点击的词同坐标系。
   * 两者逐字对不上没关系——句子顺序一致，模型自己能把「当前句」对到「全文」里。
   */
  private async askAgent(q: string, extra: string): Promise<void> {
    if (q.length === 0 || this.asking) {
      return;
    }
    this.asking = true;
    this.statusText = '正在回答…';
    try {
      let key: string = await SettingsStore.loadApiKey(this.ctx());
      if (key.length === 0) {
        key = LOCAL_DEEPSEEK_KEY;
      }
      const source: string = this.text.length > 0 ? this.text : this.displayText;
      let sentence: string = this.currentSentenceRead();
      if (sentence.length === 0) {
        // 还没有读法（未合成）→ 用原文第一句兜底；不做跨坐标系估算
        const list: string[] = splitSentences(this.text);
        sentence = list.length > 0 ? list[0] : this.text.substring(0, 200);
      }
      const prompt: string = '课文全文：\n' + source +
        '\n\n当前句：' + sentence +
        (extra.length > 0 ? '\n' + extra : '') +
        '\n\n问题：' + q;

      const client = new DeepSeekClient(key);
      const msg = await client.complete([
        { role: 'system', content: ANSWER_SYSTEM_PROMPT },
        { role: 'user', content: prompt }
      ], [], true);
      const reply: AnswerReply = parseReply(msg.content === undefined ? '' : msg.content);
      reply.answer = toPlainText(reply.answer);
      if (reply.answer.length === 0) {
        this.statusText = '回答为空，再问一次';
        return;
      }

      // 写生语汇（YAML，代码落盘）：语境/问题由应用补，单词/搭配来自模型
      const store = this.getStore();
      const entry: VocabEntry = buildEntry(reply, sentence, q);
      const before: string = store.readGlossary(this.courseId);
      store.writeGlossary(this.courseId, appendEntry(before, entry));

      this.appendDialog(q, reply.answer);
      this.statusText = '';
      void this.answerVoice.speak(reply.answer);
    } catch (err) {
      this.statusText = '回答失败：' + String(err).substring(0, 80);
    } finally {
      this.asking = false;
    }
  }

  private async onMic(): Promise<void> {
    if (!this.recording) {
      const ok: boolean = await this.recorder.ensurePermission(this.ctx());
      if (!ok) {
        this.statusText = '没有麦克风权限';
        return;
      }
      try {
        await this.recorder.start();
        this.recording = true;
        this.statusText = '录音中… 说完点一次';
      } catch (err) {
        this.statusText = '录音失败：' + String(err).substring(0, 60);
      }
      return;
    }
    this.recording = false;
    this.statusText = '识别中…';
    const b64: string = await this.recorder.stop();
    if (b64.length === 0) {
      this.statusText = '没有录到声音';
      return;
    }
    try {
      let key: string = await SettingsStore.loadDashScopeKey(this.ctx());
      if (key.length === 0) {
        key = LOCAL_DASHSCOPE_KEY;
      }
      const parser = new CqrParser(key);
      const idx: number = this.currentSentenceIndex();
      const q: string = await parser.parse(b64, this.sentenceAt(idx));
      if (q.length === 0) {
        this.statusText = '没听清，再说一次';
        return;
      }
      this.statusText = '';
      await this.askAgent(q, '');
    } catch (err) {
      this.statusText = '解析失败：' + String(err).substring(0, 60);
    }
  }

  private submit(): void {
    const q: string = this.question.trim();
    if (q.length === 0) {
      return;
    }
    this.question = '';
    void this.askAgent(q, '');
  }

  build() {
    HdsNavigation() {
    Column() {
      // 主体：左 70% 正文 / 右 30%
      Row({ space: 10 }) {
        // ---------- 左：正文 ----------
        if (this.synthesizing) {
          Column() {
            LoadingProgress().width(36).height(36)
            Text('语音合成中…').fontSize(14).fontColor('#666666').margin({ top: 8 })
          }
          .width('70%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.synthError.length > 0) {
          Column({ space: 10 }) {
            Text(this.synthError).fontSize(14).fontColor('#D32F2F')
            Button('重试').height(36).onClick(() => {
              void this.synthesize();
            })
          }
          .width('70%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.showWords) {
          Scroll() {
            Stack({ alignContent: Alignment.TopStart }) {
              ForEach(this.hlRects, (r: HlRect) => {
                Row()
                  .width(r.w)
                  .height(r.h)
                  .position({ x: r.x, y: r.y })
                  .backgroundColor('#B9D5FA')
                  .borderRadius(3)
              }, (r: HlRect) => 'h' + Math.round(r.x) + '_' + Math.round(r.y))
              Text(this.displayText, { controller: this.wordCtrl })
                .fontSize(19)
                .lineHeight(32)
                .width('100%')
                .onClick((e: ClickEvent) => {
                  void this.onWordTap(e.x, e.y);
                })
            }
            .width('100%')
          }
          .width('70%')
          .height('100%')
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)
        } else {
          List({ space: 14 }) {
            ForEach(this.indexArray(), (i: number) => {
              ListItem() {
                Text(this.paraText(i))
                  .fontSize(19)
                  .lineHeight(32)
                  .width('100%')
              }
            }, (i: number) => i.toString())
          }
          .width('70%')
          .height('100%')
          .scrollBar(BarState.Auto)
        }

        // ---------- 右：按钮 / 对话 / 输入 ----------
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            if (!this.recording) {
            Button() {
              if (this.playing && !this.paused) {
                SymbolGlyph($r('sys.symbol.pause')).fontSize(22).fontColor([Color.White])
              } else {
                SymbolGlyph($r('sys.symbol.play_fill')).fontSize(22).fontColor([Color.White])
              }
            }
            .height(44)
            .layoutWeight(1)
            .onClick(() => {
              void this.onPlayPause();
            })
            }

            if (!this.recording) {
              Button() {
                SymbolGlyph($r('sys.symbol.mic_fill')).fontSize(22).fontColor([Color.White])
              }
              .height(44)
              .layoutWeight(1)
              .backgroundColor('#4C7DF0')
              .onClick(() => {
                void this.onMic();
              })
            } else {
              Button() {
                SymbolGlyph($r('sys.symbol.stop_circle_fill')).fontSize(22).fontColor([Color.White])
              }
              .height(44)
              .layoutWeight(1)
              .backgroundColor('#D9534F')
              .onClick(() => {
                void this.onMic();
              })

              Button('取消')
                .height(44)
                .layoutWeight(1)
                .fontSize(14)
                .backgroundColor('#EEEEEE')
                .fontColor('#333333')
                .onClick(() => {
                  void this.recorder.cancel();
                  this.recording = false;
                  this.statusText = '已取消';
                })
            }
          }
          .width('100%')

          Text(this.statusText.length > 0 ? this.statusText : (this.asking ? '回答中…' : ' '))
            .fontSize(11)
            .fontColor('#888888')
            .width('100%')
            .maxLines(1)

          Scroll() {
            Text(this.dialog.length > 0 ? this.dialog : '（对话会显示在这里）')
              .fontSize(14)
              .lineHeight(22)
              .width('100%')
              .fontColor(this.dialog.length > 0 ? '#222222' : '#AAAAAA')
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)

          Row({ space: 6 }) {
            TextInput({ text: this.question, placeholder: '输入问题…' })
              .layoutWeight(1)
              .height(38)
              .fontSize(14)
              .onChange((v: string) => {
                this.question = v;
              })
              .onSubmit(() => this.submit())
            Button('发送')
              .height(38)
              .fontSize(13)
              .backgroundColor('#4C7DF0')
              .onClick(() => this.submit())
          }
          .width('100%')
        }
        .width('30%')
        .height('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .padding({ top: 56 })
    .backgroundColor('#FFFFFF')
    }
    .titleBar({
      content: {
        title: {
          mainTitle: this.title
        },
        backIcon: {
          icon: $r('sys.symbol.chevron_left'),
          label: '返回',
          action: () => {
            router.back();
          }
        },
        menu: {
          value: [{
            content: {
              label: this.showWords ? '显示原文' : '显示读法',
              type: TextStyleMode.NORMAL,
              action: () => this.toggleView()
            }
          }, {
            content: {
              label: '语汇录',
              type: TextStyleMode.NORMAL,
              action: () => {
                router.pushUrl({
                  url: 'pages/Glossary',
                  params: { id: this.courseId, title: this.title }
                });
              }
            }
          }]
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .hideToolBar(true)
  }
}
