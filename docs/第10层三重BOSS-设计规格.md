# 第 10 层「三重 BOSS」设计规格

> 需求来源：用户口述 + 4 项确认（2026-09-29）
> 状态：**规格已确认，待实现**（本文件即实现清单）
> 关联文档：`docs/游戏策划案.md`（数值）、`docs/闯关与NPC对话系统设计方案.md`（实现记录）

## 1. 需求（用户确认）

| 项 | 决定 |
|---|---|
| 出现位置 | **第 10 层**，与原 BOSS **同场出现**；新 BOSS **放 2 只** → 该层共 **3 只 BOSS** |
| 美术 | `resources/texture/源石虫.png` **第 3 排**（y=64）那只紫色敌人，3 帧 32×32 动画 |
| 体型 | **原大小 2 倍**（32×32 → 64×64，`scale = 2.0`，碰撞半径 16 → 32） |
| 技能 1 瞬移 | 模型被**紫色光芒覆盖**后，移动到**距离玩家 5 瓦片（80px）**处 |
| 技能 2 分裂 | 紫色阵营的**共享总血量**每掉到 **75% / 50% / 25%** 就加 1 个分身（共 3 个），血量独立 |
| 技能 3 加速 | 短时间移速加快，移动留下**残影**，**残影用着色器实现** |
| 分裂数量 | 最多 **3 个**分身（75/50/25 三个阈值各 1 个）；分身血量 = 本体血量的 **1/4**；**分身不能再分裂** |
| 瞬移节奏 | 紫光预警 **0.7 秒**（期间**无敌**），落点在你周围 5 格的**随机方向** |
| 胜利条件 | **本体 + 所有分身全部消灭**才算过关（血量独立） |

## 2. 与现有 BOSS 的关系

- 现有 BOSS（`scene/boss.gd`，第 5/10 层用）**不改动**，只在第 10 层多刷 2 只新 BOSS
- 第 10 层总血量（按现有数值估算）：原 BOSS 198 + 新 BOSS 198×2 + 分身 49×8 ≈ **980**
- 预计战斗时长 60~90 秒（按玩家终局 DPS≈31 估算，含走位与躲技能）

## 3. 实现方案

### 3.1 新脚本 `scene/boss_purple.gd` + `scene/boss_purple.tscn`

- 继承 `enemy.gd`（复用寻路、接触伤害、受击闪烁、拾取掉落）
- 动画：`_frames_from_row(64)`（3 帧 32×32），`scale = 2.0`
- 状态机：`CHASE →（冷却到）TELEPORT / SPEED_BOOST → CHASE`
  - `TELEPORT`：0.7s 蓄力（紫光 + 无敌）→ 瞬移到玩家 5 格处随机方向 → 0.3s 恢复
  - `SPEED_BOOST`：3 秒移速 ×2，每 0.06 秒生成一个残影；结束后回正常速度
  - 冷却：瞬移 6 秒；加速 8 秒（互斥，不同时释放）
- 分裂：**共享血条**掉到 **75% / 50% / 25%** 时各加 1 个分身（共 3 个），由 battle 统一触发
  （不再是每只本体按自己的血量各自分裂）
  - 分身：同场景、同样式、`scale=2.0`，血量 = 本体最大血量 × 0.25，**不再分裂**（`can_split = false`）
  - 分身保留瞬移与加速技能（威胁更分散），但瞬移冷却延长到 9 秒
- 无敌实现：`apply_damage()` 在 `_invulnerable` 时直接返回 false（与现有 BOSS 冲刺一致）

### 3.2 残影着色器 `resources/shaders/boss_afterimage.gdshader`

- 输入：`TexturedSprite` 当前帧纹理；uniform：`tint_color`（紫色 `#b479ff`）、`fade`（0→1 由脚本推进）
- 效果：紫色染色 + 整体透明度随 `fade` 线性衰减 + 轻微加亮边缘（模拟残影拖尾）
- 用法：脚本生成 `Sprite2D`（当前帧 `AtlasTexture`）+ `ShaderMaterial`，0.45 秒内 `fade` 0→1 后 `queue_free()`
- 注意：残影只做视觉，**无碰撞、不参与伤害判定**（避免误伤玩家）

### 3.3 第 10 层生成 3 只 BOSS

- `battle.gd::_spawn_boss()` 扩展：第 10 层刷 1 只原 BOSS + 2 只新 BOSS，出生点取**离玩家最远的 3 个红门**
- 血条 HUD：红条改为显示**全部 BOSS 的总血量占比**，标题从「BOSS」改为「**BOSS x3**」
- 胜利条件：`_boss_defeated` 从 bool 改成**存活 BOSS 计数**（含分身），计数归零才算达成
- 分身死亡也计入 `boss_defeated` 判定与金币掉落（每只 8 金币，本体 20）

### 3.4 待实现清单（按顺序）

1. `resources/shaders/boss_afterimage.gdshader`（紫色残影淡出）
2. `scene/boss_purple.gd` + `.tscn`（状态机 + 分裂 + 残影生成）
3. `battle.gd`：第 10 层三只 BOSS 生成 + 血条/标题 + 存活计数判定
4. `tools/test_boss_purple.tscn`：分裂阈值与数量、分身 HP 与"不可再分裂"、瞬移落点距离=5 格、
   无敌窗口内 `apply_damage` 返回 false、加速期间生成残影且残影会被回收
5. 数值写入 `tools/balance_report.tscn`（第 10 层总血量/预计时长）
6. 导出发布版（Windows + Web）并实机验证

## 4. 追加确认（2026-09-29 第二轮）

| 项 | 决定 |
|---|---|
| 第 5 层 BOSS | 原 BOSS 与新紫色 BOSS **各 50%** 随机出一个（用层数做种子 -> 同层结果固定，进出不会变） |
| 第 10 层血条 | 屏幕**上方三条红条**，**每一条代表一只 BOSS 的"家族"**：本体血量 + 它分出的所有分身血量合计；该家族全灭这条才空/消失（与"全灭才算过关"一致） |
| 血条标识 | **不用文字**，改为在**每条血条的右侧**放对应 BOSS 的**一帧图像**（原 BOSS 用它的第 1 帧；紫色 BOSS 用源石虫第 3 排的第 1 帧）；图像建议 32×32 缩放到与血条同高 |

### 4.1 因此追加的实现细节

- 第 10 层三只 BOSS：1 只原 BOSS + 2 只紫色 BOSS（与第一轮确认一致）
- 血条 UI：`HUDLayer` 上方新增 3 组「红条 + 右侧图像」，每组用一个 `Control` 容器；
  红条的缩放逻辑复用现有 `_update_time_bar()` 的"从左往右缩短"实现
- 场上的对象需要记录**家族归属**（`family_id`）：本体为 0/1/2，分身继承本体的 `family_id`
  -> `boss.gd` / `boss_purple.gd` 都加 `family_id` 字段，出生时由 `battle.gd` 指定
- 家族合计血量 = 该 `family_id` 下所有存活 BOSS/分身的 `current_health` 之和
  （满血基准 = 本体最大血量 + 4×分身血量 = 本体最大血量 ×2）
- 第 5 层仍只有一条红条（标题写「BOSS」）；第 10 层才有三条（各自带图像）

## 5. 追加确认（2026-09-29 第三轮）

| 项 | 决定 |
|---|---|
| 瞬移落点紫光 | **提前 0.4 秒**在落点亮起一道紫光预告（玩家能提前看到并跑开）。纯视觉、**不造成伤害** |
| 玩家无敌时间 | **1.0 → 1.5 秒**（受伤后 1.5 秒内免疫一切伤害，角色闪烁提示）—— 已实施 |

### 5.1 瞬移完整时间轴（最终版）

```
t=0.0  本体被紫色光芒覆盖（进入无敌，不能被打掉血）
t=0.3  落点亮起紫色光柱（提前预告，玩家可以跑开）
t=0.7  本体瞬移到落点，紫光淡出，0.3 秒后恢复行动（无敌结束）
```
- 落点 = 玩家当前位置周围 **5 瓦片（80px）** 的随机方向
- 瞬移冷却 6 秒（分身 9 秒）；紫光与本体光芒都用 `boss_afterimage.gdshader` 或独立材质实现

## 6. 阶段 2 实施方案（精确到函数，待执行）

> 阶段 1（BOSS 本体）已完成并自检通过：`scene/boss_purple.gd` / `boss_purple.tscn` /
> `resources/shaders/boss_afterimage.gdshader`，自检 `tools/test_boss_purple.tscn` 27 项全过。
> 下面是把 BOSS 真正接进关卡的改动。

### 6.1 `scene/battle/battle.gd`

1. **改 `_spawn_boss()`**（现在只刷 1 只原 BOSS）
   - 抽出 `_spawn_one_boss(scene_path: String, family: int, config) -> Node`：
     实例化 -> `enemy_container.add_child` -> 取第 `family` 远的红门放好 -> `setup(config, player)`
     -> 若节点有 `family_id` 属性就赋值 -> 若是紫色 BOSS 再加进 `_boss_nodes` 数组
   - 第 10 层（`RunState.is_final_floor()`）：调用 3 次
     `_spawn_one_boss(BOSS_SCENE, 0, _boss_config_for_floor())` +
     `_spawn_one_boss(PURPLE_BOSS_SCENE, 1, PurpleConfig)` +
     `_spawn_one_boss(PURPLE_BOSS_SCENE, 2, PurpleConfig)`
   - 第 5 层：用层数做种子 `RandomNumberGenerator`（`seed = floor * 7919`）50/50 决定刷哪只
     （同层结果固定，进出不会变）
   - 新增常量 `const PURPLE_BOSS_SCENE := "res://scene/boss_purple.tscn"`
2. **存活判定**：新增 `var _boss_nodes: Array[Node] = []` 与
   `func _living_boss_count() -> int`（`is_instance_valid` 且 `not is_dead` 计数，含分身——
   分身由紫色 BOSS 在运行时 `get_parent().add_child()` 生成，遍历 `enemy_container` 里
   所有带 `debug_splits_done()` 方法的节点即可拿到本体+分身）
3. **`_check_game_result()`**：BOSS 目标分支从 `_boss_defeated` 改成
   `if goal.get("type","") == LevelGoal.TYPE_BOSS and _living_boss_count() == 0`
4. **血条（阶段性方案）**：`_boss_hp_ratio()` 先改成"全部 BOSS 家族合计剩余血量占比"，
   等 6.2 的多条血条做完后替换
5. 金币：紫色 BOSS 本体死亡给 `gold_per_boss_kill`(20)，分身给 8（在 `_spawn_one_boss` 里
   连 `died` 信号时按 `is_clone` 区分，避免与现有 `_on_boss_defeated()` 重复加钱）

### 6.2 三条家族血条 UI（新增到 `_setup_battle_hud()`）

- 结构：屏幕上方水平排列 3 组 `BattleBossBar`（每组 = `TextureRect`（BOSS 一帧图，32×32）
  + 一条红色条）。**图像在右、血条在左**（用户要求"血条右侧的空白处加 BOSS 一帧图像"）
- 每组数据来源：`family_id` 0/1/2；该家族的合计血量 =
  遍历场上所有 BOSS/分身按 `family_id` 汇总 `current_health`；满血基准 = 本体最大血量 × 2
- 第 5 层只用第 1 组（1 条，标「BOSS」）；第 10 层用 3 组
- 图像取法：`animated_sprite.sprite_frames.get_frame_texture("default", 0)`（紫色 BOSS）
  或原 BOSS 的对应帧 -> `ImageTexture`/`AtlasTexture` 直接塞给 `TextureRect`
- 复用现有"从左往右缩短"的缩放逻辑（`_update_time_bar()` 的写法）
- 家族全灭 -> 该组整组隐藏

### 6.3 自检（`tools/test_boss_purple.tscn` 扩展或新建 `test_boss_floor10`）

- 第 5 层：连续 20 个种子跑 `_spawn_boss()` 的决策函数，统计两种 BOSS 各出现约一半；
  同层调用两次结果一致
- 第 10 层：场上恰好 3 只 BOSS（1 原 + 2 紫），`family_id` 分别为 0/1/2
- 打完所有本体后，若仍有分身存活 -> 目标**未达成**；分身全清 -> 达成
- 三条血条的合计血量与实际家族血量一致；家族全灭后该组隐藏
