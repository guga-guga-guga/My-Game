extends "res://scene/entities/bosses/boss_enemy.gd"
## 普通 BOSS（第 5 / 10 / 15 层的常规 BOSS）
##
## 两套状态机：
##   阶段机（基类）：血量 66% / 33% -> P2 / P3，切阶段闪黄光、技能更快、移速 x1.5
##   行为机（本文件）：CHASE 追人 -> TELEGRAPH 预警 -> CHARGE 冲撞 / RECOVER 硬直
## 技能：扔小怪、扔炸弹（抛物线 + 落点预警，会炸到自己）、玩家靠近就冲撞（冲撞期间免疫伤害）

const MinionScene := preload("res://scene/entities/enemies/enemy.tscn")

const BombConfig := preload("res://resources/config/enemy_bomber.tres")

enum State { CHASE, TELEGRAPH, CHARGE, RECOVER }

@export_group("技能节奏")

@export var skill_interval_p1: float = 8.0

@export var skill_interval_p3: float = 5.5

@export var recover_duration: float = 0.8

@export_group("技能参数")

@export var minion_count_min: int = 4

@export var minion_count_max: int = 7

@export var throw_duration: float = 0.6

@export var throw_height: float = 34.0

@export var bomb_throw_duration: float = 0.75

@export var charge_speed: float = 240.0

@export_group("冲刺触发（独立于技能池，始终可用）")

## 冲刺预警时间（比其他技能短：闪一次黄光就冲）
@export var charge_telegraph_time: float = 0.45

## 开局多少秒后才允许冲刺
@export var charge_unlock_delay: float = 5.0

## 玩家进入这个格数范围内就会触发冲刺（5 格 = 80 像素）
@export var charge_trigger_cells: float = 5.0

## 冲刺冷却（秒），避免连续冲个不停
@export var charge_cooldown: float = 5.0

@export var charge_duration: float = 1.1

@export var landing_spread_cells: int = 6

## 抛小怪的独立冷却（比其它技能长得多，避免场上小怪堆积 —— 用户反馈召唤太频繁）
@export var summon_cooldown: float = 14.0

## 场上普通敌人上限（由 battle 按关卡设置，默认与 boss_level_normal_enemy_cap 一致）：
## 红门刷的 + 抛出的都算，BOSS/紫 BOSS 不占名额（用户要求）。
## 技能可用条件：场上普通敌人 <= max_alive_minions - 1（没到 20 就能抛）；
## 抛出后可以临时超过这个上限（用户确认：先允许超，再靠玩家清场压回去）。
@export var max_alive_minions: int = 20

var _state: int = State.CHASE

var _telegraph_left: float = 0.0

var _charge_left: float = 0.0

var _recover_left: float = 0.0

var _pending_skill := ""

var _locked_target := Vector2.ZERO

var _charge_direction := Vector2.ZERO

var _summon_cooldown_left := 0.0

var _charge_cooldown_left := 0.0

var _minion_configs: Array[EnemyConfig] = []

var charge_count := 0

func _get_move_direction() -> Vector2:
	if _state == State.CHARGE:
		return _charge_direction
	return super._get_move_direction()

func _collect_minion_configs() -> void:
	for path in [
		"res://resources/config/enemy_basic.tres",
		"res://resources/config/enemy_fast.tres",
		"res://resources/config/enemy_shelled.tres",
	]:
		var cfg := load(path) as EnemyConfig
		if cfg != null:
			_minion_configs.append(cfg)

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
	# 抛小怪：冷却好了 + 场上普通敌人没到上限（<= max_alive_minions - 1，即 <=19）
	# 就可以抛；抛出后允许临时超过上限（用户确认）
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

## 技能 A：抛出 4~7 只普通敌人，落到附近的"可通行格"（数量由 minion_count_min/max 控制）
## 数量不压缩：冷却好了且释放时场上 <=19，就一定抛满 4~7 只（允许临时超过 20 上限）
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


# ============================ 生命周期 ============================

func _ready() -> void:
	super._ready()
	_collect_minion_configs()
	_skill_timer = _current_skill_interval()


## 每个物理帧的行为机（移动与阶段机由基类负责）
func _boss_update(delta: float) -> void:
	if debug_fast_skills:
		_skill_timer -= delta * 4.0
		_summon_cooldown_left = maxf(_summon_cooldown_left - delta * 4.0, 0.0)
	else:
		_skill_timer -= delta
		_summon_cooldown_left = maxf(_summon_cooldown_left - delta, 0.0)
	_charge_cooldown_left = maxf(_charge_cooldown_left - delta, 0.0)

	# 只有追击 / 冲撞时才让敌人的 AI 驱动移动；预警与硬直期间挂起
	set_ai_suspended(_state != State.CHASE and _state != State.CHARGE)

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


## 预警期自己接管闪烁，阶段黄闪不插手
func _can_flash_phase() -> bool:
	return _state != State.TELEGRAPH


func _get_move_speed() -> float:
	if _state == State.CHARGE:
		return charge_speed
	return super._get_move_speed()


## 自检用：一行摘要
func debug_summary() -> String:
	return "kind=normal phase=P%d state=%d minions=%d bombs=%d charges=%d hp=%d" % [
		_phase + 1, _state, thrown_minions, thrown_bombs, charge_count, current_health]
