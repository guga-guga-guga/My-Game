extends CharacterBody2D
class_name Enemy

#敌人进入死亡流程时广播一次，供主场景统计本局击杀数。
signal died

const DEFAULT_BULLET_DAMAGE := 1
const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const EXPLOSION_QUERY_MAX_RESULTS := 16
#路径重算间隔（秒），避免每帧都跑寻路。
const PATH_RECOMPUTE_INTERVAL := 0.25
#距离路点多近就算“已经到达”，可以开始看下一个路点（像素）。
const WAYPOINT_REACHED_DISTANCE := 5.0
#本体碰撞圆比配置半径缩小的量（像素）：16px 的格子里半径 8 是零余量，
#留出余量才能避免被物理分离反复推挤、咬在墙角。
const BODY_RADIUS_INSET := 2.0

enum DeathSequenceStage {
	NONE,
	DEATH,
	EXPLOSION,
}

#敌人配置资源，由生成器或编辑器指定。
@export var config: EnemyConfig
# 敌人接触玩家时的伤害值。
@export var touch_damage: int = 1
# 敌人持续贴住玩家时的伤害间隔。
@export var touch_damage_interval: float = 0.5
#受击闪烁持续时间。
@export var hurt_blink_duration: float = 0.16

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

@onready var touch_damage_area: Area2D = $TouchDamageArea

@onready var touch_damage_shape: CollisionShape2D = $TouchDamageArea/CollisionShape2D
@onready var explosion_area: Area2D = $ExplosionArea
@onready var explosion_shape: CollisionShape2D = $ExplosionArea/CollisionShape2D
@onready var explode_sfx_player: AudioStreamPlayer = $AudioContainer/ExplodeSfxPlayer
@onready var hit_sfx_player: AudioStreamPlayer = $AudioContainer/HitSfxPlayer
@onready var die_sfx_player: AudioStreamPlayer = $AudioContainer/DieSfxPlayer



#当前追踪的玩家对象，由敌人管理器在生成时注入。
var target_player: Player = null
#当前跟随的路径（世界坐标）；为空时表示直接朝玩家直线追踪。
var current_path: PackedVector2Array = PackedVector2Array()
#距离下次重算路径还剩多少秒。
var path_recompute_time_left: float = 0.0
#上次算路时玩家所在的格子，用于“玩家换格子后立刻重算”。
var last_goal_cell: Vector2i = Vector2i(2147483647, 2147483647)
#缓存解析到的寻路器，避免每帧都去找。
var _pathfinder: EnemyPathfinder = null
# [临时调试] 已注释，需要时取消注释：是否已经打印过首次算路信息。
#var _has_logged_path_debug: bool = false
#当前生命值，根据配置资源初始化。
var current_health: int = 1
#敌人死亡后停止移动和受伤处理。
var is_dead: bool = false
# 接触伤害冷却时间。
var touch_damage_cooldown_left: float = 0.0
#当前仍在接触范围中的玩家对象。
var touched_player: Player = null
#受击闪烁剩余时间。
var hurt_blink_time_left: float = 0.0
# 当前死亡流程所处的阶段。
var death_sequence_stage: DeathSequenceStage = DeathSequenceStage.NONE
# 当前死亡阶段正在播放的动画名。
var death_animation_name_in_use: StringName = &""
#敌人实例自己的随机数生成器，用于掉落判定。
var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()


#初始化配置、信号和默认动画。
func _ready() -> void:
	random_generator.randomize()
	#俯视角必须用 FLOATING：默认的 GROUNDED 会把墙壁当成地板/斜坡来处理。
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	#允许以任意夹角沿墙滑行。默认 15°，夹角小于它时 move_and_slide 会直接停止滑行。
	wall_min_slide_angle = 0.0
	touch_damage_area.body_entered.connect(_on_touch_damage_area_body_entered)
	touch_damage_area.body_exited.connect(_on_touch_damage_area_body_exited)
	touch_damage_area.area_entered.connect(_on_touch_damage_area_area_entered)
	animated_sprite.animation_finished.connect(_on_animated_sprite_animation_finished)
	_apply_config()

#管理器可通过统一入口同时注入配置和玩家引用。
func setup(enemy_config: EnemyConfig, player: Player) -> void:
	config = enemy_config
	target_player = player
	#错峰重算路径，避免同批敌人在同一帧一起跑寻路。
	path_recompute_time_left = randf() * PATH_RECOMPUTE_INTERVAL
	_apply_config()
	
func apply_damage(amount: int) -> bool:
	if is_dead:
		return false
	if  amount <= 0:
		return false
		
	current_health -= amount
	
	if current_health <= 0:
		_die()
		return true
		
	_start_hurt_blink()
	_play_sfx(hit_sfx_player)
	
	return true

#每帧处理移动、接触伤害和受击闪烁。
func _physics_process(delta: float) -> void:
	_update_hurt_blink(delta)
	_update_touch_damage(delta)
	
	if is_dead:
		velocity = Vector2.ZERO
		return
		
	if not is_instance_valid(target_player) or target_player.is_dead:
		velocity = Vector2.ZERO
		move_and_slide()
		return
		
	_update_path(delta)
	var move_direction := _get_move_direction()
	if move_direction == Vector2.ZERO:
		velocity = Vector2.ZERO
		move_and_slide()
		return
	
	_update_facing(move_direction)
	velocity = move_direction * _get_move_speed()
	move_and_slide()

#根据配置资源刷新数值、碰撞大小和默认动画。
func _apply_config() -> void:
	if config == null:
		return
	
	current_health = config.max_health
	_apply_collision_radius(config.collision_radius)
	_apply_explosion_radius(config.explosion_radius)
	if config.enemy_frames != null:
		animated_sprite.sprite_frames = config.enemy_frames
	if config.enemy_frames.has_animation(config.move_animation_name):
		animated_sprite.play(config.move_animation_name)
	else:
		push_warning("Missing enemy move animation: %s" % config.move_animation_name)

#将配置中的圆型半径同步到实体碰撞和接触伤害区域
func _apply_collision_radius(radius: float) -> void:
	#本体碰撞比伤害判定小一圈：本体只和 World 层碰撞，缩小它只影响撞墙，
	#不会改变接触伤害范围和子弹命中判定。
	var body_radius := maxf(radius - BODY_RADIUS_INSET, 1.0)
	var body_shape := collision_shape.shape as CircleShape2D
	if body_shape != null:
		body_shape.radius = body_radius
	
	var damage_shape := touch_damage_shape.shape as CircleShape2D
	if damage_shape != null:
		damage_shape.radius = radius
		
#将配置中的圆型半径同步到实体碰撞和接触伤害区域
func _apply_explosion_radius(radius: float) -> void:
	var explosion_circle_shape := explosion_shape.shape as CircleShape2D
	if explosion_circle_shape != null:
		explosion_circle_shape.radius = maxf(radius, 0.0)
		
#获取当前敌人移动速度
func _get_move_speed() -> float:
	if config == null:
		return 0.0
	return config.move_speed
	
# 根据水平移动方向更新贴图翻转，竖直移动时保留当前朝向。
func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
		
	animated_sprite.flip_h = move_direction.x < 0.0


#按固定间隔或玩家换格时重算一次路径，避免每帧都跑 A*。
func _update_path(delta: float) -> void:
	var pathfinder := _resolve_pathfinder()
	if pathfinder == null or not pathfinder.is_usable():
		current_path = PackedVector2Array()
		# [临时调试] 已注释，需要时取消注释
		#if not _has_logged_path_debug:
		#	_has_logged_path_debug = true
		#	print("[寻路调试] 敌人 %s 拿不到可用寻路器（pathfinder=%s），走直线" % [
		#		name,
		#		pathfinder,
		#	])
		return
	
	path_recompute_time_left = maxf(path_recompute_time_left - delta, 0.0)
	var goal_cell := pathfinder.world_to_cell(target_player.global_position)
	if path_recompute_time_left > 0.0 and goal_cell == last_goal_cell:
		return
	
	path_recompute_time_left = PATH_RECOMPUTE_INTERVAL
	last_goal_cell = goal_cell
	
	var goal_position := target_player.global_position
	#玩家没有墙体遮挡时直接走直线，连 A* 都不用跑，保持原有的追踪手感。
	var can_see_player := pathfinder.has_line_of_sight(global_position, goal_position)
	if can_see_player:
		current_path = PackedVector2Array()
	else:
		current_path = pathfinder.find_path(global_position, goal_position)
	
	# [临时调试] 已注释，需要时取消注释
	#if not _has_logged_path_debug:
	#	_has_logged_path_debug = true
	#	print("[寻路调试] 敌人 %s 自身格=%s 玩家格=%s 两者之间无墙(可见)=%s 路径点数=%d" % [
	#		name,
	#		pathfinder.world_to_cell(global_position),
	#		goal_cell,
	#		can_see_player,
	#		current_path.size(),
	#	])


#解析当前可用的寻路器：优先取全局实例，取不到时按分组兜底查找。
func _resolve_pathfinder() -> EnemyPathfinder:
	if _pathfinder != null and is_instance_valid(_pathfinder):
		return _pathfinder
	_pathfinder = EnemyPathfinder.instance
	if _pathfinder != null and is_instance_valid(_pathfinder):
		return _pathfinder
	var tree := get_tree()
	if tree == null:
		return null
	_pathfinder = tree.get_first_node_in_group(EnemyPathfinder.PATHFINDER_GROUP) as EnemyPathfinder
	return _pathfinder


#有路径就沿路点走；没有路径（或已经能直接看到玩家）就退回直线追踪。
func _get_move_direction() -> Vector2:
	if current_path.is_empty():
		return global_position.direction_to(target_player.global_position)
	
	#丢掉已经到达的路点，最后一个点永远保留。
	while current_path.size() > 1:
		if global_position.distance_to(current_path[0]) > WAYPOINT_REACHED_DISTANCE:
			break
		current_path.remove_at(0)
	
	#只剩终点时朝玩家的实时位置走，避免一直追着算路那一刻的残影。
	if current_path.size() <= 1:
		return global_position.direction_to(target_player.global_position)
	
	return global_position.direction_to(current_path[0])

#接触玩家时尝试造成伤害，后续通过冷却控制持续伤害节奏
func _on_touch_damage_area_body_entered(body: Node2D)-> void:
	if is_dead:
		return
		
	var player := body as Player
	if player == null:
		return
		
	touched_player = player
	_try_deal_touch_damage()
	
# 玩家离开接触区域后，停止持续伤寓
func _on_touch_damage_area_body_exited(body: Node2D) -> void:
	if body == touched_player:
		touched_player = null

#子弹进入接触区时，对敌人造成伤害固定伤害并销毁子弹
func  _on_touch_damage_area_area_entered(area: Area2D) -> void:
	if is_dead:
		return
		
	var bullet := area as Bullet
	if bullet == null:
		return
		
	var damaged := apply_damage(DEFAULT_BULLET_DAMAGE)
	if damaged:
		bullet.queue_free()
		
#管理与玩家持续接触时的伤害冷却
func _update_touch_damage(delta: float) -> void:
	if touch_damage_cooldown_left > 0.0:
		touch_damage_cooldown_left = maxf(touch_damage_cooldown_left - delta, 0.0)
	
	if touched_player == null:
		return
	if not is_instance_valid(touched_player):
		touched_player = null
		return
	if touch_damage_cooldown_left > 0.0:
		return
		
	_try_deal_touch_damage()

#只在当前确实接触到玩家时结算接触伤害
func _try_deal_touch_damage() -> void:
	if touched_player == null:
		return
	touched_player.apply_damage(touch_damage)
	touch_damage_cooldown_left = touch_damage_interval
		
#通过 ShaderMaterial 参数控制敌人短暂闪烁。
func _start_hurt_blink() -> void:
	hurt_blink_time_left = hurt_blink_duration
	_set_hurt_blink_enabled(true)
		
#闪烁时间结束后恢复正常显示
func _update_hurt_blink(delta: float) -> void:
	if hurt_blink_time_left <= 0.0:
		return
	
	hurt_blink_time_left = maxf(hurt_blink_time_left - delta, 0.0)
	if hurt_blink_time_left > 0.0:
		return
	_set_hurt_blink_enabled(false)
	
#统一设置受击闪烁开关，避免散落重复的材质访问代码。
func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material := animated_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)

#进入死亡阶段后停止碰撞，并启动统一的死亡动画流程。
func _die() -> void:
	if is_dead:
		return

	is_dead = true
	#先广播再走死亡流程；is_dead 已置位，保证每只敌人只统计一次
	died.emit()
	velocity = Vector2.ZERO
	current_path = PackedVector2Array()
	touched_player = null
	hurt_blink_time_left = 0.0
	_set_hurt_blink_enabled(false)
	collision_shape.set_deferred("disabled", true)
	touch_damage_shape.set_deferred("disabled", true)
	touch_damage_area.set_deferred("monitoring", false)
	touch_damage_area.set_deferred("monitorable", false)
	_try_drop_pickup()
	_start_death_sequence()
	
# 先播放通用死亡动画；自爆敌人在其播放结束后再进入爆炸阶段。
func _start_death_sequence() -> void:
	if config == null:
		queue_free()
		return
	
	_play_sfx(die_sfx_player)
	
	if _play_death_sequence_animation(config.death_animation_name, DeathSequenceStage.DEATH):
		return
	_finish_after_death_animation()

#普通敌人在死亡动画结束后直接销毁，自爆敌人则进入第二段爆炸流程。
func _finish_after_death_animation() -> void:
	if _should_play_explosion_sequence():
		_start_explosion_sequence()
		return
	
	queue_free()

#自爆阶段开始时才结算爆炸伤害，确保表现和逻辑同步
func _start_explosion_sequence() -> void:
	if not _should_play_explosion_sequence():
		queue_free()
		return
		
	_try_apply_explosion_damage()
	_play_sfx(explode_sfx_player)
	
	if _play_death_sequence_animation(config.explosion_animation_name, DeathSequenceStage.EXPLOSION):
		return
	queue_free()

#统一切换死亡阶段动画，找不到动画时返回false，由上层决定如何降级处理。
func _play_death_sequence_animation(animation_name: StringName, stage: DeathSequenceStage)-> bool:
	death_sequence_stage = stage
	death_animation_name_in_use = animation_name
	
	if config == null:
		return false
	if config.enemy_frames == null:
		return false
	if not config.enemy_frames.has_animation(animation_name):
		return false
	
	animated_sprite.play(animation_name)
	return true
	
#只有显示标记为自爆的敌人才会进入第二阶段爆炸流程
func _should_play_explosion_sequence() -> bool:
	return config != null and config.explode_on_death
	
#只对玩家和其他敌人结算爆炸伤害。
func _try_apply_explosion_damage() -> void:
	if config == null:
		return
	if not config.explode_on_death:
		return
	if config.explosion_damage <= 0 or config.explosion_radius <= 0.0:
		return
	if explosion_shape.shape == null:
		return
	
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return
	
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = explosion_shape.shape
	query.transform = explosion_shape.global_transform
	query.collision_mask = explosion_area.collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	
	var query_results := space_state.intersect_shape(query, EXPLOSION_QUERY_MAX_RESULTS)
	if query_results.is_empty():
		return
		
	var damaged_collider_ids: Dictionary = {}
	
	for result in query_results:
		var collider := result.get("collider") as Node
		if collider == null:
			continue
		if collider == self:
			continue
			
		var collider_id := collider.get_instance_id()
		if damaged_collider_ids.has(collider_id):
			continue
		damaged_collider_ids[collider_id] = true

		var hit_player := collider as Player
		if hit_player != null:
			hit_player.apply_damage(config.explosion_damage)
			continue

		var hit_enemy := collider as Enemy
		if hit_enemy != null:
			hit_enemy.apply_damage(config.explosion_damage)
			
	
#敌人死亡时按概率掉落一个随机道具。
func _try_drop_pickup() -> void:
	if config == null:
		return
	if config.pickup_drop_configs.is_empty():
		return
	if random_generator.randf() > config.pickup_drop_chance:
		return
	var pickup_config := _pick_pickup_drop_config()
	if pickup_config == null:
		return
	
	call_deferred("_spawn_dropped_pickup", pickup_config, global_position)
	
#从可掉落列表里随机挑选一个有效的道具配置
func _pick_pickup_drop_config() -> PickupConfig:
	if config == null:
		return null
	var available_pickup_configs: Array[PickupConfig] = []
	var total_weight := 0.0

	for pickup_config in config.pickup_drop_configs:
		if pickup_config == null:
			continue
		if pickup_config.drop_weight <= 0.0:
			continue
	
		available_pickup_configs.append(pickup_config)
		total_weight += pickup_config.drop_weight
	
	if available_pickup_configs.is_empty():
		return null
	if total_weight <= 0.0:
		return null

	var target_weight := random_generator.randf_range(0.0, total_weight)
	var accumulated_weight := 0.0

	for pickup_config in available_pickup_configs:
		accumulated_weight += pickup_config.drop_weight
		if target_weight <= accumulated_weight:
			return pickup_config
		
	return available_pickup_configs.back()
	
#延迟到当前物理查询结束后再实例化掉落物，避免在碰撞回调中直接修改物理对象状态。
func _spawn_dropped_pickup(pickup_config: PickupConfig, spawn_position: Vector2) -> void:
	var drop_parent := get_parent()
	if drop_parent == null:
		return
	var pickup_instance := PICKUP_SCENE.instantiate() as Pickup
	if pickup_instance == null:
		return
		
	pickup_instance.config = pickup_config
	drop_parent.add_child(pickup_instance)
	pickup_instance.global_position = spawn_position
	
	

#死亡动画播放完成后销毁敌人实例。
func _on_animated_sprite_animation_finished() -> void:
	if not is_dead:
		return
	if death_animation_name_in_use == &"":
		return
	if animated_sprite.animation != death_animation_name_in_use:
		return
	match death_sequence_stage:
		DeathSequenceStage.DEATH:
			_finish_after_death_animation()
		DeathSequenceStage.EXPLOSION:
			queue_free()
		_:
			queue_free()


#一次性音效统一使用重播逻辑
func _play_sfx(audio_player: AudioStreamPlayer) -> void:
	if audio_player == null or audio_player.stream == null:
		return
	
	audio_player.stop()
	audio_player.play()
