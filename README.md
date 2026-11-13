# dsh-desk-todo · 桌面待办挂件

把「**本周待办 + 长期任务**」贴在桌面右上角的一块小黑板上：无标题栏、不进任务栏、默认沉在窗口下面不挡东西；到点弹窗 + 叮一声。

![本周视图](docs/screenshot-week.png)

- 左边：今天起 7 天的待办（没安排的周末也留一行，看得见周末）
- 右边：长期任务和 DDL 倒计时
- 单击任意一条 → 看/改备注、标记完成、删除
- 标题栏 **＋** → 一句话快速新增（`15号下午3点在图书馆交作业` 这种）

## 实现方式

界面是 **Electron** 挂件（`app/`，无边框 + 透明 + 沉底），插件只负责找到一份 Electron 二进制并把它拉起来、崩了重启。

为什么插件不自己开窗口：DSH 的插件宿主跑在 `ELECTRON_RUN_AS_NODE` 模式（`dsh-desktop-host`），进程里没有 `app` / `BrowserWindow`。

Electron 搜索顺序：

1. 配置项 `electronPath`
2. 环境变量 `DESH_DESK_TODO_ELECTRON`（见下方示例）
3. `$DSH_HOME/data/surfcore/pet/runtime/electron-<ver>/electron.exe`（装了桌宠插件就有）
4. `%LOCALAPPDATA%\Programs\electron\electron.exe`

都找不到时**自动退回 WPF 版本**（`win/desk-todo.ps1`，Windows 自带，不需要 Electron，界面是同一套布局的简化实现）。

| 层 | 技术 | 说明 |
|---|---|---|
| 界面 | Electron（首选）/ WPF（退路） | 无边框透明窗口 |
| 提醒 | 自绘弹窗 + `SoundPlayer` / `Notification` | 不吃系统通知权限 |
| 一句话识别 | Node 正则解析器（`lib/parse.js`） | 通过 `127.0.0.1` 临时端口给界面调用 |
| 数据 | `$DSH_HOME/desk-todo/data.json` | 纯文本，改完自动刷新 |

## 安装

```bash
dsh plugin --profile desktop add dsh-desk-todo
# 或者
dsh plugin --profile desktop add github:Astryve/dsh-desk-todo
```

装完**重启 DSH**，挂件会出现在屏幕右上角。

本地开发：

```bash
git clone https://github.com/Astryve/dsh-desk-todo
dsh plugin --profile desktop add link:/绝对路径/dsh-desk-todo
```

## 第一次打开

- 挂件是空的（只有 7 天日期 + 空长期区）
- 数据文件被创建在 `$DSH_HOME/desk-todo/data.json`（Windows 默认 `C:\Users\<你>\.dsh\desk-todo\data.json`；本机把 DSH 数据放 D 盘时就是 `D:\DSH\data\desk-todo\`）
- 想立刻看到效果，把仓库里的 `data/example.json` 复制成 `data.json` 即可

## 怎么加待办

### 一句话识别（推荐）

点 **＋**，输入：

```
15号下午3点在图书馆交作业
```

会自动拆成 `2026-11-15 · 15:00–16:00 · 图书馆 · 交作业`。识别服务由插件提供；插件没起来时退化为「今天 09:00 + 原文标题」。

支持：

| 类型 | 例子 |
|---|---|
| 日期 | `15号` `11月20日` `2026-11-20` `今天/明天/后天` `周五` `下周一` |
| 时间 | `3点` `7点半` `十点` `9点到11点`，可配 `上午/下午/晚上/中午` |
| 地点 | `在图书馆` `地点：主楼W3阶`，也认 `东区414` `W3阶` `宿舍楼下` |
| 标题 | 自动去掉时间地点，只留动作 |

### 改 JSON

`data.json` 是普通 JSON，改完存盘挂件自动刷新。字段见下。

## 提醒规则

| 时机 | 表现 |
|---|---|
| 提前 N 分钟（默认 15，可设 0） | 右下角弹窗 + 轻提示音 |
| 到点 | 弹窗 + 更响提示音 |
| 逾期未完成 | 每 10 分钟一次，最多 3 次 |
| 长期任务临期 | 剩 3 天 / 1 天 / 当天各一次 |

## 鼠标操作

| 操作 | 效果 |
|---|---|
| 拖标题栏 | 移动（位置自动记住） |
| 点 ＋ | 快速新增 |
| 点 － | 隐藏（插件仍在跑，重启 DSH 会回来） |
| 点条目 | 详情：备注、完成、删除 |

## 数据格式

```json
{
  "semester": { "name": "2026-2027 秋", "week1Monday": "2026-08-31" },
  "events": [
    { "id": "e1", "title": "数值分析", "day": "2026-11-12",
      "start": "13:30", "end": "16:40", "place": "武进阶教楼W3阶",
      "color": "gold", "remindMin": 15, "repeat": "weekly", "note": "带作业" }
  ],
  "longterm": [
    { "id": "l1", "title": "毕业设计开题", "due": "2026-12-20", "done": false, "note": "" }
  ],
  "settings": { "w": 520, "h": 330, "x": null, "y": 16, "opacity": 0.85 }
}
```

| 字段 | 说明 |
|---|---|
| `day` | `YYYY-MM-DD`；`repeat: "weekly"` 时它决定周几 |
| `start` / `end` | `HH:MM` 24 小时制 |
| `place` | 自动简写：`武进东区国际教室414` → `东区414` |
| `color` | 色条：`gold` `green` `blue` `pink` `orange` |
| `remindMin` | 提前几分钟；`0` = 只到点提醒 |
| `doneOn` | 某天标记完成的日子（每周重复的第二天自动恢复） |
| `semester.week1Monday` | 有它标题就显示「第 N 周」 |

## 配置

```yaml
# ~/.dsh/profiles/<profile>/cordis.patch.yml
- id: desk-todo
  config:
    alwaysOnTop: true    # 想让它盖在窗口上面就打开（默认 false = 沉底）
    silent: true         # 只弹窗不出声
    width: 520
    height: 330
    top: 16
    right: 16
```

## 常见问题

**装完没看到？**
① 重启 DSH 了吗；② 挂件默认沉在最底层，最小化其它窗口才看得到；③ 打开 `%TEMP%\desk-todo-load.txt`，没有 `spawned powershell pid=...` 就是插件没被加载。

**弹窗不响？**
配置里 `silent: true` 关了声音，或系统音量/输出设备不对。

**能改窗口大小吗？**
改 `data.json` 里 `settings.w/h`，或配置里 `width/height`（只影响首次创建）。

**数据会不会丢？**
不会，全在 `data.json`；卸载插件不删数据。

**非 Windows？**
WPF 只有 Windows 有，这个版本不支持 macOS / Linux。

## License

MIT
