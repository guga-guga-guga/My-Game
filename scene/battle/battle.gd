extends "res://scene/game.gd"
## Battle:程序化场地 + 关卡目标 M2 
##
## 只覆盖三个钩子，其余全部复用 game.gd:
##   _ready()              插入"生成地形 到 铺瓦片 到 建红门出怪点 到 重建寻路"
##   _process(delta)       追加"波次推进 + 目标 HUD 刷新"
##   _check_game_result()  改为按 LevelGoal 判定胜负 ALL 语义 
## ⚠️ 因为覆盖了这三处，game.gd 里对应位置日后新增的逻辑需要同步到这里

const ArenaGen = preload("res://scene/arena/arena_generator.gd")
const LevelGoal = preload("res://scene/battle/level_goal.gd")
const BossScene = preload("res://scene/boss.tscn")
const BossConfig = preload("res://resources/config/enemy_boss.tres")
const AllyScene = preload("res://scene/ally.tscn")
const AllyIcon := preload("res://resources/texture/icon.png")
const ALLY_NAME := "队友A"
const HUD_FONT_GOLD := 28
const HUD_FONT_NAME := 22
const HUD_FONT_SMALL := 20
const HUD_ICON_SIZE := 48.0

@export_group("场地")
## 场地尺寸 格 ，会被 ArenaGenerator 夹到 24x16 ~ 38x23
@export var arena_width: int = 30
@export var arena_height: int = 20
## 0 = 每次随机；填数字可复现同一张图
@export var arena_seed: int = 0

@export_group("调试")
## 强制目标类型 survive / kill / clear_waves / boss ；空 = 按节点类型自动
@export var debug_goal_type: String = ""
## 打印目标与场地概要
@export var debug_print: bool = true
## 调试: 加快 Boss 技能节奏（headless 自检用）
@export var debug_fast_boss: bool = false
## Boss 关：红门每隔多少秒涌出敌人
@export var boss_door_spawn_interval: float = 5.0
## Boss 关：红门每次涌出的敌人数区间（用户要求"不低于 2 名" -> 2~4 只随机）
@export var boss_door_spawn_min: int = 2
@export var boss_door_spawn_max: int = 4
## Boss 关：场上普通敌人上限（红门刷的 + BOSS 抛的；BOSS/紫 BOSS 不占名额）
@export var boss_level_normal_enemy_cap: int = 20
## 每只普通敌人掉落的金币（M6 平衡：1 -> 2，否则中期买不起输出，打血厚的敌人会变成磨血）
@export var gold_per_enemy_kill: int = 2
## 击败 Boss 的额外金币（M6 平衡：8 -> 20，BOSS 关没有波次，收入几乎为零）
@export var gold_per_boss_kill: int = 20

## 调试: 直接模拟击败 Boss（验证"通关结算 -> 回标题"整条链路）
@export var debug_instant_boss_win: bool = false
## 调试: 任意关卡都直接模拟胜利（验证"胜利 -> 回 中间地图 -> 层数 +1"整条链路）
@export var debug_instant_win: bool = false

var arena_data: Dictionary = {}
var goal: Dictionary = {}

var _goal_label: Label
var _detail_label: Label
var _last_hud_key := ""

# 波次推进
var _waves: Array = []
var _wave_index := 0
var _waves_done := 0
var _waves_finished := false
var _wave_timer_left := 0.0
var _guard_target = null
var _guard_hud_hp: Label = null
var _boss_defeated := false
var _boss: Enemy = null
var _boss_nodes: Array[Node] = []
## 第 10 层第二条血条（两只紫 BOSS + 它们的分身 共用一个血池）；第 5 层为 null
var _boss_bar_extra: Sprite2D = null
var _boss_icon_main: Sprite2D = null
var _boss_icon_extra: Sprite2D = null
## 紫色阵营（本体+分身）的血量上限总和：每只本体按 config.max_health 加，每生成一个分身按其血量加
var _purple_total_max: float = 0.0
## 紫色共享血条每掉到下一个阈值就加 1 个分身（75% / 50% / 25%，共 3 个）
var _purple_split_stage := 0
var _debug_win_started := false
var _ally = null                  ## 第一个队友（兼容旧代码/自检）
var _allies: Array = []           ## 本关所有队友（最多 RunState.MAX_ALLIES）
var _hud_gold: Label = null
var _hud_ally_box: Control = null
var _hud_ally_hp: Label = null
var _hud_ally_state: Label = null
var _hud_ally_hint: Label = null
var _hud_ally_slots: Array[Dictionary] = []
var _last_result_won := false
var _gold_gained := 0                 ## 本关赚到的金币（汇报用）
var _result_recorded := false


func _ready() -> void:
	# 发布版（导出的 exe）里把所有调试开关和调试打印都关掉
	if not OS.is_debug_build():
		debug_print = false
		debug_goal_type = ""
		debug_fast_boss = false
		debug_instant_boss_win = false
		debug_instant_win = false
	random_generator.randomize()

	# ① 目标必须先算:限时决定倒计时条长度 stage_duration 由 _setup_hud 读取 
	goal = LevelGoal.build(_context_floor(), _context_node_type(), debug_goal_type)
	if goal.get("type", "") == LevelGoal.TYPE_BOSS:
		MusicManager.play_boss()          # BOSS 战曲
	else:
		MusicManager.play_stage()         # 普通关/精英关曲
	stage_duration = LevelGoal.stage_duration(goal)
	_waves = goal.get("waves", [])

	_configure_result_dialog()
	_setup_hud()
	_setup_goal_hud()
	_setup_battle_hud()
	_setup_pause_menu()
	_apply_goal_hud_layout()

	# ② 场地数据 到 ③ 铺瓦片 红门在 Overlay 层 到 ④ 出怪点与红门成对创建
	var use_seed := arena_seed if arena_seed != 0 else random_generator.randi()
	var generator = ArenaGen.new()
	var arena_mode := ArenaGen.MODE_BOSS if (goal["type"] == LevelGoal.TYPE_BOSS or goal["type"] == LevelGoal.TYPE_DEFEND) else ArenaGen.MODE_NORMAL
	arena_data = generator.generate(arena_width, arena_height, use_seed, arena_mode)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)
	generator.create_spawn_markers($EnemySpawnPoints, arena_data)
	player.global_position = cell_to_world(arena_data["player_spawn"])
	_apply_run_state_to_player()
	if not player.heal_ally_requested.is_connected(_on_player_heal_requested):
		player.heal_ally_requested.connect(_on_player_heal_requested)

	# ⑤ 顺序关键:铺完瓦片之后才能重建寻路网格
	_setup_enemy_pathfinder()
	_collect_enemy_spawn_points()
	_warn_spawn_points_inside_walls()
	_spawn_ally_if_hired()
	_collect_enemy_configs()
	if not _after_floor_5() and available_enemy_configs.has(SHOOTER_CONFIG):
		available_enemy_configs.erase(SHOOTER_CONFIG)   # 持枪敌人：第 5 层之后才出现
	_apply_floor_scaling_to_enemy_configs()
	if goal["type"] == LevelGoal.TYPE_DEFEND:
		_spawn_defend_target()
		_configure_defend_spawn()
	_configure_enemy_spawn_timer()
	_keep_player_centered()

	# 兜底空气墙:所有关卡都要 —— 程序化地图四条边各有一处红门，红门会把外圈边界墙
	# 挖出缺口，不额外围一圈的话玩家能顺着红门跑出地图（之前只给 BOSS 关围了，普通关会漏）
	_setup_arena_bounds()

	# ⑥ 刷怪:有波次表的关卡走波次推进；其余沿用父类的无限刷怪
	if goal["type"] == LevelGoal.TYPE_BOSS:
		_spawn_bosses_for_floor()
		_start_boss_door_spawner()
	elif _waves.is_empty():
		_spawn_initial_enemies()
		_start_enemy_spawn_timer()
	else:
		_wave_timer_left = 0.6

	_refresh_goal_hud(true)
	if debug_print:
		print("[Battle] 目标=%s 条件=%d 限时=%.0f 波次=%d | 场地 %dx%d seed=%d 房间=%d 红门=%d 寻路=%s 玩家出生=%s" % [
			goal["type"], goal["conditions"].size(), LevelGoal.time_limit(goal), _waves.size(),
			arena_data["width"], arena_data["height"], arena_data["seed"], arena_data["room_count"],
			arena_data["doors"].size(),
			str(EnemyPathfinder.instance != null and EnemyPathfinder.instance.is_usable()),
			str(arena_data["player_spawn"])])
	_start_self_check()


## M6 平衡：普通敌人血量随层数成长（1 + 0.25*(层-1)），速度/数量不变。
## 必须 duplicate()：配置资源是共享的，直接改会把倍率一路叠上去。
func _apply_floor_scaling_to_enemy_configs() -> void:
	var mul := 1.0 + 0.25 * float(maxi(_context_floor(), 1) - 1)
	if mul <= 1.0 or available_enemy_configs.is_empty():
		return
	var scaled: Array[EnemyConfig] = []
	var summary: Array[String] = []
	for cfg in available_enemy_configs:
		if cfg == null:
			continue
		var copy: EnemyConfig = cfg.duplicate()
		copy.max_health = maxi(int(round(float(cfg.max_health) * mul)), 1)
		scaled.append(copy)
		summary.append("%d->%d" % [cfg.max_health, copy.max_health])
	available_enemy_configs = scaled
	if debug_print:
		print("[Battle] 敌人血量倍率 x%.2f（第 %d 层）: %s" % [
			mul, maxi(_context_floor(), 1), "  ".join(summary)])


## BOSS 血量：基础值见 enemy_boss.tres（150）。
## 第 5 层（半路 BOSS）用基础值；第 10 层最终 BOSS 再 ×1.65 更肉（150 -> 248）
func _boss_config_for_floor() -> EnemyConfig:
	if not RunState.is_final_floor():
		return BossConfig
	var copy: EnemyConfig = BossConfig.duplicate()
	copy.max_health = maxi(int(round(float(BossConfig.max_health) * 1.65)), 1)
	if debug_print:
		print("[Battle] 最终 BOSS 血量 %d -> %d" % [BossConfig.max_health, copy.max_health])
	return copy


## 紫 BOSS 血量：统一用基础值（用户要求"紫色也一起改"），不乘最终层倍率
func _boss_config_for_purple() -> EnemyConfig:
	return BossConfig


## 整局生命值变化时（例如商店买血）同步到玩家节点
func _on_run_state_health_changed(current: int, maximum: int) -> void:
	if player == null:
		return
	player.max_health = maxi(maximum, 1)
	player.current_health = clampi(current, 1, player.max_health)


## 右上角：金币（用户要求战斗里也显示）+ 队友头像/名字/血量/状态
func _setup_battle_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "BattleHud"
	layer.layer = 5
	add_child(layer)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.grow_vertical = Control.GROW_DIRECTION_END
	box.offset_left = -280.0
	box.offset_right = -16.0
	box.offset_top = 16.0
	box.offset_bottom = 16.0
	box.add_theme_constant_override("separation", 6)
	box.alignment = BoxContainer.ALIGNMENT_END
	layer.add_child(box)

	var panel := _make_hud_panel(Vector2(-16.0, 16.0))
	box.add_child(panel)
	var gold_box := VBoxContainer.new()
	panel.add_child(gold_box)
	_hud_gold = Label.new()
	_hud_gold.add_theme_font_size_override("font_size", HUD_FONT_GOLD)
	_hud_gold.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	_hud_gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hud_gold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gold_box.add_child(_hud_gold)

	# 队友面板：最多 3 个（用户要求），每个 = 头像 + 名字 + 血量 + 右侧(T键切换/状态)
	_hud_ally_slots.clear()
	for slot in range(RunState.MAX_ALLIES):
		_hud_ally_slots.append(_make_ally_hud_panel(box, slot))
	if not _hud_ally_slots.is_empty():
		_hud_ally_box = _hud_ally_slots[0]["panel"]
		_hud_ally_hp = _hud_ally_slots[0]["hp"]
		_hud_ally_state = _hud_ally_slots[0]["state"]
		_hud_ally_hint = _hud_ally_slots[0]["hint"]

	if not RunState.gold_changed.is_connected(_on_hud_gold_changed):
		RunState.gold_changed.connect(_on_hud_gold_changed)
	_refresh_hud_gold()
	_hud_ally_box.visible = false


## 造一个队友面板（slot 0/1/2 -> 队友A/B/C）
func _make_ally_hud_panel(box: VBoxContainer, slot: int) -> Dictionary:
	var ally_panel := _make_hud_panel(Vector2(-16.0, 16.0))
	box.add_child(ally_panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	ally_panel.add_child(row)
	var icon := TextureRect.new()
	icon.texture = AllyIcon
	icon.custom_minimum_size = Vector2(HUD_ICON_SIZE, HUD_ICON_SIZE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)
	var name_label := Label.new()
	name_label.text = "队友%s" % char(65 + slot)
	name_label.add_theme_font_size_override("font_size", HUD_FONT_NAME)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.93, 1.0))
	info.add_child(name_label)
	var hp := Label.new()
	hp.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	hp.add_theme_color_override("font_color", Color(1.0, 0.55, 0.55))
	info.add_child(hp)
	var right_col := VBoxContainer.new()
	right_col.add_theme_constant_override("separation", 2)
	row.add_child(right_col)
	var hint := Label.new()
	hint.text = "T键切换"
	hint.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	hint.add_theme_color_override("font_color", Color(0.70, 0.95, 0.70))
	right_col.add_child(hint)
	var state_label := Label.new()
	state_label.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	state_label.add_theme_color_override("font_color", Color(0.70, 0.85, 1.0))
	right_col.add_child(state_label)
	ally_panel.visible = false
	return {"panel": ally_panel, "hp": hp, "state": state_label, "hint": hint}


func _make_hud_panel(_unused_offset: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.28)      # 和 中间地图 金币 HUD 一致的半透明底
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _on_hud_gold_changed(_amount: int) -> void:
	_refresh_hud_gold()


func _refresh_hud_gold() -> void:
	if _hud_gold != null:
		_hud_gold.text = "金币 %d" % RunState.gold


func _refresh_ally_hud() -> void:
	if _hud_ally_slots.is_empty():
		return
	for slot in range(_hud_ally_slots.size()):
		var panel := _hud_ally_slots[slot]["panel"] as Control
		if slot >= _allies.size():
			panel.visible = false
			continue
		var ally = _allies[slot]
		if ally == null or not is_instance_valid(ally):
			panel.visible = false
			continue
		panel.visible = true
		var hp := _hud_ally_slots[slot]["hp"] as Label
		var state_label := _hud_ally_slots[slot]["state"] as Label
		if bool(ally.get("is_dead")):
			hp.text = "0 / %d" % int(ally.get("MAX_HEALTH"))
			state_label.text = "阵亡"
		else:
			hp.text = "%d / %d" % [int(ally.get("current_health")), int(ally.get("MAX_HEALTH"))]
			state_label.text = String(ally.call("state_name"))
## 调试面板：按名册重新放一遍队友（改名册后调用）
func debug_respawn_allies() -> void:
	for ally in _allies:
		if ally != null and is_instance_valid(ally):
			ally.queue_free()
	_allies.clear()
	_ally = null
	_spawn_ally_if_hired()


func debug_hire_ally() -> void:
	if not RunState.hire_ally():
		return
	# 重新按名册放一遍（包含刚雇的）
	for ally in _allies:
		if ally != null and is_instance_valid(ally):
			ally.queue_free()
	_allies.clear()
	_ally = null
	_spawn_ally_if_hired()


func debug_fire_ally() -> void:
	for ally in _allies:
		if ally != null and is_instance_valid(ally):
			ally.queue_free()
	_allies.clear()
	_ally = null
	RunState.ally_roster.clear()
	_refresh_ally_hud()
func _on_ally_state_changed(_state: String) -> void:
	_refresh_ally_hud()


func _on_ally_health_changed(_current: int, _maximum: int) -> void:
	_refresh_ally_hud()


## 商店里雇了队友的话，这一关开场把他放出来（只在本关有效）
func _spawn_ally_if_hired() -> void:
	_allies.clear()
	_ally = null
	if RunState.ally_roster.is_empty():
		_refresh_ally_hud()
		return
	var body := player.get_node_or_null("BodySprite") as AnimatedSprite2D
	for index in range(RunState.ally_roster.size()):
		var entry: Dictionary = RunState.ally_roster[index]
		var ally = AllyScene.instantiate()      # 不用类型注解：队友脚本没有全局类名
		if ally == null:
			continue
		add_child(ally)
		# 把玩家的 AnimatedSprite2D 交给队友：共用同一套 SpriteFrames 并镜像动画
		ally.setup(player, body, RunState.get_player_damage(), RunState.get_player_fire_interval(),
			$EnemyContainer)
		# 血量沿用名册里存的（跨层保留）
		ally.current_health = clampi(int(entry.get("health", RunState.ALLY_MAX_HEALTH)),
			1, RunState.ALLY_MAX_HEALTH)
		ally.health_changed.connect(_on_ally_health_changed)
		ally.state_changed.connect(_on_ally_state_changed)
		ally.global_position = _ally_spawn_position(index)
		_allies.append(ally)
		if _ally == null:
			_ally = ally
	_refresh_ally_hud()
	if debug_print:
		print("[Battle] 放出 %d 名队友（名册 %d 个，血量 %s）" % [
			_allies.size(), RunState.ally_count(),
			str(RunState.ally_roster.map(func(e): return int(e.get("health", 0))))])


## 一层结束时把队友血量写回名册（阵亡写 0，名册会移除；层数 -1）
func _write_back_allies() -> void:
	var healths: Array = []
	for ally in _allies:
		if ally != null and is_instance_valid(ally) and not bool(ally.get("is_dead")):
			healths.append(int(ally.get("current_health")))
		else:
			healths.append(0)
	RunState.finish_ally_floor(healths)


## 给队友找一个"玩家附近、且是地板"的出生点（避免生成到地形里卡住）
## 用生成器留下的 arena_data.grid：0=地板 1=墙 2=外墙
func _ally_spawn_position(skip: int = 0) -> Vector2:
	var grid: Array = arena_data.get("grid", [])
	var width: int = int(arena_data.get("width", 0))
	var height: int = int(arena_data.get("height", 0))
	var tile := float(ArenaGen.TILE_SIZE)
	var player_cell := Vector2i(int(floor(player.global_position.x / tile)), int(floor(player.global_position.y / tile)))
	if grid.is_empty() or width <= 0:
		return player.global_position + Vector2(20.0 * float(skip + 1), 0.0)
	var found := 0
	for radius in range(0, 7):
		for offset_y in range(-radius, radius + 1):
			for offset_x in range(-radius, radius + 1):
				var cell := player_cell + Vector2i(offset_x, offset_y)
				if cell.x < 1 or cell.y < 1 or cell.x >= width - 1 or cell.y >= height - 1:
					continue
				if int(grid[cell.y * width + cell.x]) != 0:
					continue
				if found < skip:
					found += 1
					continue
				return cell_to_world(cell)
	return player.global_position + Vector2(20.0 * float(skip + 1), 0.0)
## T 键：一次切换"所有"队友的模式（用户要求；以前每个队友各自响应，第一个会把输入吃掉）
func _check_ally_switch_input() -> void:
	if is_result_displayed:
		return
	if Input.is_action_just_pressed("switch_ally"):
		_toggle_all_allies()


func _toggle_all_allies() -> void:
	for ally in _allies:
		if ally != null and is_instance_valid(ally) and not bool(ally.get("is_dead")):
			ally.toggle_state()
	_refresh_ally_hud()


## 玩家满血捡到回血道具：按 A -> B -> C 顺序给第一个没满血的队友回 1 颗；
## 队友都满血（或没有队友）则谁都不加 —— 不会溢出加到玩家身上（用户要求）。
func _on_player_heal_requested() -> void:
	for ally in _allies:
		if ally == null or not is_instance_valid(ally):
			continue
		if bool(ally.get("is_dead")):
			continue
		if ally.has_method("heal_one") and ally.heal_one():
			_refresh_ally_hud()
			return
	if debug_print:
		print("[Battle] 玩家满血捡到恢复道具：队友都满血/没队友，未生效")


func _context_floor() -> int:
	if GameFlow != null:
		return int(GameFlow.pending_battle.get("floor", RunState.floor_index))
	return 1


func _context_node_type() -> String:
	if GameFlow != null:
		return String(GameFlow.pending_battle.get("node_type", "battle"))
	return "battle"


## 保持原关卡观感:不启用相机限位 到 角色永远在屏幕中心 到 HUD 位置固定
func _keep_player_centered() -> void:
	var camera := $CameraSystem/Camera2D as Camera2D
	if camera != null:
		camera.limit_enabled = false


## 格坐标 到 世界坐标 格中心 
func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5,
		cell.y * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5)


func _process(delta: float) -> void:
	super._process(delta)              # 父类:倒计时 / HUD / 胜负判定 判定已被我覆盖 
	if debug_instant_win and not _debug_win_started:
		_debug_win_started = true
		_start_debug_instant_win()     # 调试：任意关卡秒胜（走完整条 结算 -> 切场景 链路）
	_check_ally_switch_input()
	_update_defend_spawn_cap()
	_update_purple_splits()
	_update_waves(delta)
	_refresh_goal_hud()


## 波次推进:刷完一波 到 等场上清空 到 下一波；最后一波清空即达成目标
func _update_waves(delta: float) -> void:
	if _waves.is_empty() or _waves_finished or is_result_displayed:
		return
	if _get_player_current_health() <= 0:
		return
	if _wave_index >= _waves.size():
		if _get_alive_enemy_count() == 0:
			_waves_done = _waves.size()
			_waves_finished = true
		return
	_wave_timer_left -= delta
	if _wave_timer_left > 0.0:
		return
	var wave: Dictionary = _waves[_wave_index]
	if int(wave.get("spawned", 0)) < int(wave.get("count", 0)):
		if _try_spawn_enemy():
			wave["spawned"] = int(wave.get("spawned", 0)) + 1
			_wave_timer_left = maxf(float(wave.get("interval", 0.8)), 0.05)
		else:
			_wave_timer_left = 0.25          # 场上满员 / 没有可用出生点 到 稍后重试
		return
	if _get_alive_enemy_count() > 0:
		return
	_waves_done = _wave_index + 1
	_wave_index += 1
	if _wave_index >= _waves.size():
		_waves_finished = true
		return
	_wave_timer_left = maxf(float(_waves[_wave_index].get("delay", 1.2)), 0.0)


## BOSS 专有分组：用来把"BOSS/紫 BOSS"从"普通敌人"计数里排除（用户要求）
const BOSS_GROUP := "boss_enemy"


## Boss 关：场上"普通敌人"数量（不含 BOSS / 紫 BOSS / 已死）
func _count_alive_normal_enemies() -> int:
	var count := 0
	for child in enemy_container.get_children():
		if child is Enemy and not (child as Enemy).is_dead and not child.is_in_group(BOSS_GROUP):
			count += 1
	return count


## Boss 关：红门会持续"涌出"普通敌人（复用现有出怪点 —— 它们本来就落在红门上）
func _start_boss_door_spawner() -> void:
	var timer := Timer.new()
	timer.name = "BossDoorSpawnTimer"
	timer.wait_time = maxf(boss_door_spawn_interval, 1.0)
	timer.timeout.connect(_on_boss_door_spawn)
	add_child(timer)
	timer.start()


func _on_boss_door_spawn() -> void:
	if is_result_displayed or _boss_defeated:
		return
	# 一次涌出 boss_door_spawn_min ~ boss_door_spawn_max 只；
	# 红门自己守 20 上限（BOSS 抛的小怪可以临时超出，见 boss.gd）
	var want := randi_range(maxi(boss_door_spawn_min, 1),
		maxi(boss_door_spawn_max, maxi(boss_door_spawn_min, 1)))
	var spawned := 0
	for _index in range(want):
		if _count_alive_normal_enemies() >= boss_level_normal_enemy_cap:
			break
		if _try_spawn_enemy():
			spawned += 1
	if spawned > 0 and debug_print:
		print("[Battle] 红门涌出 %d 只敌人（场上普通敌人 %d/%d）" % [
			spawned, _count_alive_normal_enemies(), boss_level_normal_enemy_cap])


## 血条左侧用「怪物图片」代替原来的「BOSS」字样；第 10 层再补一条紫 BOSS 共用血条
func _setup_boss_bar_icons(clock_bar: Sprite2D) -> void:
	var boss_hud := $Player/HUDLayer as Node2D
	if boss_hud == null or clock_bar == null:
		return
	_boss_icon_main = _make_boss_icon_sprite()
	boss_hud.add_child(_boss_icon_main)
	_boss_icon_main.position = Vector2(time_bar_left_edge_x - BOSS_ICON_GAP, clock_bar.position.y)

	if not _is_multi_boss_floor():
		return
	# 第二条血条：直接复制第一条（同纹理/同缩放），往下挪一个行距
	_boss_bar_extra = clock_bar.duplicate() as Sprite2D
	_boss_bar_extra.name = "TimeBar2"
	_boss_bar_extra.position = Vector2(clock_bar.position.x, clock_bar.position.y + BOSS_BAR_SPACING)
	_boss_bar_extra.modulate = clock_bar.modulate
	_boss_bar_extra.visible = false
	boss_hud.add_child(_boss_bar_extra)
	_boss_icon_extra = _make_boss_icon_sprite()
	boss_hud.add_child(_boss_icon_extra)
	_boss_icon_extra.position = Vector2(time_bar_left_edge_x - BOSS_ICON_GAP, _boss_bar_extra.position.y)
	# 给第二条血条腾位置：玩家生命图标/数字整体下移
	_move_life_display_down(BOSS_BAR_SPACING)


## 血条左侧的怪物图片（先留空，等 BOSS 刷出来再贴第一帧纹理）
func _make_boss_icon_sprite() -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.scale = Vector2(BOSS_ICON_SCALE, BOSS_ICON_SCALE)
	sprite.visible = false
	return sprite


## 玩家生命显示（图标 + 数字）整体下移，给第 10 层的第二条血条让位
func _move_life_display_down(delta: float) -> void:
	var life_icon := $Player/HUDLayer/LifeIcon as Sprite2D
	var life_label := $Player/HUDLayer/LifeCountLabel as Label
	if life_icon != null:
		life_icon.position.y += delta
	if life_label != null:
		life_label.offset_top += delta
		life_label.offset_bottom += delta


## 第 10 层才有两条血条（原 BOSS + 紫 BOSS 阵营）
func _is_multi_boss_floor() -> bool:
	return _context_floor() >= RunState.MAX_FLOOR


## Boss 关：从"离玩家最远的那个红门"里放出一只 Boss（复用出怪口的语义）
## 把整局成长（生命/伤害/射速）应用到玩家身上
func _apply_run_state_to_player() -> void:
	player.max_health = RunState.max_health
	player.current_health = clampi(RunState.current_health, 1, RunState.max_health)
	player.fire_interval = RunState.get_player_fire_interval()
	player.current_move_speed_multiplier = maxf(RunState.move_speed_multiplier, 0.1)
	player.invincibility_duration = RunState.get_player_invincibility()
	if not RunState.health_changed.is_connected(_on_run_state_health_changed):
		RunState.health_changed.connect(_on_run_state_health_changed)
	if debug_print:
		print("[Battle] 进场: 生命 %d/%d 子弹伤害 %d 射击间隔 %.3f 金币 %d" % [
			player.current_health, player.max_health, RunState.get_player_damage(),
			player.fire_interval, RunState.gold])


## 调试面板改完 RunState 后调用：把数值同步到场上实际的玩家/队友/HUD
func debug_sync_run_values() -> void:
	if player != null and is_instance_valid(player):
		player.max_health = RunState.max_health
		player.current_health = clampi(RunState.current_health, 0, RunState.max_health)
		player.fire_interval = RunState.get_player_fire_interval()
		player.current_move_speed_multiplier = maxf(RunState.move_speed_multiplier, 0.1)
		player.invincibility_duration = RunState.get_player_invincibility()
	_update_life_count_label()
	_refresh_hud_gold()
	if _ally != null and is_instance_valid(_ally):
		_ally.damage = RunState.get_player_damage()
		_ally.fire_interval = RunState.get_player_fire_interval()
		_refresh_ally_hud()


## 金币只来自敌人掉落
func _on_enemy_died() -> void:
	super._on_enemy_died()
	if debug_print:
		print("[Battle] 击杀 %d 只（本关累计）金币 %d" % [round_kill_count, RunState.gold])
	var gain := maxi(gold_per_enemy_kill, 0)
	RunState.add_gold(gain)
	_gold_gained += gain



func _spawn_boss() -> void:
	var boss := BossScene.instantiate() as Enemy
	if boss == null:
		push_warning("[Battle] Boss 场景实例化失败")
		return
	enemy_container.add_child(boss)
	boss.add_to_group(BOSS_GROUP)          # 不占"普通敌人"名额
	_boss = boss
	if "max_alive_minions" in boss:
		boss.max_alive_minions = boss_level_normal_enemy_cap   # BOSS 抛小怪也守同一个上限
	var spawn_cell := _farthest_spawn_cell_from(arena_data["player_spawn"])
	boss.global_position = cell_to_world(spawn_cell)
	boss.setup(_boss_config_for_floor(), player)
	if boss.has_method("set_arena"):
		boss.set_arena(arena_data["grid"], int(arena_data["width"]), int(arena_data["height"]))
	if "debug_fast_skills" in boss:
		boss.debug_fast_skills = debug_fast_boss
	if boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(_on_boss_defeated)
	if not boss.died.is_connected(_on_enemy_died):
		boss.died.connect(_on_enemy_died)
	print("[Battle] Boss 已放出: 出生格=%s（玩家在 %s，相距 %.0f 格）" % [
		str(spawn_cell), str(arena_data["player_spawn"]),
		Vector2(spawn_cell).distance_to(Vector2(arena_data["player_spawn"]))])
	if debug_instant_boss_win:
		_start_debug_instant_win()


## Boss 出生点：优先取"离玩家最远的红门"；若还不够远（不足地图短边的一半），
## 就在全场可通行格里挑离玩家最远的那个 —— 保证一进关卡玩家和 Boss 离得很远。
func _farthest_spawn_cell_from(cell: Vector2i) -> Vector2i:
	var best := _farthest_door_cell_from(cell)
	var best_distance := Vector2(best).distance_to(Vector2(cell))
	var minimum := minf(float(arena_data["width"]), float(arena_data["height"])) * 0.5
	if best_distance < minimum:
		var grid: Array = arena_data["grid"]
		var w: int = arena_data["width"]
		var h: int = arena_data["height"]
		for y in range(1, h - 1):
			for x in range(1, w - 1):
				if int(grid[y * w + x]) != 0:
					continue
				var distance := Vector2(x, y).distance_to(Vector2(cell))
				if distance > best_distance:
					best_distance = distance
					best = Vector2i(x, y)
	return best


## 取"离玩家最远的那道红门"
func _farthest_door_cell_from(cell: Vector2i) -> Vector2i:
	var best: Vector2i = cell
	var best_distance := -1.0
	for door in arena_data["doors"]:
		var door_cell: Vector2i = door["cell"]
		var distance := Vector2(door_cell).distance_to(Vector2(cell))
		if distance > best_distance:
			best_distance = distance
			best = door_cell
	return best


func _on_boss_defeated() -> void:
	_boss_defeated = true
	var boss_gain := maxi(gold_per_boss_kill, 0)
	RunState.add_gold(boss_gain)
	_gold_gained += boss_gain

	# 血条的收起改由 _update_time_bar() 每帧按血量处理（第10层还有第二条，不能在这里一起关）
	if debug_print:
		print("[Battle] Boss 已击败, 目标达成判定=%s" % str(LevelGoal.is_satisfied(goal, _goal_state())))


# ---------------- 目标驱动的 HUD 布局（顶部时间条 / 时钟 / 生命值位置） ----------------

## 规则：
##   有时限关卡（survive / elite）：保持原样（时钟 + 绿条 + 生命值在下方）
##   Boss 关：删掉时钟；绿条 → 红条并**横向居中**，绑定 Boss 血量；生命值留在原位（避免压到居中红条）
##   其他无时限关卡（clear_waves）：删掉时钟与绿条；生命值图标 + 文字**整体上移到原时间那一行**（横向不动）
func _apply_goal_hud_layout() -> void:
	var clock_icon := $Player/HUDLayer/TimeIcon as Sprite2D
	var clock_bar := $Player/HUDLayer/TimeBar as Sprite2D
	var life_icon_node := $Player/HUDLayer/LifeIcon as Sprite2D
	var life_label_node := $Player/HUDLayer/LifeCountLabel as Label
	if LevelGoal.time_limit(goal) > 0.0:
		return                                   # 有时限：完全保持原样
	if clock_icon != null:
		clock_icon.visible = false               # 无时限：时钟一律删除
	if goal.get("type", "") == LevelGoal.TYPE_BOSS:
		_prepare_boss_health_bar(clock_bar)
	else:
		if clock_bar != null:
			clock_bar.visible = false            # 其他无时限：绿条也删掉
		_move_life_display_up_to_time_row(life_icon_node, life_label_node, clock_icon, clock_bar)


## Boss 关：绿条 → 红条（居中 + 之后由 _update_time_bar 绑定 Boss 血量）
func _prepare_boss_health_bar(clock_bar: Sprite2D) -> void:
	if clock_bar == null:
		return
	clock_bar.visible = true
	clock_bar.modulate = Color(1.0, 0.28, 0.28)
	clock_bar.position.x = 0.0
	# 居中后必须重算左边缘（父类 _setup_hud 是按原位置算的），否则条会往右跑
	if clock_bar.centered:
		time_bar_left_edge_x = clock_bar.position.x - (time_bar_texture_width * time_bar_full_scale_x * 0.5)
	else:
		time_bar_left_edge_x = clock_bar.position.x
	_setup_boss_bar_icons(clock_bar)


## 其他无时限关卡：生命值图标 + 文字整体上移到"原时间那一行"（只改纵向）
func _move_life_display_up_to_time_row(life_icon_node: Sprite2D, life_label_node: Label, clock_icon: Sprite2D, clock_bar: Sprite2D) -> void:
	var time_row_y := 0.0
	if clock_icon != null:
		time_row_y = clock_icon.position.y
	elif clock_bar != null:
		time_row_y = clock_bar.position.y
	else:
		return
	if life_icon_node == null:
		return
	var delta := time_row_y - life_icon_node.position.y
	life_icon_node.position.y += delta
	if life_label_node != null:
		life_label_node.offset_top += delta
		life_label_node.offset_bottom += delta


## 第一条血条的比例（第5层若是紫 BOSS，则本体 + 分身共用一个血池）
func _boss_hp_ratio() -> float:
	return _main_boss_ratio()


## 覆盖父类：Boss 关顶部条 = BOSS 血量条（第10层是两条）；其余关卡沿用倒计时
func _update_time_bar() -> void:
	if goal.get("type", "") != LevelGoal.TYPE_BOSS or time_bar == null:
		super._update_time_bar()
		return
	# 第一条：原 BOSS；第5层若随机到紫 BOSS，则和它的分身共用这条
	_apply_boss_bar(time_bar, _main_boss_ratio())
	_update_boss_bar_icon(_boss_icon_main, _main_boss_body())
	var main_alive := _main_boss_current() > 0.0
	time_bar.visible = main_alive
	if _boss_icon_main != null:
		_boss_icon_main.visible = main_alive and _boss_icon_main.texture != null
	# 第二条（第10层）：两只紫 BOSS + 它们的分身 共用一个血池
	if _boss_bar_extra != null:
		var purple_alive := _purple_family_current() > 0.0
		_apply_boss_bar(_boss_bar_extra, _purple_family_ratio())
		_update_boss_bar_icon(_boss_icon_extra, _purple_body())
		_boss_bar_extra.visible = purple_alive
		if _boss_icon_extra != null:
			_boss_icon_extra.visible = purple_alive and _boss_icon_extra.texture != null


## 把某条血条按比例缩放（保持左边缘不动，从左往右缩短）
func _apply_boss_bar(sprite: Sprite2D, ratio: float) -> void:
	if sprite == null:
		return
	sprite.scale.x = time_bar_full_scale_x * clampf(ratio, 0.0, 1.0)
	if not sprite.centered:
		sprite.position.x = time_bar_left_edge_x
		return
	var current_width := time_bar_texture_width * sprite.scale.x
	sprite.position.x = time_bar_left_edge_x + (current_width * 0.5)


## 血条左侧的怪物图片：第一次拿到纹理后就不再改
func _update_boss_bar_icon(icon: Sprite2D, node: Node) -> void:
	if icon == null:
		return
	if icon.texture == null and node != null:
		icon.texture = _boss_icon_texture(node)


## 第一条血条追踪的对象：第5层可能是原 BOSS 或紫 BOSS
func _main_boss_body() -> Node:
	return _boss


func _main_boss_current() -> float:
	if _boss == null or not is_instance_valid(_boss):
		return 0.0
	if _boss.has_method("debug_splits_done"):
		return _purple_family_current()
	return maxf(float(_boss.current_health), 0.0)


func _main_boss_ratio() -> float:
	if _boss == null or not is_instance_valid(_boss):
		return 0.0
	if _boss.has_method("debug_splits_done"):
		return _purple_family_ratio()
	if _boss.config == null:
		return 0.0
	return clampf(float(_boss.current_health) / float(maxi(int(_boss.config.max_health), 1)), 0.0, 1.0)


## 紫色阵营（所有本体 + 分身，去掉已死的）
func _purple_nodes() -> Array[Node]:
	var nodes: Array[Node] = []
	for child in enemy_container.get_children():
		if not is_instance_valid(child):
			continue
		if child.has_method("debug_splits_done") and not bool(child.get("is_dead")):
			nodes.append(child)
	return nodes


func _purple_family_current() -> float:
	var current := 0.0
	for node in _purple_nodes():
		current += maxf(float(node.get("current_health")), 0.0)
	return current


func _purple_family_ratio() -> float:
	if _purple_total_max <= 0.0:
		return 0.0
	return clampf(_purple_family_current() / _purple_total_max, 0.0, 1.0)


## 显示图片用的紫色本体
func _purple_body() -> Node:
	for node in _boss_nodes:
		if is_instance_valid(node) and not bool(node.get("is_clone")):
			return node
	return null


## 紫色共享血条掉到 75% / 50% / 25% 时，各从一只存活的本体处分裂出 1 个分身（共 3 个）
func _update_purple_splits() -> void:
	if _purple_split_stage >= PURPLE_SPLIT_THRESHOLDS.size() or _purple_total_max <= 0.0:
		return
	if _purple_family_ratio() > PURPLE_SPLIT_THRESHOLDS[_purple_split_stage]:
		return
	_purple_split_stage += 1
	var body := _pick_alive_purple_body()
	if body != null and body.has_method("spawn_clone_now"):
		body.spawn_clone_now()
		if debug_print:
			print("[Battle] 紫色共享血条到 %.0f%%，加 1 个分身（第 %d 个）" % [
				PURPLE_SPLIT_THRESHOLDS[_purple_split_stage - 1] * 100.0, _purple_split_stage])


## 从存活的本体里挑一个来生成分身（分身不作为分裂来源）
func _pick_alive_purple_body() -> Node:
	for node in _boss_nodes:
		if is_instance_valid(node) and not bool(node.get("is_dead")) and not bool(node.get("is_clone")):
			return node
	return null


## 调试: 出生 1.2 秒后模拟"Boss 被打死"，然后走完整条 结算 -> 确定 链路
func _start_debug_instant_win() -> void:
	var timer := Timer.new()
	timer.wait_time = 1.2
	timer.one_shot = true
	timer.timeout.connect(_debug_instant_win)
	add_child(timer)
	timer.start()


func _on_result_dialog_exit_requested() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false
	_record_run_progress()
	if _last_result_won:
		if goal.get("type", "") == LevelGoal.TYPE_BOSS and RunState.is_final_floor():
			RunState.finish_run(true)          # 最终层 BOSS 通关: 整局结束
			GameFlow.goto_title()
		else:
			RunState.advance_floor()           # 普通关/精英关/中途 BOSS 胜利: 层数 +1
			GameFlow.goto_midmap()                # 回中间地图
	else:
		RunState.finish_run(false)             # 失败: 整局结束
		GameFlow.goto_title()


## 把本场战绩并进整局状态（只并一次）
func _record_run_progress() -> void:
	if _result_recorded:
		return
	_result_recorded = true
	RunState.total_kills += round_kill_count
	RunState.run_elapsed += _get_round_elapsed_time()
	# 生命值跨关卡保留：把这一场打完的血量写回整局状态
	RunState.set_health(_get_player_current_health(), player.max_health)
	# 本关成绩：留给 中间地图 在关卡之间做汇报
	RunState.last_level_report = {
		"floor": RunState.floor_index,
		"node_type": String(goal.get("node_type", "")),
		"goal_text": LevelGoal.describe(goal),
		"won": _last_result_won,
		"kills": round_kill_count,
		"elapsed": _get_round_elapsed_time(),
		"gold_gained": _gold_gained,
		"gold_total": RunState.gold,
		"health": _get_player_current_health(),
		"max_health": player.max_health,
	}
	if debug_print:
		print("[Battle] 离场写回: 生命 %d/%d 金币 %d 本关击杀 %d 用时 %.1f 秒" % [
			RunState.current_health, RunState.max_health, RunState.gold,
			round_kill_count, _get_round_elapsed_time()])


## 通关总结（打在同一个结算弹窗里，多行文本会让弹窗自动放大）
func _build_run_summary() -> String:
	_record_run_progress()
	return "恭喜通关
到达层数: %d / %d
本局总击杀: %d
本局用时: %.1f 秒
金币: %d

按确定返回标题" % [
		RunState.floor_index, RunState.MAX_FLOOR,
		RunState.total_kills, RunState.run_elapsed, RunState.gold]


## 覆盖父类: 多行文本时把弹窗放大，避免被裁掉
func _show_result_dialog(result_title: String, result_message: String) -> void:
	# 显示结算前，先把队友血量/层数写回名册（只写一次）
	if not is_result_displayed:
		_write_back_allies()
	super._show_result_dialog(result_title, result_message)
	if result_message.contains("
") and result_dialog != null:
		result_dialog.popup_centered(Vector2i(460, 260))


### 调试: 模拟击败 Boss 后，直接把"总结文本 + 确定后的整局状态"打出来。
## 说明: 结算弹窗会把 time_scale 设为 0，计时器全部冻结，所以这里不用延时，
##       直接在模拟击杀的同一帧验证流程（等价于玩家点确定）。
func _debug_instant_win() -> void:
	print("[Battle调试] 模拟胜利 目标=%s 层数=%d" % [String(goal.get("type", "?")), RunState.floor_index])
	_last_result_won = true          # 真实路径里由 _check_game_result() 置位，这里手动补上
	if not _boss_defeated:
		_on_boss_defeated()
	print("[Battle调试] 通关总结文本=%s" % _build_run_summary().replace("
", " | "))
	print("[Battle调试] 点确定前: 层数=%d 局进行中=%s 总击杀=%d 用时=%.1f" % [
		RunState.floor_index, str(RunState.is_active), RunState.total_kills, RunState.run_elapsed])
	# 模拟玩家点确定（清掉暂停，避免后续场景切不过去）
	Engine.time_scale = 1.0
	get_tree().paused = false
	_on_result_dialog_exit_requested()
	print("[Battle调试] 点确定后: 层数=%d 局进行中=%s 已通关=%s 总击杀=%d" % [
		RunState.floor_index, str(RunState.is_active), str(RunState.cleared), RunState.total_kills])


# ---------------- 目标 HUD:屏幕底部居中，纯文字 零美术  ----------------

func _setup_goal_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "GoalHUD"
	add_child(layer)
	_goal_label = _make_bottom_label(-40, 20, Color(1.0, 0.87, 0.55))
	_detail_label = _make_bottom_label(-14, 14, Color(0.85, 0.85, 0.85))
	layer.add_child(_goal_label)
	layer.add_child(_detail_label)


## 贴屏幕底部的居中文本；加黑描边，保证在任何深色地砖上都读得清
func _make_bottom_label(bottom_offset: int, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	label.offset_top = bottom_offset - font_size - 8
	label.offset_bottom = bottom_offset
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _refresh_goal_hud(force: bool = false) -> void:
	if _goal_label == null or _detail_label == null:
		return
	var state := _goal_state()
	var head := LevelGoal.describe(goal)
	var detail := LevelGoal.progress_text(goal, state)
	var key := "%s|%s|%d" % [head, detail, int(stage_time_left)]
	if not force and key == _last_hud_key:
		return
	_last_hud_key = key
	_goal_label.text = head
	var suffix := ""
	if LevelGoal.time_limit(goal) > 0.0:
		suffix = " 剩余 %.0f 秒" % maxf(stage_time_left, 0.0)
	_detail_label.text = "第 %d 层 ， %s%s" % [int(goal.get("floor", 1)), detail, suffix]


# ---------------- 胜负判定:覆盖父类，改成按 LevelGoal 的 ALL 语义 ----------------

func _goal_state() -> Dictionary:
	return {
		"kills": round_kill_count,
		"time_left": stage_time_left,
		"waves_done": _waves_done,
		"waves_total": _waves.size(),
		"boss_defeated": _living_boss_count() == 0,   # 三重 BOSS：全部家族归零才算达成
		"boss_hp_ratio": _boss_hp_ratio(),          # M3:Boss 死亡时由 Boss 置真
		"guard_alive": _guard_target != null and is_instance_valid(_guard_target) and not _guard_target.is_dead,
	}


func _check_game_result() -> void:
	if is_result_displayed:
		return
	if _get_player_current_health() <= 0:
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, RESULT_MESSAGE_LOSE)
		return
	if goal.get("type", "") == LevelGoal.TYPE_DEFEND and (_guard_target == null or not is_instance_valid(_guard_target) or _guard_target.is_dead):
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, "守护对象被击破了")
		return
	var state := _goal_state()
	if LevelGoal.is_satisfied(goal, state):
		_last_result_won = true
		if goal.get("type", "") == LevelGoal.TYPE_BOSS and RunState.is_final_floor():
			_show_result_dialog("通关", _build_run_summary())      # 最终层: 显示整局总结
		elif goal.get("type", "") == LevelGoal.TYPE_BOSS:
			_show_result_dialog("BOSS 击破", "第 %d 层 BOSS 已被击败 回中间地图" % RunState.floor_index)
		else:
			_show_result_dialog(RESULT_TITLE_WIN, "本层目标达成 回中间地图")
		return
	if LevelGoal.is_timed_out(goal, state):
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, "时间到，目标未完成")


# ---------------- 开发自检 M1/M2 验收用，稳定后可删  ----------------

func _start_self_check() -> void:
	var probe := Timer.new()
	probe.name = "SelfCheckTimer"
	probe.wait_time = 1.6
	probe.one_shot = true
	probe.timeout.connect(_self_check)
	add_child(probe)
	probe.start()


func _self_check() -> void:
	var alive := _get_alive_enemy_count()
	var first_enemy: Node2D = null
	for child in enemy_container.get_children():
		if child is Enemy:
			first_enemy = child
			break
	var door_distance := INF
	if first_enemy != null:
		var generator = ArenaGen.new()
		for door in arena_data["doors"]:
			door_distance = minf(door_distance, first_enemy.global_position.distance_to(
				generator.spawn_world_position(door)))
	print("[Battle自检] 场上敌人=%d Overlay(红门)格=%d 地面格=%d 波次=%d/%d 击杀=%d 目标达成=%s%s" % [
		alive, $OverlayTileMapLayer.get_used_cells().size(), $GroundTileMapLayer.get_used_cells().size(),
		_waves_done, _waves.size(), round_kill_count,
		str(LevelGoal.is_satisfied(goal, _goal_state())),
		("" if first_enemy == null else "；首个敌人距最近红门 %.1f px" % door_distance)])
	var _hud_bar := $Player/HUDLayer/TimeBar as Sprite2D
	var _hud_life := $Player/HUDLayer/LifeIcon as Sprite2D
	var _hud_icon_time := $Player/HUDLayer/TimeIcon as Sprite2D
	print("[Battle自检] HUD布局: 时钟可见=%s 条可见=%s 条X=%.0f 条色=%s 生命Y=%.0f" % [
		str(_hud_icon_time.visible), str(_hud_bar.visible), _hud_bar.position.x,
		str(_hud_bar.modulate), _hud_life.position.y])
	print("[Battle自检] HUD第一行=%s ， HUD第二行=%s" % [_goal_label.text, _detail_label.text])

# ---------------- 三重 BOSS（第 5 层 50/50 / 第 10 层 3 只 + 家族血条） ----------------

const DefendTargetScene := preload("res://scene/defend_target.tscn")
const SHOOTER_CONFIG := preload("res://resources/config/enemy_shooter.tres")
## 守护关：在场敌人上限从 0 线性放到 DEFEND_MAX_ALIVE，DEFEND_RAMP_TIME 秒时到顶
const DEFEND_MAX_ALIVE := 30
const DEFEND_RAMP_TIME := 90.0
const PURPLE_BOSS_SCENE := "res://scene/boss_purple.tscn"
const PURPLE_SPLIT_THRESHOLDS: Array[float] = [0.75, 0.50, 0.25]  ## 共享血条掉到这些比例各加 1 个分身
const BOSS_ICON_ATLAS := "res://resources/texture/源石虫.png"
const NORMAL_BOSS_ICON_ROW_Y := 32    ## 原 BOSS 的血条图片用源石虫.png 第 2 排（用户指定）
const BOSS_BAR_SPACING := 16.0        ## 第10层第二条血条相对第一条下移的世界单位（相机4倍 -> 屏幕64px）
const BOSS_ICON_SCALE := 1.0          ## 血条左侧怪物图片的缩放（32x32 -> 32 世界单位，用户要求放大一倍）
const BOSS_ICON_GAP := 24.0           ## 怪物图片中心到血条左边缘的距离（图片变大后同步拉远，避免压住血条）


## 第 10 层 = 原 BOSS + 2 只紫 BOSS；其它 BOSS 层 = 50/50 随机一只
## 用「每局随机种子 run_seed」参与：每局进同一层都可能不同（真随机 50/50），
## 同一局内重进该层结果固定（可复现）。
func _spawn_bosses_for_floor() -> void:
	_boss_nodes.clear()
	var floor_now := _context_floor()
	if RunState.is_final_floor() or floor_now >= RunState.MAX_FLOOR:
		_spawn_boss()
		_spawn_purple_boss(1)
		_spawn_purple_boss(2)
		print("[Battle] 第 10 层：三重 BOSS（原 BOSS + 紫 BOSS x2）")
		_spawn_final_floor_shooters(4)      # 开局再放 4 个持枪敌人（用户要求）
	else:
		var rng := RandomNumberGenerator.new()
		rng.seed = RunState.run_seed + floor_now * 7919   # 加入本局随机种子：每局都可能出紫 BOSS
		if rng.randf() < 0.5:
			print("[Battle] 第 %d 层 BOSS 抽到：原 BOSS" % floor_now)
			_spawn_boss()
		else:
			print("[Battle] 第 %d 层 BOSS 抽到：紫色 BOSS" % floor_now)
			_spawn_purple_boss(0)


## 第 10 层开局固定放出 count 个持枪敌人（用户要求 4 个）
func _spawn_final_floor_shooters(count: int) -> void:
	var cfg := _shooter_config_from_pool()
	if cfg == null:
		return
	var spawned := 0
	for _index in range(count):
		var spawn_point := _pick_spawn_point()
		if spawn_point == null:
			break
		var spawn_scene := enemy_scene
		if cfg.scene_override != null:
			spawn_scene = cfg.scene_override
		var shooter := spawn_scene.instantiate() as Enemy
		if shooter == null:
			continue
		enemy_container.add_child(shooter)
		shooter.global_position = spawn_point.global_position
		shooter.setup(cfg, player)
		if not shooter.died.is_connected(_on_enemy_died):
			shooter.died.connect(_on_enemy_died)
		spawned += 1
	if debug_print:
		print("[Battle] 第 10 层开局放出 %d 个持枪敌人" % spawned)


## 从刷怪池里取"持枪敌人"的配置（已按层数缩放血量）
func _shooter_config_from_pool() -> EnemyConfig:
	for cfg in available_enemy_configs:
		if cfg == null or cfg.scene_override == null:
			continue
		if cfg.scene_override == SHOOTER_CONFIG.scene_override:
			return cfg
	return SHOOTER_CONFIG


func _spawn_purple_boss(family: int) -> void:
	var purple = load(PURPLE_BOSS_SCENE).instantiate()
	if purple == null:
		return
	enemy_container.add_child(purple)
	purple.add_to_group(BOSS_GROUP)        # 不占"普通敌人"名额
	var spawn_cell: Vector2i = _spawn_cell_for_family(arena_data["player_spawn"], family)
	purple.global_position = cell_to_world(spawn_cell)
	purple.setup(_boss_config_for_purple(), player)
	if "family_id" in purple:
		purple.family_id = family
	_boss_nodes.append(purple)
	if _boss == null:
		_boss = purple
	if not purple.died.is_connected(_on_enemy_died):
		purple.died.connect(_on_enemy_died)
	purple.died.connect(_on_purple_boss_died)
	# 紫色阵营共用一个血池：本体先记一份 max，之后每生成一个分身再加它那份
	if purple.config != null:
		_purple_total_max += float(purple.config.max_health)
	if purple.has_signal("clone_spawned"):
		purple.clone_spawned.connect(_on_purple_clone_spawned)
	if debug_print:
		print("[Battle] 紫色 BOSS 已放出（家族 %d）出生格=%s 共享血池上限=%.0f" % [family, str(spawn_cell), _purple_total_max])


## 紫 BOSS 分裂：分身的血量也加进共享血池的上限，这样血条不会因为分身出现而突然多一截
func _on_purple_clone_spawned(clone: Node) -> void:
	if is_instance_valid(clone):
		_purple_total_max += maxf(float(clone.get("current_health")), 1.0)
		if debug_print:
			print("[Battle] 紫 BOSS 分身加入共享血池（上限 %.0f）" % _purple_total_max)


func _on_purple_boss_died() -> void:
	if not is_inside_tree():
		return
	var gain := maxi(gold_per_boss_kill, 0)
	RunState.add_gold(gain)
	_gold_gained += gain
	if debug_print:
		print("[Battle] 紫色 BOSS 阵亡 金币 +%d（合计 %d）" % [gain, RunState.gold])


## 场上所有 BOSS：原 BOSS + 紫色 BOSS 本体 + 紫色 BOSS 的分身
func _boss_nodes_all() -> Array[Node]:
	var nodes: Array[Node] = []
	for child in enemy_container.get_children():
		var node := child as Node
		if node == null:
			continue
		if node == _boss or node.has_method("debug_splits_done"):
			nodes.append(node)
	return nodes


## 还活着的 BOSS 数量（含分身）—— 归零才算过关
func _living_boss_count() -> int:
	var count := 0
	for node in _boss_nodes_all():
		if is_instance_valid(node) and not bool(node.get("is_dead")):
			count += 1
	return count


## （旧的三条家族血条已删除：改成第10层两条旧样式血条，见 _setup_boss_bar_icons / _update_time_bar）


func _boss_icon_texture(body: Node) -> Texture2D:
	if body == null:
		return null
	# 原 BOSS：血条图片固定用源石虫.png 第 2 排（用户指定，不用它自己的素材）
	if not body.has_method("debug_splits_done"):
		var atlas := load(BOSS_ICON_ATLAS) as Texture2D
		if atlas != null:
			var frame := AtlasTexture.new()
			frame.atlas = atlas
			frame.region = Rect2(0, NORMAL_BOSS_ICON_ROW_Y, 32, 32)
			return frame
	# 紫 BOSS：用它自己第 3 排的素材
	for path in ["AnimatedSprite2D", "AnimatedSprite", "BodySprite"]:
		var sprite := body.get_node_or_null(path) as AnimatedSprite2D
		if sprite == null or sprite.sprite_frames == null:
			continue
		var names := sprite.sprite_frames.get_animation_names()
		if names.is_empty():
			continue
		return sprite.sprite_frames.get_frame_texture(names[0], 0)
	return null


## 取"第 index 远"的红门格：多只 BOSS 时不要全挤在同一个格子上
func _spawn_cell_for_family(from_cell: Vector2i, index: int) -> Vector2i:
	var doors: Array = arena_data.get("doors", [])
	if doors.is_empty():
		return _farthest_spawn_cell_from(from_cell)
	var cells: Array[Vector2i] = []
	for door in doors:
		cells.append(door["cell"])
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a).distance_to(Vector2(from_cell)) \
			> Vector2(b).distance_to(Vector2(from_cell)))
	return cells[clampi(index, 0, cells.size() - 1)]






## 守护关：地图中心放一个不动的守护对象
func _spawn_defend_target() -> void:
	_guard_target = DefendTargetScene.instantiate()
	add_child(_guard_target)
	_guard_target.global_position = Vector2(
		float(arena_data["width"]) * float(ArenaGen.TILE_SIZE) * 0.5,
		float(arena_data["height"]) * float(ArenaGen.TILE_SIZE) * 0.5)
	if _guard_target.has_signal("health_changed"):
		_guard_target.health_changed.connect(_on_guard_health_changed)
	_setup_defend_hud()


## 守护关刷怪：开场不刷，在场上限随时间线性放开（90 秒到 30 只），
## 出怪间隔 0.5s（比上限增速快，被杀了也能补回来）
func _configure_defend_spawn() -> void:
	max_alive_enemies = 0
	spawn_interval = 0.5
	min_spawn_interval = 0.5
	initial_spawn_count = 0
	spawn_count_per_tick = 1


## 守护关：按已进行时间更新"在场敌人上限"（0 -> 30，90 秒到顶）
func _update_defend_spawn_cap() -> void:
	if goal.get("type", "") != LevelGoal.TYPE_DEFEND:
		return
	var elapsed := maxf(LevelGoal.DEFEND_DURATION - stage_time_left, 0.0)
	max_alive_enemies = _defend_alive_cap_for(elapsed)


func _defend_alive_cap_for(elapsed: float) -> int:
	return clampi(int(floor(DEFEND_MAX_ALIVE * minf(elapsed / DEFEND_RAMP_TIME, 1.0))),
		0, DEFEND_MAX_ALIVE)


## 第 5 层之后才允许出现守护关 / 持枪敌人（用户要求）
func _after_floor_5() -> bool:
	return _context_floor() > 5


## 自检用：当前刷怪池里是否含持枪敌人（按 scene_override 判断，血量缩放复制过也认）
func debug_pool_has_shooter() -> bool:
	for cfg in available_enemy_configs:
		if cfg != null and cfg.scene_override == SHOOTER_CONFIG.scene_override:
			return true
	return false


## 右侧守护对象面板：头像 + 血量，淡蓝色外框
func _setup_defend_hud() -> void:
	var layer := get_node_or_null("BattleHud") as CanvasLayer
	if layer == null:
		return
	var panel := PanelContainer.new()
	panel.name = "GuardPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = -240.0
	panel.offset_right = -16.0
	panel.offset_top = 150.0
	panel.offset_bottom = 150.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.08, 0.12, 0.6)
	style.border_color = Color(0.55, 0.80, 1.0, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)
	var icon := TextureRect.new()
	icon.texture = _guard_icon_texture()
	icon.custom_minimum_size = Vector2(44, 44)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var info := VBoxContainer.new()
	row.add_child(info)
	var title := Label.new()
	title.text = "守护对象"
	title.add_theme_font_size_override("font_size", HUD_FONT_NAME)
	title.add_theme_color_override("font_color", Color(0.75, 0.90, 1.0))
	info.add_child(title)
	_guard_hud_hp = Label.new()
	_guard_hud_hp.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	_guard_hud_hp.add_theme_color_override("font_color", Color(0.70, 0.90, 1.0))
	info.add_child(_guard_hud_hp)
	_refresh_guard_hud()


func _guard_icon_texture() -> Texture2D:
	if _guard_target == null or not is_instance_valid(_guard_target):
		return null
	var sprite := _guard_target.get_node_or_null("Sprite2D") as AnimatedSprite2D
	if sprite == null or sprite.sprite_frames == null:
		return null
	var names := sprite.sprite_frames.get_animation_names()
	if names.is_empty():
		return null
	return sprite.sprite_frames.get_frame_texture(names[0], 0)


func _refresh_guard_hud() -> void:
	if _guard_hud_hp == null or _guard_target == null or not is_instance_valid(_guard_target):
		return
	_guard_hud_hp.text = "%d / %d" % [int(_guard_target.current_health), int(_guard_target.MAX_HEALTH)]


func _on_guard_health_changed(_current: int, _maximum: int) -> void:
	_refresh_guard_hud()


## 兜底空气墙：按当前关卡尺寸在地图外侧围一圈不可见碰撞体
## 背景：红门那格会被挖成地板，若门后没有墙体瓦片，玩家能顺红门跑出地图
func _setup_arena_bounds() -> void:
	var tile := float(ArenaGen.TILE_SIZE)
	var width := float(arena_data["width"]) * tile
	var height := float(arena_data["height"]) * tile
	var body := StaticBody2D.new()
	body.name = "ArenaBounds"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var thickness := 16.0
	_add_bound_shape(body, Vector2(width * 0.5, -thickness * 0.5), Vector2(width + thickness * 2.0, thickness))
	_add_bound_shape(body, Vector2(width * 0.5, height + thickness * 0.5), Vector2(width + thickness * 2.0, thickness))
	_add_bound_shape(body, Vector2(-thickness * 0.5, height * 0.5), Vector2(thickness, height + thickness * 2.0))
	_add_bound_shape(body, Vector2(width + thickness * 0.5, height * 0.5), Vector2(thickness, height + thickness * 2.0))
	if debug_print:
		print("[Battle] 兜底空气墙已就位: 地图 %dx%d 格（%dx%d px）" % [int(arena_data["width"]), int(arena_data["height"]), int(width), int(height)])


func _add_bound_shape(body: StaticBody2D, center: Vector2, size: Vector2) -> void:
	var shape := RectangleShape2D.new()
	shape.size = size
	var collider := CollisionShape2D.new()
	collider.shape = shape
	collider.position = center
	body.add_child(collider)
