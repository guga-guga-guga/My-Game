extends RefCounted
## 程序化战斗场地生成器 M1 
##
## 设计目标:产出"连通，有掩体，出怪点落在红门上"的场地数据，且**不依赖任何节点**，
## 因此可以脱离场景单独 headless 测试 见 tools/test_arena_generator.gd 
##
## 瓦片坐标全部来自 tools/inspect_tileset.gd 的实测结果，改图集时必须同步这里
## 关键约定 见 docs/闯关与NPC对话系统设计方案.md 第 11 节 :
##   1) 敌人出生点必须落在红门 Overlay 装饰瓦片 上，且该格必须可通行；
##   2) 地面/墙壁的唯一判据是"该瓦片有没有碰撞多边形"，不能用错；
##   3) 生成后必须 flood fill 校验连通性

# ---- 地面图层 TileSet: source 0 = 瓦片.png 16x16, source 1 = 动态瓦片.png 16x16 ----
const GROUND_SOURCE := 0
const GROUND_TILE := Vector2i(0, 0)                    ## 主地面 无碰撞 ，实测用量最高
const WALL_TILES: Array[Vector2i] = [                  ## 静态墙/岩石 有碰撞 ，实测 7 种
	Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(0, 2),
	Vector2i(2, 3), Vector2i(3, 2), Vector2i(3, 3),
]
const EDGE_SOURCE := 1
const EDGE_TILES: Array[Vector2i] = [                  ## 边界墙 动画 4 帧，有碰撞 ，实测 4 种
	Vector2i(0, 2), Vector2i(0, 3), Vector2i(0, 4), Vector2i(0, 5),
]

# ---- Overlay 图层 独立 TileSet:source 0 = 动态瓦片.png 的 16x32 区域 ----
const DOOR_SOURCE := 0
const DOOR_TILE := Vector2i(0, 0)                       ## 红门，实测平均色 #c70404

# ---- 网格取值 ----
const CELL_FLOOR := 0
const CELL_WALL := 1
const CELL_EDGE := 2

const TILE_SIZE := 16
## 生成尺寸硬约束 见方案 11.3:不改 WorldBounds 时上限 38x23 
const MIN_WIDTH := 24
const MIN_HEIGHT := 16
const MAX_WIDTH := 38
const MAX_HEIGHT := 23
## 连通性校验失败时的重试次数
const MAX_ATTEMPTS := 24

const FOUR_DIRS: Array[Vector2i] = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]


## 生成一片场地失败会换种子重试；最终回落"空房间"保底布局
## 返回字段:ok / seed / width / height / grid / doors / spawns / player_spawn /
##           room_count / floor_count / message
func generate(width: int, height: int, rng_seed: int) -> Dictionary:
	var w := clampi(width, MIN_WIDTH, MAX_WIDTH)
	var h := clampi(height, MIN_HEIGHT, MAX_HEIGHT)
	var last_reason := ""
	for attempt in range(MAX_ATTEMPTS):
		var data := _generate_once(w, h, rng_seed + attempt)
		if data.get("ok", false):
			return data
		last_reason = String(data.get("reason", ""))
	var fallback := _empty_room(w, h)
	fallback["message"] = "连续 %d 次生成失败 最后原因:%s ，已回落保底布局" % [MAX_ATTEMPTS, last_reason]
	return fallback


func _generate_once(w: int, h: int, rng_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_WALL)

	# 房间:把可玩区域切成 cols x rows 个分区，每个分区里随机放一间房
	#  纯随机撒点会让房间扎堆，留下大片实心墙；分区撒点地形更均匀，更像原关卡 
	var room_count := clampi(3 + int(w * h / 240.0), 3, 6)
	var cols := 2
	var rows := clampi(int(ceil(float(room_count) / 2.0)), 2, 3)
	var part_w := int(floor(float(w) / float(cols)))
	var part_h := int(floor(float(h) / float(rows)))
	var rooms: Array[Rect2i] = []
	for j in range(rows):
		for i in range(cols):
			if rooms.size() >= room_count:
				break
			var max_rw := mini(9, part_w - 2)
			var max_rh := mini(7, part_h - 2)
			if max_rw < 5 or max_rh < 4:
				continue
			var rw := rng.randi_range(5, max_rw)
			var rh := rng.randi_range(4, max_rh)
			var x0 := i * part_w + 1
			var y0 := j * part_h + 1
			var x1 := mini(x0 + (part_w - rw - 1), w - rw - 2)
			var y1 := mini(y0 + (part_h - rh - 1), h - rh - 2)
			var candidate := Rect2i(
				clampi(rng.randi_range(x0, maxi(x0, x1)), 1, w - rw - 2),
				clampi(rng.randi_range(y0, maxi(y0, y1)), 1, h - rh - 2), rw, rh)
			rooms.append(candidate)
			_carve_rect(grid, w, candidate)
	if rooms.size() < 2:
		return {"ok": false, "reason": "房间数不足(%d)" % rooms.size()}

	# 走廊:按 x 排序后依次连通相邻房间中心 L 形，宽 2 格 
	var sorted_rooms := rooms.duplicate()
	sorted_rooms.sort_custom(func(a: Rect2i, b: Rect2i) -> bool: return a.position.x < b.position.x)
	for i in range(sorted_rooms.size() - 1):
		var a_center := _room_center(sorted_rooms[i])
		var b_center := _room_center(sorted_rooms[i + 1])
		_carve_h_line(grid, w, a_center.x, b_center.x, a_center.y)
		_carve_v_line(grid, w, h, a_center.y, b_center.y, b_center.x)
		_carve_h_line(grid, w, a_center.x, b_center.x, b_center.y)
		_carve_v_line(grid, w, h, a_center.y, b_center.y, a_center.x)

	# 掩体:房间里随机放几块 1x1/2x1 的静态墙 不贴房间边缘 
	for _i in range(rng.randi_range(4, 8)):
		var room := rooms[rng.randi_range(0, rooms.size() - 1)]
		if room.size.x < 4 or room.size.y < 4:
			continue
		var cx := rng.randi_range(room.position.x + 1, room.end.x - 2)
		var cy := rng.randi_range(room.position.y + 1, room.end.y - 2)
		grid[cy * w + cx] = CELL_WALL
		if rng.randf() < 0.5 and cx + 1 <= room.end.x - 2:
			grid[cy * w + cx + 1] = CELL_WALL

	# 边界墙 外圈 1 格 
	for x in range(w):
		grid[x] = CELL_EDGE
		grid[(h - 1) * w + x] = CELL_EDGE
	for y in range(h):
		grid[y * w] = CELL_EDGE
		grid[y * w + w - 1] = CELL_EDGE

	# 红门:四边各一处
	var doors: Array[Dictionary] = []
	for side in ["left", "right", "top", "bottom"]:
		var door := _make_door(grid, w, h, side, rng)
		if door.is_empty():
			return {"ok": false, "reason": "红门创建失败(%s)" % side}
		var cell: Vector2i = door["cell"]
		if grid[cell.y * w + cell.x] != CELL_FLOOR:
			return {"ok": false, "reason": "红门格不是地板(%s)" % side}
		doors.append(door)

	# 玩家出生点:离所有红门最远的地板格
	var player_spawn := _farthest_floor_from_doors(grid, w, h, doors)
	if player_spawn == Vector2i(-1, -1):
		return {"ok": false, "reason": "找不到玩家出生点"}

	var spawns: Array[Vector2i] = []
	for door in doors:
		spawns.append(door["cell"])

	var data := {
		"ok": true,
		"seed": rng_seed,
		"width": w,
		"height": h,
		"grid": grid,
		"doors": doors,
		"spawns": spawns,
		"player_spawn": player_spawn,
		"room_count": rooms.size(),
		"floor_count": _count_floor(grid),
		"message": "",
	}
	if not all_doors_reachable(data):
		return {"ok": false, "reason": "红门不可达 连通性失败 "}
	if float(data["floor_count"]) / float(w * h) < 0.35:
		return {"ok": false, "reason": "地板占比过低(%d)" % data["floor_count"]}
	return data


## 保底布局:一整块空房间 四条边中间各开一处红门 
func _empty_room(w: int, h: int) -> Dictionary:
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_FLOOR)
	for x in range(w):
		grid[x] = CELL_EDGE
		grid[(h - 1) * w + x] = CELL_EDGE
	for y in range(h):
		grid[y * w] = CELL_EDGE
		grid[y * w + w - 1] = CELL_EDGE
	var mid_h := int(h / 2.0)
	var mid_w := int(w / 2.0)
	var doors: Array[Dictionary] = [
		{"cell": Vector2i(0, mid_h), "side": "left", "step": Vector2i(0, 1)},
		{"cell": Vector2i(w - 1, mid_h), "side": "right", "step": Vector2i(0, 1)},
		{"cell": Vector2i(mid_w, 0), "side": "top", "step": Vector2i(1, 0)},
		{"cell": Vector2i(mid_w, h - 1), "side": "bottom", "step": Vector2i(1, 0)},
	]
	for door in doors:
		var cell: Vector2i = door["cell"]
		grid[cell.y * w + cell.x] = CELL_FLOOR
		var second: Vector2i = cell + door["step"]
		if _in_bounds(second, w, h):
			grid[second.y * w + second.x] = CELL_FLOOR
	var spawns: Array[Vector2i] = []
	for door in doors:
		spawns.append(door["cell"])
	return {
		"ok": true, "seed": -1, "width": w, "height": h, "grid": grid,
		"doors": doors, "spawns": spawns,
		"player_spawn": Vector2i(mid_w, mid_h),
		"room_count": 1, "floor_count": _count_floor(grid), "message": "",
	}


## 造一处红门三条要点:
##   1) 优先挑"内侧已经是地板"的边界格 天然开口，最自然，不用凿墙 ；
##   2) 该边中间带里没有天然开口时，沿 inward 找到最近的已有地板，把中间挖成 2 格宽通道 保证连通 ；
##   3) 红门占 1x2 格 与图集里 16x32 的红门贴图一致 ，step 记录第二格的方向
func _make_door(grid: Array, w: int, h: int, side: String, rng: RandomNumberGenerator) -> Dictionary:
	var band_start := 0
	var band_end := 0
	var fixed := 0
	var is_vertical := false          # 左右两边:门沿 y 变化
	if side == "left" or side == "right":
		is_vertical = true
		band_start = int(h / 3.0)
		band_end = int(h * 2.0 / 3.0)
		fixed = 0 if side == "left" else w - 1
	else:
		band_start = int(w / 3.0)
		band_end = int(w * 2.0 / 3.0)
		fixed = 0 if side == "top" else h - 1

	var inward := Vector2i.ZERO
	if side == "left":
		inward = Vector2i.RIGHT
	elif side == "right":
		inward = Vector2i.LEFT
	elif side == "top":
		inward = Vector2i.DOWN
	elif side == "bottom":
		inward = Vector2i.UP
	else:
		return {}
	var side_step := Vector2i(inward.y, inward.x)    # 垂直于 inward:用来凑出 1x2 的门

	# ---- 1) 天然开口 ----
	var natural: Array[Vector2i] = []
	for t in range(band_start, band_end + 1):
		var candidate := Vector2i(fixed, t) if is_vertical else Vector2i(t, fixed)
		var inner := candidate + inward
		if _in_bounds(inner, w, h) and grid[inner.y * w + inner.x] == CELL_FLOOR:
			natural.append(candidate)
	if not natural.is_empty():
		var picked: Vector2i = natural[rng.randi_range(0, natural.size() - 1)]
		return _open_door(grid, w, h, picked, side_step, side)

	# ---- 2) 凿通道直达已有地板 ----
	var start := Vector2i(fixed, rng.randi_range(band_start, band_end)) if is_vertical else Vector2i(rng.randi_range(band_start, band_end), fixed)
	var probe := start
	var target := Vector2i(-1, -1)
	for _step in range(maxi(w, h)):
		probe += inward
		if not _in_bounds(probe, w, h):
			return {}
		if grid[probe.y * w + probe.x] == CELL_FLOOR:
			target = probe
			break
	if target == Vector2i(-1, -1):
		return {}
	var carve := start
	while true:
		grid[carve.y * w + carve.x] = CELL_FLOOR
		var wide := carve + side_step
		if _in_bounds(wide, w, h):
			grid[wide.y * w + wide.x] = CELL_FLOOR
		if carve == target:
			break
		carve += inward
	return _open_door(grid, w, h, start, side_step, side)


## 把门格与其旁一格都挖成地板 红门贴图 16x32，正好占 1x2 格 
func _open_door(grid: Array, w: int, h: int, cell: Vector2i, side_step: Vector2i, side: String) -> Dictionary:
	grid[cell.y * w + cell.x] = CELL_FLOOR
	var second := cell + side_step
	if _in_bounds(second, w, h):
		grid[second.y * w + second.x] = CELL_FLOOR
	return {"cell": cell, "side": side, "step": side_step}


func _in_bounds(cell: Vector2i, w: int, h: int) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < w and cell.y < h


## 连通性校验:从玩家出生点 flood fill，必须覆盖全部红门格
func all_doors_reachable(data: Dictionary) -> bool:
	var w: int = data["width"]
	var h: int = data["height"]
	var grid: Array = data["grid"]
	var start: Vector2i = data["player_spawn"]
	if grid[start.y * w + start.x] != CELL_FLOOR:
		return false
	var visited := {}
	var queue: Array[Vector2i] = [start]
	visited[start] = true
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for dir in FOUR_DIRS:
			var next: Vector2i = cell + dir
			if not _in_bounds(next, w, h):
				continue
			if visited.has(next) or grid[next.y * w + next.x] != CELL_FLOOR:
				continue
			visited[next] = true
			queue.append(next)
	for door in data["doors"]:
		if not visited.has(door["cell"]):
			return false
	return true


## 把生成结果写进两个 TileMapLayer 先清空 
func apply_to_layers(ground: TileMapLayer, overlay: TileMapLayer, data: Dictionary) -> void:
	ground.clear()
	overlay.clear()
	var w: int = data["width"]
	var h: int = data["height"]
	var grid: Array = data["grid"]
	for y in range(h):
		for x in range(w):
			var cell := Vector2i(x, y)
			var value: int = grid[y * w + x]
			if value == CELL_FLOOR:
				ground.set_cell(cell, GROUND_SOURCE, GROUND_TILE)
			elif value == CELL_WALL:
				ground.set_cell(cell, GROUND_SOURCE, WALL_TILES[absi(x * 7 + y * 13 + x * y) % WALL_TILES.size()])
			else:
				ground.set_cell(cell, EDGE_SOURCE, EDGE_TILES[absi(x * 5 + y * 11) % EDGE_TILES.size()])
	for door in data["doors"]:
		overlay.set_cell(door["cell"], DOOR_SOURCE, DOOR_TILE)
		# 上下边的门开口是"横向 2 格"，而门贴图是 16x32 竖着盖 2 行 ，
		# 所以需要并排再补一块才能盖住整个开口；左右边的门贴图本身就够高，一块即可
		var step: Vector2i = door.get("step", Vector2i.ZERO)
		if step.x != 0:
			overlay.set_cell(door["cell"] + step, DOOR_SOURCE, DOOR_TILE)


## 出怪点世界坐标 = 红门 1x2 格的中心 贴图 16x32 正好覆盖这两格 
func spawn_world_position(door: Dictionary) -> Vector2:
	var cell: Vector2i = door["cell"]
	var step: Vector2i = door.get("step", Vector2i.ZERO)
	var center := Vector2(cell) + Vector2(step) * 0.5
	return Vector2(center.x * TILE_SIZE + TILE_SIZE * 0.5, center.y * TILE_SIZE + TILE_SIZE * 0.5)


## 在指定父节点下按生成结果重建出怪 Marker 先清掉旧的 ，并返回它们
func create_spawn_markers(parent: Node2D, data: Dictionary) -> Array[Marker2D]:
	# 必须"立即"释放:queue_free() 是延迟到帧末的，会让同一帧的 _collect_enemy_spawn_points()
	# 同时收下旧 Marker 和新 Marker，导致敌人从旧位置刷出
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()
	var markers: Array[Marker2D] = []
	for door in data["doors"]:
		var marker := Marker2D.new()
		marker.name = "Spawn_" + String(door["side"]).capitalize()
		marker.position = spawn_world_position(door)
		parent.add_child(marker)
		markers.append(marker)
	return markers


## 供调试/测试用的 ASCII 预览:# 边界墙 / X 内部墙 / . 地板 / D 红门 / P 玩家出生点
func to_ascii(data: Dictionary) -> String:
	var w: int = data["width"]
	var h: int = data["height"]
	var grid: Array = data["grid"]
	var door_cells := {}
	for door in data["doors"]:
		door_cells[door["cell"]] = true
		door_cells[door["cell"] + door.get("step", Vector2i.ZERO)] = true
	var player: Vector2i = data["player_spawn"]
	var text := ""
	for y in range(h):
		var line := ""
		for x in range(w):
			var cell := Vector2i(x, y)
			if cell == player:
				line += "P"
			elif door_cells.has(cell):
				line += "D"
			elif grid[y * w + x] == CELL_FLOOR:
				line += "."
			elif grid[y * w + x] == CELL_WALL:
				line += "X"
			else:
				line += "#"
		text += line + "\n"
	return text


func _carve_rect(grid: Array, w: int, rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			grid[y * w + x] = CELL_FLOOR


func _carve_h_line(grid: Array, w: int, x0: int, x1: int, y: int) -> void:
	var h := int(floor(float(grid.size()) / float(w)))
	for x in range(mini(x0, x1), maxi(x0, x1) + 1):
		grid[y * w + x] = CELL_FLOOR
		if y + 1 < h:
			grid[(y + 1) * w + x] = CELL_FLOOR


func _carve_v_line(grid: Array, w: int, h: int, y0: int, y1: int, x: int) -> void:
	for y in range(mini(y0, y1), maxi(y0, y1) + 1):
		if y < 0 or y >= h or x < 0 or x >= w:
			continue
		grid[y * w + x] = CELL_FLOOR
		if x + 1 < w:
			grid[y * w + x + 1] = CELL_FLOOR


func _room_center(room: Rect2i) -> Vector2i:
	return Vector2i(room.position.x + int(room.size.x / 2.0), room.position.y + int(room.size.y / 2.0))


func _count_floor(grid: Array) -> int:
	var n := 0
	for v in grid:
		if v == CELL_FLOOR:
			n += 1
	return n


## 多源 BFS:每个地板格到最近红门的步数，取最远者当玩家出生点
func _farthest_floor_from_doors(grid: Array, w: int, h: int, doors: Array) -> Vector2i:
	var dist: Array = []
	dist.resize(w * h)
	dist.fill(-1)
	var queue: Array[Vector2i] = []
	for door in doors:
		var cell: Vector2i = door["cell"]
		dist[cell.y * w + cell.x] = 0
		queue.append(cell)
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for dir in FOUR_DIRS:
			var next: Vector2i = cell + dir
			if not _in_bounds(next, w, h):
				continue
			if grid[next.y * w + next.x] != CELL_FLOOR or dist[next.y * w + next.x] != -1:
				continue
			dist[next.y * w + next.x] = dist[cell.y * w + cell.x] + 1
			queue.append(next)
	var best := Vector2i(-1, -1)
	var best_distance := -1
	for y in range(h):
		for x in range(w):
			if grid[y * w + x] != CELL_FLOOR:
				continue
			if dist[y * w + x] > best_distance:
				best_distance = dist[y * w + x]
				best = Vector2i(x, y)
	return best
