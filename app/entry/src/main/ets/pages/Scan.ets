/**
 * 扫描页：全屏嵌入系统「文档扫描控件」。
 *
 * 文档要点（vision-documentscanner）：
 *   - DocumentScanner 是 @Component，自带取景/自动裁剪/多拍/旋转/删除/重拍/图库；
 *   - **不允许被其他组件或窗口遮挡**，所以本页只放它，不放任何浮层；
 *   - onResult(code, saveType, uris)：200 成功、-1 用户取消；
 *   - maxShotCount 上限 50。
 *
 * 拍完（或从图库选完）后把 uris 交给确认页，由确认页建课并跑 OCR。
 */
import { DocType, DocumentScanner, DocumentScannerConfig, SaveOption, FilterId, ShootingMode, EditTab } from '@kit.VisionKit';
import { router } from '@kit.ArkUI';

const MAX_SHOTS: number = 10;

@Entry
@Component
struct Scan {
  private config: DocumentScannerConfig = new DocumentScannerConfig();

  aboutToAppear(): void {
    this.config.supportType = [DocType.DOC];
    this.config.maxShotCount = MAX_SHOTS;
    this.config.isGallerySupported = true;               // 支持从图库选图（也方便测试）
    this.config.isShareable = false;                     // 不需要分享
    // 保留「删除 / 旋转」：拍废了用户能就地修正（AUTO 模式尤其需要）
    this.config.editTabs = [EditTab.DELETE_TAB, EditTab.ROTATE_TAB];
    this.config.defaultFilterId = FilterId.STRENGTHEN;   // 增强：课本纸张偏黄时更清楚
    // 手动：AUTO 会在桌面上乱拍（实测对着桌面连拍 10 张废图）
    this.config.defaultShootingMode = ShootingMode.MANUAL;
    this.config.originalUris = [];
  }

  build() {
    Column() {
      DocumentScanner({
        scannerConfig: this.config,
        onResult: (code: number, saveType: SaveOption, uris: string[]) => {
          if (code === 200 && uris.length > 0) {
            router.replaceUrl({
              url: 'pages/Editor',
              params: { uris: uris }
            });
            return;
          }
          if (code === -1) {
            router.back();
          }
        }
      })
        .size({ width: '100%', height: '100%' })
    }
    .width('100%')
    .height('100%')
  }
}
