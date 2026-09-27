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
@export var skill_interval_p1: float = 8.0
@export var skill_interval_p3: float = 5.5
@export var telegraph_time: float = 0.7
@export var recover_duration: float = 0.8
## 阶段切换黄闪的持续时间（秒）
@export var phase_flash_duration: float = 0.5

@export_group("技能参数")
@export var minion_count_min: int = 3
@export var minion_count_max: int = 5
@export var throw_duration: float = 0.6
@export var throw_height: float = 34.0
@export var bomb_throw_duration: float = 0.75
@export var charge_speed: float = 240.0
## 冲刺预警时间（比其他技能短：闪一次黄光就冲）
@export var charge_telegraph_time: float = 0.45

@export_group("冲刺触发（独立于技能池，始终可用）")
## 开局多少秒后才允许冲刺
@export var charge_unlock_delay: float = 5.0
## 玩家进入这个格数范围内就会触发冲刺（5 格 = 80 像素）
@export var charge_trigger_cells: float = 5.0
## 冲刺冷却（秒），避免连续冲个不停
@export var charge_cooldown: float = 5.0
@export var charge_duration: float = 1.1
@export var landing_spread_cells: int = 6
@export var sprite_scale: float = 2.0
## 红色外圈半径（世界像素；Boss 本体碰撞半径 16）
@export var outline_radius: float = 21.0
## 红色外圈线宽（世界像素，技能预警时会变粗）
@export var outline_width: float = 1.5
## 抛小怪的独立冷却（比其它技能长得多，避免场上小怪堆积 —— 用户反馈召唤太频繁）
@export var summon_cooldown: float = 14.0
## 场上小怪（不含 Boss）超过这个数量就不再抛
@export var max_alive_minions: int = 6
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
var _outline_ring: Line2D = null
var _outline_ring_outer: Line2D = null
var _summon_cooldown_left := 0.0
var _invulnerable := false
var _elapsed := 0.0
var _charge_cooldown_left := 0.0
var _phase_flash_left := 0.0
var _minion_configs: Array[EnemyConfig] = []
var _telegraphs: Array[Node2D] = []

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
	_setup_outline()
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
		_elapsed += delta
	_charge_cooldown_left = maxf(_charge_cooldown_left - delta, 0.0)
	_skill_timer -= delta
	if debug_fast_skills:
		_summon_cooldown_left = maxf(_summon_cooldown_left - delta * 4.0, 0.0)
	else:
		_summon_cooldown_left = maxf(_summon_cooldown_left - delta, 0.0)

	# 只有追击/冲撞时才让父类的 AI 驱动移动；预警与硬直期间调用 set_ai_suspended
	set_ai_suspended(_state != State.CHASE and _state != State.CHARGE)

	if _phase_flash_left > 0.0:                            # 阶段切换的短脉冲
		_phase_flash_left = maxf(_phase_flash_left - delta, 0.0)
		if _state != State.TELEGRAPH:
			_set_flash(_phase_flash_left / maxf(phase_flash_duration, 0.01))
			if _phase_flash_left <= 0.0:
				_set_flash(0.0)

	if _state == State.TELEGRAPH:
		_telegraph_left -= delta
		if _pending_skill == "charge":
			_set_flash(1.0)                                # 冲刺：稳定黄光，不脉冲
			_set_outline_intensity(1.0)
		else:
			var pulse := absf(sin(_telegraph_left * 16.0))
			_set_flash(pulse)                              # 其它技能：黄闪脉冲
			_set_outline_intensity(pulse)
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
	elif _state == State.CHASE and not is_dead:
		if _should_start_charge():
			_begin_charge()          # 冲刺优先：满足条件就冲
		elif _skill_timer <= 0.0:
			_begin_skill()

	super._physics_process(delta)


## 冲刺期间免疫伤害（用户要求：闪光结束到冲刺结束之间不掉血）
func apply_damage(amount: int) -> bool:
	if _invulnerable:
		return false
	return super.apply_damage(amount)


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
	_phase_flash_left = phase_flash_duration           # 短脉冲：不能一直亮着（原来卡在 1.0 = 黄闪时间过长）
	_skill_timer = minf(_skill_timer, 1.0)
	print("[Boss] 进入阶段 P%d（血量 %.0f%%）" % [_phase + 1, ratio * 100.0])


func _current_skill_interval() -> float:
	var base := skill_interval_p3 if _phase == Phase.P3 else skill_interval_p1
	return base / 4.0 if debug_fast_skills else base


## 冲刺触发判定：开局满 charge_unlock_delay 秒 + 玩家进入 charge_trigger_cells 格 + 冷却结束
func _should_start_charge() -> bool:
	if _charge_cooldown_left > 0.0 or _elapsed < charge_unlock_delay:
		return false
	if not is_instance_valid(target_player) or target_player.is_dead:
		return false
	return global_position.distance_to(target_player.global_position) <= charge_trigger_cells * TILE


func _begin_charge() -> void:
	_pending_skill = "charge"
	_locked_target = target_player.global_position
	_state = State.TELEGRAPH
	_telegraph_left = charge_telegraph_time
	_clear_telegraphs()
	_show_charge_telegraph()
	_set_flash(1.0)                       # 闪一次稳定黄光
	_set_outline_intensity(1.0)
	boss_skill.emit("charge", _locked_target)


## 冲刺预警：一个长方形红色区域（从 Boss 指向锁定目标，长度=冲刺距离，宽度=2 格）
func _show_charge_telegraph() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var direction := _locked_target - global_position
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	var length := charge_speed * charge_duration + 24.0
	var half_width := TILE                                   # 宽度 2 格
	var corners := PackedVector2Array([
		Vector2(0.0, -half_width), Vector2(length, -half_width),
		Vector2(length, half_width), Vector2(0.0, half_width)])
	var area := Node2D.new()
	area.name = "ChargeTelegraph"
	area.global_position = global_position
	area.rotation = direction.angle()
	area.z_index = 1                                          # 高于地砖(0)，否则会被地面挡住
	parent.add_child(area)
	var fill := Polygon2D.new()
	fill.polygon = corners
	fill.color = Color(1.0, 0.15, 0.15, 0.28)
	area.add_child(fill)
	var edge := Line2D.new()
	edge.points = corners
	edge.closed = true
	edge.width = 1.5
	edge.default_color = Color(1.0, 0.3, 0.2, 0.9)
	area.add_child(edge)
	_telegraphs.append(area)
	# 预警期间从淡到浓，提示玩家"这条道要冲了"
	fill.color = Color(1.0, 0.15, 0.15, 0.12)
	var tween := area.create_tween()
	tween.tween_property(fill, "color", Color(1.0, 0.15, 0.15, 0.38), charge_telegraph_time)


func _begin_skill() -> void:
	_skill_timer = _current_skill_interval()
	var next_skill := _pick_skill()
	if next_skill.is_empty():
		_skill_timer = 1.5            # 所有技能都在冷却中：稍后再试
		return
	_pending_skill = next_skill
	# 锁定"此刻"玩家位置：扔自爆怪/冲撞都以它为落点（Boss 停止移动时的位置）
	_locked_target = target_player.global_position if is_instance_valid(target_player) else global_position
	_state = State.TELEGRAPH
	# 冲刺用更短预警（闪一次黄光就冲），其它技能用标准预警
	_telegraph_left = minf(telegraph_time, charge_telegraph_time) if _pending_skill == "charge" else telegraph_time
	_show_telegraph(next_skill)
	boss_skill.emit(next_skill, _locked_target)


func _pick_skill() -> String:
	var pool: Array[String] = []
	# 抛小怪：独立冷却 + 场上小怪上限（避免小怪越堆越多）
	if _summon_cooldown_left <= 0.0 and _count_alive_minions() < max_alive_minions:
		pool.append("minions")
	if _phase >= Phase.P2:
		pool.append("bomb")
	# 冲刺不再进随机池：改成"开局 N 秒后玩家靠近就冲"（见 _should_start_charge）
	if pool.is_empty():
		# 抛小怪在冷却时不能空着（否则 P1 会长时间不出手）—— 用扔自爆怪顶上
		return "bomb" if _phase < Phase.P2 else "charge"
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
	# charge 的预警是长方形区域，由 _show_charge_telegraph() 单独画


func _spawn_telegraph(position_world: Vector2, radius_px: float) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var sprite := Sprite2D.new()
	sprite.texture = TelegraphTexture
	sprite.global_position = position_world
	sprite.z_index = 1                                  # 必须 >=1：地砖 z=0，设 -1 会被地面挡住（落点圈看不清的根因）
	sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)          # 不透明，保证看得清
	var final_scale := (radius_px / 64.0) * 1.5          # 贴图半径 64px（128x128）：上一版放太大，收回来
	sprite.scale = Vector2.ONE * final_scale * 0.65
	parent.add_child(sprite)
	_telegraphs.append(sprite)
	var tween := sprite.create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "scale", Vector2.ONE * final_scale, telegraph_time)
	tween.tween_property(sprite, "modulate:a", 0.55, telegraph_time)


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
		_charge_cooldown_left = charge_cooldown
		_state = State.CHARGE
		_charge_left = charge_duration
		_invulnerable = true                               # 冲刺全程免伤（用户要求）
		_set_flash(1.0)
		_set_outline_intensity(1.0)
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
	_summon_cooldown_left = summon_cooldown / (4.0 if debug_fast_skills else 1.0)
	print("[Boss] 抛出 %d 只小怪（累计 %d，下次召唤冷却 %.0f 秒）" % [count, thrown_minions, _summon_cooldown_left])


## 技能 B：抛出 1 只自爆怪，落点 = Boss 停止移动时锁定的玩家位置，落地立即引爆。
## ⚠️ 注意：自爆怪的爆炸会伤害"玩家和敌人"，所以 **Boss 也会被自己的自爆怪炸到**。
##    这是**有意的设计**（已与用户确认）：玩家可以把 Boss 的投掷物当作对 Boss 的输出手段。
func _throw_bomb() -> void:
	var bomb := _spawn_minion(BombConfig)
	if bomb == null:
		return
	var landing := _snap_to_walkable(_locked_target)
	_throw_enemy(bomb, landing, bomb_throw_duration, true)
	thrown_bombs += 1
	print("[Boss] 抛出自爆怪 → 落点 %s（累计 %d）" % [str(landing.round()), thrown_bombs])


func _spawn_minion(minion_config: EnemyConfig) -> Enemy:
	if minion_config == null:
		return null
	var parent := get_parent()
	if parent == null:
		return null
	var minion := MinionScene.instantiate() as Enemy
	if minion == null:
		return null
	parent.add_child(minion)
	minion.global_position = global_position
	minion.setup(minion_config, target_player)
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
	_invulnerable = false                              # 冲刺结束，恢复可被打
	_set_flash(0.0)
	_set_outline_intensity(0.0)


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

## 红色外描边：两层很细的红环（内环稍亮 + 外环很淡）当柔光，比单圈粗红圈好看得多。
## 预警时会一起变亮变粗（见 _set_outline_intensity）。
func _setup_outline() -> void:
	_outline_ring = _make_ring("BossRingInner", outline_radius, outline_width, Color(1.0, 0.15, 0.15, 0.5))
	_outline_ring_outer = _make_ring("BossRingOuter", outline_radius + 3.5, outline_width * 2.2, Color(1.0, 0.2, 0.2, 0.16))


func _make_ring(ring_name: String, radius: float, width: float, color: Color) -> Line2D:
	var ring := Line2D.new()
	ring.name = ring_name
	ring.width = width
	ring.default_color = color
	ring.closed = true
	ring.antialiased = false
	ring.z_index = 2                 # 高于地砖(0)与普通敌人(0)
	ring.z_as_relative = true
	var points := PackedVector2Array()
	for index in range(28):
		var angle := TAU * float(index) / 28.0
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	ring.points = points
	add_child(ring)
	return ring


## 预警期间：两层环一起变亮变粗，给玩家明确的出手信号
func _set_outline_intensity(value: float) -> void:
	if _outline_ring == null or not is_instance_valid(_outline_ring):
		return
	_outline_ring.width = outline_width * (1.0 + value * 1.4)
	_outline_ring.default_color = Color(1.0, 0.15 + value * 0.6, 0.1, 0.5 + value * 0.45)
	if _outline_ring_outer != null and is_instance_valid(_outline_ring_outer):
		_outline_ring_outer.width = outline_width * 2.2 * (1.0 + value * 1.2)
		_outline_ring_outer.default_color = Color(1.0, 0.2 + value * 0.6, 0.1, 0.16 + value * 0.35)


func _setup_glow() -> void:
	var glow_material := ShaderMaterial.new()
	glow_material.shader = BossGlowShader
	animated_sprite.material = glow_material
	_glow_material = glow_material
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

## 场上还活着的小怪数量（不含 Boss 自己）
func _count_alive_minions() -> int:
	var parent := get_parent()
	if parent == null:
		return 0
	var count := 0
	for child in parent.get_children():
		if child is Enemy and child != self and not (child as Enemy).is_dead:
			count += 1
	return count
