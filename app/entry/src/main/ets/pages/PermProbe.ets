/**
 * 权限探针：把「权限」和「采集」彻底分开。
 *
 * 背景：`checkAccessTokenSync` 说已授权、`requestPermissionsFromUser` 返回 0，
 * 但 audio_server 日志报 `VerifyClientPermission Permission denied [ohos.permission.MICROPHONE]`。
 * 这个页面只做三件事，且每件都打印真实数值：
 *   1. 查询当前授权状态（before）；
 *   2. 主动申请一次（req），再查一次（after）；
 *   3. 单独试 createAudioCapturer（不开录音），把错误码打出来。
 */
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';

const PERM: Permissions = 'ohos.permission.MICROPHONE';

@Entry
@Component
struct PermProbe {
  @State status: string = '待开始';
  @State detail: string = '';

  private async tokenId(): Promise<number> {
    const info = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    return info.appInfo.accessTokenId;
  }

  private async check(): Promise<void> {
    const mgr = abilityAccessCtrl.createAtManager();
    try {
      const tid = await this.tokenId();
      const r = mgr.checkAccessTokenSync(tid, PERM);
      this.status = '查询完成';
      this.detail = 'tokenId=' + tid + '  checkAccessTokenSync=' + r + '（0=已授权，-1=未授权）';
    } catch (err) {
      const be = err as BusinessError;
      this.detail = '查询失败: ' + be.code + ' ' + be.message;
    }
  }

  private async request(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const mgr = abilityAccessCtrl.createAtManager();
    try {
      const tid = await this.tokenId();
      const before = mgr.checkAccessTokenSync(tid, PERM);
      const res = await mgr.requestPermissionsFromUser(ctx, [PERM]);
      const req = res.authResults.length > 0 ? res.authResults[0] : -99;
      const after = mgr.checkAccessTokenSync(tid, PERM);
      this.status = '申请完成';
      this.detail = 'before=' + before + '  req=' + req + '  after=' + after;
    } catch (err) {
      const be = err as BusinessError;
      this.detail = '申请失败: ' + be.code + ' ' + be.message;
    }
  }

  private async tryCreate(): Promise<void> {
    try {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
        channels: audio.AudioChannel.CHANNEL_2,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      };
      const capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      };
      const cap = await audio.createAudioCapturer({ streamInfo: streamInfo, capturerInfo: capturerInfo });
      this.status = '创建成功';
      this.detail = 'createAudioCapturer 成功，释放中…';
      await cap.release();
      this.detail = 'createAudioCapturer 成功且已释放';
    } catch (err) {
      const be = err as BusinessError;
      this.status = '创建失败';
      this.detail = 'createAudioCapturer 失败: code=' + be.code + ' msg=' + be.message;
    }
  }

  build() {
    Column({ space: 14 }) {
      Text('权限探针（麦克风）').fontSize(20).fontWeight(FontWeight.Bold)
      Text(this.status).fontSize(16)
      Text(this.detail).fontSize(14).fontColor('#222222').width('100%')
      Button('1. 只查询状态').width('70%').height(46).onClick(() => {
        void this.check();
      })
      Button('2. 申请一次').width('70%').height(46).onClick(() => {
        void this.request();
      })
      Button('3. 试创建采集器（不录音）').width('70%').height(46).onClick(() => {
        void this.tryCreate();
      })
      Blank()
    }
    .padding(20)
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
