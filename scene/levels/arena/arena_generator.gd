extends RefCounted
## 程序化战斗场地生成器 M1 
##
## 设计目标:产出"连通，有掩体，出怪点落在红门上"的场地数据，且**不依赖任何节点**，
## 因此可以脱离场景单独 headless 测试 见 tools/test_arena_generator.gd 
##
## 瓦片坐标全部来自 tools/inspect_tileset.gd 的实测结果，改图集时必须同步这里
## 关键约定 见 docs/闯关与NPC对话系统设计方案.md 第 11 节 :
##   1) 敌人出生点必须落在红门 Overlay 装饰瓦片 上，且该格必须可通行
##      （红门现在放在场地内部的地板格上，最外圈由坚固墙壁完整封住）；
##   2) 地面/墙壁的唯一判据是"该瓦片有没有碰撞多边形"，不能用错；
##   3) 生成后必须 flood fill 校验连通性

# ---- 地面图层 TileSet: source 0 = 瓦片.png 16x16, source 1 = 动态瓦片.png 16x16 ----
const GROUND_SOURCE := 0
const GROUND_TILE := Vector2i(0, 0)                    ## 主地面 无碰撞 ，实测用量最高

# ---- 地面破损材质（小范围随机斑块：严重破损区块 + 外圈一圈轻微破损）----
const TILE_FLOOR_PLAIN := Vector2i(0, 0)               ## 普通地面
const TILE_FLOOR_BROKEN_HARD := Vector2i(1, 1)         ## 严重破损地面（斑块主体）
const TILE_FLOOR_BROKEN_LIGHT := Vector2i(1, 2)        ## 轻微破损地面（斑块外圈）
const WEAR_PATCH_COUNT_MIN := 2                        ## 每张地图随机几个斑块
const WEAR_PATCH_COUNT_MAX := 5
const WEAR_PATCH_SIZE_MIN := 2                         ## 每个斑块几格（严重破损）
const WEAR_PATCH_SIZE_MAX := 6
const WEAR_RING_ENABLED := true                        ## 斑块外圈是否加一圈轻微破损

# ---- 岩浆地面（无碰撞，玩家和敌人在上面累计站满 1 秒掉血，跨格连续计时，见 battle.gd）----
const TILE_FLOOR_LAVA := Vector2i(2, 2)                ## 岩浆地面
## 每关岩浆总格数 0~8（用户要求：只撒一点点，别把难度拉高）
const LAVA_CELLS_MIN := 0                              ## 0 = 这一关可能完全没有岩浆
const LAVA_CELLS_MAX := 8
const LAVA_PATCH_CELLS_MIN := 2                        ## 单片岩浆最少几格
const LAVA_PATCH_CELLS_MAX := 4                        ## 单片岩浆最多几格
const LAVA_SPAWN_CLEARANCE := 3                        ## 玩家出生点周围 3 格内不撒岩浆

const WALL_TILES: Array[Vector2i] = [                  ## 静态墙/岩石 有碰撞 ，实测 7 种
	Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(0, 2),
	Vector2i(2, 3), Vector2i(3, 2), Vector2i(3, 3),
]
## 地图最外圈统一铺"坚固墙壁"，把整张地图完整包住（不再用有缺口的动画边界墙）。
## 外圈既然封死，红门就改为放在地图内部的地板格上。
const TILE_WALL_SOLID := Vector2i(1, 0)

# ---- 红门：放在地图内部的地板格上，贴图仍画在第二层 Overlay（16x32，竖占 2 格）----
const DOOR_COUNT := 4
const DOOR_STEP := Vector2i(0, 1)                      ## 红门第二格的方向（竖着放）
const DOOR_INSET := 2                                  ## 离最外圈墙至少 2 格
const DOOR_MIN_GAP := 4                                ## 任意两道红门之间至少相距几格
const DOOR_MIN_PLAYER_DIST := 5                        ## 红门离玩家出生点至少几格

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
## 场地模式：normal = 房间/走廊+掩体（普通关）；boss = 开阔地+少量大障碍（Boss 关）；
##           rope = 狭长的"绳子"场地（给新模式打地基，还没接进关卡流程）
const MODE_NORMAL := "normal"
const MODE_BOSS := "boss"
const MODE_ROPE := "rope"

# ---- 绳子场地：一条宽 2~3 格的蛇形走廊，长边远大于短边 ----
const ROPE_LENGTH_MIN := 40                            ## 长边格数（绳子长度）
const ROPE_LENGTH_MAX := 96
const ROPE_THICKNESS_MIN := 12                         ## 短边格数（绳子能弯的空间）
const ROPE_THICKNESS_MAX := 20
const ROPE_PATH_WIDTH_MIN := 2                         ## 走廊宽度（格）
const ROPE_PATH_WIDTH_MAX := 3
const ROPE_DOOR_COUNT := 2                             ## 两头各一道红门


func generate(width: int, height: int, rng_seed: int, mode: String = MODE_NORMAL) -> Dictionary:
	var w := width
	var h := height
	if mode == MODE_ROPE:
		# 绳子场地不受普通关 38x23 上限约束：长边可以很长，短边只保证能弯
		var long_side := clampi(maxi(width, height), ROPE_LENGTH_MIN, ROPE_LENGTH_MAX)
		var short_side := clampi(mini(width, height), ROPE_THICKNESS_MIN, ROPE_THICKNESS_MAX)
		if width >= height:
			w = long_side
			h = short_side
		else:
			w = short_side
			h = long_side
	else:
		w = clampi(width, MIN_WIDTH, MAX_WIDTH)
		h = clampi(height, MIN_HEIGHT, MAX_HEIGHT)
	var last_reason := ""
	for attempt in range(MAX_ATTEMPTS):
		var data := _generate_once(w, h, rng_seed + attempt, mode)
		if data.get("ok", false):
			return _attach_ground_tiles(data, rng_seed + attempt)
		last_reason = String(data.get("reason", ""))
	var fallback := _straight_rope(w, h) if mode == MODE_ROPE else _empty_room(w, h)
	fallback["mode"] = mode
	fallback["obstacles"] = []
	fallback["message"] = "连续 %d 次生成失败 最后原因:%s ，已回落保底布局" % [MAX_ATTEMPTS, last_reason]
	return _attach_ground_tiles(fallback, rng_seed)


## 给场地数据挂一张"地面材质图"：默认全是普通地面，再随机撒几个小范围破损斑块。
## 斑块主体用"严重破损地面"，斑块外圈（8 邻域）刷一圈"轻微破损地面"。
## 只影响贴图，不影响碰撞与连通性（这些都是无碰撞地面）。
func _attach_ground_tiles(data: Dictionary, seed_value: int) -> Dictionary:
	var w: int = int(data.get("width", 0))
	var h: int = int(data.get("height", 0))
	if w <= 0 or h <= 0 or not data.has("grid"):
		return data
	var grid: Array = data["grid"]
	var tiles: Array = []
	tiles.resize(w * h)
	for i in range(w * h):
		tiles[i] = TILE_FLOOR_PLAIN
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 31 + 7            # 独立随机流：材质分布不跟结构相关，但可复现

	# ① 岩浆池先画：只落在普通地面上，且避开红门与玩家出生点。
	#    总量按"格数预算"控制（0~8 格），分 1~4 片画，免得整张地图到处是岩浆
	var blocked := _lava_blocked_cells(data, w, h)
	var lava_cells: Array[Vector2i] = []
	var lava_budget := rng.randi_range(LAVA_CELLS_MIN, LAVA_CELLS_MAX)
	while lava_budget > 0:
		var want := mini(rng.randi_range(LAVA_PATCH_CELLS_MIN, LAVA_PATCH_CELLS_MAX), lava_budget)
		var painted := _paint_one_lava_patch(grid, w, h, rng, tiles, blocked, lava_cells, want)
		if painted <= 0:
			break                      # 场地里找不到合适位置就到此为止
		lava_budget -= painted
	data["lava_cells"] = lava_cells

	# ② 破损斑块：只铺在剩下的普通地面上（岩浆边上不会被破损覆盖）
	var patch_count := rng.randi_range(WEAR_PATCH_COUNT_MIN, WEAR_PATCH_COUNT_MAX)
	for _i in range(patch_count):
		_paint_one_wear_patch(grid, w, h, rng, tiles)
	if WEAR_RING_ENABLED:
		# 所有斑块画完后统一刷一圈"轻微破损"：任何贴着严重破损的地板格都会过渡，
		# 这样两个斑块挨在一起时交界处也不会缺过渡（用户要求）
		var ring: Array = []
		for y in range(h):
			for x in range(w):
				var index := y * w + x
				if int(grid[index]) != CELL_FLOOR or tiles[index] != TILE_FLOOR_PLAIN:
					continue
				for dy in [-1, 0, 1]:
					for dx in [-1, 0, 1]:
						if dx == 0 and dy == 0:
							continue
						var nb := Vector2i(x + int(dx), y + int(dy))
						if not _is_floor_cell(grid, w, h, nb):
							continue
						if tiles[nb.y * w + nb.x] == TILE_FLOOR_BROKEN_HARD:
							ring.append(index)
							break
					if ring.size() > 0 and ring[ring.size() - 1] == index:
						break
		for index in ring:
			tiles[index] = TILE_FLOOR_BROKEN_LIGHT
	data["ground_tiles"] = tiles
	return data


func _is_floor_cell(grid: Array, w: int, h: int, cell: Vector2i) -> bool:
	return _in_bounds(cell, w, h) and int(grid[cell.y * w + cell.x]) == CELL_FLOOR


## 岩浆不能出现的位置：红门 1x2 两格及其周围一圈，外加玩家出生点半径内
func _lava_blocked_cells(data: Dictionary, w: int, h: int) -> Dictionary:
	var blocked := {}
	for door in data.get("doors", []):
		var cell: Vector2i = door["cell"]
		var step: Vector2i = door.get("step", Vector2i.ZERO)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for extra in [Vector2i.ZERO, step]:
					blocked[cell + extra + Vector2i(int(dx), int(dy))] = true
	var spawn_cell: Vector2i = data.get("player_spawn", Vector2i(-1, -1))
	if _in_bounds(spawn_cell, w, h):
		for dy in range(-LAVA_SPAWN_CLEARANCE, LAVA_SPAWN_CLEARANCE + 1):
			for dx in range(-LAVA_SPAWN_CLEARANCE, LAVA_SPAWN_CLEARANCE + 1):
				blocked[spawn_cell + Vector2i(int(dx), int(dy))] = true
	return blocked


## 画一片岩浆：随机起点 + 4 向蔓延，只吃普通地面格，不碰红门/出生点。
## want = 这一片最多画几格；返回实际画了几格（0 = 没地方画了）
func _paint_one_lava_patch(grid: Array, w: int, h: int, rng: RandomNumberGenerator,
		tiles: Array, blocked: Dictionary, out_cells: Array[Vector2i], want: int) -> int:
	var start := Vector2i(-1, -1)
	for _try in range(60):
		var c := Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))
		if _is_floor_cell(grid, w, h, c) and not blocked.has(c) and tiles[c.y * w + c.x] == TILE_FLOOR_PLAIN:
			start = c
			break
	if start == Vector2i(-1, -1):
		return 0
	var patch := {start: true}
	var frontier: Array[Vector2i] = [start]
	while patch.size() < want and not frontier.is_empty():
		var pick := rng.randi_range(0, frontier.size() - 1)
		var cur: Vector2i = frontier[pick]
		frontier.remove_at(pick)
		for dir in FOUR_DIRS:
			var next: Vector2i = cur + dir
			if patch.has(next) or not _is_floor_cell(grid, w, h, next):
				continue
			if blocked.has(next) or tiles[next.y * w + next.x] != TILE_FLOOR_PLAIN:
				continue
			patch[next] = true
			frontier.append(next)
			if patch.size() >= want:
				break
	for c in patch.keys():
		tiles[c.y * w + c.x] = TILE_FLOOR_LAVA
		out_cells.append(c)
	return patch.size()


## 画一个斑块：先随机长一小片"严重破损"，再在外圈补一圈"轻微破损"
func _paint_one_wear_patch(grid: Array, w: int, h: int, rng: RandomNumberGenerator, tiles: Array) -> void:
	# 随机挑一个地板格当起点（找不到就放弃这次）
	var start := Vector2i(-1, -1)
	for _try in range(40):
		var c := Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))
		if _is_floor_cell(grid, w, h, c) and tiles[c.y * w + c.x] == TILE_FLOOR_PLAIN:
			start = c
			break
	if start == Vector2i(-1, -1):
		return
	var want := rng.randi_range(WEAR_PATCH_SIZE_MIN, WEAR_PATCH_SIZE_MAX)
	var patch := {start: true}
	var frontier: Array[Vector2i] = [start]
	while patch.size() < want and not frontier.is_empty():
		var pick := rng.randi_range(0, frontier.size() - 1)
		var cur: Vector2i = frontier[pick]
		frontier.remove_at(pick)
		for dir in FOUR_DIRS:
			var next: Vector2i = cur + dir
			if patch.has(next) or not _is_floor_cell(grid, w, h, next):
				continue
			if tiles[next.y * w + next.x] != TILE_FLOOR_PLAIN:
				continue                      # 别把岩浆/别的斑块改成破损
			patch[next] = true
			frontier.append(next)
			if patch.size() >= want:
				break
	# 斑块主体 -> 严重破损（外圈统一在所有斑块画完后一次性生成）
	for c in patch.keys():
		tiles[c.y * w + c.x] = TILE_FLOOR_BROKEN_HARD


func _generate_once(w: int, h: int, rng_seed: int, mode: String = MODE_NORMAL) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	if mode == MODE_BOSS:
		return _generate_boss_arena(w, h, rng_seed)
	if mode == MODE_ROPE:
		return _generate_rope_arena(w, h, rng_seed)
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

	# 红门:放在地图内部的地板格上（最外圈现在是封死的坚固墙壁，边界上不再开口）
	var doors: Array[Dictionary] = _place_interior_doors(grid, w, h, rng)
	if doors.size() != DOOR_COUNT:
		return {"ok": false, "reason": "红门放置失败(%d/%d)" % [doors.size(), DOOR_COUNT]}

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
	_seal_border(grid, w, h)
	var mid_w := int(w / 2.0)
	var mid_h := int(h / 2.0)
	var door_rng := RandomNumberGenerator.new()
	door_rng.seed = 20240701                    # 固定种子：保底布局每次一样
	var doors: Array[Dictionary] = _place_interior_doors(grid, w, h, door_rng)
	var player_spawn := _farthest_floor_from_doors(grid, w, h, doors)
	if player_spawn == Vector2i(-1, -1):
		player_spawn = Vector2i(mid_w, mid_h)
	var spawns: Array[Vector2i] = []
	for door in doors:
		spawns.append(door["cell"])
	return {
		"ok": true, "seed": -1, "width": w, "height": h, "grid": grid,
		"doors": doors, "spawns": spawns,
		"player_spawn": player_spawn,
		"room_count": 1, "floor_count": _count_floor(grid), "message": "",
	}


## 红门选址：放在地图内部的地板格上（最外圈被坚固墙壁封死，边界上没有缺口）。
## 用"最远点采样"分散 4 道门：先随机挑一道，之后每道都挑离已有红门最远的那格，
## 于是红门自然铺到场地四角附近，敌人从四个方向往中间涌。
func _place_interior_doors(grid: Array, w: int, h: int, rng: RandomNumberGenerator,
		require_2x2: bool = false) -> Array[Dictionary]:
	var candidates: Array[Vector2i] = []
	for y in range(DOOR_INSET, h - DOOR_INSET):
		for x in range(DOOR_INSET, w - DOOR_INSET):
			var cell := Vector2i(x, y)
			if _is_door_candidate(grid, w, h, cell, require_2x2):
				candidates.append(cell)
	var picked: Array[Vector2i] = []
	if candidates.is_empty():
		return []
	picked.append(candidates[rng.randi_range(0, candidates.size() - 1)])
	while picked.size() < DOOR_COUNT:
		var best := Vector2i(-1, -1)
		var best_score := -1.0
		for cell in candidates:
			var min_dist := INF
			var too_close := false
			for other in picked:
				var distance := Vector2(cell).distance_to(Vector2(other))
				if distance <= float(DOOR_MIN_GAP):
					too_close = true
					break
				min_dist = minf(min_dist, distance)
			if too_close or min_dist <= best_score:
				continue
			best_score = min_dist
			best = cell
		if best == Vector2i(-1, -1):
			break
		picked.append(best)
	var doors: Array[Dictionary] = []
	for cell in picked:
		doors.append({"cell": cell, "side": _door_side(cell, w, h), "step": DOOR_STEP})
	return doors


## 红门选址硬条件：门格与其第二格都是地板、离外圈够远（Boss 关还要 2x2 空地）
func _is_door_candidate(grid: Array, w: int, h: int, cell: Vector2i, require_2x2: bool) -> bool:
	if not _is_floor_cell(grid, w, h, cell):
		return false
	if not _is_floor_cell(grid, w, h, cell + DOOR_STEP):
		return false
	if cell.x < DOOR_INSET or cell.y < DOOR_INSET:
		return false
	if cell.x > w - 1 - DOOR_INSET or cell.y + DOOR_STEP.y > h - 1 - DOOR_INSET:
		return false
	if require_2x2 and not _is_2x2_clear(grid, w, h, cell):
		return false
	return true


## 红门"偏向哪一边"只用于调试显示与 Marker 命名（红门本身在场地内部）
func _door_side(cell: Vector2i, w: int, h: int) -> String:
	var d_left := cell.x
	var d_right := w - 1 - cell.x
	var d_top := cell.y
	var d_bottom := h - 1 - cell.y
	var smallest := mini(mini(d_left, d_right), mini(d_top, d_bottom))
	if smallest == d_left:
		return "left"
	if smallest == d_right:
		return "right"
	if smallest == d_top:
		return "top"
	return "bottom"


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
				# 地面贴图按"材质图"取：普通 / 严重破损 / 轻微破损
				var floor_tile := GROUND_TILE
				var tiles: Array = data.get("ground_tiles", [])
				if y * w + x < tiles.size():
					floor_tile = tiles[y * w + x]
				ground.set_cell(cell, GROUND_SOURCE, floor_tile)
			elif value == CELL_WALL:
				ground.set_cell(cell, GROUND_SOURCE, WALL_TILES[absi(x * 7 + y * 13 + x * y) % WALL_TILES.size()])
			else:
				# 最外圈：坚固墙壁，把整张地图完整包住（红门已经改到场地内部）
				ground.set_cell(cell, GROUND_SOURCE, TILE_WALL_SOLID)
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
		marker.name = "Spawn_%s_%d" % [String(door["side"]).capitalize(), markers.size()]
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
	var tiles: Array = data.get("ground_tiles", [])
	var text := ""
	for y in range(h):
		var line := ""
		for x in range(w):
			var cell := Vector2i(x, y)
			var index := y * w + x
			if cell == player:
				line += "P"
			elif door_cells.has(cell):
				line += "D"
			elif index < tiles.size() and tiles[index] == TILE_FLOOR_LAVA:
				line += "~"
			elif grid[index] == CELL_FLOOR:
				line += "."
			elif grid[index] == CELL_WALL:
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

## Boss 专用场地（单独一套规则，不沿用房间/走廊）：
##   ① 内部整片开阔地（没有 1 格宽的缝隙，Boss 的本体半径 16 不会被卡）
##   ② 障碍物只放 2~3 块，且每块都 >= 2x2（用户要求："障碍物至少 2 格宽、墙大量减少"）
##   ③ 边界墙只有外圈 1 格（用户要求："边界墙至多 2 格宽"）
func _generate_boss_arena(w: int, h: int, rng_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_FLOOR)
	_seal_border(grid, w, h)

	var obstacles: Array[Rect2i] = []
	var target_count := rng.randi_range(2, 3)
	for _index in range(target_count * 12):
		if obstacles.size() >= target_count:
			break
		var ow := rng.randi_range(2, 4)
		var oh := rng.randi_range(2, 3)
		if ow + 4 >= w or oh + 4 >= h:
			continue
		var candidate := Rect2i(rng.randi_range(3, w - ow - 4), rng.randi_range(3, h - oh - 4), ow, oh)
		var overlaps := false
		for existing in obstacles:
			if candidate.grow(2).intersects(existing):
				overlaps = true
				break
		if overlaps:
			continue
		obstacles.append(candidate)
		_fill_rect(grid, w, candidate, CELL_WALL)

	var doors: Array[Dictionary] = _place_interior_doors(grid, w, h, rng, true)
	if doors.size() != DOOR_COUNT:
		return {"ok": false, "reason": "Boss 场地红门放置失败(%d/%d)" % [doors.size(), DOOR_COUNT]}

	var player_spawn := _farthest_floor_from_doors(grid, w, h, doors)
	if player_spawn == Vector2i(-1, -1):
		return {"ok": false, "reason": "Boss 场地找不到玩家出生点"}

	var spawns: Array[Vector2i] = []
	for door in doors:
		spawns.append(door["cell"])

	var data := {
		"ok": true, "seed": rng_seed, "mode": MODE_BOSS, "width": w, "height": h,
		"grid": grid, "doors": doors, "spawns": spawns, "player_spawn": player_spawn,
		"room_count": 1, "obstacles": obstacles, "floor_count": _count_floor(grid), "message": "",
	}
	if not all_doors_reachable(data):
		return {"ok": false, "reason": "Boss 场地红门不可达"}
	if not is_boss_passable(data):
		return {"ok": false, "reason": "Boss 场地存在 1 格宽缝隙（Boss 会被卡住）"}
	return data


## Boss 通过性校验：只在"2x2 全空"的格子上做 flood fill，必须能到达每道红门内侧。
## 这样就保证了场地上不存在 1 格宽的缝隙 —— 半径 16 的 Boss 不会卡墙。
func is_boss_passable(data: Dictionary) -> bool:
	var w: int = data["width"]
	var h: int = data["height"]
	var grid: Array = data["grid"]
	var start: Vector2i = data["player_spawn"]
	if not _is_2x2_clear(grid, w, h, start):
		return false
	var visited := {}
	var queue: Array[Vector2i] = [start]
	visited[start] = true
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for dir in FOUR_DIRS:
			var next: Vector2i = cell + dir
			if visited.has(next) or not _is_2x2_clear(grid, w, h, next):
				continue
			visited[next] = true
			queue.append(next)
	for door in data["doors"]:
		# 红门在场地内部：只要 Boss 能走到覆盖门格的某个 2x2 锚点即可
		var reachable := false
		for offset in [Vector2i.ZERO, Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, -1)]:
			if visited.has(door["cell"] + offset):
				reachable = true
				break
		if not reachable:
			return false
	return true


func _is_2x2_clear(grid: Array, w: int, h: int, cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x + 1 >= w or cell.y + 1 >= h:
		return false
	return (grid[cell.y * w + cell.x] == CELL_FLOOR
		and grid[cell.y * w + cell.x + 1] == CELL_FLOOR
		and grid[(cell.y + 1) * w + cell.x] == CELL_FLOOR
		and grid[(cell.y + 1) * w + cell.x + 1] == CELL_FLOOR)


func _fill_rect(grid: Array, w: int, rect: Rect2i, value: int) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			grid[y * w + x] = value


# ============================ 绳子场地（新模式地基） ============================

## 绳子场地：一条宽 2~3 格的蛇形走廊，从地图一头蜿蜒到另一头。
## 规则：
##   ① 最外圈仍是坚固墙壁，走廊不贴边（始终留 1 格墙）
##   ② 走廊宽度固定 2~3 格、长度占满长边 -> 天然"狭长"
##   ③ 整张图只有这一条走廊：没有分支、没有孤立房间，走到哪都得沿绳子走
##   ④ 两头各一道红门；player_spawn 落在离两道门最远的位置（绳子中段）
## 返回数据里额外带 rope_axis / rope_width / rope_path（中心线格），
## 新模式以后可以沿中心线放守点、刷怪节奏段、推进目标等。
func _generate_rope_arena(w: int, h: int, rng_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var horizontal := w >= h
	var length := w if horizontal else h
	var thickness := h if horizontal else w
	if length < ROPE_LENGTH_MIN or thickness < ROPE_THICKNESS_MIN:
		return {"ok": false, "reason": "绳子场地尺寸不合适(%dx%d)" % [w, h]}
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_WALL)
	_seal_border(grid, w, h)

	var path_width := rng.randi_range(ROPE_PATH_WIDTH_MIN, ROPE_PATH_WIDTH_MAX)
	var center_min := 1
	var center_max := thickness - 2 - (path_width - 1)
	if center_max < center_min:
		return {"ok": false, "reason": "地图太窄，塞不下宽度 %d 的走廊" % path_width}

	# 中心线 = 一条低频正弦（保证整条绳子把短边兜满）+ 小幅随机抖动（免得像尺子画的）
	var mid := float(center_min + center_max) * 0.5
	var usable := float(center_max - center_min)
	var amplitude := usable * 0.5 * rng.randf_range(0.55, 1.0)
	var waves := rng.randf_range(1.0, 2.4)              # 整条绳子拐几个弯
	var phase := rng.randf_range(0.0, TAU)
	var wobble := 0
	var center := rng.randi_range(center_min, center_max)
	var rope_path: Array[Vector2i] = []
	for step in range(1, length - 1):
		var t := float(step) / float(maxi(1, length - 2))
		if rng.randf() < 0.5:
			wobble = clampi(wobble + rng.randi_range(-1, 1), -2, 2)
		# 每次只允许挪 1 格：保证相邻两段走廊始终有重叠格，
		# 否则抖动过猛时 2 格宽的走廊会断成好几截（红门就不可达了）
		var target := int(round(mid + amplitude * sin(phase + t * TAU * waves) + float(wobble)))
		center = clampi(target, center - 1, center + 1)
		center = clampi(center, center_min, center_max)
		rope_path.append(_rope_cell(horizontal, step, center))
		for k in range(path_width):
			var cell := _rope_cell(horizontal, step, center + k)
			grid[cell.y * w + cell.x] = CELL_FLOOR

	# 两头各一道红门（红门仍然竖着占 1x2 格，所以取"本格与下一格都在绳子上的"位置）
	var doors: Array[Dictionary] = []
	for end_step in [2, length - 3]:
		var cell := _rope_door_cell(grid, w, h, horizontal, end_step)
		if cell == Vector2i(-1, -1):
			return {"ok": false, "reason": "绳子场地红门找不到落脚点(step=%d)" % end_step}
		doors.append({"cell": cell, "side": _door_side(cell, w, h), "step": DOOR_STEP})
	if doors.size() != ROPE_DOOR_COUNT:
		return {"ok": false, "reason": "绳子场地红门数量不对(%d)" % doors.size()}

	var player_spawn := _farthest_floor_from_doors(grid, w, h, doors)
	if player_spawn == Vector2i(-1, -1):
		return {"ok": false, "reason": "绳子场地找不到玩家出生点"}
	var spawns: Array[Vector2i] = []
	for door in doors:
		spawns.append(door["cell"])

	var data := {
		"ok": true, "seed": rng_seed, "mode": MODE_ROPE, "width": w, "height": h,
		"grid": grid, "doors": doors, "spawns": spawns, "player_spawn": player_spawn,
		"room_count": 1, "obstacles": [], "floor_count": _count_floor(grid), "message": "",
		"rope_axis": "horizontal" if horizontal else "vertical",
		"rope_width": path_width,
		"rope_path": rope_path,
	}
	if not all_doors_reachable(data):
		return {"ok": false, "reason": "绳子场地红门不可达"}
	var min_floor := int(float(length - 2) * float(ROPE_PATH_WIDTH_MIN) * 0.6)
	if int(data["floor_count"]) < min_floor:
		return {"ok": false, "reason": "绳子场地地板过少(%d < %d)" % [data["floor_count"], min_floor]}
	return data


## 保底"绳子"：一条笔直居中的走廊，两头各一道红门（生成器连续失败时兜底）
func _straight_rope(w: int, h: int) -> Dictionary:
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_WALL)
	_seal_border(grid, w, h)
	var horizontal := w >= h
	var length := w if horizontal else h
	var thickness := h if horizontal else w
	var path_width := clampi(ROPE_PATH_WIDTH_MIN, 1, maxi(1, thickness - 4))
	var center := maxi(1, int(float(thickness - path_width) / 2.0))
	for step in range(1, length - 1):
		for k in range(path_width):
			var cell := _rope_cell(horizontal, step, center + k)
			grid[cell.y * w + cell.x] = CELL_FLOOR
	var doors: Array[Dictionary] = []
	for end_step in [2, length - 3]:
		var cell := _rope_door_cell(grid, w, h, horizontal, end_step)
		if cell == Vector2i(-1, -1):
			continue
		doors.append({"cell": cell, "side": _door_side(cell, w, h), "step": DOOR_STEP})
	var player_spawn := _farthest_floor_from_doors(grid, w, h, doors)
	if player_spawn == Vector2i(-1, -1):
		player_spawn = _rope_cell(horizontal, int(float(length) / 2.0), center)
	var spawns: Array[Vector2i] = []
	for door in doors:
		spawns.append(door["cell"])
	return {
		"ok": true, "seed": -1, "mode": MODE_ROPE, "width": w, "height": h, "grid": grid,
		"doors": doors, "spawns": spawns, "player_spawn": player_spawn,
		"room_count": 1, "obstacles": [], "floor_count": _count_floor(grid), "message": "",
		"rope_axis": "horizontal" if horizontal else "vertical",
		"rope_width": path_width, "rope_path": [],
	}


## 把外圈一整圈刷成边界墙（坚固墙壁）
func _seal_border(grid: Array, w: int, h: int) -> void:
	for x in range(w):
		grid[x] = CELL_EDGE
		grid[(h - 1) * w + x] = CELL_EDGE
	for y in range(h):
		grid[y * w] = CELL_EDGE
		grid[y * w + w - 1] = CELL_EDGE


## (沿绳子的第 step 格, 垂直于绳子的第 cross 格) -> 网格坐标
func _rope_cell(horizontal: bool, step: int, cross: int) -> Vector2i:
	return Vector2i(step, cross) if horizontal else Vector2i(cross, step)


## 找一根能放红门的落脚点：本格与下一格（DOOR_STEP 方向）都在绳子上
func _rope_door_cell(grid: Array, w: int, h: int, horizontal: bool, step_index: int) -> Vector2i:
	var cross_range := h if horizontal else w
	for cross in range(cross_range):
		var cell := _rope_cell(horizontal, step_index, cross)
		var second := cell + DOOR_STEP
		if not _in_bounds(cell, w, h) or not _in_bounds(second, w, h):
			continue
		if int(grid[cell.y * w + cell.x]) != CELL_FLOOR:
			continue
		if int(grid[second.y * w + second.x]) != CELL_FLOOR:
			continue
		return cell
	return Vector2i(-1, -1)
