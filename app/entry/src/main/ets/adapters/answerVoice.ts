/**
 * 回答朗读：用端侧 TTS（@kit.CoreSpeechKit）直接播报，免费、离线、不计费。
 *
 * 为什么用 playType = 1：端侧引擎可直接播报（内部走音频通道），
 * 我们不需要接 onData 的 PCM、也不用关心采样率；playType = 0 才是「只合成返回音频流」。
 *
 * 注意：端侧 TTS **没有词级时间戳**，所以只能用于回答朗读，
 * 不能用来读课文（课文高亮必须用云端 TTS 的 word timestamp）。
 */
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class AnswerVoice {
  private engine: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private seq: number = 0;

  private listener: textToSpeech.SpeakListener = {
    onStart: (requestId: string, response: textToSpeech.StartResponse) => {
    },
    onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
    },
    onStop: (requestId: string, response: textToSpeech.StopResponse) => {
    },
    onData: (requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse) => {
    },
    onError: (requestId: string, errorCode: number, errorMessage: string) => {
      console.error('[AnswerVoice] onError ' + errorCode + ' ' + errorMessage);
    }
  };

  private async ensure(): Promise<textToSpeech.TextToSpeechEngine> {
    if (this.engine === undefined) {
      // 官方示例用 online:1 + style/locate/name；online:0（纯离线）在本机创建失败（1002300005）
      const extra: Record<string, Object> = {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'name': 'EngineName'
      };
      const params: textToSpeech.CreateEngineParams = {
        language: 'zh-CN',
        person: 0,
        online: 1,
        extraParams: extra
      };
      this.engine = await textToSpeech.createEngine(params);
      this.engine.setListener(this.listener);
    }
    return this.engine!;
  }

  /** 朗读一段文本；失败只记日志，不影响界面 */
  async speak(text: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    try {
      const engine: textToSpeech.TextToSpeechEngine = await this.ensure();
      this.seq += 1;
      const extra: Record<string, Object> = {
        'queueMode': 0,
        'speed': 1,
        'volume': 2,
        'pitch': 1,
        'languageContext': 'zh-CN',
        'audioType': 'pcm',
        // 1 = 媒体流（StreamUsage MUSIC 系）：与课文共用媒体音量，避免「助手音量=0 → 回答没声」的坑。
        // 文档提示通道 1/12 在息屏时可能播报截断（低功耗模式），本场景都在前台，可接受。
        'soundChannel': 1,
        'playType': 1
      };
      const params: textToSpeech.SpeakParams = {
        requestId: 'ans-' + this.seq + '-' + Date.now(),
        extraParams: extra
      };
      engine.speak(text, params);
    } catch (err) {
      const be = err as BusinessError;
      console.error('[AnswerVoice] speak 失败 ' + be.code + ' ' + be.message);
    }
  }

  stop(): void {
    try {
      this.engine?.stop();
    } catch (err) {
    }
  }

  release(): void {
    try {
      this.engine?.shutdown();
    } catch (err) {
    }
    this.engine = undefined;
  }
}
