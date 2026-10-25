import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { CourseStore } from '../adapters/courseStore';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  // 调试用：aa start 带 --ps page pages/OcrProbe 可直接落到探针页
  private startPage: string = 'pages/Library';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params = want.parameters;
    if (params !== undefined) {
      const page = params['page'];
      if (typeof page === 'string' && (page as string).length > 0) {
        this.startPage = page as string;
        hilog.info(DOMAIN, 'testTag', 'start page overridden: %{public}s', this.startPage);
      }
    }
    // 数据结构迁移：幂等，已是最新版本时什么都不做
    try {
      const store: CourseStore = new CourseStore(this.context);
      const migrated: string = store.migrateAll();
      if (migrated.length > 0) {
        hilog.info(DOMAIN, 'testTag', 'migrated: %{public}s', migrated);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'migration failed: %{public}s', String(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent(this.startPage, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
