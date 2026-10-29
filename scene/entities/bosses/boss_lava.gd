extends "res://scene/entities/bosses/boss_enemy.gd"
## 岩浆 BOSS（第 15 层第三波）
##
## 和普通 BOSS 完全不同的三招（不用冲撞 / 扔小怪 / 扔炸弹）：
##   ① 丢自爆兵：绕自己丢 4~8 只，每只落地前画预警圈，落地把 3x3 变暂时岩浆
##   ② 跳砸：先亮落点红圈蓄力 1 秒，再腾空 1 秒砸下，落地把 5x5 变岩浆（四角保留）
##   ③ 钻地：半血锁血 10 秒期间钻进地下（视野消失、免疫伤害），
##      脚下 5x5 变岩浆，并从岩浆里陆续爬出 20 只自爆兵；锁血结束钻出
##
## 暂时岩浆由战斗场景统一管（8 秒恢复、重叠取最长），这里只通过反射调用它。

@export var lava_throw_min: int = 4

@export var lava_throw_max: int = 8

@export var lava_skill_interval: float = 7.5      ## 岩浆 BOSS 多久放一次技能（秒）

@export var lava_move_speed_scale: float = 0.55   ## 岩浆 BOSS 移速倍数（体型大 2 倍，走太快像瞬移）

const LAVA_JUMP_WINDUP := 1.0            ## 跳砸：蓄力（提示圈亮起）1 秒才起跳

const LAVA_JUMP_AIR_TIME := 1.0          ## 跳砸：腾空 + 落地 1 秒（合计 2 秒）

@export var lava_lock_bomber_count: int = 20      ## 锁血期间从岩浆里爬出来的自爆兵总数

@export var lava_lock_spawn_interval: float = 0.5 ## 每隔多久爬出来一只（20 x 0.5 = 10 秒）

const LAVA_SPRITE_PATH := "res://resources/texture/源石虫.png"

const LAVA_MOVE_ROW_Y := 0

const LAVA_DEATH_ROW_Y := 128

const LAVA_DEATH_ROW_Y2 := 160

const LAVA_FRAMES_PER_ROW := 3

const LAVA_BOMBER_SCENE := preload("res://scene/entities/enemies/enemy.tscn")

const LAVA_BOMBER_CONFIG := preload("res://resources/config/enemy_bomber.tres")

var _lava_ready := false

var _lava_skill_left := 3.0

var _lava_alternate := false

var _lava_battle = null

var _lava_underground := false

var _lava_burrow_cell := Vector2i(-1, -1)

var _lava_spawn_left := 0                  ## 锁血期间还要爬出几只自爆兵

var _lava_spawn_tick := 0.0

var _lava_jump_tween: Tween = null         ## 跳砸的腾空补间（钻地时要能中断）

var _lava_jump_token := 0                  ## 跳砸序号：中断后旧回调作废

## 找战斗场景（放岩浆 / 红门刷自爆兵都靠它）：
## 先按 "battle" 组找，找不到就顺着父节点往上找带 temp_lava 的节点，再退到当前场景
func _find_lava_battle() -> Node:
	if is_inside_tree() and get_tree() != null:
		var by_group := get_tree().get_first_node_in_group("battle")
		if by_group != null:
			return by_group
	var node: Node = get_parent()
	while node != null:
		if node.has_method("temp_lava") and node.has_method("spawn_bomber_at_lava"):
			return node
		node = node.get_parent()
	if is_inside_tree() and get_tree() != null:
		var scene := get_tree().current_scene
		if scene != null and scene.has_method("temp_lava"):
			return scene
	return null

## 第一次物理帧时初始化：换精灵帧 + 连上"半血锁血 -> 钻地"的信号
func _lava_init() -> void:
	_lava_ready = true
	_lava_battle = _find_lava_battle()
	var atlas: Texture2D = load(LAVA_SPRITE_PATH)
	if atlas != null and animated_sprite != null:
		var frames := SpriteFrames.new()
		frames.clear("default")
		for i in range(LAVA_FRAMES_PER_ROW):
			var tex := AtlasTexture.new()
			tex.atlas = atlas
			tex.region = Rect2(i * 32, LAVA_MOVE_ROW_Y, 32, 32)
			frames.add_frame("default", tex)
		frames.set_animation_speed("default", 6.0)
		frames.set_animation_loop("default", true)
		frames.add_animation(&"death")
		frames.set_animation_speed(&"death", 8.0)
		frames.set_animation_loop(&"death", false)
		for row in [LAVA_DEATH_ROW_Y, LAVA_DEATH_ROW_Y2]:
			for i in range(LAVA_FRAMES_PER_ROW):
				var tex2 := AtlasTexture.new()
				tex2.atlas = atlas
				tex2.region = Rect2(i * 32, row, 32, 32)
				frames.add_frame(&"death", tex2)
		animated_sprite.sprite_frames = frames
		animated_sprite.animation = &"default"
		animated_sprite.play()
		animated_sprite.scale = Vector2(2.0, 2.0)

## 半血锁血开始：钻地（基类已经把 hp_lock_started 接好了）
func _on_lock_started(_duration: float) -> void:
	_lava_burrow()


## 锁血结束：钻出来
func _on_lock_finished() -> void:
	_lava_unburrow()


## 岩浆 BOSS 的技能循环：丢自爆怪 / 跳砸岩浆 交替（普通 BOSS 的技能不参与）
func _update_lava_skills(delta: float) -> void:
	# 锁血 / 钻地期间彻底静默：不丢自爆兵、不跳砸（用户要求）
	if is_dead or _lava_underground or _hp_lock_left > 0.0:
		return
	_lava_skill_left = maxf(_lava_skill_left - delta, 0.0)
	if _lava_skill_left > 0.0:
		return
	_lava_skill_left = lava_skill_interval
	_lava_alternate = not _lava_alternate
	if _lava_alternate:
		_lava_throw_bombers()
	else:
		_lava_jump_smash()

## 技能一：一次性朝 BOSS 周围丢 4~8 只自爆敌人，每只落地就炸并砸出岩浆
func _lava_throw_bombers() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var count := randi_range(lava_throw_min, lava_throw_max)
	for _i in range(count):
		var bomber := LAVA_BOMBER_SCENE.instantiate() as Enemy
		if bomber == null:
			continue
		var angle := randf() * TAU
		var radius := randf_range(28.0, 96.0)
		var land := global_position + Vector2(cos(angle), sin(angle)) * radius
		if _lava_battle != null and _lava_battle.has_method("clamp_to_walkable"):
			land = _lava_battle.clamp_to_walkable(land)
		parent.add_child(bomber)
		bomber.global_position = global_position
		bomber.setup(LAVA_BOMBER_CONFIG, target_player)
		bomber.set_ai_suspended(true)
		# 落点提示圈：存活时间 = 飞行时间 + 0.1 秒，落地就自动消失
		var flight := randf_range(0.45, 0.7)
		_spawn_telegraph(land, 26.0, flight + 0.1)
		var tween := create_tween()
		tween.tween_property(bomber, "global_position", land, flight)
		tween.tween_callback(_lava_explode_at.bind(bomber, land))
	print("[LavaBoss] 技能一：朝周围丢出 %d 只自爆敌人" % count)

## 自爆敌人落地：立刻爆炸 + 砸出 3x3 暂时岩浆
func _lava_explode_at(bomber: Node, land: Vector2) -> void:
	var cell := Vector2i(int(floor(land.x / 16.0)), int(floor(land.y / 16.0)))
	var cells: Array = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			cells.append(cell + Vector2i(int(dx), int(dy)))
	if _lava_battle != null and _lava_battle.has_method("temp_lava"):
		_lava_battle.temp_lava(cells)
	if bomber != null and is_instance_valid(bomber):
		(bomber as Enemy).explode_now()

## 技能二：跳到玩家位置，砸出 5x5 岩浆（四角保留普通地板）
func _lava_jump_smash() -> void:
	if target_player == null or not is_instance_valid(target_player) or animated_sprite == null:
		return
	var target_pos := target_player.global_position
	var base_scale := Vector2(2.0, 2.0)
	# 1) 落点提示圈：整个腾空期间一直亮着（红圈 + 慢慢胀大），玩家有时间躲开
	var telegraph := _spawn_telegraph(target_pos, 48.0,
		LAVA_JUMP_WINDUP + LAVA_JUMP_AIR_TIME + 0.25)   # 蓄力 + 腾空都亮着，落地才消失
	# 2) 蓄力：先把自己压扁一点（像下蹲），蓄力时间 = LAVA_JUMP_WINDUP
	var squash := create_tween()
	squash.tween_property(animated_sprite, "scale", Vector2(2.35, 1.5), LAVA_JUMP_WINDUP)
	# 3) 起跳：沿抛物线飞向目标点（水平线性 + 垂直一条抛物线），快到时恢复体型
	var token := _lava_jump_token
	var jump := create_tween()
	_lava_jump_tween = jump
	jump.tween_interval(LAVA_JUMP_WINDUP)
	jump.tween_property(self, "global_position", target_pos, LAVA_JUMP_AIR_TIME)
	var lift := create_tween()
	lift.tween_interval(LAVA_JUMP_WINDUP)
	lift.tween_method(func(t: float) -> void:
		var arc := sin(t * PI) * 46.0
		animated_sprite.position.y = -arc
	, 0.0, 1.0, LAVA_JUMP_AIR_TIME)
	var restore := create_tween()
	restore.tween_interval(LAVA_JUMP_WINDUP + LAVA_JUMP_AIR_TIME * 0.6)
	restore.tween_property(animated_sprite, "scale", base_scale, 0.2)
	# 4) 落地：砸出 5x5 岩浆（四角保留普通地板），提示圈同时消失
	jump.tween_callback(func() -> void:
		if token != _lava_jump_token:
			return                                # 这一跳已经被钻地中断，别再砸了
		_lava_jump_tween = null
		animated_sprite.position.y = 0.0
		animated_sprite.scale = base_scale
		if telegraph != null and is_instance_valid(telegraph):
			telegraph.queue_free()
			_telegraphs.erase(telegraph)
		if _lava_battle != null and _lava_battle.has_method("cells_around_cell"):
			var center := Vector2i(int(floor(target_pos.x / 16.0)), int(floor(target_pos.y / 16.0)))
			if _lava_battle.has_method("temp_lava"):
				_lava_battle.temp_lava(_lava_battle.cells_around_cell(center), -1.0, true)
	)
	print("[LavaBoss] 技能二：蓄力压缩 -> 抛物线跳砸 -> 砸出 5x5 岩浆")

## 中断正在进行的跳砸（钻地 / 死亡时调用）：腾空补间、提示圈、压扁的体型全部还原
func _lava_cancel_jump() -> void:
	_lava_jump_token += 1
	if _lava_jump_tween != null and _lava_jump_tween.is_valid():
		_lava_jump_tween.kill()
	_lava_jump_tween = null
	if animated_sprite != null:
		animated_sprite.position.y = 0.0
		animated_sprite.scale = Vector2(2.0, 2.0)
	_clear_telegraphs()

## 锁血钻地期间：每隔 lava_lock_spawn_interval 从岩浆里爬出 1 只自爆兵
func _update_lava_lock_spawn(delta: float) -> void:
	if _lava_spawn_left <= 0:
		return
	_lava_spawn_tick -= delta
	if _lava_spawn_tick > 0.0:
		return
	_lava_spawn_tick = maxf(lava_lock_spawn_interval, 0.1)
	_lava_spawn_left -= 1
	if _lava_battle != null and _lava_battle.has_method("spawn_bomber_at_lava"):
		_lava_battle.spawn_bomber_at_lava(_lava_burrow_cell)
		if _lava_spawn_left == 0:
			print("[LavaBoss] 锁血期间的自爆兵已全部爬出")

## 技能三：半血无敌时钻地消失 + 脚下变岩浆 + 从岩浆里放出 20 只自爆敌人
func _lava_burrow() -> void:
	if _lava_underground:
		return
	_lava_cancel_jump()                          # 腾空到一半也要中断，不能"人没了还在砸"
	_lava_underground = true
	_lava_burrow_cell = Vector2i(int(floor(global_position.x / 16.0)),
		int(floor(global_position.y / 16.0)))
	if _lava_battle != null and _lava_battle.has_method("cells_around_cell"):
		if _lava_battle.has_method("temp_lava"):
			# 岩浆要撑满整个锁血时间，否则放到一半地面就恢复成普通地板了
			var burrow_cells: Array = _lava_battle.cells_around_cell(_lava_burrow_cell)
			_lava_battle.temp_lava(burrow_cells, HP_LOCK_TIME + 2.0)
	visible = false
	set_ai_suspended(true)
	# 锁血 10 秒内分批从岩浆里放出 20 只自爆兵（不是从红门）
	_lava_spawn_left = lava_lock_bomber_count
	_lava_spawn_tick = 0.0
	print("[LavaBoss] 技能三：钻入地下，%d 秒内从岩浆里爬出 %d 只自爆敌人" % [
		int(HP_LOCK_TIME), lava_lock_bomber_count])

func _lava_unburrow() -> void:
	if not _lava_underground:
		return
	_lava_underground = false
	_lava_spawn_left = 0                         # 锁血结束就不再刷自爆兵
	_lava_skill_left = maxf(_lava_skill_left, 2.0)   # 钻出来先喘 2 秒再放技能
	visible = true
	set_ai_suspended(false)
	if _lava_burrow_cell != Vector2i(-1, -1):
		global_position = Vector2(_lava_burrow_cell) * 16.0 + Vector2(8.0, 8.0)
	print("[LavaBoss] 技能三结束：从岩浆里钻出")


# ============================ 行为 ============================

func _ready() -> void:
	super._ready()
	_lava_skill_left = lava_skill_interval


## 每个物理帧：先确保岩浆外观装好，再跑岩浆技能 + 锁血刷怪
func _boss_update(delta: float) -> void:
	if not _lava_ready:
		_lava_init()
	set_ai_suspended(_lava_underground)      # 只有钻地期间才停 AI
	_update_lava_skills(delta)
	_update_lava_lock_spawn(delta)


func boss_kind() -> String:
	return "lava"


## 岩浆 BOSS 体型是普通 BOSS 的两倍，按原速走会显得在飘，单独压慢
func _get_move_speed() -> float:
	return super._get_move_speed() * lava_move_speed_scale


func debug_summary() -> String:
	return "kind=lava phase=P%d underground=%s left=%d hp=%d" % [
		_phase + 1, str(_lava_underground), _lava_spawn_left, current_health]
