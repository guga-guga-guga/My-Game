extends "res://scene/enemy.gd"
## 黑影射手（新敌人）：外形 = 玩家素材（整体染黑），会锁敌 + 每 5 秒开火一次。
##   锁定：普通关锁"最近的玩家/队友"，锁 5 秒期间不换；守护关里始终锁玩家（不锁守护对象）
##   开火：每 5 秒朝锁定目标射一发（射程 220），子弹会打到玩家/队友/守护对象
##   不会拾取道具（基类本来就没有拾取逻辑）

const SHOOTER_BULLET_SCENE := preload("res://scene/enemy_bullet.tscn")
## 持枪敌人子弹速度 = 原始 220 的 0.75 倍（用户要求）
const SHOOTER_BULLET_SPEED := 220.0 * 0.75
const LOCK_TIME := 5.0
const SHOOT_INTERVAL := 2.0   ## 每 2 秒开火一次（用户要求从 5 秒改到 2 秒）
const SHOOT_RANGE := 220.0
const BLACK_TINT := Color(0.08, 0.08, 0.10, 1.0)   ## 染黑（用 modulate，着色器层面乘色）

var _shoot_cd := 0.0
var _locked_target: Node2D = null
var _lock_left := 0.0


func setup(enemy_config, player_node) -> void:
	# 用玩家的四向素材：复制一份，别改到玩家自己的 SpriteFrames
	var player_sprite: AnimatedSprite2D = null
	if player_node != null:
		player_sprite = player_node.get_node_or_null("BodySprite") as AnimatedSprite2D
	if enemy_config != null and player_sprite != null and player_sprite.sprite_frames != null:
		enemy_config = enemy_config.duplicate()
		var frames: SpriteFrames = player_sprite.sprite_frames.duplicate(true)
		_add_death_animation(frames)
		enemy_config.enemy_frames = frames
		enemy_config.move_animation_name = &"normal_down"
		enemy_config.death_animation_name = &"death"
	super.setup(enemy_config, player_node)
	if animated_sprite != null:
		animated_sprite.modulate = BLACK_TINT
	_shoot_cd = SHOOT_INTERVAL
	_locked_target = null
	_lock_left = 0.0


## 玩家素材没有死亡动画，这里复制一份 down 当死亡动画（保留"死亡动画"表现）
func _add_death_animation(frames: SpriteFrames) -> void:
	if not frames.has_animation(&"death") and frames.has_animation(&"normal_down"):
		frames.add_animation(&"death")
		var count := frames.get_frame_count(&"normal_down")
		for i in range(count):
			frames.add_frame(&"death", frames.get_frame_texture(&"normal_down", i))
		frames.set_animation_speed(&"death", 8.0)
	# 关键：玩家素材里的 death 是 loop=true，直接拿来播会永远循环、animation_finished 不来，
	# 死亡动画就会一直播、节点永远不销毁。这里强制成不循环。
	frames.set_animation_loop(&"death", false)


## 锁定目标（覆盖基类：基类每帧都重选最近的）
func _pick_chase_target() -> Node2D:
	if _is_defend_level():
		# 守护关：始终锁玩家，绝不锁守护对象
		if is_instance_valid(target_player) and not target_player.is_dead:
			return target_player
		return null
	if _lock_left <= 0.0 or not _is_valid_target(_locked_target):
		_locked_target = _pick_nearest_actor()
		_lock_left = LOCK_TIME
	return _locked_target


func _is_valid_target(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return node.get("is_dead") != true


func _pick_nearest_actor() -> Node2D:
	var best: Node2D = null
	var best_distance := INF
	if is_instance_valid(target_player) and not target_player.is_dead:
		best = target_player
		best_distance = global_position.distance_to(target_player.global_position)
	var ally := get_tree().get_first_node_in_group("ally") as Node2D
	if ally != null and ally.get("is_dead") != true:
		var distance := global_position.distance_to(ally.global_position)
		if distance < best_distance:
			best = ally
	return best


## 当前是不是守护关（守护关里不锁守护对象）
func _is_defend_level() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var goal = scene.get("goal")
	return typeof(goal) == TYPE_DICTIONARY and String(goal.get("type", "")) == "defend"


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_lock_left = maxf(_lock_left - delta, 0.0)
	if is_dead:
		return
	_shoot_cd = maxf(_shoot_cd - delta, 0.0)
	if _shoot_cd > 0.0:
		print("[DBG] cd>0 ", _shoot_cd)
		return
	var target := _chase_target
	if target == null or not is_instance_valid(target) or target.get("is_dead") == true:
		return
	if global_position.distance_to(target.global_position) > SHOOT_RANGE:
		return
	if _has_wall_between(global_position, target.global_position):
		print("[DBG] blocked by wall, return")
		return                                   # 隔着墙不开枪（子弹不该穿墙）
	print("[DBG] fire! cd=%.3f dist=%.1f los=%s" % [_shoot_cd, global_position.distance_to(target.global_position), str(_has_wall_between(global_position, target.global_position))])
	_shoot_cd = SHOOT_INTERVAL
	_fire_at(target.global_position)


## 两点之间是否被墙挡住（World 层）
func _has_wall_between(from: Vector2, to: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters2D.create(from, to, 1)
	query.collide_with_areas = false
	return not space.intersect_ray(query).is_empty()


## 朝向：用玩家的四向动画，按移动方向切
func _update_facing(move_direction: Vector2) -> void:
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return
	if move_direction == Vector2.ZERO:
		return
	var suffix := &"down"
	if absf(move_direction.x) >= absf(move_direction.y):
		suffix = &"right" if move_direction.x >= 0.0 else &"left"
	else:
		suffix = &"down" if move_direction.y > 0.0 else &"up"
	var wanted := StringName("normal_%s" % suffix)
	if animated_sprite.sprite_frames.has_animation(wanted) and animated_sprite.animation != wanted:
		animated_sprite.animation = wanted
		animated_sprite.play()


func _fire_at(at: Vector2) -> void:
	var direction := global_position.direction_to(at)
	if direction == Vector2.ZERO:
		return
	var bullet := SHOOTER_BULLET_SCENE.instantiate()
	if bullet == null:
		return
	var parent := get_tree().current_scene
	if parent == null:
		return
	parent.add_child(bullet)
	bullet.global_position = global_position + direction * 12.0   # 出膛点贴本体边缘，别生在墙里（墙内另有兜底销毁）
	bullet.setup(direction)
	bullet.speed = SHOOTER_BULLET_SPEED   # 0.75 倍速
