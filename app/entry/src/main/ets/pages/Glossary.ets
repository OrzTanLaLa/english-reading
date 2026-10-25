/**
 * 生语汇页：**直接显示本课的 `glossary.yaml` 原文**（可滚动、可复制）。
 *
 * 为什么不解析成列表：这份文件是「人可读的交付物」，用户要的是原文本身；
 * 解析只在写入侧（`core/glossary.ts`）和「条数」统计里用。
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { CourseStore } from '../adapters/courseStore';
import { parseEntries } from '../core/glossary';
import { GLOSSARY_NAME } from '../core/prompts';

@Entry
@Component
struct Glossary {
  @State title: string = GLOSSARY_NAME;
  @State body: string = '';
  @State count: number = 0;
  @State loading: boolean = true;

  private courseId: string = '';
  private store: CourseStore | undefined = undefined;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const id: Object | undefined = params['id'];
      if (id !== undefined) {
        this.courseId = String(id);
      }
    }
    this.load();
  }

  private getStore(): CourseStore {
    if (this.store === undefined) {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.store = new CourseStore(ctx);
    }
    return this.store!;
  }

  private load(): void {
    try {
      const raw: string = this.getStore().readGlossary(this.courseId);
      this.body = raw.trim();
      this.count = parseEntries(raw).length;
    } catch (err) {
      this.body = '';
      this.count = 0;
    }
    this.loading = false;
  }

  build() {
    HdsNavigation() {
      Column() {
        if (this.loading) {
          Blank()
          Text('读取中…').fontSize(14).fontColor('#888888')
          Blank()
        } else if (this.body.length === 0) {
          Blank()
          Text('本课还没有生语汇').fontSize(15).fontColor('#888888')
          Text('朗读时点麦克风问一个词，就会记到这里').fontSize(13).fontColor('#AAAAAA')
            .margin({ top: 8 })
          Blank()
        } else {
          Scroll() {
            Text(this.body)
              .fontSize(14)
              .lineHeight(22)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
              .padding({ bottom: 24 })
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 56, bottom: 8 })
      .backgroundColor('#FFFFFF')
    }
    .titleBar({
      content: {
        title: {
          mainTitle: this.title,
          subTitle: this.count > 0 ? '共 ' + this.count + ' 条' : ''
        },
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
