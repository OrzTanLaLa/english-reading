/**
 * 探针：验证 adapters/tts.ts（官方 HarmonyOS SDK 版）端到端可用。
 * 只关心四件事：PCM 长度、词时间戳数量、首包延迟、总耗时。
 */
import { QwenTts, TtsResult, WordTiming } from '../adapters/tts';
import { LOCAL_DASHSCOPE_KEY } from '../adapters/local_secret';

const TEST_TEXT: string =
  'Coffee was once a mystery. Nobody knew why it kept people awake, or why it tasted so bitter.';

@Entry
@Component
struct TtsSdkProbe {
  @State status: string = '待开始';
  @State detail: string = '';
  @State log: string = '';

  private append(text: string): void {
    this.log = text + '\n' + this.log;
  }

  private async runTest(): Promise<void> {
    this.status = '合成中…';
    this.detail = '';
    this.log = '';
    const tts: QwenTts = new QwenTts(LOCAL_DASHSCOPE_KEY, 'Emily_v3.1');
    try {
      const res: TtsResult = await tts.synthesize(TEST_TEXT, {});
      const ms: number = Math.floor(res.pcm.byteLength / 32);
      this.status = '完成';
      this.detail = 'PCM ' + res.pcm.byteLength + ' 字节 (' + ms + 'ms) / ' +
        res.words.length + ' 词 / 首包 ' + res.firstPacketMs + 'ms / 总 ' + res.totalMs + 'ms';
      let head: string = '';
      const n: number = Math.min(5, res.words.length);
      for (let i = 0; i < n; i++) {
        const w: WordTiming = res.words[i];
        head += w.text + '@' + w.begin + '-' + w.end + '  ';
      }
      this.append('前 5 词: ' + head);
      if (res.words.length > 0) {
        const last: WordTiming = res.words[res.words.length - 1];
        this.append('末词: ' + last.text + '@' + last.begin + '-' + last.end);
      }
    } catch (err) {
      this.status = '失败';
      this.append('错误: ' + JSON.stringify(err).substring(0, 300));
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('TTS Adapter 探针').fontSize(20).fontWeight(FontWeight.Bold)
      Text(this.status).fontSize(16)
      Text(this.detail).fontSize(13).fontColor('#444444')
      Button('开始合成测试')
        .width('60%')
        .height(44)
        .onClick(() => {
          this.runTest();
        })
      Scroll() {
        Text(this.log).fontSize(12).fontColor('#666666').width('100%')
      }
      .layoutWeight(1)
      .width('100%')
    }
    .padding(20)
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
