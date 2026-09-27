# 唯时代尔 —— 闯关 / NPC 对话 / 新地图 设计方案

> 状态：**方案待评审，未动一行代码**
> 编写日期：2026-09-27
> 目标引擎：Godot 4.6.1（`F:\gt\Godot_v4.6.1-stable_win64.exe`）
> 工作区：`G:\zzgame\My Game\`

---

## 0. 需求确认（已与你确认过的选择）

| 项 | 你的选择 |
|---|---|
| 关卡结构 | **分支地图（类似爬塔）**：每关结束选下一个节点 |
| 过关条件 | **四种都要**：清空全部波次 / 击杀指定数量 / 撑满倒计时 / 击败 Boss 或到达终点 |
| 关卡之间 | **商店·升级（用现有 3 种道具）+ 剧情对话 + 本关成绩显示** |
| 对话触发 | **地图上的 NPC，靠近按 E 触发**（底部对话框 + 打字机效果） |
| 新地图 | **程序化随机生成布局**（每局不一样） |
| 本次交付 | 仅方案文档，暂不写代码 |

组合后的成品形态：**Roguelite 俯视角射击**
一局 = 一张随机生成的爬塔路线图 → 选节点 → 打一场随机地形的战斗（目标由节点类型决定）
→ 过关结算战绩 → 商店/升级 + 剧情对话 → 回到路线图继续前进 → 最终 Boss → 通关总结。

---

## 1. 现状盘点（读代码得到的事实）

| 项 | 现状 |
|---|---|
| 主场景 | `scene/game.tscn`：`Game(Node2D, game.gd)`，子节点 `GroundTileMapLayer` / `OverlayTileMapLayer` / `Player` / `HUDLayer` / `EnemyContainer` / `EnemySpawnPoints` / `EnemySpawnTimer` / `AcceptDialog`(结算) / `AudioContainer`(BGM+胜负音效) / `CameraSystem` |
| 关卡 | **只有一关**：`stage_duration = 120s`，撑满倒计时即胜；玩家 hp 归零即负；结算后回 `title.tscn` |
| 刷怪 | `Timer` + 无限刷：`initial_spawn_count / spawn_count_per_tick / spawn_interval → min_spawn_interval`（随时间线性加速）/ `max_alive_enemies = 24` |
| 敌人 | `EnemyConfig`(Resource)：`enemy_type(basic/shelled/fast/bomber)`、`max_health`、`move_speed`、`collision_radius`、动画名、`explode_on_death`、掉落概率与掉落池。现有 4 份 `.tres` |
| 敌人 AI | `enemy.gd` 自己带 `AStarGrid2D` 寻路 + 视线检测，`EnemyPathfinder`（`enemy_pathfinder.gd`）在 `game.gd::_ready()` 里 **同步 build 一次**，把"带物理多边形的瓦片格"当墙 |
| 玩家 | `player.gd`：`move_speed=120` / `max_health=3` / `fire_interval=0.18` / `invincibility_duration=1.0`；道具是**限时 buff**（移速倍率 / 射速倍率 / 浮游炮形态+螺旋弹幕），`apply_pickup(config)` 单入口 |
| 掉落 | 敌人死亡按概率掉 `pickup_speed/rapid/spiral` 三种 |
| UI 风格 | **`title.gd` 全部 UI 用代码生成**（不手写 .tscn），这是个很好的既有约定 |
| 地图数据 | `GroundTileMapLayer.tile_map_data` 是**二进制 `PackedByteArray`** → 手写 `.tscn` 改地图不可行 |
| 地图尺寸 | 瓦片 16×16，约 **38×24 格 = 608×384 px**；带碰撞的瓦片：`1:0 / 2:0 / 0:1 / 0:2 / 3:2 / 2:3 / 3:3`（瓦片.png）+ 动态瓦片系列 |
| 寻路 | `EnemyPathfinder.build(Array[TileMapLayer])`，可在**运行时重建**（这是程序化地图的关键接口，已具备） |
| 战绩 | `round_records.gd` → `user://round_records.json`，存最近 10 局（`index/elapsed/kills/won`） |
| Autoload | **项目当前 0 个 autoload**（`project.godot` 无 `[autoload]` 段） |
| 输入 | 只有 `move_left/right/up/down`、`shoot_left/right/up/down` |
| 物理层 | 1 World / 2 Player / 3 EnemyBody / 4 EnemySensor / 5 Bullet / 6 Pickup / 7 Explosion |
| 版本控制 | 无 git，`README.md` 仅一行标题 |

---

## 2. 架构决策

### 2.1 把"地图"拆成三层（最关键的一条）

你说的"新增地图"实际混了三件事，必须在架构上分开，否则后面一定打架：

| 层 | 名称 | 内容 | 实现方式 |
|---|---|---|---|
| **L1** | `RunMap` 局内路线图 | 爬塔节点图：每层 2~4 个节点，类型 = 战斗 / 精英 / Boss / 商店 / 事件 / 补给 | 纯数据 + 一个 UI 场景 `MapScreen`，**完全不碰 TileMap** |
| **L2** | `Arena` 战斗场地 | 每场战斗的实际地形（墙、掩体、出怪点、玩家出生点） | **程序化生成**：运行时 `set_cell` 铺 `GroundTileMapLayer` + 动态生成出怪点 |
| **L3** | `RunState` 整局状态 | 层数、金币、已购升级、血量上限、当前节点、是否通关 | Autoload 单例，跨场景常驻 |

- L1 负责"关卡推进 + 分支选择"
- L2 负责"每局地形都不一样"
- L3 负责"跨场景记住你的养成"

### 2.2 场景流程

```
title.tscn（开始界面）
   ├─ 开始新局 → RunState.reset() → MapScreen.tscn
   ├─ 继续上次进度（可选，读 RunState 存档）
   └─ 经典模式 → game.tscn（保留现有单关玩法，作为回退入口）

MapScreen.tscn（L1 爬塔图）
   ↓ 选中「战斗 / 精英 / Boss」节点
Battle.tscn（由 game.tscn 改造）
   ├─ 进场：ArenaGenerator 生成地形 → 重建寻路 → 生成本关目标 & 波次
   ├─ 战斗：HUD 显示目标进度
   ├─ 结束：胜利 → RewardScreen；失败 → 失败结算（重来本节点 / 结束本局）
   ↓
RewardScreen（本关成绩 + 商店/三选一升级）
   ↓（事件节点时）
DialogueBox（剧情对话）
   ↓ 回到 MapScreen（层数 +1，重新生成可选节点）
   ↓ 到达最终层并击败 Boss
EndScreen（总结：层数 / 总击杀 / 总用时 / 是否通关）→ 写入 RoundRecords
```

### 2.3 关于 `game.tscn` 的处理（不激进替换）

- **保留 `game.tscn` 现状**，作为"经典模式"入口；
- 新增 `scene/battle/Battle.tscn`，把 `game.gd` 中的"单场战斗逻辑"抽出来（胜负判定 / 刷怪 / HUD / 结算）；
- 等 `Battle` 跑通、你验收之后，再决定是否让主流程默认走新链路；
- 好处：任何一步出问题都能退回现有可玩版本。

### 2.4 UI 风格沿用现有约定

`title.gd` 已经是"UI 全用代码生成"。建议 **`MapScreen` / `RewardScreen` / `DialogueBox` 也全部用代码生成 UI**：
- 我几乎不需要手写 `.tscn` → 出错概率最低（`.tscn` 是文本但有格式陷阱，尤其 `PackedByteArray`）；
- 改版式只改代码，和你现有习惯一致。

---

## 3. 程序化随机地形（Arena 生成）

### 3.1 必须绕开的坑

`GroundTileMapLayer.tile_map_data` 是**二进制**，只能运行时用代码铺瓦片；
`EnemyPathfinder` 又依赖"有物理多边形的瓦片格 = 墙"。

### 3.2 生成流程（全部代码控制）

1. `ground_layer.clear()` 清空旧地形；
2. 生成 `Array[Array[int]]` 地图网格（0 = 地板，1 = 墙），推荐两种算法（先实现 A，B 作为可选）：
   - **A. 房间 + 走廊（BSP / 随机房间）**：房间多、掩体感强，适合俯视角射击；
   - **B. 随机游走 / 元胞自动机**：天然洞穴地形，更"野生"；
3. 逐格 `ground_layer.set_cell(Vector2i(x, y), source_id, atlas_coords)`：
   - 墙只能用**带 `physics_layer_0` 多边形的 atlas 坐标**（`1:0` `2:0` `0:1` `0:2` `3:2` `2:3` `3:3`），否则敌人会穿墙、玩家也挡不住；
   - 地板用无碰撞坐标；
4. 最外圈强制全墙（保证玩家不会走出画布）；
5. `OverlayTileMapLayer` 只放装饰（不影响物理）；
6. **重建寻路**：`EnemyPathfinder.instance.build([ground_layer, overlay_layer])`；
7. 生成出怪点：所有"距玩家出生点 ≥ N 格"的可走格作为候选池（**不再依赖场景里手摆的 `EnemySpawnPoints`**，改为运行时创建 `Marker2D` 挂到该节点下，保证 `game.gd` 现有 `_collect_enemy_spawn_points()` 逻辑可复用）；
8. 玩家出生点选"最开阔/最安全"的可走格（例如周围 3×3 全可走，且离边界 ≥ 2 格）。

### 3.3 三条硬性校验（写代码时必须实现）

1. **连通性**：铺完后对地板做 flood fill，玩家出生点与所有出怪点必须在同一连通域；不满足 → 换种子重新生成（最多重试 N 次，再失败就退回"空旷房间"保底布局）；
2. **寻路时机**：`build()` 必须在"铺完瓦片之后、刷怪之前"。现有 `_ready()` 里的调用顺序需要调整（现在是先 build 再刷怪，地形是静态的；改成动态后顺序会变）；
3. **出生点合法性**：沿用现有 `_warn_spawn_points_inside_walls()` 的思路，生成后自检一遍（落在墙里/越界就重新挑）。

### 3.4 画布尺寸与难度

- 默认保持 **38×24 格（608×384 px）**，和现在一致，摄像机/边界不用改；
- 可选：按层数递增尺寸（例如每 3 层 +2 格宽），但要注意摄像机行为（当前是 `CameraSystem/Camera2D` + `RemoteTransform2D` 跟随玩家）。

---

## 4. 关卡目标系统（四种，统一数据驱动）

把"过关条件"抽成数据，`Battle.gd` 只负责"检测 + 广播"，不关心是哪一种。

### 4.1 目标类型

| 类型 | 参数 | 胜利判定 | HUD |
|---|---|---|---|
| `SURVIVE_SECONDS` | `duration` | 倒计时归零 | 倒计时条（**现有实现，直接复用**） |
| `KILL_COUNT` | `target_kills` | `round_kill_count >= target` | `击杀 12 / 30` |
| `CLEAR_WAVES` | `waves[]`（每波敌人数/配置/间隔/是否精英） | 全部波次刷完 **且** 场上敌人为 0 | `剩余波次 2 / 3` |
| `DEFEAT_BOSS` | `boss_config` | Boss 死亡 | Boss 血条 |
| `REACH_EXIT` | `exit_cell` / `Area2D` | 玩家进入终点区域 | 终点指示箭头（可选，先不做） |

### 4.2 统一规则

- **失败** 永远只有一条：`player.hp <= 0`（沿用现有逻辑）；
- **胜利** = 目标达成；
- 可选 `time_limit`：作为**全局上限**，超时且未达成目标 = 失败（这样 `SURVIVE_SECONDS` 就是"time_limit 且目标为耗满时间"）；
- 一关可配多个目标：需要 `mode = ALL | ANY`（**待你确认**，见第 9 节）。

### 4.3 代码改动点

- `game.gd::_check_game_result()` 是当前唯一胜负出口 → 抽为 `_evaluate_goals()`；
- `game.gd::_on_enemy_died()` 已维护 `round_kill_count` → 保留，并额外广播信号给波次系统；
- 新增 `WaveRunner`：把现在的"无限刷怪 + 随时间加速"改成"按波次表刷怪"（`CLEAR_WAVES` 用）；**现有加速逻辑保留给 `SURVIVE_SECONDS` 模式**；
- 敌人配置从"随机挑一个"升级为"按波次表挑"（波次表里可指定敌人类型池与数量）。

---

## 5. NPC 对话系统

### 5.1 数据（推荐 Resource，便于编辑器内维护与挂头像）

```
resources/dialogue/npc_smith.dialogue.tres        # DialogueData (Resource)
├─ id: StringName
├─ npc_name: String
├─ avatar: Texture2D                              # 可为空
├─ default_text_speed: float                      # 打字机速度（字/秒）
└─ lines: Array[DialogueLine]
     DialogueLine
     ├─ speaker: StringName                       # 说话者（左上角名字）
     ├─ portrait: Texture2D                       # 可为空
     ├─ text: String
     ├─ auto_advance: bool / pause: float         # 自动播放（关卡间剧情用）
     └─ choices: Array[DialogueChoice]            # 分支选项（可空）
          DialogueChoice { text: String, next_line_id: int, grant_pickup/开商店 等指令 }
```

> 备选：先用 JSON 跑通再升级。**建议直接上 Resource**：你后面要加头像/立绘，资源更顺。

### 5.2 场景与交互

- `Npc.tscn`
  - `Area2D`（交互范围；建议新增物理层 **8 = `Interactable`**，或临时复用 `Pickup` 层）+ `CollisionShape2D`
  - `Sprite2D`（**目前没有任何 NPC 美术素材**，先用 `icon.svg` / 纯色块占位）
  - 头顶"按 E 对话"提示气泡：`body_entered / body_exited` 控制显隐
- `DialogueBox.tscn`
  - 底部对话框：`ColorRect/NinePatchRect` 底 + `Label`（或 `RichTextLabel`）
  - 打字机：逐帧增加 `visible_characters`（比 `visible_ratio` 更精确，且能配 `text_speed`）
  - 继续：`E` / 空格（对话中还能用 `ui_accept`）
  - 选项：`ui_up/ui_down` 选择 + `E` 确认（Godot 内置 action，无需新增），鼠标点击也支持
- `DialogueManager`（Autoload）
  - `start(data: DialogueData, on_finished: Callable)`
  - 信号：`dialogue_started` / `dialogue_line_changed` / `dialogue_finished`
  - 免费复用：**关卡间剧情**用同一个组件，只是 `auto_advance = true` 且不锁玩家操作

### 5.3 输入锁（重要）

- 对话期间要锁住玩家移动/射击 → `player.gd` 新增 `set_input_enabled(enabled: bool)`；
- **不要用 `get_tree().paused = true` 来做对话暂停**：现有结算逻辑用暂停，会把对话 UI 一起冻住（除非节点设 `process_mode = ALWAYS`）；
- 建议：对话期间 = "锁玩家输入 + 可选锁敌人"，场景树保持运行。

### 5.4 输入映射新增

`project.godot` 需要新增（现在只有 move/shoot）：
- `interact` → `E` / `回车`
- `pause` → `ESC`（可选）

---

## 6. 商店与升级

现有 3 种道具是**限时 buff**（`duration` 几秒），直接当商品会缺少"养成感"，所以分两类：

| 类别 | 数据 | 说明 |
|---|---|---|
| **消耗品** | 沿用 `PickupConfig` | 商店花金币购买，立刻生效或存进 `RunState` 供下场使用 |
| **长效升级** | 新增 `UpgradeConfig` (Resource) | 永久提升：`max_health +1`、移速 `+10%`、基础射速 `+10%`、无敌时间 `+0.2s`、开局自带 1 个道具…… 存 `RunState`，每场战斗开场应用到 Player |

- **金币**：敌人掉落（可在 `EnemyConfig` 加 `gold_drop`）+ 过关奖励，存 `RunState.gold`；
- **数值分层**（必须做，否则升级会污染 buff 计算）：
  - `player.gd` 现在 `move_speed / fire_interval / max_health` 是 `@export` 基础值，道具用倍率盖在上面；
  - 新增 `upgrade_move_speed_multiplier` / `upgrade_fire_rate_multiplier` / `bonus_max_health`，和现有 buff 倍率**相乘**即可，改动很小；
- **商店形态**：建议"摊位 NPC + 对话式购买"，与第 5 节复用同一套 NPC/对话系统；若想更快，先做纯 UI 三选一（不进对话）。

---

## 7. 文件改动清单

### 7.1 新增

```
docs/闯关与NPC对话系统设计方案.md   ← 本文件
autoload/RunState.gd                # 整局状态（层数/金币/升级/进度），可存档
autoload/GameFlow.gd                # 场景流程切换（title→map→battle→reward→map→end）
autoload/DialogueManager.gd         # 对话驱动
scene/map/MapScreen.tscn + MapScreen.gd    # 爬塔路线图 UI（UI 用代码生成）
scene/map/RunMap.gd                 # 路线图随机生成（层数/节点类型/连线）
scene/arena/ArenaGenerator.gd       # 程序化地形 + 出怪点 + 连通性校验
scene/arena/LevelGoalDef.gd         # 目标数据（按 type 枚举驱动）
scene/battle/Battle.tscn + Battle.gd  # 由 game.tscn 抽出的单场战斗
scene/battle/WaveRunner.gd          # 波次调度（CLEAR_WAVES）
scene/reward/RewardScreen.gd        # 本关成绩 + 商店/三选一升级
scene/dialogue/DialogueBox.gd       # 底部对话框 + 打字机 + 选项
scene/dialogue/Npc.tscn + Npc.gd    # 地图上的可交互 NPC
resources/dialogue/*.tres           # 对话数据（含占位剧本）
resources/upgrade/*.tres            # 长效升级数据
```

### 7.2 修改

```
project.godot          # 新增 [autoload]（RunState / GameFlow / DialogueManager）
                       # 新增 input：interact(E/回车)、pause(ESC，可选)
                       # 新增物理层 8 = Interactable
scene/game.gd          # 胜负判定抽成目标系统；刷怪抽出（保留经典模式可玩）
scene/player.gd        # set_input_enabled()；基础值/升级加成/道具 buff 三层数值；apply_upgrade()
scene/title.gd         # 新增「开始新局 → MapScreen」「经典模式 → game.tscn」
scene/round_records.gd # 战绩增加字段：到达层数、总击杀、是否通关（保持向后兼容：旧档缺字段用默认值）
scene/enemy.gd         # 可选：金币掉落
```

### 7.3 不动的东西（保证回退）

`scene/player.tscn`、`scene/enemy.tscn`、`scene/bullet.*`、`scene/pickup.*`、`resources/texture|audio|font`、`blink.gdshader`、`enemy_pathfinder.gd`（只改调用时机，不改内部算法）。

---

## 8. 风险与对策

| 风险 | 说明 | 对策 |
|---|---|---|
| 寻路卡死 | 程序化地形后 `EnemyPathfinder` 必须在铺完瓦片后重建，顺序错会导致敌人集体撞墙 | 生成器输出"生成完成"信号，Battle 里严格按 `生成地形 → build → 刷怪` 顺序；开机自检 `pathfinder.is_usable()` |
| 不连通地图 | 随机地形可能出现敌人被困在孤岛 | flood fill 校验 + 换种子重试 + 空旷房间保底 |
| `.tscn` 手写风险 | 场景文件是文本但格式敏感（`tile_map_data` 还是二进制） | UI 全部代码生成；尽量少新增 `.tscn`；新增文件独立，不改老场景 |
| autoload 引入 | 项目当前 0 autoload，加 autoload 需要改 `project.godot` | 只在 `project.godot` 追加 `[autoload]` 段，不动其它设置；先在编辑器里确认能正常启动 |
| 数值被 buff 污染 | 升级与限时 buff 都改同一批变量 | 数值分三层：`基础值 × 升级加成 × 道具 buff` |
| 暂停与 UI 冲突 | 现有结算用 `Engine.time_scale=0 + paused`，对话若照抄会冻住 UI | 对话不暂停场景树，只锁输入 |
| 无美术素材 | 没有 NPC 立绘/新敌人素材 | 先生成占位（色块 + 名字），后期替换资源即可 |

---

## 9. 需求确认结果（2026-09-27 已确认，原"开放项"已全部关闭）

| # | 问题 | 你的决定 | 对方案的影响 |
|---|---|---|---|
| 1 | NPC 美术 | **用 `resources/texture/源石虫.png` 里的敌人图**（无独立立绘素材） | 需要确认该图的帧布局（疑为敌人行走 sprite sheet）→ 可能只能裁切其中一帧作头像，或整图缩放当立绘（待我看图后确认） |
| 2 | 对话文本 | **先用占位符** | `DialogueData` 里全部填 `【占位】…`，结构完整、文案后续替换 |
| 3 | 金币来源 | **只由敌人掉落** | `EnemyConfig` 新增 `gold_drop_min / gold_drop_max`（或掉落物形式），不做"过关奖励金币" |
| 4 | 多目标语义 | **`ALL`：一关所有目标必须全部达成才能通过** | `LevelGoalDef.mode = ALL`；倒计时若要当"上限"，另用 `time_limit`（超时判负），不与其他目标混算 |
| 5 | 备份 / 版本控制 | **已自行 git 过** | 我动手前会先 `git status` 确认干净，每个里程碑提交一次，便于回退 |
| 6 | 老 `game.tscn` | **保留为"经典模式"入口** | 新流程走 `Battle.tscn`，`title.tscn` 增加「经典模式」按钮；稳定后再决定是否换默认入口 |

### 9.1 因上述决定而明确的两条实现约束

- **NPC 交互节点**：因为不新增美术资源，`Npc.tscn` 直接复用敌人的 `AnimatedSprite2D`/`SpriteFrames` 资源（或从 `源石虫.png` 裁一帧），头顶"按 E 对话"用纯文字/`Label` 表现，不画图标。
- **金币系统**：金币只从敌人身上掉 → 需要把"掉落"从现在的"概率掉道具"扩展成"金币 + 道具"两种掉落；金币 HUD 放在现有 `Player/HUDLayer` 下（与 `LifeIcon`、`TimeIcon` 同级）。

## 9.0 原始开放项（已作废，留档）

1. **NPC 美术**：有立绘/头像吗？没有的话我用"名字标签 + 对话框"纯文字（不画图）。
2. **对话文本**：你自己写，还是我先写一版占位剧本（每个 NPC 3~5 句）？
3. **商店/升级**：确认要做吗？做的话金币来源用"敌人掉落"还是"过关奖励"（或两者）？
4. **多目标语义**：一关配多个目标时是 `ALL`（全部达成才算赢）还是 `ANY`（任一达成）？倒计时当"上限（超时判负）"还是"目标本身"？
5. **备份**：动手前先 `git init` 还是复制一份 `My Game_backup`？（项目当前无版本控制）
6. **经典模式**：老 `game.tscn` 单关玩法保留为入口，还是新流程稳定后直接替换？

---

## 10. 建议实施顺序（每步都可单独验收）

| 里程碑 | 内容 | 验收方式 |
|---|---|---|
| **M0** | `RunState` + `GameFlow` + `project.godot`（autoload/输入/物理层）跑通 `title → map → battle → map` 空流程 | 能来回切场景，老玩法不受影响 |
| **M1** | `ArenaGenerator` 程序化地形 + 寻路重建 + 动态出怪点（先只用倒计时目标） | 每局地形不同、敌人能绕过墙找到玩家 |
| **M2** | 四种目标数据化 + HUD 进度 + 胜负判定（含波次系统） | 每种目标都能正确判胜/判负 |
| **M3** | `RunMap` + `MapScreen`（节点类型、分支、精英/Boss/商店/事件） | 能选节点、层数推进、路线不重复 |
| **M4** | `DialogueBox` + `Npc` + `DialogueManager` + E 键交互（打字机、选项） | 靠近 NPC 按 E 能对话，选项能分叉 |
| **M5** | 商店/升级 + 金币 + `RunState` 应用 | 买了升级下场战斗生效 |
| **M6** | 结算/存档扩展、Boss、平衡、导出 exe | 完整通关一局并留下战绩 |

---

## 11. 地图 / 瓦片生成约定（M1 依据 · 2026-09-27 实测）

> 本节数据由 `tools/inspect_tileset.gd` 直接从 `game.tscn` 的 TileSet 与地图数据导出，**不是推测**。
> 复跑命令：`godot --headless --path . --script res://tools/inspect_tileset.gd`

### 11.1 【硬规则】敌人出生点必须落在「红门」上

- 出怪点由 `EnemySpawnPoints` 下的 `Marker2D` 决定，`game.gd::_pick_spawn_point()` 每次随机挑一个；
- **「红门」= `OverlayTileMapLayer` 上的装饰瓦片**：源图 `动态瓦片.png` 的 `(0,0)`，区域 **16×32**（1 格宽 × 2 格高），
  平均色 **`#c70404`（纯红）**；该 TileSet **物理层数 = 0** → 红门不挡路、不参与寻路，纯视觉标记；
- 现有地图的实测对应关系：

| 出怪点 | 世界坐标 | 格子 | 是否落在红门上 |
|---|---|---|---|
| SpawnLeft | (8, 320) | (0, 20) | ✅ 落在左侧竖门 (0,18)~(0,21) |
| SpawnRight | (584, 64) | (36, 4) | ✅ 落在右侧竖门 (36,2)~(36,5) |
| SpawnZhong | (320, 32) | (20, 2) | ✅ 落在上方双宽门 (19~20, 1~2) |
| SpawnBottom | (88, 8) | (5, 0) | ❌ **没有红门（现状缺陷，M1 顺手补上）** |

**生成器必须遵守（M1 验收项）**：

1. 红门只贴**地图边界**（左/右/上/下边缘各一处），**不允许出现在场地中央**；
2. 每个出怪点的格子必须**同时**满足：① 落在红门覆盖范围内（16×32 的门覆盖 2 行，Marker 取其中心格）② 是**可通行格**（不得是墙）；
3. 红门数量 = 出怪点数量 = 4，由生成器**成对创建**（不再手摆）；
4. **生成后自检**：用 `EnemyPathfinder.world_to_cell()` 反查每个 Marker，若不在红门上、或落在墙里 → 修正/重新生成；
   现有 `game.gd::_warn_spawn_points_inside_walls()` 要扩展为「必须在红门上」的校验。

### 11.2 地面 / 墙壁的判定依据

**唯一依据 = 该瓦片在 `physics_layer_0` 上有没有碰撞多边形**（不是看颜色、也不是看亮暗）：

| 图集 | 坐标 | 类别 | 碰撞 | 平均色 | 现有关卡用量 |
|---|---|---|---|---|---|
| 瓦片.png | `0:0,0` | **主地面** | 无 | `#686358` | 488 格 |
| 瓦片.png | `0:1,1` `0:1,2` `0:2,1` `0:2,2` | 地面/装饰 | 无 | 灰褐系 | 15 / 43 / 26 / 22 |
| 瓦片.png | `0:0,1` `0:0,2` `0:1,0` `0:2,0` `0:2,3` `0:3,2` `0:3,3` | **墙/岩石（7 种）** | 有 | `#857a6e`~`#8c8176` | 20/17/68/42/77/15/12 |
| 动态瓦片.png | `1:0,2` `1:0,3` `1:0,4` `1:0,5` | **墙（4 帧动画）** | 有 | 深灰褐 | 14 / 6 / 8 / 33 |
| 动态瓦片.png（Overlay 图集） | `0:0`（16×32） | **红门** | 无 | `#c70404` | 10 |

⚠️ **敌人寻路依赖同一条判据**：`enemy_pathfinder.gd::_is_blocked_cell()` 检查的正是 `get_collision_polygons_count() > 0`。
所以生成器**选错瓦片（无碰撞的当墙、有碰撞的当地面）会直接导致敌人穿墙或卡死**。

### 11.3 尺寸硬约束（决定生成器参数范围）

| 约束项 | 实测值 |
|---|---|
| 现有瓦片地图 | 39×24 格（含 1 格边界外），世界 608×384 px，已用 906 格 |
| **世界硬边界**（`WorldBounds` 两个 `SegmentShape2D`） | `(0,0)→(608,0)` 与 `(0.49,-0.6)→(0,368)` → **可走区 x∈[0,608]、y∈[0,368]**（368 = **23 格**，比瓦片地图少 1 格） |
| 摄像机 | `zoom=(4,4)`、**`limit_enabled=false`**、`RemoteTransform2D` 跟随玩家 → 可视世界约 **288×162 px** |

- 不改 `WorldBounds`/摄像机 → **生成器上限 38×23 格（608×368 px）**；
- 下限 **24×16 格**（视野仅 288 px，图再小玩家会被 3 血贴脸）；
- **建议区间**：最小 24×16 / 默认 30×20 / 上限 38×23；
- 要做更大（如 60×40）**必须同步重建** `WorldBounds` 的两个 SegmentShape2D 并打开摄像机 limit（M1 一并支持）。

### 11.4 瓦片摆放规则（**不能纯随机**）

现有地图是**手工规律摆放**：外墙一圈、`y=10` 与 `y=22` 为整条横向隔断、若干竖墙分区、中间大片开阔地。
纯随机会踩三个坑：① 图集只有 12 个地面/墙位且**没有 autotile 拼角规则** → 墙块边缘错位、观感脏；
② 连通性无保证 → 敌人 A* 失败；③ 红门必须贴边。

**M1 采用的规则化生成**：
1. 地面统一铺 `0:0,0`（避免拼角问题）；
2. 外圈边界墙用动态瓦片 `1:0,2~5`，内部障碍用 7 种静态墙；
3. 房间-走廊骨架（BSP / 随机房间），保证"连通 + 有空地"；
4. 红门贴边 + Marker 与门成对生成（见 11.1）；
5. **flood fill 连通性校验**（含所有红门格与玩家出生点）；
6. 结尾自检 → 失败则换种子重生成（最多 N 次，最后回落"空旷房间"保底布局）。

### 11.5 生成顺序（顺序错会集体卡墙）

```
生成网格数据 → 铺 GroundTileMapLayer（含红门 Overlay）
  → 重建 EnemyPathfinder.build([ground, overlay])
    → 创建出怪 Marker（落在红门上）→ 启动刷怪计时器
```
现有 `game.gd::_ready()` 是「先 build 寻路 → 再刷怪」（地形静态时没问题），
改成运行时生成地形后**必须**按上面顺序执行，否则敌人首帧就落到旧网格上。

---

## 附：本次未做的事

- **没有配置任何 MCP**（`User\mcp.json` 不存在，工作区无 `.vscode\mcp.json`）；
- 本会话的 `bash` 工具不可用（`C:\Program Files\Git\bin\bash.exe` 不存在），因此无法执行 `npx`/`pip`/Godot headless；
- 因你选择"只出方案"，本次**未修改任何游戏代码或场景**，只新增本文件。

---

## 12. M3 实现记录（Boss 关已验收 ✅ 2026-09-27）

> 本节记录**已经实现并被用户确认**的规则，代码位置见各条右列。改动集中在
> `scene/boss.gd` / `scene/battle/battle.gd` / `scene/arena/arena_generator.gd`。

### 12.1 Boss 关的场地与目标
| 项 | 规则 |
|---|---|
| 场地生成 | 走 `ArenaGenerator.MODE_BOSS`（**独立于普通关**）：内部整片开阔地、障碍只放 2~3 块且**每块 ≥ 2×2**、边界墙只有外圈 1 格 |
| 通过性 | `is_boss_passable()`：只在"2×2 全空"的格子上 flood fill，必须能到达每道红门内侧 → **保证半径 16 的 Boss 不会卡墙**（1 格宽 = 16px 会卡） |
| 目标 | **只有一条**：击败 Boss（无时限、无波次）；失败只有"玩家掉完血" |
| 出生距离 | 玩家在离红门最远的地板格；Boss 从**离玩家最远的红门**出场；新增最小距离保证 —— 实测相距 **23~26 格** |
| 红门涌怪 | Boss 关每 `boss_door_spawn_interval = 5` 秒从红门涌出 1 只普通敌人，场上小怪（不含 Boss）上限 `boss_door_alive_cap = 5` |

### 12.2 Boss 技能（`scene/boss.gd`，extends `enemy.gd`）
| 阶段 | 阈值 | 行为 |
|---|---|---|
| P1 | > 66% | 追击；技能池 = 抛小怪（冷却时用扔自爆怪顶） |
| P2 | 33%~66% | 解锁**扔自爆怪** |
| P3 | < 33% | 移速 ×1.5、技能间隔 8s → 5.5s |

| 技能 | 规则 |
|---|---|
| **抛小怪** | 在 Boss 位置生成 3~5 只普通敌人（`z_index=10` 画在其上层）→ 抛物线丢到附近**可通行格** → 落地恢复 AI；**独立冷却 14 秒**、场上小怪上限 6 |
| **扔自爆怪** | Boss 停住 → 锁定玩家此刻位置 → 抛出自爆怪 → 落到该点**立即引爆**。⚠️ 爆炸会伤到 Boss 自己 —— **这是有意的设计**（玩家可借此输出） |
| **冲刺** | **始终可用**（不在随机池里）。触发：开局 ≥ `charge_unlock_delay=5` 秒 **且** 玩家距离 ≤ `charge_trigger_cells=5` 格（80px）**且** 冷却 `charge_cooldown=5` 秒结束 → 立即冲。<br>预警 = **长方形红色区域**（长 = 冲刺距离+24px、宽 = 2 格、α0.12→0.38 渐浓 + 亮红描边，`z_index=1` 高于地砖）+ 稳定黄光一次；<br>**闪光结束 → 冲刺结束期间完全免伤**（覆盖 `apply_damage()`），冲刺期间红圈最亮 |

### 12.3 显示规则（全部代码生成、零美术）
- 全项目字体统一为 `resources/font/IPix.ttf`（`project.godot` 的 `[gui] theme/custom_font`）；该字体缺 `：·　（）。、！？|` 等标点，已在全项目替换
- Boss 外圈 = **两层很细的柔光环**（`Line2D`，内环 r21/w1.5/α0.5 + 外环 +3.5px/w3.3/α0.16），预警时变亮变粗
- **无时限关卡删除时钟**；Boss 关把头顶绿条改成**红条并横向居中**（绑定 Boss 血量）+ 左端加「BOSS」字样；其他无时限关卡连绿条一起删除，并把**生命值图标+文字整体上移到原时间那一行**（横向不动）
- 底部目标 HUD（CanvasLayer 屏幕空间、居中、黑描边）：第一行「目标: …」、第二行「第 N 层 · 进度 · 剩余时间」

### 12.4 调试入口（都已接好）
| 入口 | 用法 |
|---|---|
| 标题页「调试: 直接打 Boss」 | 跳过路线图直接进最终层 Boss 关（最常用） |
| `battle.gd` → `Debug Goal Type` | 强制目标类型（survive/kill/clear_waves/boss） |
| `battle.gd` → `Debug Fast Boss` / `Debug Instant Boss Win` | 加速 Boss 技能 / 模拟击败并验证"总结→回标题"链路 |
| `boss.gd` → `Debug Force Phase` / `Debug Fast Skills` | 强制阶段（1~3）/ 技能加速 4 倍 |
| `tools/*.gd` | `test_arena_generator`（含 Boss 场地 8/8 断言）、`test_level_goal`、`inspect_tileset`、`inspect_font`、`screenshot.ps1` |

### 12.5 剩余待办
- **M4** NPC 对话系统（地图 NPC + 靠近按 E + 底部对话框打字机 + 选项分支；`DialogueManager` 骨架已就位）
- **M5** 商店 / 升级 + 金币（金币目前只预留了 `RunState.gold`，尚未产出）
- **M6** 收尾：平衡、通关总结打磨、导出 exe（`release/` 已 gitignore）

---

## 13. M4：中间地图（Hub）—— 已与用户确认的设计（2026-09-27）

> 目的：把现在"节点按钮式路线图"（`MapScreen`）换成**可以走动的中间地图**，
> 玩家在打完一关后进入这张图，自己走到想去的角色那里交互。

### 13.1 流程
```
战斗胜利 → RunState.advance_floor() → Hub（可走动，无敌人）
   → 走到某个角色旁 → 出现「按 E 交互」提示 → 按 E 弹对话框
       ├─ 进入地图  → GameFlow.start_battle({floor, node_type})
       ├─ 进入商店  → 商店界面（购买后回到 Hub，可继续交互）
       └─ 取消      → 关闭对话框，继续走动
   → 战斗胜利 → 回到 Hub（层数 +1，角色重新随机）
   → 战斗失败 → 回标题，整局结束
```

### 13.2 Hub 上的三类角色（全部复用现有素材，零新美术）
| 角色 | 代表 | 素材做法 | 交互后 |
|---|---|---|---|
| **精英关** | 紫色敌人 | 敌人 SpriteFrames + `modulate` 染紫 | 对话框 → 进入精英关（沿用 M2 规则：击杀 N + 撑满 T 秒的 ALL 目标） |
| **普通关** | 普通敌人 | 敌人 SpriteFrames（原色） | 对话框 → 进入普通关（清空 N 波） |
| **商店** | 玩家形象 | 玩家贴图（静态一帧） | 对话框 → 商店界面 |

**数量规则（用户 2026-09-27 二次确认，已取代之前的 0~3 个方案）**：
- Hub 上有 **3 个固定位置，每个位置必定站着一个角色**（不会出现空位）
- **角色类型随机**：精英 / 普通 / 商店 三选一，彼此独立 → 可能三个都是普通关，也可能这层没有商店
- **因此不需要"继续前进"出口**（不会出现无可交互对象而卡死的情况）
- 位置固定、类型随机：位置坐标写死，类型用 `floor_index` 播种，便于复现

### 13.3 生命值一致性（用户确认：局内跨关卡保留）
- `RunState.current_health` / `max_health` 在**同一局内**跨关卡保留：战斗开场时把玩家血量设成 `RunState.current_health`，战斗结束时写回
- **新开一局**（标题 →「开始新局，闯关」）重置为 `BASE_MAX_HEALTH = 3`
- 结算面板与顶部 `X3` 显示同一份数据

### 13.4 商店（全部局内成长，不带出局外）
| 商品 | 效果 | 价格（递增） |
|---|---|---|
| **+1 生命** | `max_health +1` 且当前生命 `+1`（道具目前只有这一项） | 15 |
| **射速** | 每级 `fire_rate_multiplier +10%` | 25 |
| **伤害** | 每级子弹伤害 `+1` | 40 |

- **金币来源**：只来自敌人掉落（每只普通怪 1 金币，精英/Boss 3 金币）；HUD 显示金币数
- **玩家伤害**：现状是子弹固定 1 点伤害（`enemy.gd::DEFAULT_BULLET_DAMAGE`），需要新增
  `Bullet.damage` + `RunState.player_damage`，由商店升级驱动

### 13.5 实现步骤（每步都会 headless 自测 + 可单独验收）
1. **数据层**：`RunState` 增加 `current_health / max_health / player_damage / fire_rate_level / gold`，
   战斗开场写入、结算写回（纯数据，先做单测）
2. **Hub 场景**：`scene/hub/hub.tscn` + `hub.gd`（可走动的小场地、摄像机跟随、无敌人），
   交互对象 = `Npc.tscn`（Area2D + 提示 + 按 E）
3. **对话框**：`DialogueBox`（底部对话框 + 打字机 + 选项分支），复用 `DialogueManager` 骨架
4. **商店界面**：代码生成的购买面板（三项 + 金币 + 价格递增 + 买不起置灰）
5. **接线**：`GameFlow` 增加 `goto_hub()`；战斗胜利 → Hub；`MapScreen` 保留为调试入口（或下线）

### 13.6 待确认/可调项
- Hub 场地尺寸与走动速度（默认：沿用现有 16px 瓦片、用 `ArenaGenerator.MODE_BOSS` 生成一张小图 24×16）
- 商店价格与成长幅度（用户已选"用提议的数值，先跑通再调"）
- ~~「继续前进」出口~~ → **不要**（已确认 3 个位置必定有角色）

## 14. M4-5 实施记录：战斗胜利 -> 中间地图（Hub）循环

### 14.1 流程改动
- `GameFlow` 新增 `HUB_SCENE` / `goto_hub()`；`start_new_run()` 从「标题 -> 路线图」改为「标题 -> Hub」
- 关卡胜利（非 BOSS）：`RunState.advance_floor()` + `GameFlow.goto_hub()`（原来是 `goto_map()`）
- BOSS 关胜利：`RunState.finish_run(true)` + 结算弹窗「通关 / 整局总结」+ 回标题（不变）
- 失败：`finish_run(false)` + 回标题（不变）
- 路线图 `MapScreen` 保留为**调试入口**，不再出现在主流程里
- `RunState.advance_floor()` 增加上限：已在最终层时保持第 `MAX_FLOOR` 层，
  避免在最终层打赢精英关后层数溢出到 9
- 胜利结算文案改为「本层目标达成 回中间地图」（BOSS 关仍是整局总结）

### 14.2 最终层的 BOSS 入口
Hub 三个位置顺序固定（精英 / 普通 / 商店）。到最终层（默认第 8 层）时**中间位置变成 BOSS 关**：
- kinds 变为 `["elite", "boss", "shop"]`，标题显示「BOSS」，沿用精英关那排图并染红区分
- 对话正文换成「最终决战 准备好了吗？」
- 进入后走 `GameFlow.start_battle({node_type: "boss"})`，Battle 按 boss 目标生成场地

### 14.3 验证（headless 全链路）
1. 第 8 层 Hub：角色 = 精英关 / BOSS / 商店；进入后场地 房间=1 红门=4（符合 BOSS 场地规则）
2. 完整循环：连续 7 次「胜利 -> 回 Hub -> 层数 +1」，从第 1 层一路推到第 8 层，
   第 8 层中间位置自动变成 BOSS
3. 击败 BOSS：结算弹窗显示整局总结（到达层数 8/8、总击杀、用时、金币），
   `局进行中=false / 已通关=true` -> 回标题

### 14.4 相关调试开关
| 开关 | 位置 | 作用 |
|---|---|---|
| `debug_dialogue_test` | hub.gd | 自动打开角色对话并发送真实 E 键 |
| `debug_dialogue_kind` | hub.gd | 自动对话针对哪个角色（elite / battle / shop / boss） |
| `debug_floor` | hub.gd | 强制层数（测最终层 BOSS 位置用） |
| `debug_start_gold` | hub.gd | 进入 Hub 预支金币（单独测商店用） |
| `debug_instant_win` | battle.gd | 任意关卡秒胜，走完整条结算 + 切场景链路 |
| `debug_instant_boss_win` | battle.gd | 仅 BOSS 关秒胜 |

## 15. 关卡刷新规则（用户指定，取代 §13 的固定顺序）

### 15.1 层数与 BOSS 层
- `RunState.MAX_FLOOR` 由 8 改为 **10**
- `RunState.BOSS_FLOORS = [5, 10]`：第 5 层是**中途 BOSS**，第 10 层是**最终 BOSS**
- 中途 BOSS 胜利：`advance_floor()` + 回 Hub（`is_active` 保持 true，结算弹窗写「BOSS 击破」）
- 最终 BOSS 胜利：`finish_run(true)` + 整局总结 -> 标题
- 失败：任何时候都 `finish_run(false)` -> 标题（整局结束）

### 15.2 三个位置的刷新规则（`RunState.hub_kinds(floor)`）
- **BOSS 层（第 5 / 10 层）**：固定 **商店 - BOSS - 商店**（左右各一个商店，打 BOSS 前方便补给）
- **其它层**：三个位置各自从 `精英关 / 普通关 / 商店` 里随机
  - 若这一层**没有刷出普通关**，则随机挑一个位置保底改成普通关
  - 随机用「层数 × 104729」做种子 -> **同一层结果固定可复现**，重进不会变
- 非 BOSS 层不会刷出 BOSS

### 15.3 自检
- `tools/test_hub_kinds.tscn`（7 项）：BOSS 层固定组合、非 BOSS 层类型合法/不刷 BOSS/必有一个普通关、
  同层可复现、随机有效（>= 5 种组合）
  - 实测 1~40 层：商店共出现 32 次、15 种组合、38 个非 BOSS 层里 14 层没有精英关（说明随机在起作用）
- 端到端：第 5 层 Hub = 商店/BOSS/商店 -> 进 BOSS -> 秒胜 -> **层数 6、局进行中 false、已通关 false**（继续循环）

## 16. 关卡之间的汇报（M4-7）

### 16.1 数据流
- Battle 离场时（`_record_run_progress()`）把本关成绩写进 `RunState.last_level_report`：
  `floor / node_type / goal_text / won / kills / elapsed / gold_gained / gold_total / health / max_health`
- Hub `_ready()` 里检查：非空 **且** `report.floor == RunState.floor_index - 1` 时弹一次汇报，
  然后立刻清空（只弹一次，不会重复出现）
- 层数对不上（例如用调试跳关）就静默丢弃

### 16.2 表现
- `scene/hub/level_report.gd`（纯代码 CanvasLayer，layer=12 高于对话框 10 / 商店 11）
- 标题「第 N 层 汇报」（N = 即将打的这一层）；正文 4 行：
  上一关 第 X 层 类型 + 达成状态 / 本关目标 / 击杀 + 用时 / 金币 + 总计 + 生命
- 下面接一句**本层通讯**（`STORY_LINES` 按 1~10 层各写一句，含第 5 层「前面就是本层 BOSS」提示）
- 底部提示「E 继续」；操作与对话框/商店一致：**E / 回车 / ESC** 关闭
- 面板打开期间玩家锁住（`_sync_player_lock()` 一并考虑汇报面板），关闭后有 0.25 秒交互冷却，
  避免这一下 E 顺手又开了角色对话
- 边框用冷蓝色，和商店/对话框的金色区分开

### 16.3 自检
- `tools/test_level_report.tscn`：26 项（字体字形、空数据不弹、标题/正文各行内容、未达成文案、
  E 关闭、ESC 关闭、closed 信号次数）
- 端到端：自动打关 -> 秒胜 -> 回 Hub，日志确认「本关汇报: 上一关 第 1 层 普通关 击杀 0 用时 1.3 秒 金币 +8」，
  之后依次推进到第 5 层仍是 商店-BOSS-商店
