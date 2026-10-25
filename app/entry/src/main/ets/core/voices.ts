/**
 * TTS 音色清单：qwen-audio-3.1-tts-flash 的「精品英文音色」共 15 个。
 *
 * 这些音色**仅支持英文**，voice 值区分大小写，必须带 `_v3.1` 后缀；
 * 用错音色会返回 `[cosyvoice:]Engine error [411]: TTS speak operation failed`。
 *
 * 来源：百炼「Qwen-Audio-TTS 音色列表」→ qwen-audio-3.1-tts-flash → 精品英文音色。
 */

export interface VoiceInfo {
  /** 传给 API 的 voice 值（区分大小写） */
  id: string;
  /** 展示名 */
  name: string;
  /** 'f' | 'm' */
  gender: string;
  /** 'UK' | 'US' */
  accent: string;
}

export const EN_VOICES: VoiceInfo[] = [
  { id: 'Emily_v3.1', name: 'Emily', gender: 'f', accent: 'UK' },
  { id: 'Luna_v3.1', name: 'Luna', gender: 'f', accent: 'UK' },
  { id: 'Eric_v3.1', name: 'Eric', gender: 'm', accent: 'UK' },
  { id: 'Luca_v3.1', name: 'Luca', gender: 'm', accent: 'UK' },
  { id: 'Abby_v3.1', name: 'Abby', gender: 'f', accent: 'US' },
  { id: 'Annie_v3.1', name: 'Annie', gender: 'f', accent: 'US' },
  { id: 'Ava_v3.1', name: 'Ava', gender: 'f', accent: 'US' },
  { id: 'Beth_v3.1', name: 'Beth', gender: 'f', accent: 'US' },
  { id: 'Betty_v3.1', name: 'Betty', gender: 'f', accent: 'US' },
  { id: 'Cally_v3.1', name: 'Cally', gender: 'f', accent: 'US' },
  { id: 'Cindy_v3.1', name: 'Cindy', gender: 'f', accent: 'US' },
  { id: 'Donna_v3.1', name: 'Donna', gender: 'f', accent: 'US' },
  { id: 'Andy_v3.1', name: 'Andy', gender: 'm', accent: 'US' },
  { id: 'Brian_v3.1', name: 'Brian', gender: 'm', accent: 'US' },
  { id: 'David_v3.1', name: 'David', gender: 'm', accent: 'US' }
];

/** 默认音色：美式女声，教材朗读最常见 */
export const DEFAULT_VOICE: string = 'Abby_v3.1';

export function voiceLabel(v: VoiceInfo): string {
  return v.name + '（' + (v.accent === 'UK' ? '英式' : '美式') + (v.gender === 'f' ? '女' : '男') + '）';
}

export function findVoice(id: string): VoiceInfo | undefined {
  for (const v of EN_VOICES) {
    if (v.id === id) {
      return v;
    }
  }
  return undefined;
}
