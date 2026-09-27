extends Node
class_name EnemyPathfinder

## 运行时网格寻路器：扫描场景里的 TileMapLayer，把带碰撞多边形的格子视为墙体，
## 使用 AStarGrid2D 求路径。全部逻辑都写在代码里，不需要在编辑器里烘焙导航网格，
## 也不需要修改任何 .tscn / .tres 资源。

const WORLD_COLLISION_MASK := 1
# 起点/终点落在墙体里时，向外逐圈搜索可走格的最大半径（格）。
const NEAREST_WALKABLE_SEARCH_RADIUS := 3
# 分组名：敌人取不到全局实例时按分组兜底查找。
const PATHFINDER_GROUP := &"enemy_pathfinder"

# 全局单例引用：敌人脚本通过它取用寻路能力，因此不需要改动 Enemy.setup() 的签名。
static var instance: EnemyPathfinder = null

# 坐标换算基准，取第一个有效的 TileMapLayer（所有图层共用同一套格子坐标）。
var _tile_map: TileMapLayer = null
# AStarGrid2D 直接使用 TileMapLayer 的格子坐标作为寻路节点 id。
var _grid: AStarGrid2D = null


func _ready() -> void:
	instance = self
	add_to_group(PATHFINDER_GROUP)


func _exit_tree() -> void:
	# 只有自己仍是在册实例时才清空，避免切换场景时误清掉新场景的寻路器。
	if instance == self:
		instance = null


## 构建寻路网格；地图被修改后可以再次调用以重建。
func build(tile_map_layers: Array[TileMapLayer]) -> void:
	_tile_map = null
	_grid = null

	if tile_map_layers.is_empty():
		push_warning("EnemyPathfinder: 没有可用的 TileMapLayer，寻路不可用")
		return

	# 收集所有图层的已用格子，得到地图的实际范围。
	var used_cells: Array[Vector2i] = []
	var visited_cells: Dictionary = {}
	for tile_map_layer in tile_map_layers:
		if tile_map_layer == null:
			continue
		if _tile_map == null:
			_tile_map = tile_map_layer
		for cell in tile_map_layer.get_used_cells():
			if visited_cells.has(cell):
				continue
			visited_cells[cell] = true
			used_cells.append(cell)

	if used_cells.is_empty():
		push_warning("EnemyPathfinder: 所有 TileMapLayer 都没有已用格子，寻路不可用")
		return

	var min_cell: Vector2i = used_cells[0]
	var max_cell: Vector2i = used_cells[0]
	for cell in used_cells:
		min_cell = Vector2i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y))
		max_cell = Vector2i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y))
	# 向外扩一圈，避免敌人贴在最外圈格子时越界导致完全找不到路。
	min_cell -= Vector2i.ONE
	max_cell += Vector2i.ONE

	_grid = AStarGrid2D.new()
	_grid.cell_size = Vector2.ONE
	_grid.offset = Vector2.ZERO
	# 禁止从两个实心格的夹角斜穿过去。
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	# region 必须在 update() 之前设置。
	_grid.region = Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)
	_grid.update()

	for cell in used_cells:
		if _is_blocked_cell(cell, tile_map_layers):
			_grid.set_point_solid(cell, true)
	# 设置过实心点之后必须再 update() 一次才会生效。
	_grid.update()


## 查询从 from_world 到 to_world 的路径（世界坐标）。
## 返回空数组表示“没有可用路径”，调用方应退回直线追踪。
## 约定：返回路径的最后一个点就是传入的 to_world 本身。
func find_path(from_world: Vector2, to_world: Vector2) -> PackedVector2Array:
	var path := PackedVector2Array()
	if not is_usable():
		return path

	var from_cell := _to_walkable_cell(world_to_cell(from_world))
	var to_cell := _to_walkable_cell(world_to_cell(to_world))
	if from_cell == to_cell:
		return path
	# 起点或终点最终仍在地图之外时，交给调用方做直线追踪。
	if not is_cell_inside_map(from_cell) or not is_cell_inside_map(to_cell):
		return path

	# get_id_path() 返回的是网格坐标（用 Vector2 承载），不是世界坐标。
	var id_path := _grid.get_id_path(from_cell, to_cell)
	if id_path.is_empty():
		return path

	for point in id_path:
		var cell := Vector2i(roundi(point.x), roundi(point.y))
		# 起点格已经在脚下，终点格用真实坐标补上，两者都不作为中间路点。
		if cell == from_cell or cell == to_cell:
			continue
		path.append(cell_to_world(cell))
	path.append(to_world)
	return path


## 两点之间是否没有墙体遮挡（使用与敌人本体完全相同的 World 碰撞层）。
func has_line_of_sight(from_world: Vector2, to_world: Vector2) -> bool:
	if _tile_map == null:
		return true
	var space_state := _tile_map.get_world_2d().direct_space_state
	if space_state == null:
		return true

	var query := PhysicsRayQueryParameters2D.create(from_world, to_world, WORLD_COLLISION_MASK)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return space_state.intersect_ray(query).is_empty()


## 寻路网格是否可用；不可用时调用方应退回直线追踪。
func is_usable() -> bool:
	if _grid == null or _tile_map == null:
		return false
	return _grid.region.size.x > 0 and _grid.region.size.y > 0


## 格子是否在地图范围内。
func is_cell_inside_map(cell: Vector2i) -> bool:
	if _grid == null:
		return false
	return _grid.is_in_boundsv(cell)


## 格子是否是墙体。
func is_cell_solid(cell: Vector2i) -> bool:
	if not is_cell_inside_map(cell):
		return false
	return _grid.is_point_solid(cell)


## 世界坐标 -> 格子坐标。
func world_to_cell(world_position: Vector2) -> Vector2i:
	if _tile_map == null:
		return Vector2i.ZERO
	return _tile_map.local_to_map(_tile_map.to_local(world_position))


## 格子坐标 -> 格子中心的世界坐标。
func cell_to_world(cell: Vector2i) -> Vector2:
	if _tile_map == null:
		return Vector2.ZERO
	return _tile_map.to_global(_tile_map.map_to_local(cell))


## 若格子不可走，向外逐圈找最近的可走格；找不到就原样返回。
func _to_walkable_cell(cell: Vector2i) -> Vector2i:
	if _grid == null:
		return cell
	if is_cell_inside_map(cell) and not _grid.is_point_solid(cell):
		return cell

	for radius in range(1, NEAREST_WALKABLE_SEARCH_RADIUS + 1):
		for offset_y in range(-radius, radius + 1):
			for offset_x in range(-radius, radius + 1):
				# 只看当前半径这一圈，内圈在上一次循环里已经查过了。
				if maxi(absi(offset_x), absi(offset_y)) != radius:
					continue
				var candidate := cell + Vector2i(offset_x, offset_y)
				if not is_cell_inside_map(candidate):
					continue
				if _grid.is_point_solid(candidate):
					continue
				return candidate
	return cell


## 该格子上是否存在带碰撞多边形的瓦片。
func _is_blocked_cell(cell: Vector2i, tile_map_layers: Array[TileMapLayer]) -> bool:
	for tile_map_layer in tile_map_layers:
		if tile_map_layer == null:
			continue
		var tile_set := tile_map_layer.tile_set
		if tile_set == null:
			continue
		var tile_data := tile_map_layer.get_cell_tile_data(cell)
		if tile_data == null:
			continue
		for physics_layer_id in tile_set.get_physics_layers_count():
			if tile_data.get_collision_polygons_count(physics_layer_id) > 0:
				return true
	return false


# [临时调试] 定位完成后请删除：输出网格概况，确认格子是否真的被标记成墙体。
func debug_summary() -> String:
	if _grid == null:
		return "网格未构建"
	var region := _grid.region
	var solid_count := 0
	for y in range(region.position.y, region.position.y + region.size.y):
		for x in range(region.position.x, region.position.x + region.size.x):
			if _grid.is_point_solid(Vector2i(x, y)):
				solid_count += 1
	var tile_map_name := "无"
	if _tile_map != null:
		tile_map_name = String(_tile_map.name)
	return "区域起点=%s 区域尺寸=%s 实心格数=%d 换算基准图层=%s" % [
		region.position,
		region.size,
		solid_count,
		tile_map_name,
	]


# [临时调试] 定位完成后请删除：把整张网格画成 ASCII 图，直接看清地图数据。
func debug_ascii_map() -> String:
	if _grid == null:
		return "网格未构建"
	var region := _grid.region
	var text := "ASCII 地图（# = 墙体，. = 可走），左上角格子=%s，x 向右，y 向下" % region.position
	for y in range(region.position.y, region.position.y + region.size.y):
		var line := ""
		for x in range(region.position.x, region.position.x + region.size.x):
			if _grid.is_point_solid(Vector2i(x, y)):
				line += "#"
			else:
				line += "."
		text += "\ny=%3d %s" % [y, line]
	return text
