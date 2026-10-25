/**
 * 关于页：纯文本（版本、课程数、数据结构版本、数据存放说明）。
 *
 * 结构见 应用设计 §4.9 / decisions D38：设置 → 这里，独立页面，不做交互。
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { bundleManager } from '@kit.AbilityKit';
import { CourseStore } from '../adapters/courseStore';
import { CURRENT_SCHEMA } from '../core/course';

@Entry
@Component
struct About {
  @State versionName: string = '';
  @State courseCount: number = 0;

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    try {
      this.courseCount = new CourseStore(this.ctx()).list().length;
    } catch (err) {
      this.courseCount = 0;
    }
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info) => {
        this.versionName = info.versionName;
      })
      .catch(() => {
        this.versionName = '';
      });
  }

  build() {
    HdsNavigation() {
      Column({ space: 10 }) {
        Text('英语朗读')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .width('100%')
        Text('拍课本 → 云端转写 → 逐词朗读高亮 → 随时提问 → 记进生语汇')
          .fontSize(14)
          .fontColor('#666666')
          .width('100%')

        Divider().color('#EEEEEE').margin({ top: 8, bottom: 8 })

        Text('版本  v' + (this.versionName.length > 0 ? this.versionName : '?'))
          .fontSize(15)
          .width('100%')
        Text('数据结构  v' + CURRENT_SCHEMA)
          .fontSize(15)
          .width('100%')
        Text('课程  ' + this.courseCount + ' 门')
          .fontSize(15)
          .width('100%')

        Divider().color('#EEEEEE').margin({ top: 8, bottom: 8 })

        Text('所有课程（原文、图片、音频、生语汇）都保存在本机应用目录里。' +
          '升级用覆盖安装，数据不会丢；卸载会一并清空。')
          .fontSize(14)
          .fontColor('#666666')
          .lineHeight(22)
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
        title: { mainTitle: '关于' },
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
