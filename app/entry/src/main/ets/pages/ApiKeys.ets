/**
 * API Key 列表：卡片分组，两项（百炼 / DeepSeek），点进去各自的编辑页。
 *
 * 列表控件见 decisions D38：`List` + `ListItemGroup({style: CARD})` + `ListItem({style: CARD})`。
 */
import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { SettingsStore } from '../adapters/storage';

@Entry
@Component
struct ApiKeys {
  @State dash: string = '';
  @State deep: string = '';

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** 从编辑页返回时刷新（两个 key 都读一遍，代价可忽略） */
  private async refresh(): Promise<void> {
    this.dash = await SettingsStore.loadDashScopeKey(this.ctx());
    this.deep = await SettingsStore.loadApiKey(this.ctx());
  }

  aboutToAppear(): void {
    void this.refresh();
  }

  onPageShow(): void {
    void this.refresh();
  }

  /** 行：标题 + 状态 + 箭头 */
  @Builder
  row(title: string, hint: string, set: boolean) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(16)
          .fontColor('#000000')
        Text(hint)
          .fontSize(12)
          .fontColor('#999999')
      }
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text(set ? '已设置' : '未设置')
        .fontSize(14)
        .fontColor(set ? '#0E9F6E' : '#C7C7CC')
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor(['#C7C7CC'])
        .margin({ left: 6 })
    }
    .width('100%')
    .height(60)
    .padding({ left: 16, right: 12 })
  }

  build() {
    HdsNavigation() {
      Column() {
        List({ space: 8 }) {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            ListItem({ style: ListItemStyle.CARD }) {
              this.row('百炼 API Key', 'TTS / OCR / 语音解析', this.dash.length > 0)
            }
            .onClick(() => {
              router.pushUrl({ url: 'pages/ApiKeyEdit', params: { which: 'dash' } });
            })

            ListItem({ style: ListItemStyle.CARD }) {
              this.row('DeepSeek API Key', '答疑（回答与生语汇）', this.deep.length > 0)
            }
            .onClick(() => {
              router.pushUrl({ url: 'pages/ApiKeyEdit', params: { which: 'deep' } });
            })
          }
          .divider({ strokeWidth: 1, color: '#F2F2F7', startMargin: 16, endMargin: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Text('Key 只存在本机应用数据里，不会进代码仓库，也不会随导出一起走。')
          .fontSize(12)
          .fontColor('#999999')
          .width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 16 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: 56 })
      .backgroundColor('#F5F6F8')
    }
    .titleBar({
      content: {
        title: { mainTitle: 'API Key' },
        backIcon: {
          icon: $r('sys.symbol.chevron_left'),
          label: '返回',
          action: () => {
            router.back();
          }
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .hideToolBar(true)
  }
}
