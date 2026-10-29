extends "res://scene/entities/enemies/enemy.gd"
## BOSS 共用基类：普通 / 紫色 / 岩浆三个 BOSS 都继承它
##
## 这里只放三者真正共用的东西：
##   - 阶段机（血量 66% / 33% -> P2 / P3）+ 阶段切换的黄闪
##   - 地面预警圈（普通 BOSS 的投掷、岩浆 BOSS 的跳砸都用）
##   - 程序化场地的网格工具（set_arena / 可走格判断 / 吸附到地板）
##   - 半血锁血 10 秒：把基类信号接到 _on_lock_started / _on_lock_finished 两个虚方法
##   - 描边 + 发光 + 受击闪烁
##   - boss_kind()：告诉战斗场景自己是哪种 BOSS
##
## 子类只实现 _boss_update(delta) 和 boss_kind()，
## 需要时再重写 _get_move_speed() / _on_lock_started() / _on_lock_finished()。

const HP_LOCK_TIME := 10.0

## Boss（M3）—— 三阶段 + 三个技能，复用 enemy.gd 的寻路 / 受击 / 爆炸 / 掉落。
##
## 技能（全部带 0.7 秒预警：Boss 黄闪 + 地面警示圈，给玩家反应窗口）
##   minions  抛小怪：在 Boss 位置生成 4~7 只普通敌人（画在 Boss 之上），
##                    抛物线丢到附近"可通行格"，落地后恢复 AI → 就是普通敌人
##   bomb     扔自爆怪：Boss 停住并**锁定玩家此刻位置** → 抛出自爆怪 → 落地立即引爆
##   charge   冲撞：朝锁定位置直线冲刺（P2 起解锁），撞完硬直
##
## 阶段：P1 >66%；P2 33%~66%（解锁 bomb）；P3 <33%（解锁 charge + 提速 50% + 技能更频繁）
## 显示：resources/shaders/boss_glow.gdshader（红描边 + 黄闪预警）
const BossGlowShader := preload("res://resources/shaders/boss_glow.gdshader")

const TelegraphTexture := preload("res://resources/texture/boss_telegraph.svg")

const TILE := 16.0

const CELL_FLOOR := 0          # 与 arena_generator.CELL_FLOOR 一致

signal boss_skill(skill: String, target: Vector2)

signal boss_defeated

enum Phase { P1, P2, P3 }

@export_group("阶段阈值")

@export var phase2_ratio: float = 0.66

@export var phase3_ratio: float = 0.33

## 阶段切换黄闪的持续时间（秒）
@export var phase_flash_duration: float = 0.5

@export var telegraph_time: float = 0.7

@export var sprite_scale: float = 2.0

## 红色外圈半径（世界像素；Boss 本体碰撞半径 16）
@export var outline_radius: float = 21.0

## 红色外圈线宽（世界像素，技能预警时会变粗）
@export var outline_width: float = 1.5

## 调试：技能节奏加快 4 倍 + 打印技能日志（headless 自检用）
@export var debug_fast_skills: bool = false

## 调试: 强制阶段(0=自动, 1~3=强制 P1~P3)
@export var debug_force_phase: int = 0

var _phase: int = Phase.P1

var _glow_material: ShaderMaterial = null

var _outline_ring: Line2D = null

var _outline_ring_outer: Line2D = null

var _invulnerable := false

var _elapsed := 0.0

var _phase_flash_left := 0.0

var _telegraphs: Array[Node2D] = []

# 场地数据（由 battle 注入）：把落点限制在"可通行格"上
var _grid: Array = []

var _grid_width := 0

var _grid_height := 0

# 自检计数
var thrown_minions := 0

var thrown_bombs := 0

## battle 把程序化场地的网格传进来，Boss 才知道哪些格子能落人
func set_arena(grid: Array, width: int, height: int) -> void:
	_grid = grid
	_grid_width = width
	_grid_height = height

## 冲刺期间免疫伤害（用户要求：闪光结束到冲刺结束之间不掉血）
func apply_damage(amount: int) -> bool:
	if _invulnerable:
		return false
	return super.apply_damage(amount)

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

func _spawn_telegraph(position_world: Vector2, radius_px: float,
		lifetime: float = -1.0, tint: Color = Color(1.0, 0.35, 0.25, 1.0)) -> Sprite2D:
	var parent := get_parent()
	if parent == null:
		return null
	var sprite := Sprite2D.new()
	sprite.texture = TelegraphTexture
	sprite.z_index = 3                                  # 必须压在地砖（0）和 BOSS（1~2）之上才看得见
	sprite.modulate = tint
	var final_scale := (radius_px / 64.0) * 1.5          # 贴图半径 64px（128x128）
	sprite.scale = Vector2.ONE * final_scale * 0.65
	parent.add_child(sprite)                             # 先入树再定位置，父节点有位移时才不会跑偏
	sprite.global_position = position_world
	_telegraphs.append(sprite)
	var life := lifetime if lifetime > 0.0 else telegraph_time
	var tween := sprite.create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "scale", Vector2.ONE * final_scale, life)
	tween.tween_property(sprite, "modulate:a", 0.85, life * 0.5)
	# 明确指定了存活时间的提示圈，到点自己销毁（否则会一直残留在场上）
	if lifetime > 0.0:
		tween.chain().tween_callback(func() -> void:
			if is_instance_valid(sprite):
				_telegraphs.erase(sprite)
				sprite.queue_free())
	return sprite

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
	# 受击闪烁：变淡但不完全隐身（原来 glow 材质没有闪烁，BOSS 挨打完全没反馈）
	glow_material.set_shader_parameter("hidden_ratio", 0.5)
	glow_material.set_shader_parameter("min_alpha", 0.35)
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

## 场上还活着的"普通敌人"数量（红门刷的 + 抛出的；不含 Boss 自己 / 紫 BOSS / 分身）
func _count_alive_minions() -> int:
	var parent := get_parent()
	if parent == null:
		return 0
	var count := 0
	for child in parent.get_children():
		if child == self or not (child is Enemy) or (child as Enemy).is_dead:
			continue
		if child.is_in_group("boss_enemy"):
			continue          # BOSS / 紫 BOSS 不占"普通敌人"名额（用户要求）
		count += 1
	return count

var _skill_timer: float = 0.0      # 技能冷却（普通 BOSS 用；放基类方便阶段切换时缩短）

var phases_enabled := true        # 紫色 BOSS 不用阶段机，会把它关掉


# ============================ 生命周期 ============================

func _ready() -> void:
	super._ready()
	add_to_group("boss_enemy")            # BOSS 不占场上普通敌人的名额
	half_hp_lock_time = HP_LOCK_TIME      # 半血锁血 10 秒
	chase_ally = false                    # BOSS 只盯玩家，不会被队友引走
	_setup_glow()
	animated_sprite.scale = Vector2(sprite_scale, sprite_scale)
	_setup_outline()
	if not hp_lock_started.is_connected(_on_lock_started):
		hp_lock_started.connect(_on_lock_started)
	if not hp_lock_finished.is_connected(_on_lock_finished):
		hp_lock_finished.connect(_on_lock_finished)
	if not died.is_connected(_on_died):
		died.connect(_on_died)


## 每帧：阶段机 -> 子类行为机 -> 敌人基类的移动/寻路
func _physics_process(delta: float) -> void:
	_elapsed += delta
	if phases_enabled:
		_update_phase()
		_update_phase_flash(delta)
	_boss_update(delta)
	_move_step(delta)


## 走一次敌人基类的移动/寻路（子类想自己控制移动时机就调它）
func _move_step(delta: float) -> void:
	super._physics_process(delta)


## 虚函数：子类在这里跑自己的行为机 / 技能节奏
func _boss_update(_delta: float) -> void:
	pass


## 虚函数：这是哪种 BOSS（normal / purple / lava），战斗场景用它分类
func boss_kind() -> String:
	return "normal"


## 虚函数：半血锁血开始 / 结束时干什么（岩浆 BOSS 用它钻地）
func _on_lock_started(_duration: float) -> void:
	pass


func _on_lock_finished() -> void:
	pass


## 阶段切换的那一下黄闪（预警期间由子类自己控制闪烁，这里不抢）
func _update_phase_flash(delta: float) -> void:
	if _phase_flash_left <= 0.0:
		return
	_phase_flash_left = maxf(_phase_flash_left - delta, 0.0)
	if not _can_flash_phase():
		return
	_set_flash(_phase_flash_left / maxf(phase_flash_duration, 0.01))
	if _phase_flash_left <= 0.0:
		_set_flash(0.0)


## 虚函数：现在允许阶段闪光吗（普通 BOSS 在预警期自己接管闪烁）
func _can_flash_phase() -> bool:
	return true


## 移动速度：P3 狂暴更快（子类可以再叠自己的系数）
func _get_move_speed() -> float:
	var base := super._get_move_speed()
	if _phase == Phase.P3:
		return base * 1.5
	return base


func _on_died() -> void:
	_clear_telegraphs()
	_set_flash(0.0)
	print("[Boss] 已被击败（%s，抛出小怪 %d 只 / 自爆怪 %d 只）" % [
		boss_kind(), thrown_minions, thrown_bombs])
	boss_defeated.emit()


## 自检用：一行摘要
func debug_summary() -> String:
	return "kind=%s phase=P%d minions=%d bombs=%d hp=%d" % [
		boss_kind(), _phase + 1, thrown_minions, thrown_bombs, current_health]
