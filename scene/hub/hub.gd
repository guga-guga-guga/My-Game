extends Node2D
## Hub：关卡之间的中间地图（M4-2）—— 可走动、无敌人。
## 3 个固定位置各站一个角色，顺序固定：精英关 / 普通关 / 商店（左 -> 中 -> 右）。
## 玩家走近角色 -> 出现 按 E 交互；选中后开对话框（进入 / 取消）。

const ArenaGen = preload("res://scene/arena/arena_generator.gd")
const NpcScript = preload("res://scene/hub/npc.gd")
const DialogueBoxScript = preload("res://scene/hub/dialogue_box.gd")

@export_group("场地")
@export var arena_width: int = 12
@export var arena_height: int = 6
## 0 = 每次随机；填数字可复现
@export var arena_seed: int = 0
## 调试：自动打开第一个角色的对话框并在 1.2 秒后自动选"进入"（headless 验证用）
@export var debug_dialogue_test: bool = false

## 3 个固定位置（相对地图中心的格偏移）
const SLOT_OFFSETS: Array[Vector2i] = [Vector2i(-4, -2), Vector2i(0, -2), Vector2i(4, -2)]
const KIND_COLORS := {
	"battle": Color(1.0, 1.0, 1.0),        # 普通关：原色
	"elite": Color(0.72, 0.45, 1.0),       # 精英关：染紫
	"shop": Color(1.0, 0.95, 0.55),        # 商店：偏金光（图形用玩家形象）
}

var arena_data: Dictionary = {}
var npcs: Array = []
var _player: Player = null
var _dialogue = null
var _active_npc = null
var _interact_lock := 0.0      # 对话刚关掉的那一帧 E 仍是"刚按下"，加冷却避免立刻重开


func _ready() -> void:
	var use_seed := arena_seed if arena_seed != 0 else randi()
	var generator = ArenaGen.new()
	# Hub 很小（默认 12x6），生成器有 24x16 的下限，所以这里直接铺一张干净的小房间
	arena_data = _build_hub_arena(arena_width, arena_height)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)

	_player = $Player as Player
	# 玩家出生点放在"最下面一排的中间"，三个角色在上排 —— 12x6 很小，必须拉开否则一出生就同时靠近多个角色
	var spawn_cell := _nearest_floor(Vector2i(int(floor(float(arena_data["width"]) / 2.0)), int(arena_data["height"]) - 2))
	_player.global_position = _cell_center(spawn_cell)

	# HUD：Hub 没有时间限制 → 删掉时钟与绿条，生命值上移一行（沿用 M3 定的规则）
	_apply_hub_hud_layout()

	_spawn_npcs()
	_setup_dialogue()
	if debug_dialogue_test:
		_start_debug_dialogue_test()
	if debug_dialogue_test:
		print("[Hub] 调试: 已开启自动对话测试")
	print("[Hub] 第 %d 层中间地图 seed=%d 场地 %dx%d 角色=%s" % [
		RunState.floor_index, use_seed, arena_data["width"], arena_data["height"], str(npcs.map(
			func(npc) -> String: return npc.title))])


## 3 个固定位置各生成一个角色（顺序固定：精英关 / 普通关 / 商店）
func _spawn_npcs() -> void:
	# 用户指定：三个位置固定顺序 = 精英关 / 普通关 / 商店（左 -> 中 -> 右）
	var kinds: Array[String] = ["elite", "battle", "shop"]
	# 用户指定：敌人素材取 源石虫.png 的**第 1 横排**与**第 3 横排**（每排 3 帧，32x32）
	var battle_frames: SpriteFrames = _frames_from_row(0)
	var elite_frames: SpriteFrames = _frames_from_row(64)
	var player_frames: SpriteFrames = _player_frames()
	var center := Vector2i(int(floor(float(arena_data["width"]) / 2.0)), int(floor(float(arena_data["height"]) / 2.0)))
	for index in range(SLOT_OFFSETS.size()):
		var kind: String = kinds[index]      # 顺序固定：精英 / 普通 / 商店
		var cell := _nearest_floor(center + SLOT_OFFSETS[index])
		var npc = NpcScript.new()
		# 商店用玩家形象、其它用敌人形象
		var use_frames: SpriteFrames = player_frames
		if kind == "battle":
			use_frames = battle_frames
		elif kind == "elite":
			use_frames = elite_frames
		var title := "商店" if kind == "shop" else ("精英关" if kind == "elite" else "普通关")
		add_child(npc)
		npc.global_position = _cell_center(cell)
		npc.setup(kind, title, use_frames, KIND_COLORS[kind], _player)
		npcs.append(npc)


## Hub 直接铺一张 12x6 的小房间（外圈 1 格墙 + 内部全空），不走生成器
func _build_hub_arena(w: int, h: int) -> Dictionary:
	var width := maxi(w, 8)
	var height := maxi(h, 5)
	var grid: Array = []
	grid.resize(width * height)
	grid.fill(ArenaGen.CELL_FLOOR)
	for x in range(width):
		grid[x] = ArenaGen.CELL_EDGE
		grid[(height - 1) * width + x] = ArenaGen.CELL_EDGE
	for y in range(height):
		grid[y * width] = ArenaGen.CELL_EDGE
		grid[y * width + width - 1] = ArenaGen.CELL_EDGE
	return {
		"ok": true, "mode": "hub", "width": width, "height": height, "grid": grid,
		"doors": [], "spawns": [], "player_spawn": Vector2i(int(floor(float(width) / 2.0)), int(floor(float(height) / 2.0))),
		"room_count": 1, "obstacles": [], "floor_count": (width - 2) * (height - 2), "message": "",
	}


## 从 源石虫.png 的某一横排裁出一个 3 帧动画（每帧 32x32）
func _frames_from_row(row_y: int) -> SpriteFrames:
	var atlas := load("res://resources/texture/源石虫.png") as Texture2D
	if atlas == null:
		return null
	var frames := SpriteFrames.new()
	frames.clear("default")
	for index in range(3):
		var frame := AtlasTexture.new()
		frame.atlas = atlas
		frame.region = Rect2(index * 32, row_y, 32, 32)
		frames.add_frame("default", frame)
	frames.set_animation_speed("default", 6.0)
	frames.set_animation_loop("default", true)
	return frames


func _player_frames() -> SpriteFrames:
	if _player == null:
		return null
	var body := _player.get_node_or_null("BodySprite") as AnimatedSprite2D
	return body.sprite_frames if body != null else null


## 找一个可通行格（找不到就返回原地）
func _nearest_floor(cell: Vector2i) -> Vector2i:
	var grid: Array = arena_data["grid"]
	var w: int = arena_data["width"]
	var h: int = arena_data["height"]
	for radius in range(0, 8):
		for offset_y in range(-radius, radius + 1):
			for offset_x in range(-radius, radius + 1):
				var candidate := cell + Vector2i(offset_x, offset_y)
				if candidate.x <= 0 or candidate.y <= 0 or candidate.x >= w - 1 or candidate.y >= h - 1:
					continue
				if int(grid[candidate.y * w + candidate.x]) == ArenaGen.CELL_FLOOR:
					return candidate
	return cell


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5,
		cell.y * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5)


## Hub 无时间限制：删时钟 + 绿条，生命值上移（与 M3 的规则一致）
func _apply_hub_hud_layout() -> void:
	var hud := $Player/HUDLayer as Node2D
	if hud == null:
		return
	var clock := hud.get_node_or_null("TimeIcon") as Sprite2D
	var bar := hud.get_node_or_null("TimeBar") as Sprite2D
	var life := hud.get_node_or_null("LifeIcon") as Sprite2D
	var label := hud.get_node_or_null("LifeCountLabel") as Label
	if clock != null:
		clock.visible = false
	if bar != null:
		bar.visible = false
	if clock != null and life != null:
		var delta := clock.position.y - life.position.y
		life.position.y += delta
		if label != null:
			label.offset_top += delta
			label.offset_bottom += delta

# ---------------- 交互与对话框（M4-3） ----------------

func _setup_dialogue() -> void:
	_dialogue = DialogueBoxScript.new()
	add_child(_dialogue)
	_dialogue.option_selected.connect(_on_dialogue_option)
	_dialogue.closed.connect(_on_dialogue_closed)


func _physics_process(delta: float) -> void:
	if _interact_lock > 0.0:
		_interact_lock -= delta
	if _dialogue != null and _dialogue.is_open():
		return
	if _interact_lock <= 0.0 and Input.is_action_just_pressed("interact"):
		var npc = _nearest_npc_in_range()
		if npc != null:
			_open_npc_dialogue(npc)


## 取"距离玩家最近且在交互范围内"的角色（12x6 图很小，可能同时有两个在范围内）
func _nearest_npc_in_range() -> Node:
	var best: Node = null
	var best_distance := INF
	for npc in npcs:
		if not npc.is_player_in_range():
			continue
		var distance: float = _player.global_position.distance_to(npc.global_position)
		if distance < best_distance:
			best_distance = distance
			best = npc
	return best


func _open_npc_dialogue(npc: Node) -> void:
	_active_npc = npc
	if _player != null:
		_player.set_physics_process(false)      # 对话期间玩家不能走动
	var body := "要进入这里吗？"
	if npc.kind == "shop":
		body = "要进来看看货吗？"
	_dialogue.show_dialogue(npc.title, [body], ["进入", "取消"])
	print("[Hub] 对话打开: %s" % npc.title)


func _on_dialogue_option(index: int) -> void:
	var kind := String(_active_npc.kind) if _active_npc != null else ""
	if index != 0 or kind.is_empty():
		print("[Hub] 选择了取消")
		return
	if kind == "shop":
		print("[Hub] 商店界面还没做（M4-4）")     # M4-4 接商店
		return
	print("[Hub] 进入关卡: %s（第 %d 层）" % [kind, RunState.floor_index])
	# 延迟一帧再切：不要在输入回调里把当前场景直接摘掉，
	# 否则回调后续代码（以及对话框的收尾）会作用在已离开场景树的节点上。
	GameFlow.start_battle.call_deferred({"floor": RunState.floor_index, "node_type": kind})


func _on_dialogue_closed() -> void:
	if _player != null:
		_player.set_physics_process(true)
	_active_npc = null
	_interact_lock = 0.25

## 调试链：0.6 秒后对第一个角色开对话，1.4 秒后自动选「进入」
func _start_debug_dialogue_test() -> void:
	var t1 := Timer.new()
	t1.wait_time = 0.6
	t1.one_shot = true
	t1.timeout.connect(_debug_open_first_npc)
	add_child(t1)
	t1.start()
	var t2 := Timer.new()
	t2.wait_time = 1.4
	t2.one_shot = true
	t2.timeout.connect(_debug_pick_enter)
	add_child(t2)
	t2.start()


func _debug_open_first_npc() -> void:
	print("[Hub] 调试: 打开第一个角色的对话")
	if npcs.size() > 0:
		_open_npc_dialogue(npcs[0])


func _debug_pick_enter() -> void:
	print("[Hub] 调试: 发送真实 E 按键事件（走 _unhandled_input，和玩家按键完全同一条路）")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_E
	event.pressed = true
	Input.parse_input_event(event)
