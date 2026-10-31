extends CharacterBody2D
class_name Player

## 玩家满血时捡到回血道具：请求战斗把这次回血转给队友（A->B->C，都满则不加）
signal heal_ally_requested

const NORMAL_ANIMATION_PREFIX := &"normal"

const BULLET_SCENE := preload("res://scene/entities/projectiles/bullet.tscn")
const ARMED_ANIMATION_PREFIX := &"armed"
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const DEFAULT_MOVE_SPEED_MULTIPLIER := 1.0
const SPIRAL_PHASE_STEP := PI / 12
const BLINK_ENABLED_SHADER_PARAMETER := &"blink_enabled"
const WORLD_COLLISION_MASK := 1

#移动动画
@onready var body_sprite: AnimatedSprite2D = $BodySprite
#浮游炮特效
@onready var armed_effect_sprite: AnimatedSprite2D = $ArmedEffectSprite
#射击计时器
@onready var shooting_timer: Timer = $ShootingTimer
@onready var shoot_sfx_player: AudioStreamPlayer = $AudioContainer/ShootSfxPlayer
@onready var move_sfx_player: AudioStreamPlayer = $AudioContainer/MoveSfxPlayer
@onready var pickup_sfx_player: AudioStreamPlayer = $AudioContainer/PickupSfxPlayer

#当前朝向后缀
var facing_suffix: StringName = &"right"  
#当前移速倍率，由道具效果驱动
var current_move_speed_multiplier: float = DEFAULT_MOVE_SPEED_MULTIPLIER
#普通射速道具倍率，加成
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
#特殊道具射速倍率，加成
var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
#当前玩家形态，normal/armed,正常/浮游炮
var current_form_mode: int = PickupConfig.PlayerFormMode.NORMAL
#当前弹幕模式，normal/armed,正常/浮游炮
var current_shot_pattern: int = PickupConfig.ShotPattern.NORMAL
#Buff分别持续时间
var speed_buff_time_left: float = 0.0
var rapid_buff_time_left: float = 0.0
var form_buff_time_left:float = 0.0
#螺旋弹幕的相位
var spiral_phase: float =0.0

#速度，生命，无敌持续时间
@export var move_speed: float = 120.0
@export var max_health: int = 3
## 受伤后的无敌时长（用户要求：延长到 1.5 秒；期间免疫一切伤害并闪烁提示）
@export var invincibility_duration: float = 1.5
## 完全免疫伤害（守护关的建造模式下打开，退出建造模式就关掉）
@export var damage_immune: bool = false

#玩家当前生命，由最大生命值初始化
var current_health: int = 0
var _aim_cursor: Sprite2D = null      ## 鼠标射击模式下的准星 sprite
var _aim_cursor_active := false       ## 只有战斗界面才打开准星（菜单/中间地图用系统指针）
#无敌剩余时间， > 0 忽略受伤请求
var invincibility_time_left: float = 0.0
#玩家死亡后停止移动和射击
var is_dead: bool = false

#玩家子弹连续发射的间隔
@export var fire_interval: float = 0.18
#子弹生成位移
@export var bullet_spawn_distance: float = 18.0

func _ready() -> void:
	# 准星默认不激活（中间地图、暂停菜单都用系统指针），由战斗场景调 set_aim_cursor_active()
	_refresh_aim_cursor()
	set_aim_cursor_active(false)
	if not GameSettings.changed.is_connected(_refresh_aim_cursor):
		GameSettings.changed.connect(_refresh_aim_cursor)
	current_health = max(max_health, 1)
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	_set_hurt_blink_enabled(false)
	_update_animation()
	_update_armed_effect()
	
	
func _exit_tree() -> void:
	GameSettings.apply_cursor(false)          # 离开战斗还原系统指针
	if GameSettings.changed.is_connected(_refresh_aim_cursor):
		GameSettings.changed.disconnect(_refresh_aim_cursor)
	if _aim_cursor != null and is_instance_valid(_aim_cursor):
		_aim_cursor.queue_free()
		_aim_cursor = null


## 战斗界面才用它：true = 藏系统指针 + 显示倒三角准星；false = 恢复系统指针
func set_aim_cursor_active(active: bool) -> void:
	var want := active and GameSettings.is_mouse_shoot()
	if want == _aim_cursor_active:
		return
	_aim_cursor_active = want
	if want:
		_create_aim_cursor()
	if _aim_cursor != null and is_instance_valid(_aim_cursor):
		_aim_cursor.visible = want
	GameSettings.apply_cursor(want)


func is_aim_cursor_active() -> bool:
	return _aim_cursor_active


## 自检用：拿到准星 sprite 本体
func debug_aim_cursor() -> Node:
	return _aim_cursor


## 建准星 sprite（只建一次）
func _create_aim_cursor() -> void:
	if _aim_cursor != null and is_instance_valid(_aim_cursor):
		return
	_aim_cursor = Sprite2D.new()
	_aim_cursor.name = "AimCursor"
	_aim_cursor.texture = GameSettings.aim_cursor_texture()
	_aim_cursor.centered = false
	# 热点：默认倒三角对准尖角，自定义光标对准画布正中
	_aim_cursor.offset = -GameSettings.aim_cursor_hotspot()
	_aim_cursor.scale = Vector2(GameSettings.CURSOR_BLOCK_SCALE, GameSettings.CURSOR_BLOCK_SCALE)
	_aim_cursor.set_meta("cursor_kind", GameSettings.cursor_kind)
	_aim_cursor.z_as_relative = false
	_aim_cursor.z_index = 150
	_aim_cursor.top_level = true
	_aim_cursor.visible = false
	add_child(_aim_cursor)


## 准星就是 3x2 的倒三角贴图，按 0.5 缩放 → 一个色块 = 角色像素块的一半
func _refresh_aim_cursor() -> void:
	var want := GameSettings.is_mouse_shoot() and _aim_cursor_active
	GameSettings.apply_cursor(want)
	if GameSettings.is_mouse_shoot():
		_create_aim_cursor()                          # 鼠标模式：把 sprite 建好
		# 光标可能被换成自定义画布：贴图和热点都要跟着更新
		_aim_cursor.texture = GameSettings.aim_cursor_texture()
		_aim_cursor.offset = -GameSettings.aim_cursor_hotspot()
		_aim_cursor.visible = _aim_cursor_active
	else:
		_aim_cursor_active = false
		if _aim_cursor != null and is_instance_valid(_aim_cursor):
			_aim_cursor.visible = false


func _physics_process(delta: float) -> void:
	_update_pickup_effects(delta)
	_update_invincibility(delta)  # 添加这行来更新无敌状态
	
	if is_dead:
		velocity = Vector2.ZERO
		_set_move_sfx_active(false)
		return
	
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")  
	# 射击操作模式严格二选一：鼠标模式下方向键不再射击，改成朝光标方向打
	var mouse_shoot := GameSettings.is_mouse_shoot()
	var mouse_aim := Vector2.ZERO
	var shoot_input := Vector2.ZERO
	if mouse_shoot:
		mouse_aim = global_position.direction_to(get_global_mouse_position())
	else:
		shoot_input = Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	var is_moving := move_input != Vector2.ZERO

	velocity = move_input * _get_effective_move_speed()
	move_and_slide()
	_set_move_sfx_active(is_moving)
	
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		_try_auto_spiral_shoot()
	elif mouse_shoot:
		# 按住鼠标左键开火，方向就是光标方向（任意角度）
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and mouse_aim != Vector2.ZERO:
			_try_shoot(mouse_aim)
	elif shoot_input != Vector2.ZERO:
		_try_shoot(shoot_input)

	_update_facing(move_input, mouse_aim if mouse_shoot else shoot_input)
	if mouse_shoot and _aim_cursor_active and _aim_cursor != null and is_instance_valid(_aim_cursor):
		_aim_cursor.global_position = get_global_mouse_position()
	_update_animation()
	_update_armed_effect()
	
	#根据当前朝鲜更新动画
func _update_animation() -> void:
	var animation_name := StringName("%s_%s"% [_get_animation_prefix(), facing_suffix])
	
	if not body_sprite.sprite_frames.has_animation(animation_name):
		var fallback_animation_name := StringName("%s_%s" % [NORMAL_ANIMATION_PREFIX, facing_suffix])
		if not body_sprite.sprite_frames.has_animation(fallback_animation_name):
			push_warning("Missing player animation: %s" % animation_name)
			return
		animation_name = fallback_animation_name
				
	if body_sprite.animation != animation_name:
		body_sprite.play(animation_name)
	
	#射击方向优先与移动方向，螺旋状态下不读取射击输入仅按照移动方向更新动画
func _update_facing(move_input: Vector2, shoot_input: Vector2) -> void:
	# 鼠标模式下瞄准方向就是朝向（鼠标一直在动，所以每帧都跟着转）
	if GameSettings.is_mouse_shoot() and shoot_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(shoot_input)
		return
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		if move_input != Vector2.ZERO:
			facing_suffix = _vector_to_facing_suffix(move_input)
		return
	if shoot_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(shoot_input)
	elif move_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(move_input)

#敌人或其他来源以次入口来让为玩家受伤
func apply_damage(amount: int) -> bool:
	if is_dead:
		return false
	if damage_immune:
		return false                      # 建造模式下完全免疫伤害（守护关用）
	if amount <= 0:  
		return false
	if invincibility_time_left > 0.0:
		return false
	
	current_health = maxi(current_health - amount, 0)
	if current_health <= 0:
		_die()
		return true
		
	_start_invincibility()
	return true
	
#获取玩家生命值
func get_current_health() -> int:
	return current_health

#尝试发射子弹:检查冷却-判断发射模式-发射
func _try_shoot(shoot_input: Vector2) -> void:
	if not shooting_timer.is_stopped():
		return
	if shoot_input == Vector2.ZERO:
		print("警告:射击输入为零向量")
		return
	
	var shoot_direction := shoot_input.normalized()
	var has_spawned_bullet := _fire_bullets(shoot_direction)
	if has_spawned_bullet:
		_play_sfx(shoot_sfx_player)
	shooting_timer.start(_get_effective_fire_interval())

#道具统一入口，不参与直接修改玩家细节
func apply_pickup(config: PickupConfig) -> bool:
	if config == null:
		return false
	# 恢复道具：回 1 颗心；满血也照样消耗（用户要求）
	if config.pickup_type == PickupConfig.PickupType.HEAL:
		if current_health < max_health:
			current_health = mini(current_health + 1, max_health)
		else:
			# 玩家满血：这次回血转给队友（战斗里按 A->B->C 找第一个没满血的队友；
			# 队友也都满血则谁都不加）。道具照样消耗（沿用原来的规则）。
			heal_ally_requested.emit()
		_play_sfx(pickup_sfx_player)
		return true
	
	var applied := false
	var should_refresh_shooting_timer := false 
	var buff_duration := maxf(config.duration, 0.0)
	var has_form_override :=(
		config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or config.shot_pattern != PickupConfig.ShotPattern.NORMAL
	)
	
	var has_fire_rate_override := not is_equal_approx(
		config.fire_rate_multiplier,
		DEFAULT_FIRE_RATE_MULTIPLIER
	)
	
	if not is_equal_approx(config.move_speed_multiplier, DEFAULT_MOVE_SPEED_MULTIPLIER):
		current_move_speed_multiplier = config.move_speed_multiplier
		speed_buff_time_left = buff_duration
		applied = true
	if has_fire_rate_override and not has_form_override:
		rapid_fire_rate_multiplier = config.fire_rate_multiplier
		rapid_buff_time_left = buff_duration
		should_refresh_shooting_timer = true
		applied = true
	if has_form_override:
		current_form_mode = config.player_form_mode
		current_shot_pattern = config.shot_pattern
		form_fire_rate_multiplier = (
			config.fire_rate_multiplier if has_fire_rate_override else DEFAULT_FIRE_RATE_MULTIPLIER
		)
		form_buff_time_left = buff_duration
		spiral_phase = 0.0
		should_refresh_shooting_timer = true
		applied = true
	
	if should_refresh_shooting_timer:
		_refresh_shooting_timer_wait_time()
	if applied:
		_play_sfx(pickup_sfx_player)
	
	return applied

#根据当前弹幕模式发射子弹并返回这次是否至少生成了一枚子弹
func _fire_bullets(base_direction: Vector2)-> bool:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		var has_spawned_forward_bullet := _spawn_bullet(base_direction)
		var has_spawned_backward_bullet := _spawn_bullet(base_direction.rotated(PI))
		spiral_phase = wrapf(spiral_phase + SPIRAL_PHASE_STEP, 0.0, TAU)
		return has_spawned_forward_bullet or has_spawned_backward_bullet
	#var result = _spawn_bullet(base_direction)
	return _spawn_bullet(base_direction)
	
func _spawn_bullet(shoot_direction: Vector2) -> bool:
	if not _can_spawn_bullet(shoot_direction):
		return false
	
	var bullet = BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		return false
		
	bullet.top_level = true
	bullet.damage = RunState.get_player_damage()
	bullet.setup(shoot_direction)
	
	#将子弹挂在当前主场景下，避免跟随玩家一起移动
	var spawn_parent := get_tree().current_scene
	if spawn_parent == null:
		print("❌ 无法获取当前场景")
		return false
	
	spawn_parent.add_child(bullet)
	bullet.global_position = global_position + shoot_direction * bullet_spawn_distance
	return true
	
#发射前检查从玩家中心到子弹生成点是否被遮挡
func _can_spawn_bullet(shoot_direction: Vector2) -> bool:
	var spawn_position = global_position + shoot_direction *bullet_spawn_distance
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return true
	
	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		spawn_position,
		WORLD_COLLISION_MASK
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var hit_result: Dictionary = space_state.intersect_ray(query)
	return hit_result.is_empty()

	
#螺旋形态下自动按照固定节奏360度发射子弹
func _try_auto_spiral_shoot() -> void:
	if not shooting_timer.is_stopped():
		return
	
	var spiral_direction := Vector2.RIGHT.rotated(spiral_phase)
	var has_spawned_bullet := _fire_bullets(spiral_direction)
	if has_spawned_bullet:
		_play_sfx(shoot_sfx_player)
	shooting_timer.start(_get_effective_fire_interval())

#每帧获取道具 Buff 剩余时间，并且在后期恢复默认状态
func _update_pickup_effects(delta: float) -> void:
	if speed_buff_time_left > 0.0:
		speed_buff_time_left = maxf(speed_buff_time_left - delta, 0.0)
		if speed_buff_time_left <= 0.0:
			current_move_speed_multiplier = DEFAULT_MOVE_SPEED_MULTIPLIER
			
	if rapid_buff_time_left > 0.0:
		rapid_buff_time_left = maxf(rapid_buff_time_left - delta, 0.0)
		if rapid_buff_time_left <= 0.0:
			rapid_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			_refresh_shooting_timer_wait_time()
		
	if form_buff_time_left > 0.0:
		form_buff_time_left = maxf(form_buff_time_left - delta, 0.0)
		if form_buff_time_left <= 0.0:
			current_form_mode = PickupConfig.PlayerFormMode.NORMAL 
			current_shot_pattern = PickupConfig.ShotPattern.NORMAL 
			form_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER 
			spiral_phase = 0.0
			_refresh_shooting_timer_wait_time()

#更新玩家无敌时间，并在结束时关闭闪烁效果
func _update_invincibility(delta: float) -> void:
	if invincibility_time_left <= 0.0:
		return
	
	invincibility_time_left = maxf(invincibility_time_left - delta, 0.0)
	if invincibility_time_left > 0.0:
		return
	
	_set_hurt_blink_enabled(false)  

#移速
func _get_effective_move_speed() -> float:
	return move_speed * current_move_speed_multiplier
#射速
func _get_effective_fire_interval() -> float:
	return maxf(fire_interval / _get_effective_fire_rate_multiplier(), 0.01)
#强化形态下的固定射速
func _get_effective_fire_rate_multiplier() -> float:
	if _has_active_form_override():
		return maxf(form_fire_rate_multiplier, 0.01)
	
	return maxf(rapid_fire_rate_multiplier, 0.01)

#只有玩家处于特殊形态或者特殊弹幕模式，就视为强化在生效
func _has_active_form_override() -> bool:
	return (
		current_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or current_shot_pattern != PickupConfig.ShotPattern.NORMAL
	)

#统一刷新射击计时器的基础间隔
func _refresh_shooting_timer_wait_time() -> void:
	var new_interval := _get_effective_fire_interval()
	shooting_timer.wait_time = new_interval
	
	#如果玩家在冷却图中拾取了更快的射速 Buff ,需要让当前这次冷却也立刻缩短
	if shooting_timer.is_stopped():
		return
	if shooting_timer.time_left <= new_interval:
		return
	shooting_timer.start(new_interval)

#开枪玩家受伤后的无敌闪烁状态
func _start_invincibility() -> void:
	invincibility_time_left = maxf(invincibility_duration, 0.0)
	_set_hurt_blink_enabled(invincibility_time_left > 0.0)

#统一设置玩家收击闪烁状态
func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material := body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARAMETER, enabled)

#w玩家生命值归零进入死亡状态
func _die() -> void:
	is_dead = true
	velocity = Vector2.ZERO
	invincibility_time_left = 0.0
	_set_hurt_blink_enabled(false)
	shooting_timer.stop()
	_set_move_sfx_active(false)
	armed_effect_sprite.visible = false
	armed_effect_sprite.stop()

#根据当前形态选择动画前缀
func _get_animation_prefix() -> StringName:
	if current_form_mode == PickupConfig.PlayerFormMode.ARMED:
		return ARMED_ANIMATION_PREFIX
	
	return NORMAL_ANIMATION_PREFIX

#强化螺旋形态下显示浮游炮动画，结束后隐藏并停止播放
func _update_armed_effect() -> void:
	var is_armed := current_form_mode == PickupConfig.PlayerFormMode.ARMED
	if not is_armed:
		if armed_effect_sprite.visible:
			armed_effect_sprite.visible = false 
		if armed_effect_sprite.is_playing():
			armed_effect_sprite.stop()
		return
	if not armed_effect_sprite.visible:
		armed_effect_sprite.visible = true 
	if armed_effect_sprite.is_playing():
		return
	if armed_effect_sprite.sprite_frames == null:
		return
	if armed_effect_sprite.sprite_frames.has_animation(&"default"):
		armed_effect_sprite.play(&"default")

#主场景在结束时可调用这个接口，统一关闭玩家仍然在播放的运输时的音效
func stop_runtime_audio() -> void:
	_set_move_sfx_active(false)
	if shoot_sfx_player != null and shoot_sfx_player.playing:
		shoot_sfx_player.stop()
	if pickup_sfx_player != null and pickup_sfx_player.playing:
		pickup_sfx_player.stop()
	

# 根据移动状态启停移动音效
func _set_move_sfx_active(active: bool) -> void:
	if move_sfx_player == null or move_sfx_player.stream == null:
		return
	if active:
		if not move_sfx_player.playing:
			move_sfx_player.play()
			return
	if move_sfx_player.playing:
		move_sfx_player.stop()

# 一次性音效统一使用重播逻辑，避免快速触发时无法从头开始
func _play_sfx(audio_player: AudioStreamPlayer) -> void:
	if audio_player == null or audio_player.stream == null:
		return
	
	audio_player.stop()
	audio_player.play()

func _vector_to_facing_suffix(direction: Vector2) -> StringName:
	if abs(direction.x) >= abs(direction.y):
		return &"right" if direction.x > 0.0 else &"left"
		
	return &"down" if direction.y > 0.0 else &"up"
