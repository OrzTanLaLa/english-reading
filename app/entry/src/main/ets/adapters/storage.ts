/**
 * 平台相关的存储：设置（Key）与 vocab.txt。
 * 注意：Key 目前明文存 preferences，仅用于 B1.5 联调；正式版要换 HUKS 加密（TECH_PLAN §3.4.8）。
 */
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

const SETTINGS_NAME = 'settings';
const KEY_DEEPSEEK = 'deepseek_api_key';
const KEY_DASHSCOPE = 'dashscope_api_key';
const KEY_VOICE = 'tts_voice';

export class SettingsStore {
  static async saveApiKey(ctx: common.UIAbilityContext, apiKey: string): Promise<void> {
    const store = await preferences.getPreferences(ctx, SETTINGS_NAME);
    await store.put(KEY_DEEPSEEK, apiKey);
    await store.flush();
  }

  static async loadApiKey(ctx: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(ctx, SETTINGS_NAME);
    const value = await store.get(KEY_DEEPSEEK, '');
    return value as string;
  }

  /** 百炼 Key（云 OCR / TTS 用） */
  static async saveDashScopeKey(ctx: common.UIAbilityContext, apiKey: string): Promise<void> {
    const store = await preferences.getPreferences(ctx, SETTINGS_NAME);
    await store.put(KEY_DASHSCOPE, apiKey);
    await store.flush();
  }

  static async loadDashScopeKey(ctx: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(ctx, SETTINGS_NAME);
    const value = await store.get(KEY_DASHSCOPE, '');
    return value as string;
  }

  /** 选中的 TTS 音色 */
  static async saveVoice(ctx: common.UIAbilityContext, voiceId: string): Promise<void> {
    const store = await preferences.getPreferences(ctx, SETTINGS_NAME);
    await store.put(KEY_VOICE, voiceId);
    await store.flush();
  }

  static async loadVoice(ctx: common.UIAbilityContext): Promise<string> {
    const store = await preferences.getPreferences(ctx, SETTINGS_NAME);
    const value = await store.get(KEY_VOICE, '');
    return value as string;
  }
}
