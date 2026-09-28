extends CharacterBody2D
## 队友（商店道具"雇佣队友"）：只在本关存在，3 点血，会被敌人打死。
##
## 两种 AI 状态（玩家按 T 切换，默认自主攻击）：
##   attack 自主攻击：自己去找敌人打（保持距离边打边退），顺路捡道具，绕开贴脸的敌人
##   guard  保护    ：在玩家周围随机游走，只打身边看得见的敌人；离玩家太远会自动跑回来
##
## 行为要点：
##   - 两种状态下都会"躲敌人"（附近敌人给一个斥力，不让它贴脸硬吃接触伤害）
##   - 只打"视线没被墙挡住"的敌人（隔着墙开枪等于把子弹送给墙）
##   - 道具只作用于队友自己（用户选择）；玩家的形态/弹幕类道具它用不了 -> 不捡也不消耗
##   - 走位用 EnemyPathfinder 算路，被墙挡住时绕路
## 注意：这里**故意不写 class_name**（全局类缓存要编辑器扫描，直接跑游戏时是空的）

const BULLET_SCENE := preload("res://scene/bullet.tscn")

const STATE_ATTACK := "attack"
const STATE_GUARD := "guard"

const MAX_HEALTH := 3
const FIRE_RATE_MULTIPLIER := 0.7        ## 射速打七折 -> 开火间隔 = 玩家间隔 / 0.7
const MOVE_SPEED := 120.0
const WAYPOINT_REACHED_DISTANCE := 10.0
const REPATH_INTERVAL := 0.3

## 保护状态
const GUARD_RADIUS := 56.0
const GUARD_REPICK_INTERVAL := 1.1
const GUARD_RETURN_DISTANCE := 96.0
const GUARD_FIRE_RANGE := 130.0

## 自主攻击状态
const ATTACK_FIRE_RANGE := 210.0
const KEEP_DISTANCE := 78.0
const APPROACH_DISTANCE := 150.0

## 通用
const AVOID_RADIUS := 46.0
const AVOID_STRENGTH := 2.2
const PICKUP_SEEK_RANGE := 240.0
const BULLET_SPAWN_DISTANCE := 16.0
const WORLD_COLLISION_MASK := 1

signal died
signal health_changed(current: int, maximum: int)
signal state_changed(state: String)

var state := STATE_ATTACK
var current_health: int = MAX_HEALTH
var is_dead := false
var damage := 1
var fire_interval := 0.18

var _player: Node2D = null
var _enemy_container: Node = null
var _pathfinder = null
var _path := PackedVector2Array()
var _goal := Vector2.ZERO
var _repath_left := 0.0
var _fire_cooldown := 0.0
var _guard_point := Vector2.ZERO
var _guard_repick_left := 0.0
var _speed_buff_mult := 1.0
var _speed_buff_left := 0.0
var _fire_buff_mult := 1.0
var _fire_buff_left := 0.0
var _blink_tween: Tween = null

@onready var _sprite: AnimatedSprite2D = $BodySprite


func setup(player_node: Node2D, frames: SpriteFrames, player_damage: int,
		player_fire_interval: float, enemy_container: Node) -> void:
	_player = player_node
	_enemy_container = enemy_container
	damage = maxi(player_damage, 1)
	fire_interval = maxf(player_fire_interval / FIRE_RATE_MULTIPLIER, 0.05)
	if frames != null:
		_sprite.sprite_frames = frames
		var names := frames.get_animation_names()
		if names.size() > 0:
			_sprite.animation = names[0]
		_sprite.play()
	if player_node != null:
		global_position = player_node.global_position + Vector2(22.0, 0.0)


func _ready() -> void:
	add_to_group("ally")
	collision_layer = 2          # 和玩家同层：敌人的接触伤害/爆炸能打到它
	collision_mask = WORLD_COLLISION_MASK
	health_changed.emit(current_health, MAX_HEALTH)


## 玩家按 T 切换；从自主攻击切回保护会自己跑回玩家身边
func toggle_state() -> void:
	set_state(STATE_GUARD if state == STATE_ATTACK else STATE_ATTACK)


func set_state(new_state: String) -> void:
	if is_dead or new_state == state:
		return
	state = new_state
	_path = PackedVector2Array()
	_repath_left = 0.0
	_guard_repick_left = 0.0
	state_changed.emit(state)
	print("[Ally] 切换状态 -> %s" % state_name())


func state_name() -> String:
	return "保护" if state == STATE_GUARD else "自主攻击"


func _unhandled_input(event: InputEvent) -> void:
	if is_dead:
		return
	if event.is_action_pressed("switch_ally"):
		toggle_state()
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if _player == null or not is_instance_valid(_player) or _player.get("is_dead"):
		velocity = Vector2.ZERO
		move_and_slide()
		return
	_update_buffs(delta)
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_goal = _pick_goal(delta)
	_move_towards(_goal, delta)
	_try_fire()


## 当前该往哪走
func _pick_goal(delta: float) -> Vector2:
	if state == STATE_GUARD:
		return _guard_goal(delta)
	# 自主攻击：先捡能用的道具，再找敌人（保持距离），没目标就回玩家附近待命
	var pickup := _nearest_usable_pickup()
	if pickup != null:
		return pickup.global_position
	var enemy := _nearest_visible_enemy(ATTACK_FIRE_RANGE)
	if enemy == null:
		return _guard_goal(delta)
	var distance := global_position.distance_to(enemy.global_position)
	var to_enemy := global_position.direction_to(enemy.global_position)
	if distance > APPROACH_DISTANCE:
		return enemy.global_position                       # 太远 -> 靠近
	if distance < KEEP_DISTANCE:
		return global_position - to_enemy * 60.0           # 太近 -> 后退（躲）
	return global_position + to_enemy.rotated(PI * 0.5) * 40.0   # 距离合适 -> 横向游走


func _guard_goal(delta: float) -> Vector2:
	var to_player := _player.global_position - global_position
	if to_player.length() > GUARD_RETURN_DISTANCE:
		return _player.global_position                     # 离太远 -> 直接跑回去
	_guard_repick_left = maxf(_guard_repick_left - delta, 0.0)
	if _guard_repick_left <= 0.0 or global_position.distance_to(_guard_point) < 8.0:
		_guard_repick_left = GUARD_REPICK_INTERVAL
		var angle := randf() * TAU
		_guard_point = _player.global_position + Vector2(cos(angle), sin(angle)) * randf_range(12.0, GUARD_RADIUS)
	return _guard_point


## 朝目标走：有墙就用寻路器绕，没墙走直线；附近有敌人额外加一个斥力躲开
func _move_towards(goal: Vector2, delta: float) -> void:
	var direction := _path_direction(goal, delta)
	direction += _avoid_enemies()
	if direction.length() < 0.05:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	direction = direction.normalized()
	velocity = direction * (MOVE_SPEED * _speed_buff_mult)
	move_and_slide()
	_sprite.flip_h = direction.x < 0.0


func _path_direction(goal: Vector2, delta: float) -> Vector2:
	var tree := get_tree()
	if tree != null:
		_pathfinder = tree.get_first_node_in_group(EnemyPathfinder.PATHFINDER_GROUP)
	_repath_left = maxf(_repath_left - delta, 0.0)
	if _repath_left <= 0.0 and _pathfinder != null and _pathfinder.is_usable():
		_repath_left = REPATH_INTERVAL
		if _pathfinder.has_line_of_sight(global_position, goal):
			_path = PackedVector2Array()
		else:
			_path = _pathfinder.find_path(global_position, goal)
	if _path.is_empty():
		return global_position.direction_to(goal)
	# 丢掉已经到达的路点，最后一个点永远留着
	while _path.size() > 1 and global_position.distance_to(_path[0]) <= WAYPOINT_REACHED_DISTANCE:
		_path.remove_at(0)
	if _path.size() <= 1:
		return global_position.direction_to(goal)
	return global_position.direction_to(_path[0])


## 附近敌人给的斥力（贴脸会吃接触伤害，所以主动散开）
func _avoid_enemies() -> Vector2:
	if _enemy_container == null or not is_instance_valid(_enemy_container):
		return Vector2.ZERO
	var repel := Vector2.ZERO
	for child in _enemy_container.get_children():
		var enemy := child as Node2D
		if enemy == null or enemy.get("is_dead"):
			continue
		var away := global_position - enemy.global_position
		var distance := away.length()
		if distance <= 0.01 or distance > AVOID_RADIUS:
			continue
		repel += away.normalized() * (1.0 - distance / AVOID_RADIUS) * AVOID_STRENGTH
	return repel


func _try_fire() -> void:
	if _fire_cooldown > 0.0:
		return
	var range_limit := GUARD_FIRE_RANGE if state == STATE_GUARD else ATTACK_FIRE_RANGE
	var target := _nearest_visible_enemy(range_limit)
	if target == null:
		return
	var direction := global_position.direction_to(target.global_position)
	if direction == Vector2.ZERO:
		return
	_fire_cooldown = fire_interval / maxf(_fire_buff_mult, 0.01)
	_fire(direction)


func _nearest_visible_enemy(max_range: float) -> Node2D:
	if _enemy_container == null or not is_instance_valid(_enemy_container):
		return null
	var best: Node2D = null
	var best_distance := max_range
	for child in _enemy_container.get_children():
		var enemy := child as Node2D
		if enemy == null or enemy.get("is_dead"):
			continue
		if not child.has_method("apply_damage"):
			continue                     # 只打敌人：掉落物也挂在 EnemyContainer 下面
		var distance := global_position.distance_to(enemy.global_position)
		if distance >= best_distance:
			continue
		if not _has_line_of_sight(enemy.global_position):
			continue
		best_distance = distance
		best = enemy
	return best


## 只捡"队友能用"的道具：玩家的形态/弹幕类道具它用不了，留给玩家
func _nearest_usable_pickup() -> Node2D:
	var tree := get_tree()
	if tree == null:
		return null
	var best: Node2D = null
	var best_distance := PICKUP_SEEK_RANGE
	for node in tree.get_nodes_in_group("pickup"):
		var pickup := node as Node2D
		if pickup == null or not _pickup_is_usable(pickup):
			continue
		var distance := global_position.distance_to(pickup.global_position)
		if distance >= best_distance:
			continue
		if not _has_line_of_sight(pickup.global_position):
			continue
		best_distance = distance
		best = pickup
	return best


func _pickup_is_usable(pickup: Node2D) -> bool:
	var config = pickup.get("config")
	if config == null:
		return false
	if config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL:
		return false
	if config.shot_pattern != PickupConfig.ShotPattern.NORMAL:
		return false
	return true


func _has_line_of_sight(target_position: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return true
	var query := PhysicsRayQueryParameters2D.create(global_position, target_position, WORLD_COLLISION_MASK)
	query.exclude = [get_rid()]
	return space.intersect_ray(query).is_empty()


func _fire(direction: Vector2) -> void:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		return
	bullet.top_level = true
	bullet.damage = damage
	bullet.setup(direction)
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		return
	spawn_parent.add_child(bullet)
	bullet.global_position = global_position + direction * BULLET_SPAWN_DISTANCE
	_sprite.flip_h = direction.x < 0.0


## 队友吃道具：只加在它自己身上（用户选择）
func apply_pickup(config) -> bool:
	if config == null or is_dead:
		return false
	# 形态/弹幕类（螺旋弹等）队友用不了，留给玩家：不吃也不消耗
	if config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL:
		return false
	if config.shot_pattern != PickupConfig.ShotPattern.NORMAL:
		return false
	var applied := false
	if not is_equal_approx(config.move_speed_multiplier, 1.0):
		_speed_buff_mult = config.move_speed_multiplier
		_speed_buff_left = maxf(config.duration, 0.0)
		applied = true
	if not is_equal_approx(config.fire_rate_multiplier, 1.0):
		_fire_buff_mult = config.fire_rate_multiplier
		_fire_buff_left = maxf(config.duration, 0.0)
		applied = true
	if applied:
		print("[Ally] 吃到道具 %s: 移速 x%.2f 射速 x%.2f（%.0f 秒）" % [
			String(config.display_name), _speed_buff_mult, _fire_buff_mult, maxf(config.duration, 0.0)])
	return applied


func _update_buffs(delta: float) -> void:
	if _speed_buff_left > 0.0:
		_speed_buff_left = maxf(_speed_buff_left - delta, 0.0)
		if _speed_buff_left <= 0.0:
			_speed_buff_mult = 1.0
	if _fire_buff_left > 0.0:
		_fire_buff_left = maxf(_fire_buff_left - delta, 0.0)
		if _fire_buff_left <= 0.0:
			_fire_buff_mult = 1.0


func apply_damage(amount: int) -> bool:
	if is_dead or amount <= 0:
		return false
	current_health -= amount
	health_changed.emit(maxi(current_health, 0), MAX_HEALTH)
	_play_hit_feedback()
	if current_health <= 0:
		_die()
		return true
	return true


func _die() -> void:
	if is_dead:
		return
	is_dead = true
	velocity = Vector2.ZERO
	died.emit()
	print("[Ally] 队友被击倒")
	queue_free()


func _play_hit_feedback() -> void:
	if _sprite == null:
		return
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	_sprite.modulate = Color(1.0, 0.45, 0.45)
	_blink_tween = create_tween()
	_blink_tween.tween_property(_sprite, "modulate", Color.WHITE, 0.25)


# ---------------- 供 headless 自检调用 ----------------

func debug_goal() -> Vector2:
	return _goal


func debug_set_guard_point(point: Vector2) -> void:
	_guard_point = point
	_guard_repick_left = 999.0
