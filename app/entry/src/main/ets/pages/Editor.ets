/**
 * 编辑页：一门课的全部编辑都在这里（替代旧的「确认页」与「查看原图」）。
 *
 * 能做的事：改标题、增/删/排序图片、识别（把正文替换为识别结果）、手改全文、保存。
 * 两种进入方式：
 *   1) 扫描页「保存」后自动跳进来（params.uris，新建课程）；
 *   2) 文库页 ⋮ →「编辑」（params.id，编辑已有课程）。
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, TextStyleMode } from '@kit.UIDesignKit';
import { CourseStore } from '../adapters/courseStore';
import { CloudOcr } from '../adapters/ocr';
import { SettingsStore } from '../adapters/storage';
import { CourseMeta, hashText } from '../core/course';
import { DEFAULT_VOICE } from '../core/voices';
import { LOCAL_DASHSCOPE_KEY } from '../adapters/local_secret';
import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';

function defaultTitle(ms: number): string {
  const d = new Date(ms);
  const p = (n: number): string => n < 10 ? '0' + n : '' + n;
  return '未命名 ' + d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
    ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

@Entry
@Component
struct Editor {
  @State uris: string[] = [];
  @State title: string = defaultTitle(Date.now());
  @State body: string = '';
  @State busy: boolean = false;
  @State progress: string = '';
  @State courseId: string = '';
  @State dirty: boolean = false;

  private created: boolean = false;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    const id: string = params !== undefined && params['id'] !== undefined ? String(params['id']) : '';
    if (id.length > 0) {
      this.courseId = id;
      this.load(id);
          return;
    }
    const incoming: string[] = params !== undefined && params['uris'] !== undefined
      ? (params['uris'] as string[]) : [];
    this.uris = incoming;
    this.createCourse(incoming);
  }

  private store(): CourseStore {
    return new CourseStore(getContext(this) as common.UIAbilityContext);
  }

  private load(id: string): void {
    const s = this.store();
    const m: CourseMeta | undefined = s.meta(id);
    if (m !== undefined) {
      this.title = m.title;
    }
    this.body = s.readText(id);
    this.uris = s.listImages(id);
  }

  private createCourse(uris: string[]): void {
    const s = this.store();
    const m: CourseMeta = s.create(this.title, DEFAULT_VOICE);
    this.courseId = m.id;
    this.created = true;
    if (uris.length > 0) {
      s.addImages(m.id, uris);
      this.uris = s.listImages(m.id);
    }
  }

  private async apiKey(): Promise<string> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const k: string = await SettingsStore.loadDashScopeKey(ctx);
    return k.length > 0 ? k : LOCAL_DASHSCOPE_KEY;
  }

  private readBytes(path: string): Uint8Array {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const st = fs.statSync(path);
      const buf = new ArrayBuffer(st.size);
      fs.readSync(file.fd, buf);
      return new Uint8Array(buf);
    } finally {
      fs.closeSync(file.fd);
    }
  }

  private async recognize(): Promise<void> {
    if (this.uris.length === 0 || this.busy) {
          return;
    }
    this.busy = true;
    const key: string = await this.apiKey();
    const ocr = new CloudOcr(key);
    const parts: string[] = [];
    try {
      for (let i = 0; i < this.uris.length; i++) {
        this.progress = '正在识别第 ' + (i + 1) + ' / ' + this.uris.length + ' 页…';
        const bytes = this.readBytes(this.uris[i]);
        const b64 = buffer.from(bytes.buffer).toString('base64');
        const pages = await ocr.recognize(b64);
        for (let k = 0; k < pages.length; k++) {
          parts.push(pages[k].text.trim());
        }
      }
      // 识别后「全文替换为识别结果」
      this.body = parts.join('\n\n');
      this.dirty = true;
      this.progress = '识别完成，可继续编辑';
    } catch (err) {
      this.progress = '识别失败: ' + String(err).substring(0, 120);
    } finally {
      this.busy = false;
    }
  }

  private removeImage(i: number): void {
    const path: string = this.uris[i];
    const next: string[] = [];
    for (let k = 0; k < this.uris.length; k++) {
      if (k !== i) {
        next.push(this.uris[k]);
      }
    }
    this.uris = next;
    try {
      fs.unlinkSync(path);
    } catch (err) {
    }
    this.dirty = true;
  }

  @Builder
  deleteAction(idx: number) {
    Button('删除')
      .height(56)
      .width(72)
      .fontSize(14)
      .backgroundColor('#D9534F')
      .borderRadius(10)
      .margin({ left: 4 })
      .onClick(() => this.removeImage(idx))
  }

  private save(): void {
    if (this.courseId.length === 0) {
          return;
    }
    const s = this.store();
    const m: CourseMeta | undefined = s.meta(this.courseId);
    if (m === undefined) {
          return;
    }
    const newTitle: string = this.title.trim().length > 0 ? this.title.trim() : m.title;
    if (newTitle !== m.title) {
      s.rename(this.courseId, newTitle);
    }
    const oldText: string = s.readText(this.courseId);
    if (this.body !== oldText) {
      s.writeText(this.courseId, this.body, hashText(this.body, m.voice));
      s.dropAudio(this.courseId);   // 文本变了，旧音频作废
    }
    promptAction.showToast({ message: '已保存', duration: 1200 });
    if (this.created) {
      router.replaceUrl({ url: 'pages/Library' });
    } else {
      router.back();
    }
  }

  build() {
    HdsNavigation() {
    Column({ space: 10 }) {
      TextInput({ text: this.title, placeholder: '给这篇课文起个名字' })
        .width('100%')
        .height(44)
        .onChange((v: string) => {
          this.title = v;
          this.dirty = true;
        })

      // 主体：左侧窄的图片列表 | 右侧按钮区 + 宽文本编辑框
      Row({ space: 14 }) {
        // 左：图片列表（上下滚动、左滑删除、长按拖拽排序）
        List({ space: 10 }) {
          ForEach(this.uris, (u: string, idx: number) => {
            ListItem() {
              Row() {
                Image('file://' + u)
                  .objectFit(ImageFit.Cover)
                  .width('100%')
                  .height(72)
                  .borderRadius(8)
              }
              .width('100%')
              .padding(8)
              .backgroundColor('#F7F8FA')
              .borderRadius(10)
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.deleteAction(idx)
                },
                actionAreaDistance: 64
              }
            })
          }, (u: string) => u)
            .onMove((from: number, to: number) => {
              if (from === to || from >= this.uris.length) {
                return;
              }
              const tmp: string[] = this.uris.splice(from, 1);
              this.uris.splice(to, 0, tmp[0]);
              this.dirty = true;
            })
        }
        .width('20%')
        .layoutWeight(0)
        .height('100%')
        .scrollBar(BarState.Auto)

        // 右：上按钮区，下文本编辑框
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Button('添加图片')
              .height(38)
              .fontSize(14)
              .backgroundColor('#EEF3FF')
              .fontColor('#1A6DD9')
              .onClick(() => {
                router.pushUrl({ url: 'pages/Scan', params: { forCourse: this.courseId } });
              })
            Button(this.busy ? '识别中…' : '识别')
              .height(38)
              .fontSize(14)
              .backgroundColor('#4C7DF0')
              .enabled(!this.busy)
              .onClick(() => {
                void this.recognize();
              })
            Text(this.progress).fontSize(11).fontColor('#D9534F').layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')

          TextArea({ text: this.body, placeholder: '识别出的正文会出现在这里，也可以直接手打或粘贴' })
            .width('100%')
            .layoutWeight(1)
            .fontSize(15)
            .onChange((v: string) => {
              this.body = v;
              this.dirty = true;
            })
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .padding({ left: 16, right: 16, bottom: 16, top: 56 })
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    }
    .titleBar({
      content: {
        title: {
          mainTitle: this.courseId.length > 0 ? '编辑课文' : '新建课文'
        },
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
              action: () => this.save()
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
