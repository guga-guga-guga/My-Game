extends Node2D
## Hub：关卡之间的中间地图（M4-2）—— 可走动、无敌人。
## 场上 3 个固定位置各站一个角色，类型随机（精英/普通/商店，彼此独立，可能三个都一样）。
## 玩家走到角色旁 → 出现"按 E 交互"；真正的对话框在 M4-3、商店在 M4-4。

const ArenaGen = preload("res://scene/arena/arena_generator.gd")
const NpcScript = preload("res://scene/hub/npc.gd")

@export_group("场地")
@export var arena_width: int = 12
@export var arena_height: int = 6
## 0 = 每次随机；填数字可复现
@export var arena_seed: int = 0

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


func _ready() -> void:
	var use_seed := arena_seed if arena_seed != 0 else randi()
	var generator = ArenaGen.new()
	# Hub 很小（默认 12x6），生成器有 24x16 的下限，所以这里直接铺一张干净的小房间
	arena_data = _build_hub_arena(arena_width, arena_height)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)

	_player = $Player as Player
	# 玩家出生点放在"最下面一排的中间"，三个角色在上排 —— 12x6 很小，必须拉开否则一出生就同时靠近多个角色
	var spawn_cell := _nearest_floor(Vector2i(int(arena_data["width"]) / 2, int(arena_data["height"]) - 2))
	_player.global_position = _cell_center(spawn_cell)

	# HUD：Hub 没有时间限制 → 删掉时钟与绿条，生命值上移一行（沿用 M3 定的规则）
	_apply_hub_hud_layout()

	_spawn_npcs()
	print("[Hub] 第 %d 层中间地图 seed=%d 场地 %dx%d 角色=%s" % [
		RunState.floor_index, use_seed, arena_data["width"], arena_data["height"], str(npcs.map(
			func(npc) -> String: return npc.title))])


## 3 个固定位置各生成一个角色（类型随机；同一层固定）
func _spawn_npcs() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = RunState.floor_index * 104729
	var kinds: Array[String] = ["battle", "elite", "shop"]
	# 用户指定：敌人素材取 源石虫.png 的**第 1 横排**与**第 3 横排**（每排 3 帧，32x32）
	var battle_frames: SpriteFrames = _frames_from_row(0)
	var elite_frames: SpriteFrames = _frames_from_row(64)
	var player_frames: SpriteFrames = _player_frames()
	var center := Vector2i(int(arena_data["width"]) / 2, int(arena_data["height"]) / 2)
	for index in range(SLOT_OFFSETS.size()):
		var kind: String = kinds[rng.randi_range(0, kinds.size() - 1)]
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
		"doors": [], "spawns": [], "player_spawn": Vector2i(int(width / 2), int(height / 2)),
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
