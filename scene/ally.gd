extends CharacterBody2D
## 队友（商店道具"雇佣队友"）：
##   - 只在本关存在（每关最多买 1 个，下次进关可以再买）
##   - 伤害和玩家一样，射速打七折；自动打离自己最近的敌人
##   - 3 点血，会被敌人打死（和玩家一样会受伤、会闪烁）
## 敌人怎么找到它：敌人脚本会优先追"更近的那个目标"（玩家或 ally 组里的节点）
## 注意：这里**故意不写 class_name**，免得依赖编辑器的全局类缓存（直接跑游戏时会是空的）

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const MAX_HEALTH := 3
## 射速打七折 -> 开火间隔 = 玩家间隔 / 0.7（也就是更慢）
const FIRE_RATE_MULTIPLIER := 0.7
const MOVE_SPEED := 130.0
const FOLLOW_DISTANCE := 30.0          ## 离玩家这么近就停下
const REPOSITION_DISTANCE := 200.0     ## 被墙卡住掉太远就回到玩家身边
const BULLET_SPAWN_DISTANCE := 16.0
const WORLD_COLLISION_MASK := 1

signal died

var current_health: int = MAX_HEALTH
var is_dead := false
var damage := 1
var fire_interval := 0.18

var _player: Node2D = null
var _enemy_container: Node = null
var _fire_cooldown := 0.0
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
	collision_layer = 2          # 和玩家同一层：敌人的接触伤害区/爆炸能打到它
	collision_mask = WORLD_COLLISION_MASK
	global_position = global_position


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	if _player == null or not is_instance_valid(_player) or _player.get("is_dead"):
		velocity = Vector2.ZERO
		move_and_slide()
		return
	_follow_player(delta)
	_update_fire(delta)


func _follow_player(_delta: float) -> void:
	var to_player := _player.global_position - global_position
	var distance := to_player.length()
	if distance > REPOSITION_DISTANCE:
		# 被墙卡住/掉队太远：直接回到玩家身边（否则会永远卡在墙角）
		global_position = _player.global_position + Vector2(22.0, 0.0)
		velocity = Vector2.ZERO
	elif distance > FOLLOW_DISTANCE:
		velocity = to_player.normalized() * MOVE_SPEED
	else:
		velocity = Vector2.ZERO
	move_and_slide()
	if velocity.length() > 1.0:
		_sprite.flip_h = velocity.x < 0.0


func _update_fire(delta: float) -> void:
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	if _fire_cooldown > 0.0:
		return
	var target := _nearest_enemy()
	if target == null:
		return
	var direction := (target.global_position - global_position).normalized()
	if direction == Vector2.ZERO:
		return
	_fire_cooldown = fire_interval
	_fire(direction)


## 最近的、且中间没有墙挡住的敌人（有墙挡着的打了也是白打，子弹会撞墙）
func _nearest_enemy() -> Node2D:
	if _enemy_container == null or not is_instance_valid(_enemy_container):
		return null
	var best: Node2D = null
	var best_distance := INF
	for child in _enemy_container.get_children():
		var enemy := child as Node2D
		if enemy == null or enemy.get("is_dead"):
			continue
		if not child.has_method("apply_damage"):
			continue            # 只打敌人：掉落物(pickup)也挂在 EnemyContainer 下面
		var distance := global_position.distance_to(enemy.global_position)
		if distance >= best_distance:
			continue
		if not _has_line_of_sight(enemy.global_position):
			continue
		best_distance = distance
		best = enemy
	return best


## 到目标的直线上有没有墙（用物理射线查世界层）
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
	direction = direction
	_sprite.flip_h = direction.x < 0.0


func apply_damage(amount: int) -> bool:
	if is_dead or amount <= 0:
		return false
	current_health -= amount
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
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	_sprite.modulate = Color(1.0, 0.45, 0.45)
	_blink_tween = create_tween()
	_blink_tween.tween_property(_sprite, "modulate", Color.WHITE, 0.25)
