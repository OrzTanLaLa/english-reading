# English Reading · 拍照课文 → 朗读 → 语音提问生词本

鸿蒙（HarmonyOS）平板应用。拍照导入英语课文，用云端大模型 TTS 朗读并逐词高亮；
随时暂停，用语音提问，Agent 查词典后把生词／短语／句式写进 `vocab.txt`。

## 现在到哪一步

| 阶段 | 状态 |
|---|---|
| 方案设计 | ✅ 完成，按实测改过 4 轮（v4 定稿） |
| B0-a 音色 | ✅ 四个英文音色均可用，改为用户自选 |
| B0-b 时间戳 | ✅ 三篇课文 78/79/57 词，100% 对齐 |
| B0-b2 语义分组 | ✅ DeepSeek 分组与人工一致，0 重试 0 回退 |
| B0-c 语音提问解析 | ✅ 真人录音 19/20 |
| 环境 | 🔧 DevEco 26.0.0.851 已装，SDK API 26 就绪 |
| 工程 | ⬜ 尚未创建 |
| B1 → M1 | ⬜ 下一步 |

## 目录

| 路径 | 内容 |
|---|---|
| `docs/交接说明.md` | **新会话从这里开始**：决策、结论、坑、资产、TODO |
| `docs/TECH_PLAN.md` | 完整技术方案（架构、模块、契约、风险、里程碑） |
| `docs/环境搭建.md` | DevEco／SDK／设备连接，含已确认的实际路径 |
| `validation/B0A/` | 音色取样与盲听工具、12 段测试音频 |
| `validation/B0B/` | 标点规范化、分句、时间戳、语义分组、渲染对拍页 |
| `validation/B0C/` | 语音提问解析探针、20 条用例与结果 |
| `scripts/` | 一次性工具（工作区迁移） |

## 跑验证脚本的前提

- **Python 3.14**：`E:\Program Files\Python314\python.exe`（用到 `compression.zstd`）
- **ffmpeg** 在 PATH（音频转码、拼接、静音）
- 云端 Key 放 `validation/B0A/config.json`（已 gitignore，别提交）

## 快速验证（不花钱）

```powershell
cd validation\B0B
python ts_probe.py --self-test          # 高亮页能否工作，用正弦波
python segment.py ..\B0A\texts\t2.txt   # 分句结果
python normalize.py --all               # 标点规范化改了什么
```
