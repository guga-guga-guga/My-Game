extends "res://scene/enemy.gd"
## Boss（M3）—— 三阶段 + 三个技能，复用 enemy.gd 的寻路 / 受击 / 爆炸 / 掉落。
##
## 技能（全部带 0.7 秒预警：Boss 黄闪 + 地面警示圈，给玩家反应窗口）
##   minions  抛小怪：在 Boss 位置生成 3~5 只普通敌人（画在 Boss 之上），
##                    抛物线丢到附近"可通行格"，落地后恢复 AI → 就是普通敌人
##   bomb     扔自爆怪：Boss 停住并**锁定玩家此刻位置** → 抛出自爆怪 → 落地立即引爆
##   charge   冲撞：朝锁定位置直线冲刺（P2 起解锁），撞完硬直
##
## 阶段：P1 >66%；P2 33%~66%（解锁 bomb）；P3 <33%（解锁 charge + 提速 50% + 技能更频繁）
## 显示：resources/shaders/boss_glow.gdshader（红描边 + 黄闪预警）

const BossGlowShader := preload("res://resources/shaders/boss_glow.gdshader")
const MinionScene := preload("res://scene/enemy.tscn")
const BombConfig := preload("res://resources/config/enemy_bomber.tres")
const TelegraphTexture := preload("res://resources/texture/boss_telegraph.svg")
const TILE := 16.0
const CELL_FLOOR := 0          # 与 arena_generator.CELL_FLOOR 一致

signal boss_skill(skill: String, target: Vector2)
signal boss_defeated

enum Phase { P1, P2, P3 }
enum State { CHASE, TELEGRAPH, CHARGE, RECOVER }

@export_group("阶段阈值")
@export var phase2_ratio: float = 0.66
@export var phase3_ratio: float = 0.33

@export_group("技能节奏")
@export var skill_interval_p1: float = 6.0
@export var skill_interval_p3: float = 4.0
@export var telegraph_time: float = 0.7
@export var recover_duration: float = 0.8

@export_group("技能参数")
@export var minion_count_min: int = 3
@export var minion_count_max: int = 5
@export var throw_duration: float = 0.6
@export var throw_height: float = 34.0
@export var bomb_throw_duration: float = 0.75
@export var charge_speed: float = 240.0
@export var charge_duration: float = 1.1
@export var landing_spread_cells: int = 6
@export var sprite_scale: float = 2.0
## 调试：技能节奏加快 4 倍 + 打印技能日志（headless 自检用）
@export var debug_fast_skills: bool = false
## 调试: 强制阶段(0=自动, 1~3=强制 P1~P3)
@export var debug_force_phase: int = 0

var _phase: int = Phase.P1
var _state: int = State.CHASE
var _skill_timer: float = 0.0
var _telegraph_left: float = 0.0
var _charge_left: float = 0.0
var _recover_left: float = 0.0
var _pending_skill := ""
var _locked_target := Vector2.ZERO
var _charge_direction := Vector2.ZERO
var _glow_material: ShaderMaterial = null
var _minion_configs: Array[EnemyConfig] = []
var _telegraphs: Array[Sprite2D] = []

# 场地数据（由 battle 注入）：把落点限制在"可通行格"上
var _grid: Array = []
var _grid_width := 0
var _grid_height := 0

# 自检计数
var thrown_minions := 0
var thrown_bombs := 0
var charge_count := 0


func _ready() -> void:
	super._ready()
	_setup_glow()
	animated_sprite.scale = Vector2(sprite_scale, sprite_scale)
	_collect_minion_configs()
	_skill_timer = _current_skill_interval()
	died.connect(_on_died)


func _collect_minion_configs() -> void:
	for path in [
		"res://resources/config/enemy_basic.tres",
		"res://resources/config/enemy_fast.tres",
		"res://resources/config/enemy_shelled.tres",
	]:
		var cfg := load(path) as EnemyConfig
		if cfg != null:
			_minion_configs.append(cfg)


## battle 把程序化场地的网格传进来，Boss 才知道哪些格子能落人
func set_arena(grid: Array, width: int, height: int) -> void:
	_grid = grid
	_grid_width = width
	_grid_height = height


func _physics_process(delta: float) -> void:
	_update_phase()
	if debug_fast_skills:
		_skill_timer -= delta * 4.0
	else:
		_skill_timer -= delta

	# 只有追击/冲撞时才让父类的 AI 驱动移动；预警与硬直期间调用 set_ai_suspended
	set_ai_suspended(_state != State.CHASE and _state != State.CHARGE)

	if _state == State.TELEGRAPH:
		_telegraph_left -= delta
		_set_flash(absf(sin(_telegraph_left * 16.0)))     # 黄闪脉冲
		if _telegraph_left <= 0.0:
			_execute_pending_skill()
	elif _state == State.CHARGE:
		_charge_left -= delta
		if _charge_left <= 0.0:
			_enter_recover()
	elif _state == State.RECOVER:
		_recover_left -= delta
		if _recover_left <= 0.0:
			_state = State.CHASE
			_set_flash(0.0)
	elif _state == State.CHASE and _skill_timer <= 0.0 and not is_dead:
		_begin_skill()

	super._physics_process(delta)


func _get_move_direction() -> Vector2:
	if _state == State.CHARGE:
		return _charge_direction
	return super._get_move_direction()


func _get_move_speed() -> float:
	if _state == State.CHARGE:
		return charge_speed
	var base := super._get_move_speed()
	if _phase == Phase.P3:
		return base * 1.5          # 狂暴：更快
	return base


func _update_phase() -> void:
	if config == null:
		return
	if debug_force_phase > 0:
		var forced := clampi(debug_force_phase - 1, Phase.P1, Phase.P3)
		if forced != _phase:
			_phase = forced
			print("[Boss] 调试: 强制阶段 P%d" % [_phase + 1])
		return
	var ratio := float(current_health) / float(maxi(config.max_health, 1))
	var next := Phase.P1
	if ratio <= phase3_ratio:
		next = Phase.P3
	elif ratio <= phase2_ratio:
		next = Phase.P2
	if next == _phase:
		return
	_phase = next
	_set_flash(1.0)                                    # 阶段切换也闪一下，提示玩家
	_skill_timer = minf(_skill_timer, 1.0)
	print("[Boss] 进入阶段 P%d（血量 %.0f%%）" % [_phase + 1, ratio * 100.0])


func _current_skill_interval() -> float:
	var base := skill_interval_p3 if _phase == Phase.P3 else skill_interval_p1
	return base / 4.0 if debug_fast_skills else base


func _begin_skill() -> void:
	_skill_timer = _current_skill_interval()
	var next_skill := _pick_skill()
	_pending_skill = next_skill
	# 锁定"此刻"玩家位置：扔自爆怪/冲撞都以它为落点（Boss 停止移动时的位置）
	_locked_target = target_player.global_position if is_instance_valid(target_player) else global_position
	_state = State.TELEGRAPH
	_telegraph_left = telegraph_time
	_show_telegraph(next_skill)
	boss_skill.emit(next_skill, _locked_target)


func _pick_skill() -> String:
	var pool: Array[String] = ["minions"]
	if _phase >= Phase.P2:
		pool.append("bomb")
	if _phase >= Phase.P3:
		pool.append("charge")
	var index := randi() % pool.size()
	if pool.size() > 1 and pool[index] == _pending_skill:
		index = (index + 1) % pool.size()          # 避免连续两次同一技能
	return pool[index]


func _show_telegraph(skill: String) -> void:
	_clear_telegraphs()
	if skill == "minions":
		for _index in range(randi_range(minion_count_min, minion_count_max)):
			var cell := _random_walkable_cell_near(global_position, landing_spread_cells)
			_spawn_telegraph(_cell_center(cell), 18.0)
	elif skill == "bomb":
		_spawn_telegraph(_snap_to_walkable(_locked_target), 22.0)
	else:
		_spawn_telegraph(_locked_target, 20.0)


func _spawn_telegraph(position_world: Vector2, radius_px: float) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var sprite := Sprite2D.new()
	sprite.texture = TelegraphTexture
	sprite.global_position = position_world
	sprite.z_index = -1                                 # 画在地面上、角色之下
	sprite.modulate = Color(1.0, 1.0, 1.0, 0.85)
	var final_scale := (radius_px / 64.0) * 2.0          # 贴图半径 64px（128x128）
	sprite.scale = Vector2.ONE * final_scale * 0.35
	parent.add_child(sprite)
	_telegraphs.append(sprite)
	var tween := sprite.create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "scale", Vector2.ONE * final_scale, telegraph_time)
	tween.tween_property(sprite, "modulate:a", 0.25, telegraph_time)


# ---------------- 技能执行 ----------------

func _execute_pending_skill() -> void:
	_set_flash(0.0)
	var skill := _pending_skill
	if debug_fast_skills:
		print("[Boss] 释放技能 %s（锁定落点 %s）" % [skill, str(_locked_target.round())])
	if skill == "minions":
		_throw_minions()
		_enter_recover()
	elif skill == "bomb":
		_throw_bomb()
		_enter_recover()
	elif skill == "charge":
		_charge_direction = (_locked_target - global_position).normalized()
		if _charge_direction == Vector2.ZERO:
			_charge_direction = Vector2.RIGHT
		charge_count += 1
		_state = State.CHARGE
		_charge_left = charge_duration
		print("[Boss] 冲撞开始（方向 %s）" % str(_charge_direction.round()))
	else:
		_enter_recover()
	_clear_telegraphs()


## 技能 A：抛出 3~5 只普通敌人，落到附近的"可通行格"
func _throw_minions() -> void:
	var count := randi_range(minion_count_min, minion_count_max)
	for index in range(count):
		var minion := _spawn_minion(_minion_configs[randi() % maxi(_minion_configs.size(), 1)] if not _minion_configs.is_empty() else null)
		if minion == null:
			continue
		var cell := _random_walkable_cell_near(global_position, landing_spread_cells)
		_throw_enemy(minion, _cell_center(cell), throw_duration + 0.08 * float(index), false)
		thrown_minions += 1
	print("[Boss] 抛出 %d 只小怪（累计 %d）" % [count, thrown_minions])


## 技能 B：抛出 1 只自爆怪，落点 = Boss 停止移动时锁定的玩家位置，落地立即引爆
func _throw_bomb() -> void:
	var bomb := _spawn_minion(BombConfig)
	if bomb == null:
		return
	var landing := _snap_to_walkable(_locked_target)
	_throw_enemy(bomb, landing, bomb_throw_duration, true)
	thrown_bombs += 1
	print("[Boss] 抛出自爆怪 → 落点 %s（累计 %d）" % [str(landing.round()), thrown_bombs])


func _spawn_minion(config: EnemyConfig) -> Enemy:
	if config == null:
		return null
	var parent := get_parent()
	if parent == null:
		return null
	var minion := MinionScene.instantiate() as Enemy
	if minion == null:
		return null
	parent.add_child(minion)
	minion.global_position = global_position
	minion.setup(config, target_player)
	minion.set_airborne(true)                 # 空中：暂停 AI、不吃接触伤害、画在 Boss 之上
	return minion


## 抛物线投掷：start 到 target（中间抬高 throw_height），落地后交还 AI 或就地引爆
func _throw_enemy(node: Enemy, target_position: Vector2, duration: float, detonate_on_land: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	var start := node.global_position
	var tween := node.create_tween()
	tween.tween_method(_interpolate_throw.bind(node, start, target_position), 0.0, 1.0, duration)
	tween.tween_callback(_on_throw_finished.bind(node, target_position, detonate_on_land))


## 抛物线插值（Callable.bind 会把 node/start/target 追加到 progress 之后）
func _interpolate_throw(progress: float, node: Enemy, start: Vector2, target_position: Vector2) -> void:
	if not is_instance_valid(node):
		return
	var point := start.lerp(target_position, progress)
	point.y -= sin(progress * PI) * throw_height
	node.global_position = point


## 落地回调：自爆怪就地引爆；普通小怪恢复 AI（就是普通敌人了）
func _on_throw_finished(node: Enemy, target_position: Vector2, detonate_on_land: bool) -> void:
	if not is_instance_valid(node):
		return
	node.global_position = target_position
	if detonate_on_land:
		node.explode_now()
		print("[Boss自检] 自爆怪已在落点引爆（%s）" % str(target_position.round()))
	else:
		node.set_airborne(false)
		print("[Boss自检] 小怪落地并恢复 AI（%s，落点可通行=%s）" % [
			str(target_position.round()), str(_is_walkable(_world_to_cell(target_position)))])


func _enter_recover() -> void:
	_state = State.RECOVER
	_recover_left = recover_duration
	_set_flash(0.0)


# ---------------- 网格工具（落点必须落在可通行格上） ----------------

func _world_to_cell(position_world: Vector2) -> Vector2i:
	return Vector2i(int(floor(position_world.x / TILE)), int(floor(position_world.y / TILE)))


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5)


func _is_walkable(cell: Vector2i) -> bool:
	if _grid.is_empty():
		return true
	if cell.x <= 0 or cell.y <= 0 or cell.x >= _grid_width - 1 or cell.y >= _grid_height - 1:
		return false
	return int(_grid[cell.y * _grid_width + cell.x]) == CELL_FLOOR


func _random_walkable_cell_near(target: Vector2, spread_cells: int) -> Vector2i:
	var base := _world_to_cell(target)
	if _grid.is_empty():
		return base
	for _attempt in range(24):
		var cell := base + Vector2i(
			randi_range(-spread_cells, spread_cells), randi_range(-spread_cells, spread_cells))
		if _is_walkable(cell):
			return cell
	return base


## 把世界坐标吸附到可通行格中心（玩家可能站在墙边，落点要回到地上）
func _snap_to_walkable(position_world: Vector2) -> Vector2:
	var base := _world_to_cell(position_world)
	if _is_walkable(base):
		return _cell_center(base)          # 优先精确落在锁定位置本身
	return _cell_center(_random_walkable_cell_near(position_world, 1))


# ---------------- 显示（shader）与收尾 ----------------

func _setup_glow() -> void:
	var material := ShaderMaterial.new()
	material.shader = BossGlowShader
	animated_sprite.material = material
	_glow_material = material
	_set_flash(0.0)


func _set_flash(value: float) -> void:
	if _glow_material != null:
		_glow_material.set_shader_parameter("flash_amount", clampf(value, 0.0, 1.0))


func _clear_telegraphs() -> void:
	for sprite in _telegraphs:
		if is_instance_valid(sprite):
			sprite.queue_free()
	_telegraphs.clear()


func _on_died() -> void:
	_clear_telegraphs()
	_set_flash(0.0)
	print("[Boss] 已被击败（抛出小怪 %d 只 / 自爆怪 %d 只 / 冲撞 %d 次）" % [
		thrown_minions, thrown_bombs, charge_count])
	boss_defeated.emit()


## 自检用：一行摘要
func debug_summary() -> String:
	return "phase=P%d state=%d minions=%d bombs=%d charges=%d hp=%d" % [
		_phase + 1, _state, thrown_minions, thrown_bombs, charge_count, current_health]
