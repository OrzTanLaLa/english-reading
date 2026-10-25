/**
 * 文库页：列出全部课文。
 *
 * 设计见 docs/应用设计.md §4.1：
 *   行 = 标题 + 副标题（页数 · 时长 · 相对时间）+ ⋮ 菜单
 *   ⋮ = 编辑 / 生语汇 / 删除
 *   右上角悬浮 ＋（sys.symbol.plus）→ 扫描页
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { bundleManager } from '@kit.AbilityKit';
import { CourseStore } from '../adapters/courseStore';
import { CourseMeta, subtitle } from '../core/course';

@Entry
@Component
struct Library {
  @State courses: CourseMeta[] = [];
  @State renameId: string = '';
  @State renameBuf: string = '';
  @State now: number = Date.now();
  /** versionName，例如 1.0.0（来自 app.json5） */
  @State version: string = '';

  private store: CourseStore | undefined = undefined;

  aboutToAppear(): void {
    void this.reload();
  }

  onPageShow(): void {
    void this.reload();
  }

  private getStore(): CourseStore {
    if (this.store === undefined) {
      this.store = new CourseStore(getContext(this) as common.UIAbilityContext);
    }
    return this.store;
  }

  private async reload(): Promise<void> {
    this.now = Date.now();
    this.courses = this.getStore().list();
    if (this.version.length === 0) {
      try {
        const info = await bundleManager.getBundleInfoForSelf(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        this.version = info.versionName;
      } catch (err) {
        this.version = '';
      }
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1800 });
  }

  private openCourse(id: string): void {
    router.pushUrl({ url: 'pages/Reader', params: { id: id } });
  }

  private confirmDelete(meta: CourseMeta): void {
    AlertDialog.show({
      title: '删除课文',
      message: '将删除《' + meta.title + '》的文本、原图、音频和生语汇，且无法恢复。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#D32F2F',
        action: () => {
          this.getStore().remove(meta.id);
          void this.reload();
          this.toast('已删除');
        }
      }
    });
  }

  private showGlossary(meta: CourseMeta): void {
    const text: string = this.getStore().readGlossary(meta.id).trim();
    AlertDialog.show({
      title: '本课生语汇',
      message: text.length > 0 ? text : '还没有收录。在朗读页问词句的意思，就会记到这里。',
      confirm: { value: '知道了', action: () => {
      } }
    });
  }

  @Builder
  rowMenu(meta: CourseMeta) {
    Menu() {
      MenuItem({ content: '编辑' }).onClick(() => {
        router.pushUrl({ url: 'pages/Editor', params: { id: meta.id } });
      })
      MenuItem({ content: '生语汇' }).onClick(() => {
        router.pushUrl({ url: 'pages/Glossary', params: { id: meta.id, title: meta.title } });
      })
      MenuItem({ content: '删除' }).onClick(() => {
        this.confirmDelete(meta);
      })
    }
  }

  build() {
    HdsNavigation() {
      Stack() {
        Column() {
          if (this.courses.length === 0) {
            Column({ space: 8 }) {
              Text('还没有课文')
                .fontSize(17)
                .fontColor('#666666')
              Text('点右上角 ＋ 新建课文')
                .fontSize(14)
                .fontColor('#999999')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ space: 10 }) {
              ForEach(this.courses, (m: CourseMeta) => {
                ListItem() {
                  Row() {
                    Column({ space: 4 }) {
                      Text(m.title)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(subtitle(m, this.now))
                        .fontSize(12)
                        .fontColor('#888888')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Button('⋮')
                      .fontSize(18)
                      .backgroundColor(Color.Transparent)
                      .fontColor('#666666')
                      .width(44)
                      .height(44)
                      .bindMenu(this.rowMenu(m))
                      .onClick(() => {
                        // bindMenu 由长按/点击触发，这里留空避免冒泡到整行
                      })
                  }
                  .width('100%')
                  .padding(14)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(12)
                  .onClick(() => {
                    this.openCourse(m.id);
                  })
                }
              }, (m: CourseMeta) => m.id + m.updatedAt)
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 20, right: 20, top: 12 })
            .scrollBar(BarState.Auto)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ top: 56 })

        // 重命名浮层
        if (this.renameId.length > 0) {
          Stack() {
            Column() {
            }
            .width('100%')
            .height('100%')
            .backgroundColor('#66000000')
            .onClick(() => {
              this.renameId = '';
            })

            Column({ space: 12 }) {
              Text('编辑标题').fontSize(17).fontWeight(FontWeight.Bold)
              TextInput({ text: this.renameBuf, placeholder: '课文标题' })
                .width('100%')
                .height(44)
                .onChange((v: string) => {
                  this.renameBuf = v;
                })
              Row({ space: 12 }) {
                Button('取消').layoutWeight(1).onClick(() => {
                  this.renameId = '';
                })
                Button('保存').layoutWeight(1).onClick(() => {
                  this.getStore().rename(this.renameId, this.renameBuf);
                  this.renameId = '';
                  void this.reload();
                })
              }
              .width('100%')
            }
            .width('80%')
            .padding(20)
            .backgroundColor(Color.White)
            .borderRadius(14)
          }
          .width('100%')
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F5F6F8')
    }
    .titleBar({
      content: {
        title: {
          mainTitle: '文库',
          subTitle: this.version.length > 0 ? 'v' + this.version : ''
        },
        menu: {
          value: [{
            content: {
              icon: $r('sys.symbol.plus'),
              label: '新建',
              action: () => {
                router.pushUrl({ url: 'pages/Editor' });
              }
            }
          }, {
            content: {
              icon: $r('sys.symbol.gearshape'),
              label: '设置',
              action: () => {
                router.pushUrl({ url: 'pages/Settings' });
              }
            }
          }]
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
  }
}
