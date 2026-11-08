# apple-calendar-skill

> 把日程、日期、注意事项写进 macOS 日历的 agent skill：口述或照片进来，先出确认表，再批量写入 iCloud 日历，写完读回校验，手机上自动同步。

## 这是什么

一个给 AI agent（DeepSeek Harness / Claude Code 这类认 `SKILL.md` 的运行环境）用的技能包。它由两部分组成：

- `SKILL.md`：给 agent 看的作业说明书——什么时候触发、怎么拆解时间信息、确认表长什么样、出错怎么排。
- `CalendarHelper.app`：真正干活的 EventKit 程序，提供 `status / calendars / add / list / delete` 五个命令，JSON 进 JSON 出。

设计目标只有一个：**agent 写日历这件事必须可核对**。所以每条事件先出表格让人点头，写完读回来对一遍，重复执行不会写出两份。

> 配套项目：[mail-to-calendar-skill](https://github.com/DAweiD1/mail-to-calendar-skill) —— 从邮箱里捞出面试、笔试、截止日期，抽成日程后交给这个 skill 写入。

## 为什么不直接用 AppleScript 或 .ics

| 方案 | 问题 |
|---|---|
| AppleScript 操作日历 App | 每条事件一次 IPC，十几条要等十几秒；日期字符串解析笨；**拿不到这个日历属于哪个账户** |
| 生成 .ics 再导入 | 会弹导入对话框、重复导入就重复入库、落哪个日历不好控 |
| EventKit（本方案） | 可以直接读 `calendar.source.sourceType`，判断这个日历到底是不是 iCloud——这是"手机能不能看到"的唯一可靠依据 |

## 为什么必须打包成 .app

这是本项目最容易被坑的一点，写清楚免得别人重走一遍。

macOS 的 TCC 把日历权限算在**责任进程**头上。如果你直接跑一个裸二进制，责任进程会落到启动它的父进程（比如终端或某个 Electron 应用）。那个宿主如果 Info.plist 里没有 `NSCalendarsFullAccessUsageDescription`，系统连授权弹窗都不会弹，`requestFullAccessToEvents` 直接返回 false，`authorizationStatus` 一直是 `notDetermined`——看起来像代码写错了，其实是权限根本没发问。

所以：把二进制装进一个带完整 Info.plist 的 `.app`，用 `open` 通过 LaunchServices 启动，它就成了自己的责任进程，能正常弹窗、正常被授权。`bin/cal` 这个 wrapper 干的就是这件事（顺带解决 `open` 拿不到 stdout 的问题——结果写到临时文件里再 cat 出来）。

## 环境要求

- macOS 14+（用到 `requestFullAccessToEvents`）
- Xcode Command Line Tools（要有 `swiftc`）

## 安装

```bash
git clone https://github.com/DAweiD1/apple-calendar-skill.git
cd apple-calendar-skill

bash scripts/build.sh      # 编译并组装 CalendarHelper.app
bash scripts/install.sh    # 装到 ~/.agents/skills/apple-calendar

~/.agents/skills/apple-calendar/bin/cal calendars   # 第一次会弹系统授权，点「允许」
```

授权之后，系统设置 → 隐私与安全性 → 日历 里会多一条「日历助手」。**别删那条**，删了得重新授权。

不想装到默认位置就 `bash scripts/install.sh /你的/路径`。

## 配置

`~/.agents/skills/apple-calendar/config.json`：

```json
{
  "calendar": "",
  "timezone": "Asia/Hong_Kong"
}
```

- `calendar`：日历 id 或名称。留空就用系统主日历（`defaultCalendarForNewEvents`）。先用 `bin/cal calendars` 看有哪些可选。
- `timezone`：解析不带时区的时间时用这个。

**要同步到 iPhone，就必须写 iCloud 日历。** `bin/cal calendars` 的返回里每条都有 `syncs_to_icloud`，写进 `false` 的本地日历只在电脑上能看到。

## 命令

```bash
CAL=~/.agents/skills/apple-calendar/bin/cal

$CAL status                                        # 授权状态、默认日历、时区
$CAL calendars                                     # 所有日历 + 所属账户 + 是否可写
$CAL add --file plan.json --dry-run                # 只检查，不写
$CAL add --file plan.json                          # 批量写入
$CAL list --from 2026-12-01 --to 2026-12-31        # 读回
$CAL delete --id <事件ID>                          # 删除单条
```

`plan.json`：

```json
{
  "events": [
    {
      "title": "牙医复诊",
      "start": "2026-11-12T15:00:00",
      "end": "2026-11-12T15:40:00",
      "all_day": false,
      "location": "XX 口腔",
      "notes": "带上次的片子",
      "alarms": [-60],
      "repeat": { "freq": "WEEKLY", "interval": 1, "count": 4 }
    }
  ]
}
```

- `start` / `end` 不带时区时按 `timezone` 解析；没给 `end` 就定时 +1 小时、全天 +1 天。
- `alarms` 单位是「提前几分钟」，默认不加。
- `repeat` 支持 `DAILY / WEEKLY / MONTHLY / YEARLY` + `interval / count / until / byday`。
- `add` 会做去重：同一日历里已有同名、同开始时间（±1 分钟）的事件就跳过，返回在 `skipped` 里。

判断成败看 JSON 的 `ok` 字段，别看退出码（wrapper 恒返回 0，因为 `open` 不传子进程退出码）。

## 给 agent 用

把整个目录放进 `~/.agents/skills/apple-calendar/` 即可，`SKILL.md` 的 frontmatter 会被自动发现。工作流和话术都在里面，不要只看 README。

## 已知限制

- 只能在 macOS 上用，依赖 EventKit。
- ad-hoc 签名：重新编译后二进制 hash 变了，系统可能把它当成新应用再问一次权限。
- 时区按配置走，不做跨时区航班的自动换算——要写别的时区就在 `start` 里带 `+09:00` 这种偏移量。

## License

MIT，见 [LICENSE](./LICENSE)。
