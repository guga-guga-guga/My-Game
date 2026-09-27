extends Node2D
## Hub：关卡之间的中间地图（M4-2）—— 可走动、无敌人。
## 场上 3 个固定位置各站一个角色，类型随机（精英/普通/商店，彼此独立，可能三个都一样）。
## 玩家走到角色旁 → 出现"按 E 交互"；真正的对话框在 M4-3、商店在 M4-4。

const ArenaGen = preload("res://scene/arena/arena_generator.gd")
const NpcScript = preload("res://scene/hub/npc.gd")

@export_group("场地")
@export var arena_width: int = 24
@export var arena_height: int = 16
## 0 = 每次随机；填数字可复现
@export var arena_seed: int = 0

## 3 个固定位置（相对地图中心的格偏移）
const SLOT_OFFSETS: Array[Vector2i] = [Vector2i(-6, -3), Vector2i(0, 4), Vector2i(6, -3)]
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
	# Hub 用 Boss 那套开阔地规则（障碍少且都 >= 2x2，不会把玩家卡住）
	arena_data = generator.generate(arena_width, arena_height, use_seed, ArenaGen.MODE_BOSS)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)

	_player = $Player as Player
	var center := Vector2i(int(arena_data["width"]) / 2, int(arena_data["height"]) / 2)
	_player.global_position = _cell_center(_nearest_floor(center))

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
	var frames: SpriteFrames = _enemy_frames()
	var player_frames: SpriteFrames = _player_frames()
	var center := Vector2i(int(arena_data["width"]) / 2, int(arena_data["height"]) / 2)
	for index in range(SLOT_OFFSETS.size()):
		var kind: String = kinds[rng.randi_range(0, kinds.size() - 1)]
		var cell := _nearest_floor(center + SLOT_OFFSETS[index])
		var npc = NpcScript.new()
		# 商店用玩家形象、其它用敌人形象
		var use_frames: SpriteFrames = player_frames if kind == "shop" else frames
		var title := "商店" if kind == "shop" else ("精英关" if kind == "elite" else "普通关")
		add_child(npc)
		npc.global_position = _cell_center(cell)
		npc.setup(kind, title, use_frames, KIND_COLORS[kind], _player)
		npcs.append(npc)


func _enemy_frames() -> SpriteFrames:
	var config := load("res://resources/config/enemy_basic.tres") as EnemyConfig
	return config.enemy_frames if config != null else null


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
