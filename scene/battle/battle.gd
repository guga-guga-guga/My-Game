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


func _ready() -> void:
	random_generator.randomize()

	# ① 目标必须先算:限时决定倒计时条长度 stage_duration 由 _setup_hud 读取 
	goal = LevelGoal.build(_context_floor(), _context_node_type(), debug_goal_type)
	stage_duration = LevelGoal.stage_duration(goal)
	_waves = goal.get("waves", [])

	_configure_result_dialog()
	_setup_hud()
	_setup_goal_hud()

	# ② 场地数据 到 ③ 铺瓦片 红门在 Overlay 层 到 ④ 出怪点与红门成对创建
	var use_seed := arena_seed if arena_seed != 0 else random_generator.randi()
	var generator = ArenaGen.new()
	arena_data = generator.generate(arena_width, arena_height, use_seed)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)
	generator.create_spawn_markers($EnemySpawnPoints, arena_data)
	player.global_position = cell_to_world(arena_data["player_spawn"])

	# ⑤ 顺序关键:铺完瓦片之后才能重建寻路网格
	_setup_enemy_pathfinder()
	_collect_enemy_spawn_points()
	_warn_spawn_points_inside_walls()
	_collect_enemy_configs()
	_configure_enemy_spawn_timer()
	_keep_player_centered()

	# ⑥ 刷怪:有波次表的关卡走波次推进；其余沿用父类的无限刷怪
	if goal["type"] == LevelGoal.TYPE_BOSS:
		_spawn_boss()
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


## Boss 关：从"离玩家最远的那个红门"里放出一只 Boss（复用出怪口的语义）
func _spawn_boss() -> void:
	var boss := BossScene.instantiate() as Enemy
	if boss == null:
		push_warning("[Battle] Boss 场景实例化失败")
		return
	enemy_container.add_child(boss)
	var spawn_cell := _farthest_door_cell_from(arena_data["player_spawn"])
	boss.global_position = cell_to_world(spawn_cell)
	boss.setup(BossConfig, player)
	if boss.has_method("set_arena"):
		boss.set_arena(arena_data["grid"], int(arena_data["width"]), int(arena_data["height"]))
	if "debug_fast_skills" in boss:
		boss.debug_fast_skills = debug_fast_boss
	if boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(_on_boss_defeated)
	if not boss.died.is_connected(_on_enemy_died):
		boss.died.connect(_on_enemy_died)
	print("[Battle] Boss 已放出: 出生格=%s（玩家在 %s）" % [str(spawn_cell), str(arena_data["player_spawn"])])


## 取"离玩家最远的那道红门"作为 Boss 出生点
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
	if debug_print:
		print("[Battle] Boss 已击败, 目标达成判定=%s" % str(LevelGoal.is_satisfied(goal, _goal_state())))


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
		"boss_defeated": _boss_defeated,          # M3:Boss 死亡时由 Boss 置真
	}


func _check_game_result() -> void:
	if is_result_displayed:
		return
	if _get_player_current_health() <= 0:
		_show_result_dialog(RESULT_TITLE_LOSE, RESULT_MESSAGE_LOSE)
		return
	var state := _goal_state()
	if LevelGoal.is_satisfied(goal, state):
		_show_result_dialog(RESULT_TITLE_WIN, RESULT_MESSAGE_WIN)
		return
	if LevelGoal.is_timed_out(goal, state):
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
	print("[Battle自检] HUD第一行=%s ， HUD第二行=%s" % [_goal_label.text, _detail_label.text])
