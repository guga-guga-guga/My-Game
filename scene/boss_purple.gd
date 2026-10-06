extends "res://scene/enemy.gd"
## 紫色 BOSS（第 5 层 50% 随机 / 第 10 层固定 2 只）
## 素材：源石虫.png 第 3 排（y=64）紫色敌人，3 帧 32×32，**体型 2 倍**
##
## 三个技能（用户确认）：
##   瞬移  本体被紫光覆盖 0.7 秒（期间无敌）-> 落到玩家周围 5 瓦片（80px）的随机方向；
##         落地前 0.4 秒在落点亮起紫色光柱预告（纯视觉，不造成伤害）
##   分裂  由 battle 按"紫色阵营共享血条"的 75%/50%/25% 统一触发，各加 1 个（共 3 个）；
##         分身血量 = 本体最大血量 ×0.25，由存活的紫本体处生成，**不能再分裂**
##   加速  短时间移速 ×2（3 秒），移动时每 0.06 秒留下一个紫色残影（着色器淡出）

const AfterimageShader := preload("res://resources/shaders/boss_afterimage.gdshader")

const SPRITE_ROW_Y := 64              ## 源石虫.png 第 3 排
const BODY_SCALE := 2.0               ## 用户要求：原大小 2 倍
const TILE_SIZE := 16                 ## 与 ArenaGen.TILE_SIZE 一致（1 瓦片 16px）
const PURPLE_TINT := Color(1.35, 0.95, 1.9, 1.0)   ## 蓄力紫光（用 modulate 染紫）

const TELEPORT_CHARGE := 0.7          ## 紫光覆盖时长（期间无敌）
const TELEPORT_FLASH_LEAD := 0.4      ## 落地前多久在落点点亮紫光
const TELEPORT_RECOVER := 0.3         ## 落地后僵直
const TELEPORT_CD := 6.0              ## 本体冷却（分身 9 秒）
const TELEPORT_DISTANCE_TILES := 5.0  ## 落点距玩家 5 瓦片（16px/瓦片 -> 80px；原来 2 瓦片太超模）

const SPEED_MULTIPLIER := 2.0
const SPEED_DURATION := 3.0
const SPEED_CD := 8.0
const AFTERIMAGE_INTERVAL := 0.06
const AFTERIMAGE_LIFE := 0.45

const SPLIT_HP_RATIO := 0.25          ## 分身血量 = 本体最大血量 ×0.25

signal clone_spawned(clone: Node)

## family_id: 家族归属（血条按家族汇总）。本体由 battle 指定，分身继承
var family_id := 0
var can_split := true                 ## 分身设为 false -> 不能再分裂
var is_clone := false

var _invulnerable := false
var _teleport_cd := 0.0
var _teleport_left := 0.0
var _teleport_flash_spawned := false
var _teleport_destination := Vector2.ZERO
var _recover_left := 0.0
var _speed_cd := 0.0
var _speed_left := 0.0
var _afterimage_left := 0.0
var _splits_done := 0


func _ready() -> void:
	super._ready()
	add_to_group("boss_enemy")   # 紫 BOSS（含分身）不占"场上普通敌人"名额
	_setup_purple_visuals()


## 注意：父类 setup() 会用配置里的 enemy_frames 覆盖精灵，所以紫色素材/放大/碰撞
## 必须在 super.setup() 之后再套一层，否则会被打回原样
func setup(enemy_config, player_node) -> void:
	super.setup(enemy_config, player_node)
	_setup_purple_visuals()
	_teleport_cd = TELEPORT_CD * 0.5      # 开场不要太快就瞬移
	_speed_cd = SPEED_CD * 0.7


## 换成第 3 排紫色素材 + 放大 2 倍 + 碰撞同步放大
func _setup_purple_visuals() -> void:
	if animated_sprite != null:
		animated_sprite.sprite_frames = _build_frames_from_row(SPRITE_ROW_Y)
		animated_sprite.scale = Vector2(BODY_SCALE, BODY_SCALE)
		var names := animated_sprite.sprite_frames.get_animation_names()
		if names.size() > 0:
			animated_sprite.play(names[0])
	if config != null:
		config = config.duplicate()       # 别改到共享的 boss 配置
		config.collision_radius = float(config.collision_radius) * BODY_SCALE
		config.explosion_radius = float(config.explosion_radius) * BODY_SCALE


## 从源石虫.png 的某一横排裁出 3 帧 SpriteFrames（和中间地图里角色用的同一套做法）
func _build_frames_from_row(row_y: int) -> SpriteFrames:
	var atlas := load("res://resources/texture/源石虫.png") as Texture2D
	var frames := SpriteFrames.new()
	frames.clear("default")
	if atlas == null:
		return frames
	for index in range(3):
		var frame := AtlasTexture.new()
		frame.atlas = atlas
		frame.region = Rect2(index * 32, row_y, 32, 32)
		frames.add_frame("default", frame)
	frames.set_animation_speed("default", 6.0)
	frames.set_animation_loop("default", true)
	return frames


## 无敌期间打不掉血（瞬移蓄力时）
func apply_damage(amount: int) -> bool:
	if _invulnerable:
		return false
	return super.apply_damage(amount)


func is_invulnerable() -> bool:
	return _invulnerable


func _physics_process(delta: float) -> void:
	_teleport_cd = maxf(_teleport_cd - delta, 0.0)
	_speed_cd = maxf(_speed_cd - delta, 0.0)
	if is_dead:
		super._physics_process(delta)
		return

	# 瞬移流程（蓄力中不移动、不吃伤害）
	if _teleport_left > 0.0:
		_update_teleport(delta)
		super._physics_process(delta)
		return
	if _recover_left > 0.0:
		_recover_left = maxf(_recover_left - delta, 0.0)
		if _recover_left <= 0.0:
			set_ai_suspended(false)
		super._physics_process(delta)
		return

	_update_speed_boost(delta)
	super._physics_process(delta)
	_try_start_skills()


## 冷却到了就随机选一个技能（瞬移 / 加速 互斥）
func _try_start_skills() -> void:
	if target_player == null or not is_instance_valid(target_player):
		return
	if _teleport_cd <= 0.0:
		_start_teleport()
	elif _speed_cd <= 0.0:
		_start_speed_boost()


func _start_teleport() -> void:
	_teleport_destination = _pick_teleport_destination()
	_teleport_left = TELEPORT_CHARGE + TELEPORT_RECOVER
	_teleport_flash_spawned = false
	_teleport_cd = TELEPORT_CD if not is_clone else TELEPORT_CD * 1.5
	_invulnerable = true
	set_ai_suspended(true)
	if animated_sprite != null:
		animated_sprite.modulate = PURPLE_TINT     # 本体被紫光覆盖


func _update_teleport(delta: float) -> void:
	_teleport_left = maxf(_teleport_left - delta, 0.0)
	# 落地前 TELEPORT_FLASH_LEAD 秒：在落点亮起紫光柱预告
	if not _teleport_flash_spawned and _teleport_left <= TELEPORT_RECOVER + TELEPORT_FLASH_LEAD:
		_teleport_flash_spawned = true
		_spawn_landing_light(_teleport_destination)
	if _teleport_left <= TELEPORT_RECOVER and _teleport_flash_spawned and global_position != _teleport_destination:
		global_position = _teleport_destination      # 真正瞬移过去
		if animated_sprite != null:
			animated_sprite.modulate = Color.WHITE
		_invulnerable = false
	# 瞬移 + 落地僵直全部结束：恢复移动与受击
	# （之前漏了这一步：蓄力时 set_ai_suspended(true) 之后没人恢复，导致紫 BOSS 瞬移一次后永久不动）
	if _teleport_left <= 0.0:
		_invulnerable = false
		if animated_sprite != null:
			animated_sprite.modulate = Color.WHITE
		set_ai_suspended(false)


## 落点：玩家周围 5 瓦片，随机方向；落点本身和"玩家到落点之间"都不能有墙
## 只检查落点会漏掉"落点在地图外"的情况（空气墙在两者之间），所以再加一条射线检查
func _pick_teleport_destination() -> Vector2:
	var tile := float(TILE_SIZE)
	var base := target_player.global_position
	var start_angle := randf() * TAU
	for index in range(16):
		var angle := start_angle + TAU * float(index) / 16.0
		var candidate := base + Vector2(cos(angle), sin(angle)) * (TELEPORT_DISTANCE_TILES * tile)
		if _is_blocked_point(candidate):
			continue
		if _has_wall_between(base, candidate):
			continue
		return candidate
	# 所有方向都不合法：原地不动，绝不瞬到玩家身上或地图外
	return global_position


## 玩家 -> 落点 这条线是否穿墙（含地图外圈空气墙）
func _has_wall_between(from: Vector2, to: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters2D.create(from, to, 1)   # mask=1 World 层
	query.collide_with_areas = false
	return not space.intersect_ray(query).is_empty()


func _is_blocked_point(point: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var query := PhysicsPointQueryParameters2D.new()
	query.position = point
	query.collision_mask = 1          # World 层（墙）
	query.collide_with_areas = false
	return not space.intersect_point(query, 1).is_empty()


## 加速：移速 ×2 + 每 0.06 秒留一个紫色残影
func _start_speed_boost() -> void:
	_speed_left = SPEED_DURATION
	_speed_cd = SPEED_CD
	_afterimage_left = 0.0


func _update_speed_boost(delta: float) -> void:
	if _speed_left <= 0.0:
		return
	_speed_left = maxf(_speed_left - delta, 0.0)
	_afterimage_left -= delta
	if _afterimage_left <= 0.0:
		_afterimage_left = AFTERIMAGE_INTERVAL
		_spawn_afterimage()
	if _speed_left <= 0.0:
		_afterimage_left = 0.0


func is_speed_boosting() -> bool:
	return _speed_left > 0.0


## 留一个紫色残影（当前帧纹理 + 着色器淡出；纯视觉、无碰撞）
func _spawn_afterimage() -> void:
	if animated_sprite == null or animated_sprite.sprite_frames == null:
		return
	var texture := animated_sprite.sprite_frames.get_frame_texture(animated_sprite.animation, animated_sprite.frame)
	if texture == null:
		return
	var ghost := _make_effect_sprite(texture, global_position, Vector2(BODY_SCALE, BODY_SCALE), 0)
	_fade_out(ghost, AFTERIMAGE_LIFE)
	if animated_sprite.flip_h:
		ghost.flip_h = true


## 落点的紫色光柱（提前 0.4 秒预告）
func _spawn_landing_light(position: Vector2) -> void:
	var ghost := _make_effect_sprite(null, position, Vector2(3.0, 3.0), 1)
	_fade_out(ghost, TELEPORT_FLASH_LEAD + 0.35)


func _make_effect_sprite(texture: Texture2D, at: Vector2, effect_scale: Vector2, mode: int) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.scale = effect_scale
	sprite.z_index = z_index + (2 if mode == 1 else 1)
	var material := ShaderMaterial.new()
	material.shader = AfterimageShader
	material.set_shader_parameter("fade", 0.0)
	material.set_shader_parameter("mode", mode)
	sprite.material = material
	var parent := get_parent()
	if parent == null:
		return sprite
	parent.add_child(sprite)
	sprite.global_position = at
	if mode == 1:
		sprite.texture = _build_light_texture()
	return sprite


func _build_light_texture() -> Texture2D:
	var image := Image.create(24, 48, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(image)


## 让特效在 life 秒内把 fade 从 0 推到 1，然后销毁
## 关键：tween 必须挂在 SceneTree 上（不能用 create_tween() 绑在本 BOSS 节点上），
## 否则 BOSS 一死被 queue_free()，tween 被一起杀掉，残影/落点紫光就永远留在场上
func _fade_out(sprite: Sprite2D, life: float) -> void:
	if sprite == null or not is_instance_valid(sprite):
		return
	var tree := get_tree()
	if tree == null:
		sprite.queue_free()
		return
	var tween := tree.create_tween()
	tween.tween_method(func(value: float): 
		if is_instance_valid(sprite) and sprite.material is ShaderMaterial:
			(sprite.material as ShaderMaterial).set_shader_parameter("fade", value)
	, 0.0, 1.0, maxf(life, 0.05))
	tween.tween_callback(func():
		if is_instance_valid(sprite):
			sprite.queue_free())


## 分裂由 battle 按"紫色阵营共享血条"的 75%/50%/25% 统一触发后调用这里
## （不再由每只本体按自己的血量各自分裂）
func spawn_clone_now() -> void:
	if is_dead:
		return
	_splits_done += 1
	_spawn_clone()


func _spawn_clone() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var clone = load("res://scene/boss_purple.tscn").instantiate()
	parent.add_child(clone)
	clone.is_clone = true
	clone.can_split = false
	clone.family_id = family_id
	clone.global_position = _pick_clone_spawn_position()
	# config 在 _setup_purple_visuals() 里已经被翻倍过一次，直接给分身会让它再翻一倍
	# （碰撞半径 16 -> 32，直径 4 格，会卡在窄道里不动）。这里先还原再交给分身。
	var clone_config = config
	if config != null:
		clone_config = config.duplicate()
		clone_config.collision_radius = float(config.collision_radius) / BODY_SCALE
		clone_config.explosion_radius = float(config.explosion_radius) / BODY_SCALE
	clone.setup(clone_config, target_player)
	clone.current_health = maxi(int(float(config.max_health) * SPLIT_HP_RATIO), 1)
	clone_spawned.emit(clone)
	print("[紫BOSS] 分裂出分身（第 %d 个，血量 %d/%d）" % [_splits_done, clone.current_health, config.max_health])


## 分身出生点：本体附近随机偏移，但必须在可站立的地板上（否则会卡进墙里不动）
func _pick_clone_spawn_position() -> Vector2:
	for _i in range(12):
		var candidate := global_position + Vector2(randf_range(-40.0, 40.0), randf_range(-40.0, 40.0))
		if not _is_blocked_point(candidate):
			return candidate
	return global_position


# ---------------- 供 headless 自检调用 ----------------

func debug_force_teleport() -> void:
	_teleport_cd = 0.0
	_start_teleport()


func debug_teleport_state() -> Dictionary:
	return {"left": _teleport_left, "invulnerable": _invulnerable,
		"destination": _teleport_destination, "flash": _teleport_flash_spawned}


func debug_force_speed() -> void:
	_speed_cd = 0.0
	_start_speed_boost()


func debug_splits_done() -> int:
	return _splits_done


func debug_set_health(value: int) -> void:
	current_health = value
