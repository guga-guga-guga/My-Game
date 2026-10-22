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
## 房间门：动态瓦片.png 第二排那半张 16x16，4 帧循环动画（竖排烘焙成 门动画.png）
const ROOM_DOOR_SOURCE := 1
const ROOM_DOOR_TILE := Vector2i(0, 0)

# ---- 网格取值 ----
const CELL_FLOOR := 0
const CELL_WALL := 1
const CELL_EDGE := 2
## 空：既不铺地面也不铺墙（场外留空，视觉上是背景）
const CELL_VOID := 3

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
const MODE_PUSH := "push"
const MODE_MAZE := "maze"                              ## 迷宫关                              ## 推车关：宽路网 + 房间 + 单条警戒线

# ---- 绳子场地：一条宽 2~3 格的蛇形走廊，长边远大于短边 ----
const ROPE_LENGTH_MIN := 40                            ## 长边格数（绳子长度）
const ROPE_LENGTH_MAX := 96
const ROPE_THICKNESS_MIN := 12                         ## 短边格数（绳子能弯的空间）
const ROPE_THICKNESS_MAX := 20
const ROPE_PATH_WIDTH_MIN := 2                         ## 走廊宽度（格）
const ROPE_PATH_WIDTH_MAX := 3
const ROPE_DOOR_COUNT := 2                             ## 两头各一道红门

## 推车关尺寸随层数成长（用户要求：层数越高地图越长）
##   长边 = 60 + (层数-1) x 8，上限 96；短边 = 24 + (层数-1)，上限 34
static func push_length_for_floor(floor_index: int) -> int:
	return clampi(PUSH_LENGTH_MIN + (maxi(floor_index, 1) - 1) * 8, PUSH_LENGTH_MIN, PUSH_LENGTH_MAX)


static func push_thickness_for_floor(floor_index: int) -> int:
	return clampi(PUSH_THICKNESS_MIN + (maxi(floor_index, 1) - 1) * 2,
		PUSH_THICKNESS_MIN, PUSH_THICKNESS_MAX)


# ---- 迷宫关 ----
const MAZE_LENGTH_MIN := 44
const MAZE_LENGTH_MAX := 120
const MAZE_ENEMY_MIN := 10                             ## 迷宫关怪物数量区间
const MAZE_ENEMY_MAX := 20
const MAZE_SPAWN_SAFE_CELLS := 5                       ## 离玩家出生点多少格内不刷怪
const MAZE_SPAWN_GAP_CELLS := 3                        ## 怪物彼此至少相隔几格
const MAZE_THICKNESS_MIN := 28
const MAZE_THICKNESS_MAX := 64

# ---- 推车关：宽路网（主路 + 岔路 + 回环）+ 道路两侧房间 ----
## 长边格数：警戒线长度 ≈ 长边长度，5 分钟倒计时 + 3 秒/格 => 上限约 80 格
const PUSH_LENGTH_MIN := 60
const PUSH_LENGTH_MAX := 96
const PUSH_THICKNESS_MIN := 36                         ## 短边格数（要同时放主路矩形 + 环路）
const PUSH_THICKNESS_MAX := 52
const PUSH_ROAD_WIDTH := 5                             ## 主路宽度（格）
const PUSH_DETOUR_WIDTH := 4                           ## 岔路 / 回环宽度（格）
const PUSH_RING_WIDTH := 2                             ## 环路（八边形绳子）宽度
const PUSH_BRANCH_WIDTH := 3                           ## 支路（另一条街）的宽度
const PUSH_TRUNK_WIDTH := 5                            ## 主干（主路）宽度：要保证警戒线两侧各 1 格以上
const PUSH_BRANCH_MAX_WIDTH := 5                       ## 支路最宽 5 格（接口处固定 2 格）
const PUSH_GAP_CELLS := 0                              ## 主路与环/支路之间不留墙（马路直接相交）
const PUSH_RING_RADIUS_ALONG_MIN := 10                 ## 环路沿路方向的半径
const PUSH_RING_RADIUS_ALONG_MAX := 22
const PUSH_LOOP_COUNT_MIN := 2                         ## 回环数量
const PUSH_LOOP_COUNT_MAX := 4
const PUSH_BRANCH_COUNT_MIN := 4                       ## 岔路数量（用户要求支路多一些）
const PUSH_BRANCH_COUNT_MAX := 7
const PUSH_ROOM_ALONG_MIN := 5                         ## 房间尺寸（沿路方向 x 垂直方向）
const PUSH_ROOM_ALONG_MAX := 9
const PUSH_ROOM_ACROSS_MIN := 3
const PUSH_ROOM_ACROSS_MAX := 7
const PUSH_ROOM_COUNT_MIN := 4                         ## 房间数量随地图大小浮动
const PUSH_ROOM_COUNT_MAX := 20
const PUSH_DOORWAY_WIDTH_MIN := 1                      ## 房间门口宽度（格）
const PUSH_DOORWAY_WIDTH_MAX := 3
const PUSH_START_AREA := 1                             ## 起点/终点 3x3 警戒地板的半径
const PUSH_RED_DOOR_ROOMS_MAX := 3                     ## 最多几个房间里有红门
## 警戒标志地面：推车关的"轨道"，只占 1 格宽
const TILE_FLOOR_GUARD := Vector2i(2, 1)


func generate(width: int, height: int, rng_seed: int, mode: String = MODE_NORMAL,
		floor_index: int = 1, node_type: String = "") -> Dictionary:
	var w := width
	var h := height
	if mode == MODE_MAZE:
		var maze_long := clampi(maxi(width, height), MAZE_LENGTH_MIN, MAZE_LENGTH_MAX)
		var maze_short := clampi(mini(width, height), MAZE_THICKNESS_MIN, MAZE_THICKNESS_MAX)
		if width >= height:
			w = maze_long
			h = maze_short
		else:
			w = maze_short
			h = maze_long
	elif mode == MODE_PUSH:
		var push_long := clampi(maxi(width, height), PUSH_LENGTH_MIN, PUSH_LENGTH_MAX)
		var push_short := clampi(mini(width, height), PUSH_THICKNESS_MIN, PUSH_THICKNESS_MAX)
		if width >= height:
			w = push_long
			h = push_short
		else:
			w = push_short
			h = push_long
	elif mode == MODE_ROPE:
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
		var data := _generate_once(w, h, rng_seed + attempt, mode, floor_index, node_type)
		if data.get("ok", false):
			return _attach_ground_tiles(data, rng_seed + attempt)
		last_reason = String(data.get("reason", ""))
	var fallback := _straight_rope(w, h) if mode != MODE_NORMAL and mode != MODE_BOSS else _empty_room(w, h)
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
	if String(data.get("mode", "")) == MODE_PUSH or String(data.get("mode", "")) == MODE_MAZE:
		lava_budget = 0                    # 推车关/迷宫关不放初始岩浆（迷宫关的岩浆是 60 秒后才漫延出来的）
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

	# ③ 推车关：警戒地板（轨道 / 起终点 3x3 / 房间门口）最后刷，盖在其它材质之上
	for cell in data.get("push_guard_cells", []):
		if _is_floor_cell(grid, w, h, cell):
			tiles[cell.y * w + cell.x] = TILE_FLOOR_GUARD
	# 迷宫关：出口那 3x3 也铺警戒标志地面，方便玩家认
	for cell in data.get("maze_guard_cells", []):
		if _is_floor_cell(grid, w, h, cell):
			tiles[cell.y * w + cell.x] = TILE_FLOOR_GUARD
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


func _generate_once(w: int, h: int, rng_seed: int, mode: String = MODE_NORMAL,
		floor_index: int = 1, node_type: String = "") -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	if mode == MODE_BOSS:
		return _generate_boss_arena(w, h, rng_seed, node_type == "defend")
	if mode == MODE_ROPE:
		return _generate_rope_arena(w, h, rng_seed)
	if mode == MODE_PUSH:
		return _generate_push_arena(w, h, rng_seed, floor_index)
	if mode == MODE_MAZE:
		return _generate_maze_arena(w, h, rng_seed, floor_index)
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
		require_2x2: bool = false, door_count: int = DOOR_COUNT) -> Array[Dictionary]:
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
	while picked.size() < door_count:
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
			elif value == CELL_EDGE:
				# 最外圈：坚固墙壁，把整张地图完整包住（红门已经改到场地内部）
				ground.set_cell(cell, GROUND_SOURCE, TILE_WALL_SOLID)
			else:
				pass                      # CELL_VOID：场外留空，什么都不画
	# 推车关的房间门：每格门口铺一块 16x16 动态门瓦片（第二层）
	for room in data.get("rooms", []):
		for door_cell in room.get("door_cells", []):
			overlay.set_cell(door_cell, ROOM_DOOR_SOURCE, ROOM_DOOR_TILE)
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
			elif grid[index] == CELL_EDGE:
				line += "#"
			else:
				line += " "
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
func _generate_boss_arena(w: int, h: int, rng_seed: int, defend_layout: bool = false) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_FLOOR)
	_seal_border(grid, w, h)

	var obstacles: Array[Rect2i] = []
	# 守护关：障碍数量少量增加（3~4 块）；BOSS 关仍是 2~3 块
	var target_count := rng.randi_range(3, 4) if defend_layout else rng.randi_range(2, 3)
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

	var want_doors := 3 if defend_layout else DOOR_COUNT
	var doors: Array[Dictionary] = _place_interior_doors(grid, w, h, rng, true, want_doors)
	if doors.size() != want_doors:
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


# ============================ 推车关地形 ============================

## 推车关地形（按用户示意图重写）：
##   白色 = 主路：一条笔直横穿地图的大路，警戒线就压在这条路的中心线上
##   蓝色 = 回环：坐落在主路上/下方的八边形环路，底边搭在主路上，能绕一圈回到原处
##   黄色 = 支路：竖直的折线窄绳，从主路分出去、可以穿过主路一直伸到接近外墙
## 其余：路两侧挂房间（上锁房随机内容 / 敞开房放红门），起终点各 3x3 警戒地板
func _generate_push_arena(w: int, h: int, rng_seed: int, floor_index: int = 1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var horizontal := w >= h
	var length := w if horizontal else h
	var thickness := h if horizontal else w
	if length < PUSH_LENGTH_MIN or thickness < PUSH_THICKNESS_MIN:
		return {"ok": false, "reason": "推车关尺寸不合适(%dx%d)" % [w, h]}
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_WALL)
	_seal_border(grid, w, h)

	# 主路是一条"马路"：固定宽度（不再占短边 30%，那样整张图就是一块大长方形）
	var road_half := int(float(PUSH_ROAD_WIDTH) / 2.0)
	if thickness - 2 - road_half * 2 < 8:
		return {"ok": false, "reason": "推车关短边太窄(%d)" % thickness}
	var road_across := int(float(thickness) / 2.0)

	# ---- ① 主干：分段水平前进 + 偶尔上下挪几格（树枝式道路的主干，宽 3 格）----
	var trunk_half := int(float(PUSH_TRUNK_WIDTH) / 2.0)
	var across := int(float(thickness) / 2.0)
	var along := 3
	var trunk_cells: Array[Vector2i] = []
	while along < length - 4:
		var run := rng.randi_range(8, 16)
		for _step in range(run):
			if along >= length - 4:
				break
			trunk_cells.append(Vector2i(along, across))
			along += 1
		# 竖直挪一下（一格一格挪，保证相邻格永远只差 1）
		var room_up := across - (2 + trunk_half)
		var room_down := (thickness - 3 - trunk_half) - across
		var dy := rng.randi_range(-3, 3)
		dy = clampi(dy, -room_up, room_down)
		if dy == 0:
			continue
		var step_dir := 1 if dy > 0 else -1
		for _step in range(absi(dy)):
			across += step_dir
			trunk_cells.append(Vector2i(along - 1, across))
	if trunk_cells.size() < 12:
		return {"ok": false, "reason": "推车关主干太短(%d)" % trunk_cells.size()}
	for cell in trunk_cells:
		_push_fill(grid, w, h, horizontal, cell.x, cell.y - trunk_half, cell.x, cell.y + trunk_half)
	# 房间可以挂在主干上，也可以挂在支路上（后面一起用）
	var attach_points: Array[Vector2i] = []
	for cell in trunk_cells:
		attach_points.append(cell)

	# ---- ② 警戒线：走主干这条精确路径（相邻格只差 1）----
	var path: Array[Vector2i] = []
	path.resize(0)
	for cell in trunk_cells:
		path.append(_rope_cell(horizontal, cell.x, cell.y))

	# ---- ③ 树枝：从主干分出去的竖直支路（宽 3 格），部分支路再横向分小叉 ----
	var branch_tips: Array[Vector2i] = []
	var branch_count := rng.randi_range(PUSH_BRANCH_COUNT_MIN, PUSH_BRANCH_COUNT_MAX)
	var branch_reach_max := clampi(10 + (maxi(floor_index, 1) - 1) * 2, 10, 26)
	for _branch in range(branch_count):
		var start_index := rng.randi_range(4, maxi(5, trunk_cells.size() - 5))
		var start_cell: Vector2i = trunk_cells[start_index]
		var branch_dir := -1 if rng.randf() < 0.5 else 1
		var branch_across := start_cell.y
		var branch_along := start_cell.x
		# 支路宽度最宽 5 格；和主路交接的地方只开 2 格宽的"接口"，不要连通一大片
		var branch_width := rng.randi_range(2, PUSH_BRANCH_MAX_WIDTH)
		var neck_steps := 2
		var steps := rng.randi_range(maxi(4, int(float(branch_reach_max) * 0.5)), branch_reach_max)
		for _step in range(steps):
			branch_across += branch_dir
			if branch_across < 2 + trunk_half or branch_across > thickness - 3 - trunk_half:
				break
			var cell_width := 2 if _step < neck_steps else branch_width
			var from_along := branch_along - int(float(cell_width) / 2.0)
			_push_fill(grid, w, h, horizontal, from_along, branch_across,
				from_along + cell_width - 1, branch_across)
			attach_points.append(Vector2i(branch_along, branch_across))
		# 末端小平台
		_push_fill(grid, w, h, horizontal, branch_along - 1, branch_across - 1,
			branch_along + 1, branch_across + 1)
		branch_tips.append(Vector2i(branch_along, branch_across))
		# 一半的支路再横向分一个小叉
		if rng.randf() < 0.55:
			var sub_dir := 1 if rng.randf() < 0.5 else -1
			var sub_along := branch_along
			for _sub in range(rng.randi_range(3, 6)):
				sub_along = clampi(sub_along + sub_dir, 3 + trunk_half, length - 4 - trunk_half)
				_push_fill(grid, w, h, horizontal, sub_along, branch_across - trunk_half,
					sub_along, branch_across + trunk_half)

	# ---- ④ 回环：把一条支路末端水平接到主干另一处，围出一块闭环 ----
	if branch_tips.size() >= 1 and rng.randf() < 0.85:
		var tip: Vector2i = branch_tips[0]
		var walk_along := tip.x
		var step_along := 1 if (tip.x + 12) < (length - 5) else -1
		for _step in range(rng.randi_range(8, 14)):
			walk_along = clampi(walk_along + step_along, 3 + trunk_half, length - 4 - trunk_half)
			_push_fill(grid, w, h, horizontal, walk_along, tip.y - trunk_half,
				walk_along, tip.y + trunk_half)
		# 竖直接回主干
		var walk_across := tip.y
		var target_across := trunk_cells[clampi(int(float(trunk_cells.size()) / 2.0), 0, trunk_cells.size() - 1)].y
		var step_across := 1 if target_across > walk_across else -1
		while walk_across != target_across:
			_push_fill(grid, w, h, horizontal, walk_along - trunk_half, walk_across,
				walk_along + trunk_half, walk_across)
			walk_across += step_across

	# ---- ⑤ 房间：挂在主路两侧（撞到环路/支路就换位置）----
	var rooms: Array[Dictionary] = []
	var guard_cells: Array[Vector2i] = []
	var room_count := clampi(int(float(length) / 8.0), PUSH_ROOM_COUNT_MIN, PUSH_ROOM_COUNT_MAX)
	var across_space := thickness - 2 - (road_half + 2) - 2
	if across_space < PUSH_ROOM_ACROSS_MIN:
		return {"ok": false, "reason": "推车关短边塞不下房间(%d)" % thickness}
	var room_stride := maxi(4, int(float(attach_points.size()) / float(room_count + 1)))
	var slot_index := room_stride
	while slot_index < attach_points.size() - 2 and rooms.size() < room_count:
		var wp: Vector2i = attach_points[slot_index]
		var dirs: Array[Vector2i] = [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]
		for dir in dirs:
			if rooms.size() >= room_count:
				break
			for _attempt in range(4):
				if _push_try_room(grid, w, h, horizontal, length, thickness, road_half,
						wp, dir, across_space, rng, rooms, guard_cells):
					break
		slot_index += room_stride
	if rooms.size() < PUSH_ROOM_COUNT_MIN:
		return {"ok": false, "reason": "推车关房间太少(%d)" % rooms.size()}
	_push_force_third_locked_ally_room(rooms, path)

	# ---- ⑥ 红门：只放在未上锁的房间里 ----
	var red_door_rooms: Array[int] = []
	var order: Array[int] = []
	for i in range(rooms.size()):
		order.append(i)
	order.shuffle()
	for i in order:
		if red_door_rooms.size() >= PUSH_RED_DOOR_ROOMS_MAX:
			break
		var room: Dictionary = rooms[i]
		if bool(room["locked"]):
			continue
		var spot := _push_red_door_cell(grid, w, h, room["rect"], room["door_cells"])
		if spot == Vector2i(-1, -1):
			continue
		room["red_door_cell"] = spot
		room["spawn_enabled"] = true
		rooms[i] = room
		red_door_rooms.append(i)

	# ---- ⑦ 起点 / 终点：各 3x3 警戒地板 ----
	var start_center: Vector2i = path[0]
	var end_center: Vector2i = path[path.size() - 1]
	var start_area := _push_area_cells(grid, w, h, start_center)
	var end_area := _push_area_cells(grid, w, h, end_center)
	for cell in path:
		guard_cells.append(cell)
	guard_cells.append_array(start_area)
	guard_cells.append_array(end_area)

	var doors: Array[Dictionary] = []
	for i in red_door_rooms:
		var room: Dictionary = rooms[i]
		var cell: Vector2i = room["red_door_cell"]
		doors.append({"cell": cell, "side": _door_side(cell, w, h), "step": DOOR_STEP, "room": i})
	var spawns: Array[Vector2i] = []
	for door in doors:
		spawns.append(door["cell"])

	var data := {
		"ok": true, "seed": rng_seed, "mode": MODE_PUSH, "width": w, "height": h,
		"grid": grid, "doors": doors, "spawns": spawns, "player_spawn": start_center,
		"room_count": rooms.size(), "obstacles": [], "floor_count": _count_floor(grid), "message": "",
		"rope_axis": "horizontal" if horizontal else "vertical",
		"push_path": path,
		"push_start": start_center,
		"push_end": end_center,
		"push_start_area": start_area,
		"push_end_area": end_area,
		"push_guard_cells": guard_cells,
		"rooms": rooms,
	}
	# 兜底：保证警戒线每一格的九宫格都是地面（用户硬要求）
	_push_widen_path(grid, w, h, path)
	# 兜底：把零碎的小地板缝回主体，避免地形生成因为连通性被打回
	_push_connect_components(grid, w, h, horizontal)
	# 薄墙化：离可走地面超过 3 格的墙改成"空"，场外留空（墙只有 1~3 格厚）
	_push_thin_walls(grid, w, h)

	if not _push_path_is_valid(grid, w, h, path):
		var bad_cell := Vector2i(-1, -1)
		for i in range(path.size()):
			var cell: Vector2i = path[i]
			if not _in_bounds(cell, w, h) or int(grid[cell.y * w + cell.x]) != CELL_FLOOR:
				bad_cell = cell
				break
			if i > 0:
				var prev: Vector2i = path[i - 1]
				if absi(prev.x - cell.x) + absi(prev.y - cell.y) != 1:
					bad_cell = cell
					break
		return {"ok": false, "reason": "推车关警戒线不合法（坏格 %s）" % str(bad_cell),
			"grid": grid, "width": w, "height": h}
	var comps := _floor_components(grid, w, h)
	if comps != 1:
		# 失败时也把 grid 带上，方便定位是哪一块没连上
		return {"ok": false, "reason": "推车关地面分成 %d 块（应该整张图连成一片）" % comps,
			"grid": grid, "width": w, "height": h}
	return data


## 挖一个八边形环路（宽度 2 格的绳子）
func _carve_push_ring(grid: Array, w: int, h: int, horizontal: bool,
		center_along: int, center_across: int, radius_along: int, radius_across: int) -> void:
	var steps := maxi(32, (radius_along + radius_across) * 4)
	for i in range(steps):
		var t := TAU * float(i) / float(steps)
		var ca := cos(t)
		var sa := sin(t)
		# 超椭圆（p=4）近似八边形
		var denom := pow(pow(absf(ca), 4.0) + pow(absf(sa), 4.0), 0.25)
		if denom <= 0.0001:
			continue
		var along := center_along + int(round(float(radius_along) * ca / denom))
		var across := center_across + int(round(float(radius_across) * sa / denom))
		_push_fill(grid, w, h, horizontal, along, across, along + PUSH_RING_WIDTH - 1,
			across + PUSH_RING_WIDTH - 1)


## 挖一条竖直折线支路（宽 2 格的绳子），允许左右抖
func _carve_push_branch(grid: Array, w: int, h: int, horizontal: bool, along_start: int,
		across_start: int, dir: int, steps: int, rng: RandomNumberGenerator) -> void:
	var along := along_start
	var across := across_start
	var jog := 0
	var max_along := (w - 4) if horizontal else (h - 4)
	var max_across := (h - 3) if horizontal else (w - 3)
	var last_along := along
	var last_across := across
	for step_index in range(steps):
		if jitter_should_jog(step_index):
			jog = rng.randi_range(-1, 1)
		var draw_along := clampi(along + jog, 2, max_along)
		if across < 2 or across > max_across:
			break
		_push_fill(grid, w, h, horizontal, draw_along, across, draw_along + 1, across)
		last_along = draw_along
		last_across = across
		across += dir
	# 尽头小平台紧贴真正画到的最后一格（否则会留下孤立方块）
	_push_fill(grid, w, h, horizontal, last_along - 1, last_across - 1, last_along + 2, last_across + 1)

func jitter_should_jog(step_index: int) -> bool:
	return step_index % 3 == 2


## 自然上锁（进关卡时就锁着）的房间按警戒线上的先后排序，第 3 个改成临时队友房。
## 如果上锁房间不到 3 个，就把靠后的敞开房间改成上锁，保证规则一定成立。
func _push_force_third_locked_ally_room(rooms: Array[Dictionary], path: Array[Vector2i]) -> void:
	var locked: Array[int] = []
	for i in range(rooms.size()):
		if bool(rooms[i]["locked"]):
			locked.append(i)
	for i in range(rooms.size()):
		if locked.size() >= 3:
			break
		if not bool(rooms[i]["locked"]):
			var state: Dictionary = rooms[i]
			state["locked"] = true
			state["content"] = "empty"
			rooms[i] = state
			locked.append(i)
	if locked.size() < 3:
		return
	locked.sort_custom(func(a: int, b: int) -> bool:
		return _push_room_path_index(rooms[a], path) < _push_room_path_index(rooms[b], path))
	var target: Dictionary = rooms[locked[2]]
	target["content"] = "ally"
	target["ally_count"] = 1
	target["enemy_count"] = 0
	target["item_count"] = 0
	rooms[locked[2]] = target


## 这个房间的门口在警戒线上大概排第几格（用来排"玩家遇到的顺序"）
func _push_room_path_index(room: Dictionary, path: Array[Vector2i]) -> int:
	var cells: Array = room.get("door_cells", [])
	if cells.is_empty() or path.is_empty():
		return 0
	var center := Vector2.ZERO
	for cell in cells:
		center += Vector2(cell)
	center /= float(cells.size())
	var best_index := 0
	var best_distance := INF
	for i in range(path.size()):
		var distance := Vector2(path[i]).distance_to(center)
		if distance < best_distance:
			best_distance = distance
			best_index = i
	return best_index

func _push_fill(grid: Array, w: int, h: int, horizontal: bool, a0: int, c0: int, a1: int, c1: int) -> void:
	for a in range(mini(a0, a1), maxi(a0, a1) + 1):
		for c in range(mini(c0, c1), maxi(c0, c1) + 1):
			var cell := _rope_cell(horizontal, a, c)
			if cell.x <= 0 or cell.y <= 0 or cell.x >= w - 1 or cell.y >= h - 1:
				continue
			grid[cell.y * w + cell.x] = CELL_FLOOR


## L 形宽走廊：先沿长边走，再沿短边走
func _carve_push_segment(grid: Array, w: int, h: int, horizontal: bool, a: Vector2i, b: Vector2i, width: int) -> void:
	var half := int(float(width) / 2.0)
	_push_fill(grid, w, h, horizontal, mini(a.x, b.x), a.y - half, maxi(a.x, b.x), a.y + half)
	_push_fill(grid, w, h, horizontal, b.x - half, mini(a.y, b.y), b.x + half, maxi(a.y, b.y))


## 把 L 形中心线按顺序追加进格序列（相邻重复格只留一个）
func _append_push_line(path: Array[Vector2i], horizontal: bool, a: Vector2i, b: Vector2i) -> void:
	var step_along := 1 if b.x >= a.x else -1
	var x := a.x
	while x != b.x:
		_push_append_cell(path, _rope_cell(horizontal, x, a.y))
		x += step_along
	var step_across := 1 if b.y >= a.y else -1
	var y := a.y
	while y != b.y:
		_push_append_cell(path, _rope_cell(horizontal, b.x, y))
		y += step_across
	_push_append_cell(path, _rope_cell(horizontal, b.x, b.y))


func _push_append_cell(path: Array[Vector2i], cell: Vector2i) -> void:
	if path.is_empty() or path[path.size() - 1] != cell:
		path.append(cell)


## 这块矩形（含端点）是否全是可以改动的墙：用来判断房间会不会撞到已有道路/房间
func _push_rect_is_wall(grid: Array, w: int, h: int, horizontal: bool, a0: int, c0: int, a1: int, c1: int) -> bool:
	for a in range(mini(a0, a1), maxi(a0, a1) + 1):
		for c in range(mini(c0, c1), maxi(c0, c1) + 1):
			var cell := _rope_cell(horizontal, a, c)
			if cell.x <= 1 or cell.y <= 1 or cell.x >= w - 2 or cell.y >= h - 2:
				return false
			if int(grid[cell.y * w + cell.x]) != CELL_WALL:
				return false
	return true


## 房间内部找一个能放红门的格子（本格与下一格都是地板，且不在门口）
func _push_red_door_cell(grid: Array, w: int, h: int, rect: Rect2i, door_cells: Array) -> Vector2i:
	for y in range(rect.position.y, rect.end.y - DOOR_STEP.y):
		for x in range(rect.position.x, rect.end.x):
			var cell := Vector2i(x, y)
			var second := cell + DOOR_STEP
			if door_cells.has(cell) or door_cells.has(second):
				continue
			if int(grid[cell.y * w + cell.x]) != CELL_FLOOR:
				continue
			if int(grid[second.y * w + second.x]) != CELL_FLOOR:
				continue
			return cell
	return Vector2i(-1, -1)


## 起点/终点：以中心格为中心的 3x3 区域，全部挖成可走地面
func _push_area_cells(grid: Array, w: int, h: int, center: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var radius := PUSH_START_AREA
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var cell := center + Vector2i(int(dx), int(dy))
			if cell.x <= 0 or cell.y <= 0 or cell.x >= w - 1 or cell.y >= h - 1:
				continue
			grid[cell.y * w + cell.x] = CELL_FLOOR
			cells.append(cell)
	return cells


## 警戒线必须整条落在可走地面上，且每一格与下一格相邻
func _push_path_is_valid(grid: Array, w: int, h: int, path: Array[Vector2i]) -> bool:
	for i in range(path.size()):
		var cell: Vector2i = path[i]
		if not _in_bounds(cell, w, h):
			return false
		if int(grid[cell.y * w + cell.x]) != CELL_FLOOR:
			return false
		if i > 0:
			var prev: Vector2i = path[i - 1]
			if absi(prev.x - cell.x) + absi(prev.y - cell.y) != 1:
				return false
	return true


## 地面连通块个数（推车关必须整张图连成一片）
func _floor_components(grid: Array, w: int, h: int) -> int:
	var seen := {}
	var comps := 0
	for y in range(h):
		for x in range(w):
			var start := Vector2i(x, y)
			if int(grid[y * w + x]) != CELL_FLOOR or seen.has(start):
				continue
			comps += 1
			var queue: Array[Vector2i] = [start]
			seen[start] = true
			while not queue.is_empty():
				var cell: Vector2i = queue.pop_front()
				for dir in FOUR_DIRS:
					var next: Vector2i = cell + dir
					if not _in_bounds(next, w, h):
						continue
					if seen.has(next) or int(grid[next.y * w + next.x]) != CELL_FLOOR:
						continue
					seen[next] = true
					queue.append(next)
	return comps


## 试着在道路某一侧的 wp 处挂一个房间：挖房间 + 开门口 + 记房间信息。
## 成功返回 true；位置放不下（撞到别的房间/路，或超出地图）返回 false。
func _push_try_room(grid: Array, w: int, h: int, horizontal: bool, length: int, thickness: int,
		road_half: int, wp: Vector2i, dir: Vector2i, across_space: int, rng: RandomNumberGenerator,
		rooms: Array[Dictionary], guard_cells: Array[Vector2i]) -> bool:
	# dir 是 (沿路方向, 垂直方向) 上的朝向：(0,-1) 上 / (0,1) 下 / (-1,0) 左 / (1,0) 右
	# 先试随机尺寸，放不下再依次缩小（贴着边界的地方也能塞进小房间）
	for attempt in range(3):
		var ra := 0
		var rc := 0
		if attempt == 0:
			ra = rng.randi_range(PUSH_ROOM_ALONG_MIN, PUSH_ROOM_ALONG_MAX)
			rc = rng.randi_range(PUSH_ROOM_ACROSS_MIN, mini(PUSH_ROOM_ACROSS_MAX, across_space))
		elif attempt == 1:
			ra = PUSH_ROOM_ALONG_MIN
			rc = mini(PUSH_ROOM_ACROSS_MIN, across_space)
		else:
			ra = maxi(3, PUSH_ROOM_ALONG_MIN - 1)
			rc = maxi(3, PUSH_ROOM_ACROSS_MIN - 1)
		if rc < 2 or ra < 3:
			continue
		var a0 := 0
		var a1 := 0
		var c0 := 0
		var c1 := 0
		var wall_along := 0
		var wall_across := 0
		if dir.y != 0:
			# 上下房间：宽度沿路方向展开
			wall_across = wp.y + dir.y * (road_half + 1)
			a0 = wp.x - int(ra / 2.0)
			a1 = a0 + ra - 1
			if dir.y > 0:
				c0 = wall_across + 1
				c1 = c0 + rc - 1
			else:
				c1 = wall_across - 1
				c0 = c1 - rc + 1
		else:
			# 左右房间：宽度垂直路方向展开
			wall_along = wp.x + dir.x * (road_half + 1)
			c0 = wp.y - int(rc / 2.0)
			c1 = c0 + rc - 1
			if dir.x > 0:
				a0 = wall_along + 1
				a1 = a0 + ra - 1
			else:
				a1 = wall_along - 1
				a0 = a1 - ra + 1
		if a0 < 2 or a1 > length - 3 or c0 < 2 or c1 > thickness - 3:
			continue
		# 只要求房间本身还是墙；房间四周的墙下面会"重新砌一遍"，保证房间不会和路连通
		if not _push_rect_is_wall(grid, w, h, horizontal, a0, c0, a1, c1):
			continue
		_push_fill(grid, w, h, horizontal, a0, c0, a1, c1)

		# 门口：在靠路那面墙上开 1~3 格
		var door_cells: Array[Vector2i] = []
		if dir.y != 0:
			var doorway_w := rng.randi_range(PUSH_DOORWAY_WIDTH_MIN, mini(PUSH_DOORWAY_WIDTH_MAX, a1 - a0 + 1))
			var da0 := clampi(wp.x - int(float(doorway_w) / 2.0), a0, a1 - doorway_w + 1)
			for da in range(da0, da0 + doorway_w):
				var cell := _rope_cell(horizontal, da, wall_across)
				grid[cell.y * w + cell.x] = CELL_FLOOR
				door_cells.append(cell)
		else:
			var doorway_h := rng.randi_range(PUSH_DOORWAY_WIDTH_MIN, mini(PUSH_DOORWAY_WIDTH_MAX, c1 - c0 + 1))
			var dc0 := clampi(wp.y - int(float(doorway_h) / 2.0), c0, c1 - doorway_h + 1)
			for dc in range(dc0, dc0 + doorway_h):
				var cell2 := _rope_cell(horizontal, wall_along, dc)
				grid[cell2.y * w + cell2.x] = CELL_FLOOR
				door_cells.append(cell2)
		if door_cells.is_empty():
			continue
		# 门口朝路的一侧再挖最多 3 格，保证一定接上真实路面
		# （房间可能挂在主路、也可能挂在支路上，两者宽度不同，接口位置会有偏差）
		for door_cell in door_cells:
			var probe_a := 0
			var probe_c := 0
			if dir.y != 0:
				probe_a = door_cell.x if horizontal else door_cell.y
				probe_c = door_cell.y if horizontal else door_cell.x
			else:
				probe_a = door_cell.x if horizontal else door_cell.y
				probe_c = door_cell.y if horizontal else door_cell.x
			for _step in range(1, 4):
				probe_a -= dir.x
				probe_c -= dir.y
				var probe_cell := _rope_cell(horizontal, probe_a, probe_c)
				if probe_cell.x <= 1 or probe_cell.y <= 1 						or probe_cell.x >= w - 2 or probe_cell.y >= h - 2:
					break
				if int(grid[probe_cell.y * w + probe_cell.x]) == CELL_FLOOR:
					break                    # 已经接上路面了
				grid[probe_cell.y * w + probe_cell.x] = CELL_FLOOR
		for door_cell in door_cells:
			guard_cells.append(door_cell)
		# 把房间四周重新砌一圈墙（门口那几格留空），保证房间不会和外面的路连成一片
		for ring_a in range(a0 - 1, a1 + 2):
			for ring_c in range(c0 - 1, c1 + 2):
				if ring_a >= a0 and ring_a <= a1 and ring_c >= c0 and ring_c <= c1:
					continue
				var ring_cell := _rope_cell(horizontal, ring_a, ring_c)
				if ring_cell.x <= 1 or ring_cell.y <= 1 						or ring_cell.x >= w - 2 or ring_cell.y >= h - 2:
					continue
				if door_cells.has(ring_cell):
					continue
				grid[ring_cell.y * w + ring_cell.x] = CELL_WALL

		# 上锁房间才随机那 4 种内容（敌人/道具/队友/空，各 25%）；
		# 未上锁的敞开房间只放红门，不放这些内容（用户规则）
		var locked := rng.randf() < 0.5
		var content := "empty"
		if locked:
			var roll := rng.randf()
			if roll < 0.25:
				content = "enemy"
			elif roll < 0.5:
				content = "item"
			elif roll < 0.75:
				content = "ally"
		var rect_origin := _rope_cell(horizontal, a0, c0)
		var rect_size := Vector2i(a1 - a0 + 1, c1 - c0 + 1)
		if not horizontal:
			rect_size = Vector2i(c1 - c0 + 1, a1 - a0 + 1)
		rooms.append({
			"rect": Rect2i(rect_origin, rect_size),
			"door_cells": door_cells,
			"content": content,
			"enemy_count": rng.randi_range(1, 6) if content == "enemy" else 0,
			"item_count": rng.randi_range(1, 2) if content == "item" else 0,
			"ally_count": 1 if content == "ally" else 0,
			"locked": locked,
			"red_door_cell": Vector2i(-1, -1),
			"door_step": DOOR_STEP,
			"spawn_enabled": false,
		})
		return true
	return false
func _push_segment_free(w: int, h: int, horizontal: bool, a: Vector2i, b: Vector2i, width: int,
		room_rects: Array[Rect2i]) -> bool:
	var half := int(float(width) / 2.0)
	var rects: Array[Rect2i] = [
		_push_rect_from_bounds(horizontal, mini(a.x, b.x), a.y - half, maxi(a.x, b.x), a.y + half),
		_push_rect_from_bounds(horizontal, b.x - half, mini(a.y, b.y), b.x + half, maxi(a.y, b.y)),
	]
	for rect in rects:
		if rect.position.x < 2 or rect.position.y < 2 or rect.end.x > w - 2 or rect.end.y > h - 2:
			return false
		for room_rect in room_rects:
			if rect.grow(1).intersects(room_rect.grow(1)):
				return false
	return true


## (沿路, 垂直) 坐标下的矩形 -> 网格矩形
func _push_rect_from_bounds(horizontal: bool, a0: int, c0: int, a1: int, c1: int) -> Rect2i:
	var origin := _rope_cell(horizontal, mini(a0, a1), mini(c0, c1))
	var along_span := absi(a1 - a0) + 1
	var across_span := absi(c1 - c0) + 1
	var size := Vector2i(along_span, across_span)
	if not horizontal:
		size = Vector2i(across_span, along_span)
	return Rect2i(origin, size)


## 把所有孤立的零碎地板用 1 格宽的小通道缝回最大那块（生成完地形后兜底）
func _push_connect_components(grid: Array, w: int, h: int, horizontal: bool) -> void:
	for _guard in range(8):
		var labels := _push_label_components(grid, w, h)
		if labels.size() <= 1:
			return
		# 找最大的一块当主体
		var main_index := 0
		var main_size := -1
		for i in range(labels.size()):
			var size: int = (labels[i]["cells"] as Array).size()
			if size > main_size:
				main_size = size
				main_index = i
		var main_cells: Array = labels[main_index]["cells"]
		for i in range(labels.size()):
			if i == main_index:
				continue
			var cells: Array = labels[i]["cells"]
			if cells.is_empty():
				continue
			# 找距离最近的一对格子，挖一条 L 形通道把它们接起来
			var best_a: Vector2i = cells[0]
			var best_b: Vector2i = main_cells[0]
			var best_distance := -1
			for ca in cells:
				for cb in main_cells:
					var distance: int = absi(ca.x - cb.x) + absi(ca.y - cb.y)
					if best_distance < 0 or distance < best_distance:
						best_distance = distance
						best_a = ca
						best_b = cb
			var step_x := 1 if best_b.x >= best_a.x else -1
			var walk_x := best_a.x
			while walk_x != best_b.x:
				_push_fill(grid, w, h, horizontal, walk_x, best_a.y, walk_x, best_a.y)
				walk_x += step_x
			var step_y := 1 if best_b.y >= best_a.y else -1
			var walk_y := best_a.y
			while walk_y != best_b.y:
				_push_fill(grid, w, h, horizontal, best_b.x, walk_y, best_b.x, walk_y)
				walk_y += step_y


## 给每块地板打标签（返回 [{cells: Array}, ...]）
func _push_label_components(grid: Array, w: int, h: int) -> Array[Dictionary]:
	var seen := {}
	var out: Array[Dictionary] = []
	for y in range(h):
		for x in range(w):
			var start := Vector2i(x, y)
			if int(grid[y * w + x]) != CELL_FLOOR or seen.has(start):
				continue
			var cells: Array[Vector2i] = []
			var queue: Array[Vector2i] = [start]
			seen[start] = true
			while not queue.is_empty():
				var cell: Vector2i = queue.pop_front()
				cells.append(cell)
				for dir in FOUR_DIRS:
					var next: Vector2i = cell + dir
					if not _in_bounds(next, w, h):
						continue
					if seen.has(next) or int(grid[next.y * w + next.x]) != CELL_FLOOR:
						continue
					seen[next] = true
					queue.append(next)
			out.append({"cells": cells})
	return out


## 薄墙化：离可走地面超过 3 格的墙格改成 CELL_VOID（不画瓦片）。
## 这样地图上只剩 1~3 格厚的墙体轮廓，其余是场外留空，不会出现大片实心墙。
func _push_thin_walls(grid: Array, w: int, h: int) -> void:
	const MAX_THICKNESS := 3
	var near := {}
	var queue: Array[Vector2i] = []
	for y in range(h):
		for x in range(w):
			if int(grid[y * w + x]) == CELL_FLOOR:
				var cell := Vector2i(x, y)
				near[cell] = 0
				queue.append(cell)
	while not queue.is_empty():
		var cell2: Vector2i = queue.pop_front()
		var dist: int = int(near[cell2])
		if dist >= MAX_THICKNESS:
			continue
		for dir in FOUR_DIRS:
			var next: Vector2i = cell2 + dir
			if not _in_bounds(next, w, h) or near.has(next):
				continue
			near[next] = dist + 1
			queue.append(next)
	for y in range(h):
		for x in range(w):
			var value: int = int(grid[y * w + x])
			if value != CELL_WALL:
				continue                     # 外圈边界墙（CELL_EDGE）保持不动
			if not near.has(Vector2i(x, y)):
				grid[y * w + x] = CELL_VOID


## 保证警戒线（警戒地板）每一格周围 3x3 全是地面：
## 把线路上每格为中心的九宫格都填成地板，箱子/玩家推车时不会被挤在单格通道里。
func _push_widen_path(grid: Array, w: int, h: int, path: Array[Vector2i]) -> void:
	for cell in path:
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var target := Vector2i(cell.x + int(dx), cell.y + int(dy))
				if target.x <= 0 or target.y <= 0 or target.x >= w - 1 or target.y >= h - 1:
					continue
				grid[target.y * w + target.x] = CELL_FLOOR

## 迷宫关占地随层数成长：长边 = 40+(层-1)*4（上限 76），短边 = 26+(层-1)*2（上限 44）
static func maze_length_for_floor(floor_index: int) -> int:
	return clampi(MAZE_LENGTH_MIN + (maxi(floor_index, 1) - 1) * 8, MAZE_LENGTH_MIN, MAZE_LENGTH_MAX)


static func maze_thickness_for_floor(floor_index: int) -> int:
	return clampi(MAZE_THICKNESS_MIN + (maxi(floor_index, 1) - 1) * 4,
		MAZE_THICKNESS_MIN, MAZE_THICKNESS_MAX)


# ============================ 迷宫关地形 ============================

## 迷宫关：随机 DFS 挖出来的迷宫，走廊 2 格宽、墙 1 格厚。
## 起点在一侧，出口在另一侧（3x3）；另有若干怪物出生点，供 battle 摆怪。
## 60 秒后的"警戒指引线"和"岩浆漫延"由 battle 运行时处理。
func _generate_maze_arena(w: int, h: int, rng_seed: int, floor_index: int = 1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var horizontal := w >= h
	var length := w if horizontal else h
	var thickness := h if horizontal else w
	if length < MAZE_LENGTH_MIN or thickness < MAZE_THICKNESS_MIN:
		return {"ok": false, "reason": "迷宫关尺寸不合适(%dx%d)" % [w, h]}
	var grid: Array = []
	grid.resize(w * h)
	grid.fill(CELL_WALL)
	_seal_border(grid, w, h)

	const STEP := 3                     # 每格：2x2 地面 + 1 格墙
	var cols := int(float(length - 4) / float(STEP))
	var rows := int(float(thickness - 4) / float(STEP))
	if cols < 4 or rows < 4:
		return {"ok": false, "reason": "迷宫格数太少(%dx%d)" % [cols, rows]}

	# ---- 随机 Prim 生成迷宫（比 DFS 的岔路更多、不会一条长蛇走到底）----
	var visited := {}
	var order: Array[Vector2i] = []
	var start_cell := Vector2i(0, rng.randi_range(0, rows - 1))
	visited[start_cell] = true
	order.append(start_cell)
	var frontier: Array[Vector2i] = []
	for dir in FOUR_DIRS:
		var nxt: Vector2i = start_cell + dir
		if nxt.x >= 0 and nxt.y >= 0 and nxt.x < cols and nxt.y < rows:
			frontier.append(nxt)
	while not frontier.is_empty():
		var pick_index := rng.randi_range(0, frontier.size() - 1)
		var cell: Vector2i = frontier[pick_index]
		frontier.remove_at(pick_index)
		if visited.has(cell):
			continue
		# 从已加入的邻居里随机挑一个打通
		var joined: Array[Vector2i] = []
		for dir2 in FOUR_DIRS:
			var nb: Vector2i = cell + dir2
			if nb.x < 0 or nb.y < 0 or nb.x >= cols or nb.y >= rows:
				continue
			if visited.has(nb):
				joined.append(nb)
		if joined.is_empty():
			continue
		var link: Vector2i = joined[rng.randi_range(0, joined.size() - 1)]
		_carve_maze_link(grid, w, h, horizontal, link, cell)
		visited[cell] = true
		order.append(cell)
		for dir3 in FOUR_DIRS:
			var nb2: Vector2i = cell + dir3
			if nb2.x < 0 or nb2.y < 0 or nb2.x >= cols or nb2.y >= rows:
				continue
			if not visited.has(nb2):
				frontier.append(nb2)
	# 再补一批"死胡同短枝"：从已有走廊往外挖 1 格，增加岔路数量
	var spur_count := int(float(order.size()) / 4.0)
	for _spur in range(spur_count):
		var base: Vector2i = order[rng.randi_range(0, order.size() - 1)]
		var dir4: Vector2i = FOUR_DIRS[rng.randi_range(0, 3)]
		var tip: Vector2i = base + dir4
		if tip.x < 0 or tip.y < 0 or tip.x >= cols or tip.y >= rows:
			continue
		if visited.has(tip):
			continue
		_carve_maze_link(grid, w, h, horizontal, base, tip)
		visited[tip] = true
		order.append(tip)
	# 挖出所有格子带
	for cell in order:
		_carve_maze_cell(grid, w, h, horizontal, cell)

	# ---- 起点 / 出口 ----
	var start_along := _maze_along(start_cell.x)
	var start_across := _maze_across(start_cell.y)
	var player_spawn := _rope_cell(horizontal, start_along + 1, start_across + 1)
	if not _in_bounds(player_spawn, w, h):
		return {"ok": false, "reason": "迷宫起点越界"}
	# 出口：只在"右边缘"的格子里挑，且用真实步行距离（BFS）取最远的那一个
	var flood := _maze_flood(grid, w, h, player_spawn)
	var exit_cell := Vector2i(cols - 1, clampi(int(float(rows) / 2.0), 0, rows - 1))
	var best := -1
	for cell in order:
		if cell.x != cols - 1:
			continue
		var center := _rope_cell(horizontal, _maze_along(cell.x) + 1, _maze_across(cell.y) + 1)
		if not flood.has(center):
			continue
		var distance := int(flood[center])
		if distance > best:
			best = distance
			exit_cell = cell
	if best < 0:
		# 兜底：右边缘都不可达时退回"全场步行最远"
		for cell in order:
			var center2 := _rope_cell(horizontal, _maze_along(cell.x) + 1, _maze_across(cell.y) + 1)
			if not flood.has(center2):
				continue
			var distance2 := int(flood[center2])
			if distance2 > best:
				best = distance2
				exit_cell = cell
	var exit_cells: Array[Vector2i] = []
	var exit_along := _maze_along(exit_cell.x)
	var exit_across := _maze_across(exit_cell.y)
	for da in range(-1, 2):
		for dc in range(-1, 2):
			var cell := _rope_cell(horizontal, exit_along + 1 + da, exit_across + 1 + dc)
			if cell.x <= 0 or cell.y <= 0 or cell.x >= w - 1 or cell.y >= h - 1:
				continue
			grid[cell.y * w + cell.x] = CELL_FLOOR
			exit_cells.append(cell)
	# ---- 怪物出生点：离玩家出生点 5 格以外的任意地板格，随机撒 10~20 只 ----
	var spawns: Array[Vector2i] = []
	var spawn_count := rng.randi_range(MAZE_ENEMY_MIN, MAZE_ENEMY_MAX)
	var candidates: Array[Vector2i] = []
	for y in range(2, h - 2):
		for x in range(2, w - 2):
			var cell := Vector2i(x, y)
			if int(grid[y * w + x]) != CELL_FLOOR:
				continue
			if Vector2(cell).distance_to(Vector2(player_spawn)) <= float(MAZE_SPAWN_SAFE_CELLS):
				continue
			candidates.append(cell)
	# 打乱后逐个挑，并保证彼此间隔 3 格以上，别全挤在一起
	for _try in range(spawn_count * 12):
		if spawns.size() >= spawn_count or candidates.is_empty():
			break
		var pick := candidates[rng.randi_range(0, candidates.size() - 1)]
		var too_close := false
		for existing in spawns:
			if Vector2(existing).distance_to(Vector2(pick)) < float(MAZE_SPAWN_GAP_CELLS):
				too_close = true
				break
		if too_close:
			continue
		spawns.append(pick)

	var data := {
		"ok": true, "seed": rng_seed, "mode": MODE_MAZE, "width": w, "height": h,
		"grid": grid, "doors": [], "spawns": spawns, "player_spawn": player_spawn,
		"room_count": 0, "obstacles": [], "floor_count": _count_floor(grid), "message": "",
		"rope_axis": "horizontal" if horizontal else "vertical",
		"maze_exit_cells": exit_cells,
		"maze_guard_cells": exit_cells,
		"maze_exit_center": _rope_cell(horizontal, exit_along + 1, exit_across + 1),
		"maze_cols": cols, "maze_rows": rows,
	}
	if _floor_components(grid, w, h) != 1:
		return {"ok": false, "reason": "迷宫地面没连成一片", "grid": grid, "width": w, "height": h}
	return data


func _maze_along(index: int) -> int:
	return 2 + index * 3


func _maze_across(index: int) -> int:
	return 2 + index * 3


## 挖出一个迷宫的"格"（2x2 地面）
func _carve_maze_cell(grid: Array, w: int, h: int, horizontal: bool, cell: Vector2i) -> void:
	var along := _maze_along(cell.x)
	var across := _maze_across(cell.y)
	_push_fill(grid, w, h, horizontal, along, across, along + 1, across + 1)


## 打通相邻两格之间的 1 格墙（宽 2 格）
func _carve_maze_link(grid: Array, w: int, h: int, horizontal: bool, a: Vector2i, b: Vector2i) -> void:
	var along_a := _maze_along(a.x)
	var across_a := _maze_across(a.y)
	if b.x > a.x:
		_push_fill(grid, w, h, horizontal, along_a + 2, across_a, along_a + 2, across_a + 1)
	elif b.x < a.x:
		_push_fill(grid, w, h, horizontal, along_a - 1, across_a, along_a - 1, across_a + 1)
	elif b.y > a.y:
		_push_fill(grid, w, h, horizontal, along_a, across_a + 2, along_a + 1, across_a + 2)
	else:
		_push_fill(grid, w, h, horizontal, along_a, across_a - 1, along_a + 1, across_a - 1)


## 从某个起点在迷宫里做一次 BFS，返回 {格子: 步数}（用于算真实步行距离）
func _maze_flood(grid: Array, w: int, h: int, start: Vector2i) -> Dictionary:
	var dist := {}
	if start.x <= 0 or start.y <= 0 or start.x >= w - 1 or start.y >= h - 1:
		return dist
	if int(grid[start.y * w + start.x]) != CELL_FLOOR:
		return dist
	dist[start] = 0
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for dir in FOUR_DIRS:
			var next: Vector2i = cell + dir
			if next.x <= 0 or next.y <= 0 or next.x >= w - 1 or next.y >= h - 1:
				continue
			if dist.has(next) or int(grid[next.y * w + next.x]) != CELL_FLOOR:
				continue
			dist[next] = int(dist[cell]) + 1
			queue.append(next)
	return dist
