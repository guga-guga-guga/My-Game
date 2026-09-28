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
## Boss 关：红门每隔多少秒涌出一只普通敌人
@export var boss_door_spawn_interval: float = 5.0
## Boss 关：场上小怪（不含 Boss）上限
@export var boss_door_alive_cap: int = 5
## 每只普通敌人掉落的金币（M6 平衡：1 -> 2，否则中期买不起输出，打血厚的敌人会变成磨血）
@export var gold_per_enemy_kill: int = 2
## 击败 Boss 的额外金币（M6 平衡：8 -> 20，BOSS 关没有波次，收入几乎为零）
@export var gold_per_boss_kill: int = 20

## 调试: 直接模拟击败 Boss（验证"通关结算 -> 回标题"整条链路）
@export var debug_instant_boss_win: bool = false
## 调试: 任意关卡都直接模拟胜利（验证"胜利 -> 回 Hub -> 层数 +1"整条链路）
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
var _boss_defeated := false
var _boss: Enemy = null
var _boss_title_label: Label = null
var _debug_win_started := false
var _ally = null
var _hud_gold: Label = null
var _hud_ally_box: Control = null
var _hud_ally_hp: Label = null
var _hud_ally_state: Label = null
var _last_result_won := false
var _gold_gained := 0                 ## 本关赚到的金币（汇报用）
var _result_recorded := false


func _ready() -> void:
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
	_apply_goal_hud_layout()

	# ② 场地数据 到 ③ 铺瓦片 红门在 Overlay 层 到 ④ 出怪点与红门成对创建
	var use_seed := arena_seed if arena_seed != 0 else random_generator.randi()
	var generator = ArenaGen.new()
	var arena_mode := ArenaGen.MODE_BOSS if goal["type"] == LevelGoal.TYPE_BOSS else ArenaGen.MODE_NORMAL
	arena_data = generator.generate(arena_width, arena_height, use_seed, arena_mode)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)
	generator.create_spawn_markers($EnemySpawnPoints, arena_data)
	player.global_position = cell_to_world(arena_data["player_spawn"])
	_apply_run_state_to_player()

	# ⑤ 顺序关键:铺完瓦片之后才能重建寻路网格
	_setup_enemy_pathfinder()
	_collect_enemy_spawn_points()
	_warn_spawn_points_inside_walls()
	_spawn_ally_if_hired()
	_collect_enemy_configs()
	_apply_floor_scaling_to_enemy_configs()
	_configure_enemy_spawn_timer()
	_keep_player_centered()

	# ⑥ 刷怪:有波次表的关卡走波次推进；其余沿用父类的无限刷怪
	if goal["type"] == LevelGoal.TYPE_BOSS:
		_spawn_boss()
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


## M6 平衡：最终 BOSS 更肉（半路 BOSS 保持不变）
func _boss_config_for_floor() -> EnemyConfig:
	if not RunState.is_final_floor():
		return BossConfig
	var copy: EnemyConfig = BossConfig.duplicate()
	copy.max_health = maxi(int(round(float(BossConfig.max_health) * 1.65)), 1)
	if debug_print:
		print("[Battle] 最终 BOSS 血量 %d -> %d" % [BossConfig.max_health, copy.max_health])
	return copy


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

	# 队友面板：头像 + 名字 + 血量 + 状态
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
	name_label.text = ALLY_NAME
	name_label.add_theme_font_size_override("font_size", HUD_FONT_NAME)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.93, 1.0))
	info.add_child(name_label)
	_hud_ally_hp = Label.new()
	_hud_ally_hp.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	_hud_ally_hp.add_theme_color_override("font_color", Color(1.0, 0.55, 0.55))
	info.add_child(_hud_ally_hp)
	_hud_ally_state = Label.new()
	_hud_ally_state.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	_hud_ally_state.add_theme_color_override("font_color", Color(0.70, 0.85, 1.0))
	info.add_child(_hud_ally_state)
	_hud_ally_box = ally_panel

	if not RunState.gold_changed.is_connected(_on_hud_gold_changed):
		RunState.gold_changed.connect(_on_hud_gold_changed)
	_refresh_hud_gold()
	_hud_ally_box.visible = false


func _make_hud_panel(_unused_offset: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.28)      # 和 Hub 金币 HUD 一致的半透明底
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
	if _hud_ally_box == null:
		return
	if _ally == null or not is_instance_valid(_ally):
		_hud_ally_box.visible = false
		return
	_hud_ally_box.visible = true
	if _ally.is_dead:
		_hud_ally_hp.text = "0 / %d" % _ally.MAX_HEALTH
		_hud_ally_state.text = "阵亡"
		return
	_hud_ally_hp.text = "%d / %d" % [_ally.current_health, _ally.MAX_HEALTH]
	_hud_ally_state.text = String(_ally.state_name())


func _on_ally_state_changed(_state: String) -> void:
	_refresh_ally_hud()


func _on_ally_health_changed(_current: int, _maximum: int) -> void:
	_refresh_ally_hud()


## 商店里雇了队友的话，这一关开场把他放出来（只在本关有效）
func _spawn_ally_if_hired() -> void:
	if not RunState.ally_pending:
		return
	RunState.ally_pending = false          # 用完即清：下一关要重新雇
	var ally = AllyScene.instantiate()          # 不用类型注解：队友脚本没有全局类名
	if ally == null:
		return
	add_child(ally)
	var body := player.get_node_or_null("BodySprite") as AnimatedSprite2D
	ally.setup(player, body.sprite_frames if body != null else null,
		RunState.get_player_damage(), RunState.get_player_fire_interval(), $EnemyContainer)
	_ally = ally
	ally.health_changed.connect(_on_ally_health_changed)
	ally.state_changed.connect(_on_ally_state_changed)
	_refresh_ally_hud()
	if debug_print:
		print("[Battle] 队友已出场: 伤害 %d 开火间隔 %.3f（玩家 %.3f 的七折射速）状态=%s" % [
			ally.damage, ally.fire_interval, RunState.get_player_fire_interval(), ally.state_name()])
		print("[Battle自检] 右上角 HUD: %s / 队友 %s %s %s" % [
			_hud_gold.text, ALLY_NAME, _hud_ally_hp.text, _hud_ally_state.text])


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
	var boss_alive := 0
	if _boss != null and is_instance_valid(_boss) and not _boss.is_dead:
		boss_alive = 1
	if _get_alive_enemy_count() - boss_alive >= boss_door_alive_cap:
		return
	if _try_spawn_enemy() and debug_print:
		print("[Battle] 红门涌出一只敌人（场上共 %d）" % _get_alive_enemy_count())


## 在红条左边加「BOSS」字样（和血条同层、世界空间，跟着角色走）
func _add_boss_health_title(clock_bar: Sprite2D) -> void:
	if _boss_title_label != null and is_instance_valid(_boss_title_label):
		return
	var boss_hud := $Player/HUDLayer as Node2D
	if boss_hud == null:
		return
	var label := Label.new()
	label.name = "BossHealthTitle"
	label.text = "BOSS"
	label.add_theme_font_size_override("font_size", 10)          # 世界空间会被相机放大 4 倍
	label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 2)
	boss_hud.add_child(label)
	label.position = Vector2(time_bar_left_edge_x - 34.0, clock_bar.position.y - 7.0)
	_boss_title_label = label


## Boss 关：从"离玩家最远的那个红门"里放出一只 Boss（复用出怪口的语义）
## 把整局成长（生命/伤害/射速）应用到玩家身上
func _apply_run_state_to_player() -> void:
	player.max_health = RunState.max_health
	player.current_health = clampi(RunState.current_health, 1, RunState.max_health)
	player.fire_interval = RunState.get_player_fire_interval()
	if not RunState.health_changed.is_connected(_on_run_state_health_changed):
		RunState.health_changed.connect(_on_run_state_health_changed)
	if debug_print:
		print("[Battle] 进场: 生命 %d/%d 子弹伤害 %d 射击间隔 %.3f 金币 %d" % [
			player.current_health, player.max_health, RunState.get_player_damage(),
			player.fire_interval, RunState.gold])


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
	_boss = boss
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

	var bar := $Player/HUDLayer/TimeBar as Sprite2D
	if bar != null:
		bar.visible = false          # Boss 死后收起红条
	if _boss_title_label != null and is_instance_valid(_boss_title_label):
		_boss_title_label.visible = false
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
	_add_boss_health_title(clock_bar)


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


## Boss 血量比例（0~1）
func _boss_hp_ratio() -> float:
	if _boss == null or not is_instance_valid(_boss) or _boss.config == null:
		return 1.0
	return clampf(float(_boss.current_health) / float(maxi(_boss.config.max_health, 1)), 0.0, 1.0)


## 覆盖父类：Boss 关顶部条 = Boss 血量条；其余关卡沿用倒计时
func _update_time_bar() -> void:
	if goal.get("type", "") != LevelGoal.TYPE_BOSS or time_bar == null:
		super._update_time_bar()
		return
	var fill_ratio := 0.0
	if not _boss_defeated:
		fill_ratio = _boss_hp_ratio()
	time_bar.scale.x = time_bar_full_scale_x * fill_ratio
	if not time_bar.centered:
		time_bar.position.x = time_bar_left_edge_x
		return
	var current_width := time_bar_texture_width * time_bar.scale.x
	time_bar.position.x = time_bar_left_edge_x + (current_width * 0.5)


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
			GameFlow.goto_hub()                # 回中间地图
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
	# 本关成绩：留给 Hub 在关卡之间做汇报
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
		"boss_defeated": _boss_defeated,
		"boss_hp_ratio": _boss_hp_ratio(),          # M3:Boss 死亡时由 Boss 置真
	}


func _check_game_result() -> void:
	if is_result_displayed:
		return
	if _get_player_current_health() <= 0:
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, RESULT_MESSAGE_LOSE)
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
