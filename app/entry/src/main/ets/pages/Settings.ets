/**
 * 设置页：卡片分组列表，两项——关于 / 修改 API Key。
 *
 * 结构（应用设计 §4.9 / decisions D38）：每层都是独立页面。
 */
import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { Exporter, ExportResult } from '../adapters/exporter';

@Entry
@Component
struct Settings {
  @State exporting: boolean = false;

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }


  /** 选目录 → 逐课复制；不打包，结构照旧 */
  private async doExport(): Promise<void> {
    if (this.exporting) {
      return;
    }
    this.exporting = true;
    try {
      const exporter: Exporter = new Exporter(this.ctx());
      const r: ExportResult = await exporter.exportZip();
      const sizeMb: string = (r.zipBytes / 1024 / 1024).toFixed(1);
      const msg: string = r.failed.length === 0
        ? '已导出 ' + r.ok + ' 份（' + sizeMb + ' MB）：' + r.zipName
        : '导出失败：' + r.failed[0];
      promptAction.showToast({ message: msg, duration: 3000 });
    } catch (err) {
      promptAction.showToast({ message: '导出失败：' + String(err).substring(0, 60), duration: 2500 });
    } finally {
      this.exporting = false;
    }
  }

  @Builder
  row(title: string, value: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor('#000000')
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor('#999999')
        .maxLines(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor(['#C7C7CC'])
        .margin({ left: 6 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 12 })
  }

  build() {
    HdsNavigation() {
      Column() {
        List({ space: 8 }) {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            ListItem({ style: ListItemStyle.CARD }) {
              this.row('关于', '')
            }
            .onClick(() => {
              router.pushUrl({ url: 'pages/About' });
            })

            ListItem({ style: ListItemStyle.CARD }) {
              this.row('修改 API Key', '')
            }
            .onClick(() => {
              router.pushUrl({ url: 'pages/ApiKeys' });
            })

            ListItem({ style: ListItemStyle.CARD }) {
              this.row('导出文库数据', this.exporting ? '导出中…' : '')
            }
            .onClick(() => {
              void this.doExport();
            })
          }
          .divider({ strokeWidth: 1, color: '#F2F2F7', startMargin: 16, endMargin: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .padding({ top: 56 })
      .backgroundColor('#F5F6F8')
    }
    .titleBar({
      content: {
        title: { mainTitle: '设置' },
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
