extends Node2D
## Hub：关卡之间的中间地图（M4-2）—— 可走动、无敌人。
## 3 个固定位置各站一个角色，顺序固定：精英关 / 普通关 / 商店（左 -> 中 -> 右）。
## 玩家走近角色 -> 出现 按 E 交互；选中后开对话框（进入 / 取消）。

const ArenaGen = preload("res://scene/arena/arena_generator.gd")
const NpcScript = preload("res://scene/hub/npc.gd")
const DialogueBoxScript = preload("res://scene/hub/dialogue_box.gd")
const ShopPanelScript = preload("res://scene/hub/shop_panel.gd")
const LevelReportScript = preload("res://scene/hub/level_report.gd")

@export_group("场地")
@export var arena_width: int = 12
@export var arena_height: int = 6
## 0 = 每次随机；填数字可复现
@export var arena_seed: int = 0
## 调试：自动打开角色对话框并自动确认"进入"（headless 验证用）
@export var debug_dialogue_test: bool = false
## 调试：自动对话针对哪个角色（elite / battle / shop，空 = 第一个）
@export var debug_dialogue_kind: String = ""
## 调试：进入 Hub 时预支多少金币（单独测商店用；0 = 不预支）
@export var debug_start_gold: int = 0
## 调试：进入 Hub 时预支多少生命上限（测生命 HUD 用；0 = 不预支）
@export var debug_start_health: int = 0
## 调试：进入 Hub 时直接雇一个队友（测队友用）
@export var debug_start_ally: bool = false
## 调试：进入 Hub 时强制层数（测最终层的 BOSS 位置用；0 = 用真实层数）
@export var debug_floor: int = 0

## 3 个固定位置（相对地图中心的格偏移）
const SLOT_OFFSETS: Array[Vector2i] = [Vector2i(-4, -2), Vector2i(0, -2), Vector2i(4, -2)]
## 右上角金币 HUD 的字号（用户要求：和对话框同一套大字）
const GOLD_HUD_FONT_SIZE := 28

const KIND_COLORS := {
	"battle": Color(1.0, 1.0, 1.0),        # 普通关：原色
	"elite": Color(0.72, 0.45, 1.0),       # 精英关：染紫
	"shop": Color(1.0, 0.95, 0.55),        # 商店：偏金光（图形用玩家形象）
	"boss": Color(1.0, 0.42, 0.38),        # BOSS 关：染红（图形用精英关那一排）
}

var arena_data: Dictionary = {}
var npcs: Array = []
var _player: Player = null
var _dialogue = null
var _shop = null
var _report = null
var _gold_hud: Label = null
var _active_npc = null
var _interact_lock := 0.0      # 对话刚关掉的那一帧 E 仍是"刚按下"，加冷却避免立刻重开


func _ready() -> void:
	MusicManager.play_hub()               # 大厅曲（Overworld）
	# 调试开关先于一切生效：层数决定三个位置的角色类型，必须在 _spawn_npcs() 之前赋值
	if debug_floor > 0:
		RunState.floor_index = debug_floor
		print("[Hub] 调试: 强制层数 = %d" % debug_floor)
	if debug_start_gold > 0:
		RunState.add_gold(debug_start_gold)
		print("[Hub] 调试: 预支金币 %d -> 当前 %d" % [debug_start_gold, RunState.gold])
	for _index in range(maxi(debug_start_health, 0)):
		RunState.buy_max_health()
	if debug_start_ally:
		RunState.ally_pending = true
		print("[Hub] 调试: 预支一个队友")
	if debug_start_health > 0:
		print("[Hub] 调试: 预支生命 +%d -> 当前 %d/%d" % [
			debug_start_health, RunState.current_health, RunState.max_health])
	var use_seed := arena_seed if arena_seed != 0 else randi()
	var generator = ArenaGen.new()
	# Hub 很小（默认 12x6），生成器有 24x16 的下限，所以这里直接铺一张干净的小房间
	arena_data = _build_hub_arena(arena_width, arena_height)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)

	_player = $Player as Player
	# 玩家出生点放在"最下面一排的中间"，三个角色在上排 —— 12x6 很小，必须拉开否则一出生就同时靠近多个角色
	var spawn_cell := _nearest_floor(Vector2i(int(floor(float(arena_data["width"]) / 2.0)), int(arena_data["height"]) - 2))
	_player.global_position = _cell_center(spawn_cell)

	# 生命值跨关卡保留：整局状态里的血要同步到玩家节点上，
	# 否则 HUD 显示的是场景默认的 3（玩家在商店买 +1 生命也不会变）
	_sync_player_health()
	if not RunState.health_changed.is_connected(_on_run_state_health_changed):
		RunState.health_changed.connect(_on_run_state_health_changed)

	# HUD：Hub 没有时间限制 → 删掉时钟与绿条，生命值上移一行（沿用 M3 定的规则）
	_apply_hub_hud_layout()

	_spawn_npcs()
	_setup_dialogue()
	_setup_gold_hud()
	_setup_level_report()
	_show_pending_level_report()
	if debug_dialogue_test:
		_start_debug_dialogue_test()
	if debug_dialogue_test:
		print("[Hub] 调试: 已开启自动对话测试")
	print("[Hub] 第 %d 层中间地图 seed=%d 场地 %dx%d 角色=%s" % [
		RunState.floor_index, use_seed, arena_data["width"], arena_data["height"], str(npcs.map(
			func(npc) -> String: return npc.title))])


## 3 个固定位置各生成一个角色（顺序固定：精英关 / 普通关 / 商店）
func _spawn_npcs() -> void:
	# 用户指定（本轮）：三个位置随机刷关卡，没有普通关时保底刷一个普通关；
	# BOSS 层（第 5 / 10 层）固定 商店 - BOSS - 商店
	var kinds: Array[String] = RunState.hub_kinds()
	if RunState.is_boss_floor():
		print("[Hub] BOSS 层（第 %d 层）：左右商店 中间 BOSS" % RunState.floor_index)
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
		elif kind == "elite" or kind == "boss":
			use_frames = elite_frames       # BOSS 也用精英那排图，靠颜色区分
		var title := _npc_title(kind)
		add_child(npc)
		npc.global_position = _cell_center(cell)
		npc.setup(kind, title, use_frames, KIND_COLORS[kind], _player)
		npcs.append(npc)


func _npc_title(kind: String) -> String:
	return RunState.kind_title(kind)


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


## 右上角常驻金币显示（用户要求）；买完东西立刻刷新
func _setup_gold_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "GoldHud"
	layer.layer = 5                       # 在对话框(10)/商店(11)之下，不挡它们
	add_child(layer)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN    # 内容变宽时往左长
	panel.grow_vertical = Control.GROW_DIRECTION_END
	panel.offset_left = -16.0
	panel.offset_right = -16.0
	panel.offset_top = 16.0
	panel.offset_bottom = 16.0
	layer.add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.80)
	style.border_color = Color(1.0, 0.87, 0.55, 0.85)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	_gold_hud = Label.new()
	_gold_hud.name = "GoldLabel"
	_gold_hud.add_theme_font_size_override("font_size", GOLD_HUD_FONT_SIZE)
	_gold_hud.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	_gold_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	panel.add_child(_gold_hud)
	if not RunState.gold_changed.is_connected(_on_gold_changed):
		RunState.gold_changed.connect(_on_gold_changed)
	_refresh_gold_hud()
	print("[Hub] 金币 HUD 就绪: %s" % _gold_hud.text)
	_check_gold_hud_rect.call_deferred()
	_check_health_sync.call_deferred()


## 自检：金币 HUD 是否完整落在屏幕内（右上角留 16px 边距）
func _check_gold_hud_rect() -> void:
	if _gold_hud == null:
		return
	var rect: Rect2 = (_gold_hud.get_parent() as Control).get_global_rect()
	var screen := Vector2(get_viewport().get_visible_rect().size)
	print("[Hub] 金币 HUD 矩形位置 %s 宽高 %dx%d 屏幕 %dx%d 右边距 %d 上边距 %d" % [
		str(rect.position), int(rect.size.x), int(rect.size.y),
		int(screen.x), int(screen.y), int(screen.x - rect.end.x), int(rect.position.y)])


func _on_gold_changed(_amount: int) -> void:
	_refresh_gold_hud()


func _on_run_state_health_changed(_current: int, _maximum: int) -> void:
	_sync_player_health()          # 商店买 +1 生命后，Hub 的 HUD 要立刻跟着变


## 把整局状态的生命值同步到玩家节点 + 刷新 HUD 文本
## （刷新标签的 _update_life_count_label() 在战斗场景的 game.gd 里，
##   Hub 是自己的脚本，不刷的话标签会一直停在场景默认值 "X 3"）
func _sync_player_health() -> void:
	if _player == null:
		return
	_player.max_health = maxi(RunState.max_health, 1)
	_player.current_health = clampi(RunState.current_health, 1, _player.max_health)
	var label := $Player/HUDLayer/LifeCountLabel as Label
	if label != null:
		label.text = "X %d" % _player.current_health


## 自检：玩家身上的血 & HUD 文本是否和整局状态一致（deferred，等 HUD 刷过一帧）
func _check_health_sync() -> void:
	var label := $Player/HUDLayer/LifeCountLabel as Label
	print("[Hub自检] 生命: 玩家 %d/%d  HUD文本=%s  整局 %d/%d" % [
		_player.current_health, _player.max_health,
		label.text if label != null else "?", RunState.current_health, RunState.max_health])


func _refresh_gold_hud() -> void:
	if _gold_hud != null:
		_gold_hud.text = "金币 %d" % RunState.gold


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
	_shop = ShopPanelScript.new()
	add_child(_shop)
	_shop.closed.connect(_on_shop_closed)


func _physics_process(delta: float) -> void:
	if _interact_lock > 0.0:
		_interact_lock -= delta
	if _is_ui_open():
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
	var body := "要进入这里吗？"
	if npc.kind == "shop":
		body = "要进来看看货吗？"
	elif npc.kind == "boss":
		body = "最终决战 准备好了吗？"
	_dialogue.show_dialogue(npc.title, [body], ["进入", "取消"])
	_sync_player_lock()                         # 开完再锁，_is_ui_open() 这时才是 true
	print("[Hub] 对话打开: %s" % npc.title)


## 关卡之间的汇报（上一关成绩 + 本层通讯）：只有刚打完一关才会弹
func _setup_level_report() -> void:
	_report = LevelReportScript.new()
	add_child(_report)
	_report.closed.connect(_on_report_closed)


func _show_pending_level_report() -> void:
	if _report == null:
		return
	var report := RunState.last_level_report
	if report.is_empty():
		return
	RunState.last_level_report = {}         # 只展示一次
	if int(report.get("floor", 0)) != RunState.floor_index - 1:
		return                              # 层数对不上（例如调试跳关）就不显示
	_report.show_report(report, RunState.floor_index)
	_sync_player_lock()
	print("[Hub] 本关汇报: 上一关 第 %d 层 %s 击杀 %d 用时 %.1f 秒 金币 +%d" % [
		int(report.get("floor", 0)), RunState.kind_title(String(report.get("node_type", ""))),
		int(report.get("kills", 0)), float(report.get("elapsed", 0.0)), int(report.get("gold_gained", 0))])


func _on_report_closed() -> void:
	_sync_player_lock()
	_interact_lock = 0.25


func _on_shop_closed() -> void:
	_sync_player_lock()
	_interact_lock = 0.25
	print("[Hub] 离开商店 金币=%d" % RunState.gold)


func _open_shop() -> void:
	if _shop == null:
		return
	_shop.open()
	print("[Hub] 打开商店 金币=%d" % RunState.gold)


## 任一界面（对话/商店）打开时锁住玩家移动；集中一处判断，避免两边互相解锁
func _is_ui_open() -> bool:
	return ((_dialogue != null and _dialogue.is_open())
		or (_shop != null and _shop.is_open())
		or (_report != null and _report.is_open()))


func _sync_player_lock() -> void:
	if _player != null:
		_player.set_physics_process(not _is_ui_open())


func _on_dialogue_option(index: int) -> void:
	var kind := String(_active_npc.kind) if _active_npc != null else ""
	if index != 0 or kind.is_empty():
		print("[Hub] 选择了取消")
		return
	if kind == "shop":
		_open_shop()
		return
	print("[Hub] 进入关卡: %s（第 %d 层）" % [kind, RunState.floor_index])
	# 延迟一帧再切：不要在输入回调里把当前场景直接摘掉，
	# 否则回调后续代码（以及对话框的收尾）会作用在已离开场景树的节点上。
	GameFlow.start_battle.call_deferred({"floor": RunState.floor_index, "node_type": kind})


func _on_dialogue_closed() -> void:
	_active_npc = null
	_sync_player_lock()                         # 商店若已打开，这里会保持锁住
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
	var t3 := Timer.new()
	t3.wait_time = 2.4
	t3.one_shot = true
	t3.timeout.connect(_debug_report_and_close)
	add_child(t3)
	t3.start()
	var t4 := Timer.new()
	t4.wait_time = 3.2
	t4.one_shot = true
	t4.timeout.connect(_debug_report_after_close)
	add_child(t4)
	t4.start()


func _debug_open_first_npc() -> void:
	if _report != null and _report.is_open():
		print("[Hub] 调试: 先关掉本关汇报")
		_report.debug_close()
	var target: Node = null
	for npc in npcs:
		if debug_dialogue_kind.is_empty() or String(npc.kind) == debug_dialogue_kind:
			target = npc
			break
	if target == null:
		print("[Hub] 调试: 没找到类型为 %s 的角色" % debug_dialogue_kind)
		return
	print("[Hub] 调试: 打开角色对话 [%s]" % String(target.title))
	_open_npc_dialogue(target)


func _debug_report_and_close() -> void:
	var shop_open: bool = _shop != null and _shop.is_open()
	var locked: bool = _player != null and not _player.is_physics_processing()
	print("[Hub] 调试: 商店开=%s 玩家已锁=%s 金币=%d" % [shop_open, locked, RunState.gold])
	if shop_open:
		var event := InputEventKey.new()
		event.physical_keycode = KEY_ESCAPE
		event.pressed = true
		Input.parse_input_event(event)


func _debug_report_after_close() -> void:
	var shop_open: bool = _shop != null and _shop.is_open()
	var locked: bool = _player != null and not _player.is_physics_processing()
	print("[Hub] 调试: 关闭后 商店开=%s 玩家已锁=%s 金币=%d" % [shop_open, locked, RunState.gold])


func _debug_pick_enter() -> void:
	print("[Hub] 调试: 发送真实 E 按键事件（走 _unhandled_input，和玩家按键完全同一条路）")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_E
	event.pressed = true
	Input.parse_input_event(event)
