extends "res://scene/game.gd"
## Battle：程序化场地版战斗场景（M1）
##
## 做法：**只覆盖 _ready()**，在"建寻路 / 收出怪点"之前插入地形生成，
## 其余全部复用 game.gd（HUD、结算弹窗、刷怪、寻路、音效），避免复制 400 行逻辑。
## ⚠️ 因为覆盖了 _ready，所以 game.gd 里 _ready 新增的步骤需要同步到这里。

const ArenaGen = preload("res://scene/arena/arena_generator.gd")

@export_group("场地")
## 场地尺寸（格）。会被 ArenaGenerator 自动夹到 24x16 ~ 38x23
@export var arena_width: int = 30
@export var arena_height: int = 20
## 0 = 每次随机；填具体数字可复现同一张图
@export var arena_seed: int = 0

## 本场生成结果（doors / spawns / player_spawn / grid 等）
var arena_data: Dictionary = {}


func _ready() -> void:
	random_generator.randomize()
	_configure_result_dialog()
	_setup_hud()

	# ① 生成场地数据（纯数据，可复现）
	var use_seed := arena_seed if arena_seed != 0 else random_generator.randi()
	var generator = ArenaGen.new()
	arena_data = generator.generate(arena_width, arena_height, use_seed)

	# ② 铺瓦片：地面/墙 → GroundTileMapLayer；红门 → OverlayTileMapLayer
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)

	# ③ 出怪 Marker 与红门成对创建（硬规则：无红门则无出怪点）
	generator.create_spawn_markers($EnemySpawnPoints, arena_data)

	# ④ 玩家出生点 = 离所有红门最远的可通行格
	player.global_position = cell_to_world(arena_data["player_spawn"])

	# ⑤ 顺序关键：铺完瓦片之后才能重建寻路网格
	_setup_enemy_pathfinder()
	_collect_enemy_spawn_points()
	_warn_spawn_points_inside_walls()
	_collect_enemy_configs()
	_configure_enemy_spawn_timer()
	_apply_camera_limits()

	# ⑥ 开始刷怪（沿用 game.gd 的逻辑）
	_spawn_initial_enemies()
	_start_enemy_spawn_timer()

	var pathfinder := EnemyPathfinder.instance
	print("[Battle] 场地 %dx%d seed=%d 房间=%d 地板=%d 红门=%d 寻路可用=%s 玩家出生=%s" % [
		arena_data["width"], arena_data["height"], arena_data["seed"], arena_data["room_count"],
		arena_data["floor_count"], arena_data["doors"].size(),
		str(pathfinder != null and pathfinder.is_usable()), str(arena_data["player_spawn"])])
	if not String(arena_data.get("message", "")).is_empty():
		push_warning("[Battle] %s" % arena_data["message"])
	_start_self_check()


## 格坐标 → 世界坐标（格中心）
func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5,
		cell.y * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5)


## 把摄像机限制在场地范围内（否则场地比旧地图小时会看到场地外的空白）
func _apply_camera_limits() -> void:
	var camera := $CameraSystem/Camera2D as Camera2D
	if camera == null:
		return
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(arena_data["width"]) * ArenaGen.TILE_SIZE
	camera.limit_bottom = int(arena_data["height"]) * ArenaGen.TILE_SIZE
	camera.limit_enabled = true


## 临时自检（M1 验收用，稳定后可删）：确认敌人确实是从红门刷出来的
func _start_self_check() -> void:
	var probe := Timer.new()
	probe.name = "SelfCheckTimer"
	probe.wait_time = 0.35
	probe.one_shot = true
	probe.timeout.connect(_self_check_spawn_origin)
	add_child(probe)
	probe.start()


func _self_check_spawn_origin() -> void:
	var alive := _get_alive_enemy_count()
	var message := "[Battle自检] 场上敌人=%d Overlay(红门)格=%d 地面已铺格=%d" % [
		alive, $OverlayTileMapLayer.get_used_cells().size(), $GroundTileMapLayer.get_used_cells().size()]
	var first_enemy: Node2D = null
	for child in enemy_container.get_children():
		if child is Enemy:
			first_enemy = child
			break
	if first_enemy != null:
		var nearest := INF
		for door in arena_data["doors"]:
			nearest = minf(nearest, first_enemy.global_position.distance_to(
				ArenaGen.new().spawn_world_position(door)))
		message += "；首个敌人距最近红门 %.1f px（≈0 表示确实从红门刷出）" % nearest
	print(message)
