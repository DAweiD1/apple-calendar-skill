---
name: apple-calendar
description: 读写 Mac 日历（默认系统主日历，经 iCloud 同步到 iPhone/iPad）：把口述的日程、日期、注意事项或照片里的时间表整理成事件写进去，写完读回校验；也能查「这周/下周有什么安排」。当用户说「加到日历」「帮我记一下日程」「读一下这张日程表」「这周有什么安排」「下周有什么」时使用。
---

# 苹果日历

把零散的时间信息（口述、照片、文件）整理成事件写进 Mac 日历，再读回来核对。

## 铁律

1. **先给清单，等用户点头，再写。** 任何情况都不跳过确认。
2. **只增不改不删。** 要改、要删已有事件，先把影响范围讲清楚并取得同意。
3. **默认写主日历，默认不加提醒。** 用户明确要求时才换日历或加闹钟。

## 工具

```bash
CAL=~/.agents/skills/apple-calendar/bin/cal
```

- `bin/cal` 是个 wrapper：它用 `open` 启动 `CalendarHelper.app`，日历权限记在这个 helper 上。**不要直接调 `bin/calendar`**，裸二进制请求权限会被系统静默拒绝。
- 判断成败看 JSON 里的 `ok` 字段，不要看退出码（wrapper 恒返回 0）。
- 配置：`~/.agents/skills/apple-calendar/config.json`
  - `calendar` 填日历 id 或名称；留空则跟系统主日历（`defaultCalendarForNewEvents`）
  - `timezone` 默认 `Asia/Hong_Kong`
- 重编译：`bash ~/.agents/skills/apple-calendar/scripts/build.sh`（重新签名后系统可能会再问一次权限）

## 第 1 步 查权限

```bash
$CAL status
```

| status | 做法 |
|---|---|
| `fullAccess` | 继续 |
| `notDetermined` | 跑一次 `$CAL calendars`，屏幕上会弹「“日历助手”想要访问你的日历」，让用户点「允许」 |
| `denied` / `restricted` | 让用户去 系统设置 → 隐私与安全性 → 日历 勾选「日历助手」，不要硬试 |

`$CAL calendars` 会列出每个日历的 `source`、`syncs_to_icloud`、`is_default`。写进 `syncs_to_icloud: false` 的本地日历只在电脑上，手机看不到——用户要手机能看，就必须用 iCloud 日历。

## 第 2 步 把输入拆成事件

照片/截图直接用 read_image 看，逐条抄时间。字被遮、行列对不上、字迹认不准就问用户，**不要猜**。

| 字段 | 规则 |
|---|---|
| `title` | 短，动词开头：`牙医复诊`、`和小李看展`；不要带日期 |
| `start` / `end` | `YYYY-MM-DDTHH:mm:ss`，本地时间，不带时区 |
| | 单点事件没给结束时间 → 定时 +1 小时；全天 +1 天 |
| `all_day` | 「某天要做/截止」→ true；有钟点 → false |
| `location` | 没有就留空，不要编地址 |
| `notes` | 注意事项、要带的东西、联系人电话 |
| `alarms` | 默认 `[]`；用户要才填，单位是「提前几分钟」 |
| `repeat` | 只有用户说「每周」「每月几号」才填 |

日期规则：

- 一律 Asia/Hong_Kong。
- 相对说法（「下周三」「这个月底」）先算出具体日期，**在确认表里回显**，让用户一眼看出算错没有。
- 缺日期只给时间 → 问。只说「要体检」没说钟点 → 问是全天还是有具体时间。
- 同一时段撞车 → 在表里标出来，让用户决定。

## 第 3 步 出确认清单

```
准备写入「Calendar」（iCloud），共 3 条：

| # | 日期 | 时间 | 事件 | 地点 | 备注 |
|---|------|------|------|------|------|
| 1 | 11/12 周四（=下周三） | 15:00–15:40 | 牙医复诊 | XX 口腔 | 带上次的片子 |
| 2 | 11/15 周日 | 全天 | 交房租 | — | — |

确认写入 / 有要改的？
```

「日期」列带上相对日期的推算结果。表里不要塞 plan.json、不要贴命令。

## 第 4 步 写入

确认后落一份 plan.json（放 `.tmp/`，用完删）：

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
      "alarms": []
    }
  ]
}
```

先 dry-run：

```bash
$CAL add --file .tmp/plan.json --dry-run
```

`skipped` 有内容 = 那个日历里已有同名同时间事件，先跟用户确认是不是重复，再决定跳过还是照写。

再真写：

```bash
$CAL add --file .tmp/plan.json
```

## 第 5 步 读回校验

```bash
$CAL list --from 2026-11-12 --to 2026-11-16
```

把 `added` 和 `list` 对上，回给用户一张「写好了」的表：日历名、条数、日期范围，加上跳过/失败条目和原因。`failed` 非空就把 `error` 原文摆出来，不要自己解释成「网络问题」。

收尾一句：iCloud 同步通常几十秒到 iPhone，日历 App 下拉刷新即可。别承诺「立刻」。

## 排错

| 报错 | 处理 |
|---|---|
| `needs_permission` / `no_permission` | 系统设置 → 隐私与安全性 → 日历 里勾选「日历助手」；重编译后可能要再授权一次 |
| `timeout` | helper 卡在授权弹窗或被杀掉了；重跑，必要时 `open ~/.agents/skills/apple-calendar/CalendarHelper.app` 单独触发授权 |
| `calendar_not_found` | `$CAL calendars` 看清单，改 `config.json` 或 `--calendar` |
| `ambiguous_calendar` | 同名日历不止一个，用返回的 `id` 指定 |
| `readonly_calendar` | 订阅日历写不了，换主日历 |
| 编译报 `Operation not permitted` | 用 `scripts/build.sh`，它把 module cache 指到了项目内 |

## 查日程

用户问「这周/下周/某个月有什么安排」时，不是聊天揣测，直接读：

```bash
$CAL list --from 2026-11-09 --to 2026-11-16
```

返回按开始时间排序。汇报时按天分组，全天事件和定时事件分开列；跨天或同一天三件以上的，先给一句总览。只读，不要顺手写。

## 改和删

1. `$CAL list --from ... --to ...` 找到事件 `id`
2. 讲清楚「动哪条、改成什么」，等确认
3. `$CAL delete --id <id>`

不批量删，不删用户没点名的事件。
