/**
 * 单个 API Key 的编辑页：一个输入框 + 标题栏右上「保存」。
 *
 * 入口参数：`which` = 'dash'（百炼）| 'deep'（DeepSeek）。
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, TextStyleMode } from '@kit.UIDesignKit';
import { SettingsStore } from '../adapters/storage';

@Entry
@Component
struct ApiKeyEdit {
  @State title: string = 'API Key';
  @State hint: string = '';
  @State value: string = '';
  @State loaded: boolean = false;

  private which: string = 'dash';

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const w: Object | undefined = params['which'];
      if (w !== undefined) {
        this.which = String(w);
      }
    }
    if (this.which === 'deep') {
      this.title = 'DeepSeek API Key';
      this.hint = '用于回答提问、写生语汇。以 sk- 开头。';
    } else {
      this.title = '百炼 API Key';
      this.hint = '用于语音合成、OCR、语音提问解析。以 sk- 开头。';
    }
    void this.load();
  }

  private async load(): Promise<void> {
    if (this.which === 'deep') {
      this.value = await SettingsStore.loadApiKey(this.ctx());
    } else {
      this.value = await SettingsStore.loadDashScopeKey(this.ctx());
    }
    this.loaded = true;
  }

  private async save(): Promise<void> {
    const v: string = this.value.trim();
    if (this.which === 'deep') {
      await SettingsStore.saveApiKey(this.ctx(), v);
    } else {
      await SettingsStore.saveDashScopeKey(this.ctx(), v);
    }
    router.back();
  }

  build() {
    HdsNavigation() {
      Column({ space: 10 }) {
        // 密码样式：默认掩码；末尾眼睛图标（showPasswordIcon）点一下可看明文——
        // 这是 TextInput 密码模式自带的行为（文档 ts-basic-components-textinput）。
        TextInput({ text: this.loaded ? this.value : '', placeholder: 'sk-...' })
          .width('100%')
          .height(48)
          .fontSize(14)
          .type(InputType.Password)
          .showPasswordIcon(true)
          .onChange((v: string) => {
            this.value = v;
          })
        Text(this.hint)
          .fontSize(12)
          .fontColor('#999999')
          .width('100%')
        Text('留空表示改用代码里的默认 Key（仅开发时用）。')
          .fontSize(12)
          .fontColor('#AAAAAA')
          .width('100%')
        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: 72 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#FFFFFF')
    }
    .titleBar({
      content: {
        title: { mainTitle: this.title },
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
              label: '保存',
              type: TextStyleMode.NORMAL,
              action: () => {
                void this.save();
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
