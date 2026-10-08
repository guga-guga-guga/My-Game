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

## 队友用自己的移动方向切动画（和玩家那套一模一样的四向动画，只是各播各的）
## 玩家动画名: normal_down / normal_left / normal_right / normal_up（armed_* 是螺旋弹形态，队友用不了）
const ANIMATION_PREFIX := &"normal"
const WALK_ANIMATION_THRESHOLD := 8.0

const STATE_ATTACK := "attack"
const STATE_GUARD := "guard"

const MAX_HEALTH := 3
## 受击后的无敌时间（和玩家基础无敌一致）。没有它的话，被两三只敌人/子弹同时命中就瞬间清空 3 点血，
## 表现成"队友只能活一层"（用户反馈的问题）
const HURT_INVINCIBILITY := 1.5
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
## 自主攻击时的"搜索半径"：比开火距离大得多，会主动上门找敌人（看不到也敢去，靠寻路绕墙）
const ATTACK_SEEK_RANGE := 420.0
## 站位迟滞（用户要求）：进入/退出用不同阈值，避免在单条边界上反复切"靠近/横走/后退"
const APPROACH_ENTER := 160.0         ## 比这远 -> 靠近
const APPROACH_EXIT := 130.0          ## 靠近中，近到这就改成横走
const RETREAT_ENTER := 70.0           ## 比这近 -> 后退
const RETREAT_EXIT := 100.0           ## 后退中，远到这就改成横走
const STRAFE_DISTANCE := 40.0         ## 横走时离敌人的侧向偏移
const STRAFE_HOLD_TIME := 1.2         ## 绕圈方向保持多久才考虑换边
## 目标锁定（用户要求）：选中后锁一段时间，只有新目标明显更近才换，治"目标/动画来回抖"
const TARGET_LOCK_TIME := 1.0
const TARGET_SWITCH_RATIO := 0.7      ## 新目标距离 < 旧目标 * 0.7（近 30%）才换
## 动画防抖（用户要求）：新朝向连续保持这么久才真的切，避免方向在 45° 分界处乱跳
const FACING_DEBOUNCE := 0.12

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
var _hurt_invincibility_left := 0.0
var damage := 1
var fire_interval := 0.18

var _player: Node2D = null
var _player_sprite: AnimatedSprite2D = null
var _facing_suffix := &"down"          ## 没在动时保持最后一次朝向
var _pending_facing := &"down"         ## 动画防抖：候选朝向
var _pending_facing_left := 0.0        ## 动画防抖：候选朝向还要保持多久
var _chase_target: Node2D = null       ## 锁定的追击目标（走路用，不是开火目标）
var _target_lock_left := 0.0           ## 目标还要锁多久
var _stance := "strafe"                ## 站位：approach / strafe / retreat
var _strafe_sign := 1.0                ## 绕圈方向（正/负）
var _strafe_left := 0.0                ## 绕圈方向还要保持多久
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


## player_sprite: 玩家的 AnimatedSprite2D（BodySprite）。队友共用它的 SpriteFrames，
## 并每帧镜像"动画名 + 当前帧 + 缩放"，所以 idle/walk/形态变化都和本体一致。
func setup(player_node: Node2D, player_sprite: AnimatedSprite2D, player_damage: int,
		player_fire_interval: float, enemy_container: Node) -> void:
	_player = player_node
	_player_sprite = player_sprite
	_enemy_container = enemy_container
	damage = maxi(player_damage, 1)
	fire_interval = maxf(player_fire_interval / FIRE_RATE_MULTIPLIER, 0.05)
	if player_sprite != null:
		_sprite.sprite_frames = player_sprite.sprite_frames
		_sprite.scale = player_sprite.scale
	_update_animation(Vector2.ZERO)
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
	return "周围保护" if state == STATE_GUARD else "自主攻击"


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if _player == null or not is_instance_valid(_player) or _player.get("is_dead"):
		velocity = Vector2.ZERO
		move_and_slide()
		return
	_update_buffs(delta)
	_update_hurt_invincibility(delta)
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	_goal = _pick_goal(delta)
	_move_towards(_goal, delta)
	_try_fire()


## 按自己的移动方向切动画（方向取自本帧实际要走的方向；站着就保持上次朝向）
## delta + force：新朝向要连续保持 FACING_DEBOUNCE 秒才真的切（防抖，治"鬼畜"）；force 给自检用
func _update_animation(move_direction: Vector2, delta: float = 0.0, force: bool = false) -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return
	if move_direction != Vector2.ZERO:
		var raw := _direction_suffix(move_direction)
		if force or raw == _facing_suffix:
			_facing_suffix = raw
			_pending_facing = raw
			_pending_facing_left = 0.0
		elif raw != _pending_facing:
			# 出现新的候选朝向：重新计时（方向每帧乱跳的话永远凑不满时间，就不会切）
			_pending_facing = raw
			_pending_facing_left = FACING_DEBOUNCE
		else:
			_pending_facing_left = maxf(_pending_facing_left - delta, 0.0)
			if _pending_facing_left <= 0.0:
				_facing_suffix = _pending_facing
	var wanted := StringName("%s_%s" % [ANIMATION_PREFIX, _facing_suffix])
	if not _sprite.sprite_frames.has_animation(wanted):
		var names := _sprite.sprite_frames.get_animation_names()
		if names.is_empty():
			return
		wanted = names[0]
	if _sprite.animation != wanted:
		_sprite.animation = wanted
		_sprite.play()


## 方向 -> 动画名后缀（和玩家一样按主轴取，四个方向各一套）
func _direction_suffix(direction: Vector2) -> StringName:
	if direction == Vector2.ZERO:
		return _facing_suffix
	if absf(direction.x) >= absf(direction.y):
		return &"right" if direction.x >= 0.0 else &"left"
	return &"down" if direction.y > 0.0 else &"up"


## 当前该往哪走
func _pick_goal(delta: float) -> Vector2:
	if state == STATE_GUARD:
		return _guard_goal(delta)
	# 自主攻击：先捡能用的道具，再找敌人（保持距离），没目标就原地待命
	var pickup := _nearest_usable_pickup()
	if pickup != null:
		return pickup.global_position
	_update_chase_target(delta)
	if _chase_target == null:
		# 场上没有敌人可打：原地待命，**不回玩家身边**（只有切到保护模式才回去）
		return global_position
	var distance := global_position.distance_to(_chase_target.global_position)
	var to_enemy := global_position.direction_to(_chase_target.global_position)
	_update_stance(distance, delta)
	if _stance == "approach":
		return _chase_target.global_position                       # 太远 -> 靠近
	if _stance == "retreat":
		return global_position - to_enemy * 60.0                   # 太近 -> 后退（躲）
	# 距离合适 -> 横向游走（绕圈方向保持 STRAFE_HOLD_TIME 秒不换，治原地打转）
	return global_position + to_enemy.rotated(PI * 0.5 * _strafe_sign) * STRAFE_DISTANCE


## 锁定追击目标：选中后锁 TARGET_LOCK_TIME 秒；目标死/跑出搜索半径会立刻重选；
## 锁到期时只有"新目标近 30% 以上"才换，否则继续追旧的（治目标来回抖）
func _update_chase_target(delta: float) -> void:
	_target_lock_left = maxf(_target_lock_left - delta, 0.0)
	var current_valid := _is_valid_chase_target(_chase_target)
	if current_valid and _target_lock_left > 0.0:
		return
	var candidate := _nearest_visible_enemy(ATTACK_SEEK_RANGE)
	if candidate == null:
		candidate = _nearest_enemy(ATTACK_SEEK_RANGE, false)
	if candidate == null:
		_chase_target = null
		_target_lock_left = 0.0
		return
	if current_valid and candidate != _chase_target:
		var current_distance := global_position.distance_to(_chase_target.global_position)
		var candidate_distance := global_position.distance_to(candidate.global_position)
		if candidate_distance >= current_distance * TARGET_SWITCH_RATIO:
			_target_lock_left = TARGET_LOCK_TIME      # 新目标不够近 -> 继续锁旧的
			return
	_chase_target = candidate
	_target_lock_left = TARGET_LOCK_TIME


## 目标还活着、还在搜索半径内，才算有效
func _is_valid_chase_target(node: Node2D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if bool(node.get("is_dead")) or not node.has_method("apply_damage"):
		return false
	return global_position.distance_to(node.global_position) <= ATTACK_SEEK_RANGE


## 站位迟滞：用"进入/退出"两套阈值，避免卡在单条边界上反复切
func _update_stance(distance: float, delta: float) -> void:
	if distance < RETREAT_ENTER:
		_stance = "retreat"
	elif distance > APPROACH_ENTER:
		_stance = "approach"
	elif _stance == "approach" and distance <= APPROACH_EXIT:
		_stance = "strafe"
	elif _stance == "retreat" and distance >= RETREAT_EXIT:
		_stance = "strafe"
	if _stance != "strafe":
		return
	_strafe_left = maxf(_strafe_left - delta, 0.0)
	if _strafe_left <= 0.0:
		_strafe_left = STRAFE_HOLD_TIME
		if randf() < 0.5:
			_strafe_sign = -_strafe_sign


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
	_update_animation(direction, delta)


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
	var target := _nearest_enemy(range_limit, true)
	if target == null:
		return
	var direction := global_position.direction_to(target.global_position)
	if direction == Vector2.ZERO:
		return
	_fire_cooldown = fire_interval / maxf(_fire_buff_mult, 0.01)
	_fire(direction)


## 找敌人。require_los=true 时只要"看得见"的（开火用），false 时连隔着墙的也算（自主攻击上门用）
func _nearest_enemy(max_range: float, require_los: bool) -> Node2D:
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
		if require_los and not _has_line_of_sight(enemy.global_position):
			continue
		best_distance = distance
		best = enemy
	return best


## 只看"看得见"的敌人（开火判定 / 自检用）
func _nearest_visible_enemy(max_range: float) -> Node2D:
	return _nearest_enemy(max_range, true)


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


## 队友吃道具：只加在它自己身上（用户选择）
## 被外部治疗 1 颗（玩家满血捡到回血道具时转给队友用）。
## 满血返回 false：战斗层按 A->B->C 顺序找第一个没满血的队友。
func heal_one() -> bool:
	if current_health >= MAX_HEALTH:
		return false
	current_health = mini(current_health + 1, MAX_HEALTH)
	health_changed.emit(current_health, MAX_HEALTH)
	print("[Ally] 由玩家满血道具恢复 -> %d/%d" % [current_health, MAX_HEALTH])
	return true


func apply_pickup(config) -> bool:
	if config == null or is_dead:
		return false
	# 形态/弹幕类（螺旋弹等）队友用不了，留给玩家：不吃也不消耗
	if config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL:
		return false
	if config.shot_pattern != PickupConfig.ShotPattern.NORMAL:
		return false
	# 恢复道具：队友吃到给队友自己回 1 颗心（用户要求）
	if config.pickup_type == PickupConfig.PickupType.HEAL:
		current_health = mini(current_health + 1, MAX_HEALTH)
		health_changed.emit(current_health, MAX_HEALTH)
		print("[Ally] 吃到恢复道具 -> %d/%d" % [current_health, MAX_HEALTH])
		return true
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
	if _hurt_invincibility_left > 0.0:
		return false                      # 受击无敌中（和玩家一致）
	current_health = maxi(current_health - amount, 0)   # 下限 0：不要再出现 -1
	health_changed.emit(current_health, MAX_HEALTH)
	_play_hit_feedback()
	if current_health <= 0:
		_die()
		return true
	_hurt_invincibility_left = HURT_INVINCIBILITY
	return true


func _update_hurt_invincibility(delta: float) -> void:
	if _hurt_invincibility_left <= 0.0:
		return
	_hurt_invincibility_left = maxf(_hurt_invincibility_left - delta, 0.0)


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

func debug_update_animation(direction: Vector2) -> void:
	_update_animation(direction, 0.0, true)   # 自检用：跳过防抖，立刻生效


## 以下给自检用：锁目标 / 站位迟滞 / 绕圈方向
func debug_chase_target() -> Node2D:
	return _chase_target


func debug_stance() -> String:
	return _stance


func debug_target_lock_left() -> float:
	return _target_lock_left


func debug_strafe_sign() -> float:
	return _strafe_sign


func debug_goal() -> Vector2:
	return _goal


func debug_set_guard_point(point: Vector2) -> void:
	_guard_point = point
	_guard_repick_left = 999.0
