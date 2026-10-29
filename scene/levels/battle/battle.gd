extends "res://scene/levels/classic/game.gd"
## Battle:程序化场地 + 关卡目标 M2 
##
## 只覆盖三个钩子，其余全部复用 game.gd:
##   _ready()              插入"生成地形 到 铺瓦片 到 建红门出怪点 到 重建寻路"
##   _process(delta)       追加"波次推进 + 目标 HUD 刷新"
##   _check_game_result()  改为按 LevelGoal 判定胜负 ALL 语义 
## ⚠️ 因为覆盖了这三处，game.gd 里对应位置日后新增的逻辑需要同步到这里

const ArenaGen = preload("res://scene/levels/arena/arena_generator.gd")
const LevelGoal = preload("res://scene/levels/battle/level_goal.gd")
const BossScene = preload("res://scene/entities/bosses/boss.tscn")
const BossConfig = preload("res://resources/config/enemy_boss.tres")
const AllyScene = preload("res://scene/entities/ally/ally.tscn")
const PushBoxScene = preload("res://scene/entities/objectives/push_box.tscn")
const PickupScene := preload("res://scene/entities/pickups/pickup.tscn")
const DialogueBoxScript := preload("res://scene/hub/midmap/dialogue_box.gd")
## 房间道具房随机用这几种道具
const ROOM_PICKUP_CONFIGS: Array = [
	preload("res://resources/config/pickup_heal.tres"),
	preload("res://resources/config/pickup_rapid.tres"),
	preload("res://resources/config/pickup_speed.tres"),
	preload("res://resources/config/pickup_spiral.tres"),
]
## 临时友方：2 血、伤害固定 2、射速用持枪敌人的、撤离每人 40 金币
const TEMP_ALLY_MAX_HEALTH := 2
const TEMP_ALLY_DAMAGE := 2
const TEMP_ALLY_FIRE_INTERVAL := 0.75
const TEMP_ALLY_REWARD_GOLD := 40
const TEMP_ALLY_FOLLOW_LIMIT := 2          ## 超过这个人数就不再老实跟着箱子
## 临时友方活动范围：箱子为中心的 9x9 格（半径 4 格；原来是 5x5，用户要求再扩大一倍）
const TEMP_ALLY_LEASH_CELLS := 4
## 出范围后往箱子右侧靠的偏移（像素）：1 格半左右，不挤在一起
const TEMP_ALLY_RETURN_OFFSET := Vector2(24.0, 0.0)
const AllyIcon := preload("res://resources/texture/icon.png")
const ALLY_NAME := "队友A"
const HUD_FONT_GOLD := 28
const HUD_FONT_NAME := 22
const HUD_FONT_SMALL := 20
const HUD_ICON_SIZE := 48.0

@export_group("场地")
## 场地尺寸 格 ，会被 ArenaGenerator 夹到 24x16 ~ 38x23
@export var arena_width: int = 30
@export var arena_height: int = 20
## 0 = 每次随机；填数字可复现同一张图
@export var arena_seed: int = 0
## 强制场地模式：normal / boss / rope；空 = 按关卡类型自动（rope 是给新模式打的地基）
@export var arena_mode_override: String = ""
## 绳子场地（新模式地基）：长边 / 短边格数，只在模式跑到 rope 时才用
@export var arena_rope_length: int = 72
@export var arena_rope_thickness: int = 16
## 推车关：长边 / 短边格数；填 0 = 按层数自动成长（60+(层-1)*8，上限 96）
@export var arena_push_length: int = 0
@export var arena_push_thickness: int = 0

@export_group("推车关房间")
## 按住交互键多久开门 / 关门（用户要求 3 秒）
@export var room_interact_seconds: float = 3.0
## 玩家离门口多近才能交互（格）
@export var room_reach_cells: float = 1.6
## 已废弃：房间内容改成玩家按下交互键那一刻才生成，这个值不再生效（保留字段兼容旧场景）
@export var room_prespawn_cells: float = 6.0
## 门口提示的字号（调小就不挡视野了）
@export var room_prompt_font_size: int = 12
## 门口提示相对门格中心的偏移
@export var room_prompt_offset: Vector2 = Vector2(-40.0, -26.0)
## 头顶时钟图标相对玩家的偏移
@export var room_clock_offset: Vector2 = Vector2(-16.0, -40.0)
## 头顶倒计时文字相对玩家时钟的偏移
@export var room_clock_text_offset: Vector2 = Vector2(8.0, -42.0)
## 门在玩家上方时，倒计时改到角色下方的偏移（避免被黑幕/门挡）
@export var room_clock_offset_below: Vector2 = Vector2(-16.0, 26.0)
@export var room_clock_text_offset_below: Vector2 = Vector2(8.0, 22.0)

@export_group("岩浆地面")
## 岩浆对玩家结算一次扣多少血
@export var lava_damage: int = 1
## 在岩浆上连续站多久结算一次（跨瓦片连续计时，只有离开岩浆才清零）
@export var lava_damage_interval: float = 1.0
## 岩浆对敌人（含 BOSS）结算一次扣多少血
@export var lava_enemy_damage: int = 1
## 敌人站在岩浆上多久结算一次
@export var lava_enemy_damage_interval: float = 1.0

@export_group("调试")
## 强制目标类型 survive / kill / clear_waves / boss ；空 = 按节点类型自动
@export var debug_goal_type: String = ""
## 打印目标与场地概要
@export var debug_print: bool = true
## 调试: 加快 Boss 技能节奏（headless 自检用）
@export var debug_fast_boss: bool = false
## Boss 关：红门每隔多少秒涌出敌人
@export var boss_door_spawn_interval: float = 5.0
## Boss 关：红门每次涌出的敌人数区间（用户要求"不低于 2 名" -> 2~4 只随机）
@export var boss_door_spawn_min: int = 2
@export var boss_door_spawn_max: int = 4
## Boss 关：场上普通敌人上限（红门刷的 + BOSS 抛的；BOSS/紫 BOSS 不占名额）
@export var boss_level_normal_enemy_cap: int = 20
## 每只普通敌人掉落的金币（M6 平衡：1 -> 2，否则中期买不起输出，打血厚的敌人会变成磨血）
@export var gold_per_enemy_kill: int = 2
## 击败 Boss 的额外金币（M6 平衡：8 -> 20，BOSS 关没有波次，收入几乎为零）
@export var gold_per_boss_kill: int = 20

## 调试: 直接模拟击败 Boss（验证"通关结算 -> 回标题"整条链路）
@export var debug_instant_boss_win: bool = false
## 调试: 任意关卡都直接模拟胜利（验证"胜利 -> 回 中间地图 -> 层数 +1"整条链路）
@export var debug_instant_win: bool = false

var arena_data: Dictionary = {}
var goal: Dictionary = {}

## 玩家在岩浆上已经连续站了多久（跨岩浆瓦片累计，离开岩浆清零）
var _lava_stand_time: float = 0.0

# ---- 推车关 ----
var _push_box = null                       ## 箱子（PushBox）
var _push_arrived: bool = false            ## 箱子是否已经抵达终点
var _temp_allies: Array = []               ## 本关的临时友方单位（不进右侧 HUD）
var _room_states: Array = []               ## 每个房间的运行时状态（是否打开 / 是否已生成内容…）
var _room_mask_layer: CanvasLayer = null   ## 黑幕所在的画布层
var _room_masks: Array = []                ## 上锁房间的黑幕（ColorRect）
var _room_door_bodies: Array = []          ## 房间门的碰撞体（关着时挡住玩家）
var _room_enemies: Array = []              ## 每个房间刷出来的敌人
var _room_ui_layer: CanvasLayer = null
var _room_clock_icon: Sprite2D = null
var _room_clock_label: Label = null
var _room_interact_target: int = -1
var _room_needs_release: bool = false      ## 刚开/关过门，必须先松开交互键才能再操作
var _temp_ally_candidates: Array = []      ## 房间里站着、等玩家决定要不要带走的临时队友
var _recruited_allies: Array = []          ## 已经带走的临时队友
var _temp_ally_pick: int = -1              ## 正在对话的临时队友下标
var _temp_ally_dialogue = null             ## 正式对话框（复用中间地图那套）
var _temp_ally_prompts: Array = []         ## 临时队友头顶的「按 E 交谈」提示
var _temp_ally_wander_left: float = 0.0
var _room_ever_opened: Array = []          ## 房间是否被打开过（保留字段，黑幕改成按开关状态走）
var _door_prompts: Array = []              ## 每个房间门口的「按住 E 交互」提示
var _room_spawn_markers: Array = []        ## 每个房间对应的红门出怪点（关上门就不刷怪）
## 每只敌人各自在岩浆上站了多久（instance_id -> 秒），玩家与敌人各算各的
var _enemy_lava_time: Dictionary = {}
## 每个队友各自在岩浆上站了多久（instance_id -> 秒）
var _ally_lava_time: Dictionary = {}

var _goal_label: Label
var _detail_label: Label
var _last_hud_key := ""

# 波次推进
var _waves: Array = []
var _wave_index := 0
var _waves_done := 0
var _waves_finished := false
var _wave_timer_left := 0.0
var _guard_target = null
var _guard_hud_hp: Label = null
var _boss_defeated := false
var _boss: Enemy = null
var _boss_nodes: Array[Node] = []
var _boss_lock_label: Label = null            ## 第一条血条右侧的锁血倒计时（9.5S）
var _boss_lock_marker: ColorRect = null       ## 第一条血条上 50% 处的刻度线
var _boss_icon_main: Sprite2D = null
var _boss_bars_shifted := false               ## 是否已经为了多条血条把生命值显示下移过
## 紫色阵营（本体+分身）的血量上限总和：每只本体按 config.max_health 加，每生成一个分身按其血量加
var _purple_shared_max: float = 0.0       ## 紫色阵营共用血条的上限（本体之和；分身不加）
var _purple_shared_hp: float = 0.0        ## 紫色阵营共用血条当前值
var _purple_family_killing: bool = false  ## 正在执行"全家同时死亡"（期间不按只算金币）
## 紫色共享血条每掉到下一个阈值就加 1 个分身（75% / 50% / 25%，共 3 个）
var _purple_split_stage := 0        ## （兼容旧字段）已经分裂过的阶段数
var _purple_split_stage_by_family: Dictionary = {}
var _purple_family_lock_left := 0.0      ## （兼容旧字段）所有家族里最长的锁血剩余
var _purple_family_lock_used := false
## 按家族分开的血池与锁血状态（家族 0 / 家族 1 各自一份）
var _purple_max_by_family: Dictionary = {}
var _purple_hp_by_family: Dictionary = {}
var _purple_lock_left_by_family: Dictionary = {}
var _purple_lock_used_by_family: Dictionary = {}
var _debug_win_started := false
var _ally = null                  ## 第一个队友（兼容旧代码/自检）
var _allies: Array = []           ## 本关所有队友（最多 RunState.MAX_ALLIES）
var _hud_gold: Label = null
var _hud_ally_box: Control = null
var _hud_ally_hp: Label = null
var _hud_ally_state: Label = null
var _hud_ally_hint: Label = null
var _hud_ally_slots: Array[Dictionary] = []
var _last_result_won := false
var _gold_gained := 0                 ## 本关赚到的金币（汇报用）
var _result_recorded := false


func _ready() -> void:
	# 发布版（导出的 exe）里把所有调试开关和调试打印都关掉
	if not OS.is_debug_build():
		debug_print = false
		debug_goal_type = ""
		debug_fast_boss = false
		debug_instant_boss_win = false
		debug_instant_win = false
		arena_mode_override = ""
	random_generator.randomize()
	# 岩浆 BOSS 靠这个组找到战斗场景（放岩浆/红门刷自爆兵），不加进来它就只能干瞪眼
	add_to_group("battle")

	# ① 目标必须先算:限时决定倒计时条长度 stage_duration 由 _setup_hud 读取 
	goal = LevelGoal.build(_context_floor(), _context_node_type(), debug_goal_type)
	MusicManager.play_boss()              # 战斗一律用 1-29（用户要求：战斗时始终循环这一首）
	stage_duration = LevelGoal.stage_duration(goal)
	_waves = goal.get("waves", [])

	_configure_result_dialog()
	_setup_hud()
	_setup_goal_hud()
	_setup_battle_hud()
	_raise_hud_above_world()
	_setup_pause_menu()
	_apply_goal_hud_layout()

	# ② 场地数据 到 ③ 铺瓦片 红门在 Overlay 层 到 ④ 出怪点与红门成对创建
	var use_seed := arena_seed if arena_seed != 0 else random_generator.randi()
	var generator = ArenaGen.new()
	var arena_mode := ArenaGen.MODE_BOSS if (goal["type"] == LevelGoal.TYPE_BOSS or goal["type"] == LevelGoal.TYPE_DEFEND) else ArenaGen.MODE_NORMAL
	if goal["type"] == LevelGoal.TYPE_PUSH:
		arena_mode = ArenaGen.MODE_PUSH
	if goal["type"] == LevelGoal.TYPE_MAZE:
		arena_mode = ArenaGen.MODE_MAZE
	if not arena_mode_override.is_empty():
		arena_mode = arena_mode_override
	var arena_w := arena_width
	var arena_h := arena_height
	if arena_mode == ArenaGen.MODE_ROPE:
		arena_w = arena_rope_length
		arena_h = arena_rope_thickness
	elif arena_mode == ArenaGen.MODE_MAZE:
		var maze_floor := maxi(_context_floor(), 1)
		arena_w = ArenaGen.maze_length_for_floor(maze_floor)
		arena_h = ArenaGen.maze_thickness_for_floor(maze_floor)
	elif arena_mode == ArenaGen.MODE_PUSH:
		var push_floor := maxi(_context_floor(), 1)
		arena_w = arena_push_length if arena_push_length > 0 else ArenaGen.push_length_for_floor(push_floor)
		arena_h = arena_push_thickness if arena_push_thickness > 0 else ArenaGen.push_thickness_for_floor(push_floor)
	arena_data = generator.generate(arena_w, arena_h, use_seed, arena_mode,
		maxi(_context_floor(), 1), _context_node_type())
	if goal["type"] == LevelGoal.TYPE_PUSH:
		_apply_push_time_limit()
		if debug_print:
			print("[Battle] 推车关地形预览（# 外墙 X 墙 . 地板 D 红门 P 出生点）")
			print(generator.to_ascii(arena_data))
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)
	generator.create_spawn_markers($EnemySpawnPoints, arena_data)
	player.global_position = cell_to_world(arena_data["player_spawn"])
	_apply_run_state_to_player()
	if not player.heal_ally_requested.is_connected(_on_player_heal_requested):
		player.heal_ally_requested.connect(_on_player_heal_requested)

	if arena_mode == ArenaGen.MODE_MAZE:
		_setup_maze()
	if arena_mode == ArenaGen.MODE_PUSH:
		_spawn_push_box()
		_setup_push_rooms()

	# ⑤ 顺序关键:铺完瓦片之后才能重建寻路网格
	_setup_enemy_pathfinder()
	_collect_enemy_spawn_points()
	if not _room_states.is_empty():
		_refresh_room_spawn_markers()
	_warn_spawn_points_inside_walls()
	_spawn_ally_if_hired()
	_collect_enemy_configs()
	if not _after_floor_5() and available_enemy_configs.has(SHOOTER_CONFIG):
		available_enemy_configs.erase(SHOOTER_CONFIG)   # 持枪敌人：第 5 层之后才出现
	_apply_floor_scaling_to_enemy_configs()
	if goal["type"] == LevelGoal.TYPE_DEFEND:
		_spawn_defend_target()
		_configure_defend_spawn()
		_setup_defend_build()
	if arena_mode == ArenaGen.MODE_MAZE:
		_spawn_maze_enemies()
	if arena_mode == ArenaGen.MODE_PUSH:
		# 推车关红门刷怪放慢：每 5 秒一只，别把推车路堵死
		spawn_interval = 5.0
		min_spawn_interval = 5.0
		spawn_count_per_tick = 1
	_configure_enemy_spawn_timer()
	_keep_player_centered()

	# 兜底空气墙:所有关卡都要 —— 程序化地图四条边各有一处红门，红门会把外圈边界墙
	# 挖出缺口，不额外围一圈的话玩家能顺着红门跑出地图（之前只给 BOSS 关围了，普通关会漏）
	_setup_arena_bounds()

	# ⑥ 刷怪:有波次表的关卡走波次推进；其余沿用父类的无限刷怪
	if goal["type"] == LevelGoal.TYPE_BOSS:
		_spawn_bosses_for_floor()
		_start_boss_door_spawner()
		if _context_floor() == RunState.MAX_FLOOR:
			_start_boss_wave(1)          # 第 15 层：进关卡立刻开第 1 波
	elif _waves.is_empty():
		if goal["type"] == LevelGoal.TYPE_DEFEND:
			pass                              # 守护关：等建造模式里点「开始关卡」再刷怪
		elif arena_mode != ArenaGen.MODE_PUSH:
			_spawn_initial_enemies()          # 推车关开局不刷一片，只靠红门每 5 秒一只
			_start_enemy_spawn_timer()
		else:
			_start_enemy_spawn_timer()
	else:
		_wave_timer_left = 0.6

	_refresh_goal_hud(true)
	if debug_print:
		print("[Battle] 目标=%s 条件=%d 限时=%.0f 波次=%d | 场地 %dx%d seed=%d 房间=%d 红门=%d 岩浆=%d格 寻路=%s 玩家出生=%s" % [
			goal["type"], goal["conditions"].size(), LevelGoal.time_limit(goal), _waves.size(),
			arena_data["width"], arena_data["height"], arena_data["seed"], arena_data["room_count"],
			arena_data["doors"].size(), arena_data.get("lava_cells", []).size(),
			str(EnemyPathfinder.instance != null and EnemyPathfinder.instance.is_usable()),
			str(arena_data["player_spawn"])])
	_start_self_check()


## M6 平衡：普通敌人血量随层数成长（1 + 0.25*(层-1)），速度/数量不变。
## 必须 duplicate()：配置资源是共享的，直接改会把倍率一路叠上去。
func _apply_floor_scaling_to_enemy_configs() -> void:
	var mul := 1.0 + 0.25 * float(maxi(_context_floor(), 1) - 1)
	if mul <= 1.0 or available_enemy_configs.is_empty():
		return
	var scaled: Array[EnemyConfig] = []
	var summary: Array[String] = []
	for cfg in available_enemy_configs:
		if cfg == null:
			continue
		var copy: EnemyConfig = cfg.duplicate()
		copy.max_health = maxi(int(round(float(cfg.max_health) * mul)), 1)
		scaled.append(copy)
		summary.append("%d->%d" % [cfg.max_health, copy.max_health])
	available_enemy_configs = scaled
	if debug_print:
		print("[Battle] 敌人血量倍率 x%.2f（第 %d 层）: %s" % [
			mul, maxi(_context_floor(), 1), "  ".join(summary)])


## BOSS 血量：基础值见 enemy_boss.tres（150）。
## 第 5 层（半路 BOSS）用基础值；第 10 层最终 BOSS 再 ×1.65 更肉（150 -> 248）
## BOSS 血量倍率：按 BOSS 层给（用户定的曲线）——第 5 层 ×1、第 10 层 ×2、第 15 层 ×3
## 普通 BOSS / 紫 BOSS 本体 / 岩浆 BOSS 都吃这张表
const BOSS_HP_MULT_BY_FLOOR := {5: 1.0, 10: 2.0, 15: 3.0}
## 岩浆 BOSS 额外的"更肉"系数（在层倍率之上再乘）
const LAVA_BOSS_HP_BONUS := 1.2


## 当前层对应的 BOSS 血量倍率（调试直接开别的层的 BOSS 时，按 5->1、10->2、15->3 线性插值）
func _boss_hp_multiplier() -> float:
	var floor_now := _context_floor()
	if BOSS_HP_MULT_BY_FLOOR.has(floor_now):
		return float(BOSS_HP_MULT_BY_FLOOR[floor_now])
	return maxf(1.0, 1.0 + float(floor_now - 5) * 0.2)


## 把基础 BOSS 配置按当前层的倍率放大一份（倍率 1 时直接返回原配置）
func _boss_config_with_mult(mult: float) -> EnemyConfig:
	if is_equal_approx(mult, 1.0):
		return BossConfig
	var copy: EnemyConfig = BossConfig.duplicate()
	copy.max_health = maxi(int(round(float(BossConfig.max_health) * mult)), 1)
	return copy


func _boss_config_for_floor() -> EnemyConfig:
	var mult := _boss_hp_multiplier()
	var cfg := _boss_config_with_mult(mult)
	if debug_print and not is_equal_approx(mult, 1.0):
		print("[Battle] 第 %d 层 BOSS 血量 %d -> %d（×%.2f）" % [
			_context_floor(), BossConfig.max_health, cfg.max_health, mult])
	return cfg


## 紫 BOSS 血量：和普通 BOSS 吃同一张表；家族血池 = 每只本体各贡献一份
func _boss_config_for_purple() -> EnemyConfig:
	return _boss_config_with_mult(_boss_hp_multiplier())


## 整局生命值变化时（例如商店买血）同步到玩家节点
func _on_run_state_health_changed(current: int, maximum: int) -> void:
	if player == null:
		return
	player.max_health = maxi(maximum, 1)
	player.current_health = clampi(current, 1, player.max_health)


## 右上角：金币（用户要求战斗里也显示）+ 队友头像/名字/血量/状态
## 玩家头顶的 HUD（生命/时间条）挂在世界空间的 HUDLayer 上，
## 不抬高 z 会被房间黑幕、门口提示这些东西盖住（实测遮挡）
func _raise_hud_above_world() -> void:
	var hud_layer := get_node_or_null("Player/HUDLayer") as Node2D
	if hud_layer != null:
		hud_layer.z_index = 200          # 永远压在世界物体 / 黑幕（40） / 提示（80）之上


func _setup_battle_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "BattleHud"
	layer.layer = 5
	add_child(layer)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.grow_vertical = Control.GROW_DIRECTION_END
	box.offset_left = -280.0
	box.offset_right = -16.0
	box.offset_top = 16.0
	box.offset_bottom = 16.0
	box.add_theme_constant_override("separation", 6)
	box.alignment = BoxContainer.ALIGNMENT_END
	layer.add_child(box)

	var panel := _make_hud_panel(Vector2(-16.0, 16.0))
	box.add_child(panel)
	var gold_box := VBoxContainer.new()
	panel.add_child(gold_box)
	_hud_gold = Label.new()
	_hud_gold.add_theme_font_size_override("font_size", HUD_FONT_GOLD)
	_hud_gold.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	_hud_gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hud_gold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gold_box.add_child(_hud_gold)

	# 队友面板：最多 3 个（用户要求），每个 = 头像 + 名字 + 血量 + 右侧(T键切换/状态)
	_hud_ally_slots.clear()
	for slot in range(RunState.MAX_ALLIES):
		_hud_ally_slots.append(_make_ally_hud_panel(box, slot))
	if not _hud_ally_slots.is_empty():
		_hud_ally_box = _hud_ally_slots[0]["panel"]
		_hud_ally_hp = _hud_ally_slots[0]["hp"]
		_hud_ally_state = _hud_ally_slots[0]["state"]
		_hud_ally_hint = _hud_ally_slots[0]["hint"]

	if not RunState.gold_changed.is_connected(_on_hud_gold_changed):
		RunState.gold_changed.connect(_on_hud_gold_changed)
	_refresh_hud_gold()
	_hud_ally_box.visible = false


## 造一个队友面板（slot 0/1/2 -> 队友A/B/C）
func _make_ally_hud_panel(box: VBoxContainer, slot: int) -> Dictionary:
	var ally_panel := _make_hud_panel(Vector2(-16.0, 16.0))
	box.add_child(ally_panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	ally_panel.add_child(row)
	var icon := TextureRect.new()
	icon.texture = AllyIcon
	icon.custom_minimum_size = Vector2(HUD_ICON_SIZE, HUD_ICON_SIZE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)
	var name_label := Label.new()
	name_label.text = "队友%s" % char(65 + slot)
	name_label.add_theme_font_size_override("font_size", HUD_FONT_NAME)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.93, 1.0))
	info.add_child(name_label)
	var hp := Label.new()
	hp.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	hp.add_theme_color_override("font_color", Color(1.0, 0.55, 0.55))
	info.add_child(hp)
	var right_col := VBoxContainer.new()
	right_col.add_theme_constant_override("separation", 2)
	row.add_child(right_col)
	var hint := Label.new()
	hint.text = "T键切换"
	hint.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	hint.add_theme_color_override("font_color", Color(0.70, 0.95, 0.70))
	right_col.add_child(hint)
	var state_label := Label.new()
	state_label.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	state_label.add_theme_color_override("font_color", Color(0.70, 0.85, 1.0))
	right_col.add_child(state_label)
	ally_panel.visible = false
	# dead：本关内该队友是否已阵亡（阵亡后节点会被释放，HUD 靠这个标记继续显示"阵亡"）
	return {"panel": ally_panel, "hp": hp, "state": state_label, "hint": hint, "dead": false}


func _make_hud_panel(_unused_offset: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.28)      # 和 中间地图 金币 HUD 一致的半透明底
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _on_hud_gold_changed(_amount: int) -> void:
	_refresh_hud_gold()


func _refresh_hud_gold() -> void:
	if _hud_gold != null:
		_hud_gold.text = "金币 %d" % RunState.gold


func _refresh_ally_hud() -> void:
	if _hud_ally_slots.is_empty():
		return
	for slot in range(_hud_ally_slots.size()):
		var entry := _hud_ally_slots[slot]
		var panel := entry["panel"] as Control
		if slot >= _allies.size():
			panel.visible = false
			continue
		var ally = _allies[slot]
		var valid := ally != null and is_instance_valid(ally)
		var dead := bool(entry.get("dead", false))
		if valid and bool(ally.get("is_dead")):
			dead = true
			entry["dead"] = true
		# 阵亡后节点被释放：仍然保留面板，显示"阵亡"（用户要求）
		if not valid and not dead:
			panel.visible = false
			continue
		panel.visible = true
		var hp := entry["hp"] as Label
		var state_label := entry["state"] as Label
		var hint := entry["hint"] as Label
		var max_hp: int = int(ally.get("MAX_HEALTH")) if valid else RunState.ALLY_MAX_HEALTH
		if dead:
			hp.text = "0 / %d" % max_hp
			hint.text = "阵亡"                    # 「按T切换」-> 阵亡（用户要求）
			state_label.text = ""
			panel.modulate = Color(1.0, 1.0, 1.0, 0.6)   # 整块压暗一点
		else:
			hp.text = "%d / %d" % [int(ally.get("current_health")), max_hp]
			hint.text = "T键切换"
			state_label.text = String(ally.call("state_name"))
			panel.modulate = Color.WHITE
## 调试面板：按名册重新放一遍队友（改名册后调用）
func debug_respawn_allies() -> void:
	for ally in _allies:
		if ally != null and is_instance_valid(ally):
			ally.queue_free()
	_allies.clear()
	_ally = null
	_spawn_ally_if_hired()


func debug_hire_ally() -> void:
	if not RunState.hire_ally():
		return
	# 重新按名册放一遍（包含刚雇的）
	for ally in _allies:
		if ally != null and is_instance_valid(ally):
			ally.queue_free()
	_allies.clear()
	_ally = null
	_spawn_ally_if_hired()


func debug_fire_ally() -> void:
	for ally in _allies:
		if ally != null and is_instance_valid(ally):
			ally.queue_free()
	_allies.clear()
	_ally = null
	RunState.ally_roster.clear()
	_refresh_ally_hud()
func _on_ally_state_changed(_state: String) -> void:
	_refresh_ally_hud()


func _on_ally_health_changed(_current: int, _maximum: int) -> void:
	_refresh_ally_hud()


## 队友阵亡：标记该槽位（节点随后会被释放，HUD 仍要显示"阵亡"）
func _on_ally_died(slot: int) -> void:
	if slot >= 0 and slot < _hud_ally_slots.size():
		_hud_ally_slots[slot]["dead"] = true
	_refresh_ally_hud()


## 商店里雇了队友的话，这一关开场把他放出来（只在本关有效）
func _spawn_ally_if_hired() -> void:
	_allies.clear()
	_ally = null
	if RunState.ally_roster.is_empty():
		_refresh_ally_hud()
		return
	var body := player.get_node_or_null("BodySprite") as AnimatedSprite2D
	for index in range(RunState.ally_roster.size()):
		var entry: Dictionary = RunState.ally_roster[index]
		var ally = AllyScene.instantiate()      # 不用类型注解：队友脚本没有全局类名
		if ally == null:
			continue
		add_child(ally)
		# 把玩家的 AnimatedSprite2D 交给队友：共用同一套 SpriteFrames 并镜像动画
		ally.setup(player, body, RunState.get_player_damage(), RunState.get_player_fire_interval(),
			$EnemyContainer)
		# 血量沿用名册里存的（跨层保留）
		ally.current_health = clampi(int(entry.get("health", RunState.ALLY_MAX_HEALTH)),
			1, RunState.ALLY_MAX_HEALTH)
		ally.health_changed.connect(_on_ally_health_changed)
		ally.state_changed.connect(_on_ally_state_changed)
		ally.died.connect(_on_ally_died.bind(index))          # 阵亡 -> HUD 改显示"阵亡"
		if index < _hud_ally_slots.size():
			_hud_ally_slots[index]["dead"] = false
		ally.global_position = _ally_spawn_position(index)
		_allies.append(ally)
		if _ally == null:
			_ally = ally
	_refresh_ally_hud()
	if debug_print:
		print("[Battle] 放出 %d 名队友（名册 %d 个，血量 %s）" % [
			_allies.size(), RunState.ally_count(),
			str(RunState.ally_roster.map(func(e): return int(e.get("health", 0))))])


## 一层结束时把队友血量写回名册（阵亡写 0，名册会移除；层数 -1）
func _write_back_allies() -> void:
	var healths: Array = []
	for ally in _allies:
		if ally != null and is_instance_valid(ally) and not bool(ally.get("is_dead")):
			healths.append(int(ally.get("current_health")))
		else:
			healths.append(0)
	RunState.finish_ally_floor(healths)


## 给队友找一个"玩家附近、且是地板"的出生点（避免生成到地形里卡住）
## 用生成器留下的 arena_data.grid：0=地板 1=墙 2=外墙
func _ally_spawn_position(skip: int = 0) -> Vector2:
	var grid: Array = arena_data.get("grid", [])
	var width: int = int(arena_data.get("width", 0))
	var height: int = int(arena_data.get("height", 0))
	var tile := float(ArenaGen.TILE_SIZE)
	var player_cell := Vector2i(int(floor(player.global_position.x / tile)), int(floor(player.global_position.y / tile)))
	if grid.is_empty() or width <= 0:
		return player.global_position + Vector2(20.0 * float(skip + 1), 0.0)
	var found := 0
	for radius in range(0, 7):
		for offset_y in range(-radius, radius + 1):
			for offset_x in range(-radius, radius + 1):
				var cell := player_cell + Vector2i(offset_x, offset_y)
				if cell.x < 1 or cell.y < 1 or cell.x >= width - 1 or cell.y >= height - 1:
					continue
				if int(grid[cell.y * width + cell.x]) != 0:
					continue
				if found < skip:
					found += 1
					continue
				return cell_to_world(cell)
	return player.global_position + Vector2(20.0 * float(skip + 1), 0.0)
## T 键：一次切换"所有"队友的模式（用户要求；以前每个队友各自响应，第一个会把输入吃掉）
func _check_ally_switch_input() -> void:
	if is_result_displayed:
		return
	if Input.is_action_just_pressed("switch_ally"):
		_toggle_all_allies()


func _toggle_all_allies() -> void:
	for ally in _allies:
		if ally != null and is_instance_valid(ally) and not bool(ally.get("is_dead")):
			ally.toggle_state()
	_refresh_ally_hud()


## 玩家满血捡到回血道具：按 A -> B -> C 顺序给第一个没满血的队友回 1 颗；
## 队友都满血（或没有队友）则谁都不加 —— 不会溢出加到玩家身上（用户要求）。
func _on_player_heal_requested() -> void:
	for ally in _allies:
		if ally == null or not is_instance_valid(ally):
			continue
		if bool(ally.get("is_dead")):
			continue
		if ally.has_method("heal_one") and ally.heal_one():
			_refresh_ally_hud()
			return
	if debug_print:
		print("[Battle] 玩家满血捡到恢复道具：队友都满血/没队友，未生效")


func _context_floor() -> int:
	if GameFlow != null:
		return int(GameFlow.pending_battle.get("floor", RunState.floor_index))
	return 1


func _context_node_type() -> String:
	if GameFlow != null:
		return String(GameFlow.pending_battle.get("node_type", "battle"))
	return "battle"


## 保持原关卡观感:不启用相机限位 到 角色永远在屏幕中心 到 HUD 位置固定
func _keep_player_centered() -> void:
	var camera := $CameraSystem/Camera2D as Camera2D
	if camera != null:
		camera.limit_enabled = false


## 格坐标 到 世界坐标 格中心 
func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5,
		cell.y * ArenaGen.TILE_SIZE + ArenaGen.TILE_SIZE * 0.5)


func _process(delta: float) -> void:
	super._process(delta)              # 父类:倒计时 / HUD / 胜负判定 判定已被我覆盖 
	if debug_instant_win and not _debug_win_started:
		_debug_win_started = true
		_start_debug_instant_win()     # 调试：任意关卡秒胜（走完整条 结算 -> 切场景 链路）
	_check_ally_switch_input()
	_update_defend_spawn_cap()
	_update_purple_splits()
	_update_purple_family_lock(delta)
	_update_waves(delta)
	_refresh_goal_hud()
	_update_lava_damage(delta)
	_update_push_rooms(delta)
	if not _maze_exit_cells.is_empty():
		_update_maze(delta)
	_update_temp_lava(delta)
	if goal.get("type", "") == LevelGoal.TYPE_BOSS:
		_separate_bosses(delta)
	if goal.get("type", "") == LevelGoal.TYPE_BOSS and _context_floor() == RunState.MAX_FLOOR:
		_update_boss_waves(delta)
	if goal.get("type", "") == LevelGoal.TYPE_DEFEND:
		_update_defend_build(delta)
		if not _defend_started:
			stage_time_left = stage_duration      # 建造模式期间倒计时不走


## 波次推进:刷完一波 到 等场上清空 到 下一波；最后一波清空即达成目标
func _update_waves(delta: float) -> void:
	if _waves.is_empty() or _waves_finished or is_result_displayed:
		return
	if _get_player_current_health() <= 0:
		return
	if _wave_index >= _waves.size():
		if _get_alive_enemy_count() == 0:
			_waves_done = _waves.size()
			_waves_finished = true
		return
	_wave_timer_left -= delta
	if _wave_timer_left > 0.0:
		return
	var wave: Dictionary = _waves[_wave_index]
	if int(wave.get("spawned", 0)) < int(wave.get("count", 0)):
		if _try_spawn_enemy():
			wave["spawned"] = int(wave.get("spawned", 0)) + 1
			_wave_timer_left = maxf(float(wave.get("interval", 0.8)), 0.05)
		else:
			_wave_timer_left = 0.25          # 场上满员 / 没有可用出生点 到 稍后重试
		return
	if _get_alive_enemy_count() > 0:
		return
	_waves_done = _wave_index + 1
	_wave_index += 1
	if _wave_index >= _waves.size():
		_waves_finished = true
		return
	_wave_timer_left = maxf(float(_waves[_wave_index].get("delay", 1.2)), 0.0)


## BOSS 专有分组：用来把"BOSS/紫 BOSS"从"普通敌人"计数里排除（用户要求）
const BOSS_GROUP := "boss_enemy"


## Boss 关：场上"普通敌人"数量（不含 BOSS / 紫 BOSS / 已死）
func _count_alive_normal_enemies() -> int:
	var count := 0
	for child in enemy_container.get_children():
		if child is Enemy and not (child as Enemy).is_dead and not child.is_in_group(BOSS_GROUP):
			count += 1
	return count


## Boss 关：红门会持续"涌出"普通敌人（复用现有出怪点 —— 它们本来就落在红门上）
func _start_boss_door_spawner() -> void:
	var timer := Timer.new()
	timer.name = "BossDoorSpawnTimer"
	timer.wait_time = maxf(boss_door_spawn_interval, 1.0)
	timer.timeout.connect(_on_boss_door_spawn)
	add_child(timer)
	timer.start()


func _on_boss_door_spawn() -> void:
	if is_result_displayed or _boss_defeated:
		return
	# 一次涌出 boss_door_spawn_min ~ boss_door_spawn_max 只；
	# 红门自己守 20 上限（BOSS 抛的小怪可以临时超出，见 boss.gd）
	var want := randi_range(maxi(boss_door_spawn_min, 1),
		maxi(boss_door_spawn_max, maxi(boss_door_spawn_min, 1)))
	var spawned := 0
	for _index in range(want):
		if _count_alive_door_enemies() >= boss_level_normal_enemy_cap:
			break
		if _try_spawn_enemy():
			spawned += 1
	if spawned > 0 and debug_print:
		print("[Battle] 红门涌出 %d 只敌人（场上普通敌人 %d/%d）" % [
			spawned, _count_alive_normal_enemies(), boss_level_normal_enemy_cap])


## 血条左侧用「怪物图片」代替原来的「BOSS」字样；第 10 层再补一条紫 BOSS 共用血条
func _setup_boss_bar_icons(clock_bar: Sprite2D) -> void:
	var boss_hud := $Player/HUDLayer as Node2D
	if boss_hud == null or clock_bar == null:
		return
	_boss_icon_main = _make_boss_icon_sprite()
	boss_hud.add_child(_boss_icon_main)
	_boss_icon_main.position = Vector2(time_bar_left_edge_x - BOSS_ICON_GAP, clock_bar.position.y)

	# 第二条及以后的血条由 _ensure_boss_bars 按"实际活着的 BOSS 条数"动态建，
	# 建第一条额外血条时顺手把玩家生命值显示下移一行


## 血条左侧的怪物图片（先留空，等 BOSS 刷出来再贴第一帧纹理）
func _make_boss_icon_sprite() -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.scale = Vector2(BOSS_ICON_SCALE, BOSS_ICON_SCALE)
	sprite.visible = false
	return sprite


## 玩家生命显示（图标 + 数字）整体下移，给第 10 层的第二条血条让位
func _move_life_display_down(delta: float) -> void:
	var life_icon := $Player/HUDLayer/LifeIcon as Sprite2D
	var life_label := $Player/HUDLayer/LifeCountLabel as Label
	if life_icon != null:
		life_icon.position.y += delta
	if life_label != null:
		life_label.offset_top += delta
		life_label.offset_bottom += delta


## 第 10 层才有两条血条（原 BOSS + 紫 BOSS 阵营）
## Boss 关：从"离玩家最远的那个红门"里放出一只 Boss（复用出怪口的语义）
## 把整局成长（生命/伤害/射速）应用到玩家身上
func _apply_run_state_to_player() -> void:
	player.max_health = RunState.max_health
	player.current_health = clampi(RunState.current_health, 1, RunState.max_health)
	player.fire_interval = RunState.get_player_fire_interval()
	player.current_move_speed_multiplier = maxf(RunState.move_speed_multiplier, 0.1)
	player.invincibility_duration = RunState.get_player_invincibility()
	if not RunState.health_changed.is_connected(_on_run_state_health_changed):
		RunState.health_changed.connect(_on_run_state_health_changed)
	if debug_print:
		print("[Battle] 进场: 生命 %d/%d 子弹伤害 %d 射击间隔 %.3f 金币 %d" % [
			player.current_health, player.max_health, RunState.get_player_damage(),
			player.fire_interval, RunState.gold])


## 调试面板改完 RunState 后调用：把数值同步到场上实际的玩家/队友/HUD
func debug_sync_run_values() -> void:
	if player != null and is_instance_valid(player):
		player.max_health = RunState.max_health
		player.current_health = clampi(RunState.current_health, 0, RunState.max_health)
		player.fire_interval = RunState.get_player_fire_interval()
		player.current_move_speed_multiplier = maxf(RunState.move_speed_multiplier, 0.1)
		player.invincibility_duration = RunState.get_player_invincibility()
	_update_life_count_label()
	_refresh_hud_gold()
	if _ally != null and is_instance_valid(_ally):
		_ally.damage = RunState.get_player_damage()
		_ally.fire_interval = RunState.get_player_fire_interval()
		_refresh_ally_hud()


## 金币只来自敌人掉落
func _on_enemy_died() -> void:
	super._on_enemy_died()
	if _purple_family_killing:
		return                    # 紫 BOSS 家族：统一结算（第 5 层 +30 金），不按只算
	if debug_print:
		print("[Battle] 击杀 %d 只（本关累计）金币 %d" % [round_kill_count, RunState.gold])
	var gain := maxi(gold_per_enemy_kill, 0)
	RunState.add_gold(gain)
	_gold_gained += gain



func _spawn_boss() -> void:
	var boss := BossScene.instantiate() as Enemy
	if boss == null:
		push_warning("[Battle] Boss 场景实例化失败")
		return
	enemy_container.add_child(boss)
	boss.add_to_group(BOSS_GROUP)          # 不占"普通敌人"名额
	if _boss == null or not is_instance_valid(_boss) or bool(_boss.is_dead):
		_boss = boss
	if not _boss_nodes.has(boss):
		_boss_nodes.append(boss)
	if "max_alive_minions" in boss:
		boss.max_alive_minions = boss_level_normal_enemy_cap   # BOSS 抛小怪也守同一个上限
	var spawn_cell := _next_boss_spawn_cell()
	boss.global_position = cell_to_world(spawn_cell)
	boss.setup(_boss_config_for_floor(), player)
	if boss.has_method("set_arena"):
		boss.set_arena(arena_data["grid"], int(arena_data["width"]), int(arena_data["height"]))
	if "debug_fast_skills" in boss:
		boss.debug_fast_skills = debug_fast_boss
	if boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(_on_boss_defeated)
	if not boss.died.is_connected(_on_enemy_died):
		boss.died.connect(_on_enemy_died)
	print("[Battle] Boss 已放出: 出生格=%s（玩家在 %s，相距 %.0f 格）" % [
		str(spawn_cell), str(arena_data["player_spawn"]),
		Vector2(spawn_cell).distance_to(Vector2(arena_data["player_spawn"]))])
	if debug_instant_boss_win:
		_start_debug_instant_win()


## 两只 BOSS 之间的最小间距（像素）：追人时互相挤开，免得叠成一坨看起来像一只
const BOSS_MIN_SEPARATION := 24.0
const BOSS_SEPARATION_SPEED := 110.0


## 多只 BOSS 同场时（第 15 层最多 4 只紫 BOSS / 2 只岩浆 BOSS），每帧互相推开一点
func _separate_bosses(delta: float) -> void:
	var list: Array = []
	for node in _boss_nodes_all():
		if not is_instance_valid(node) or bool(node.get("is_dead")):
			continue
		var node2d := node as Node2D
		if node2d == null:
			continue
		list.append(node2d)
	if list.size() < 2:
		return
	var max_step := BOSS_SEPARATION_SPEED * delta
	for i in range(list.size()):
		var a: Node2D = list[i]
		for j in range(i + 1, list.size()):
			var b: Node2D = list[j]
			var diff := b.global_position - a.global_position
			var dist := diff.length()
			if dist >= BOSS_MIN_SEPARATION:
				continue
			var dir := diff.normalized() if dist > 0.01 else Vector2.RIGHT.rotated(randf() * TAU)
			# 每帧只推很小一点（不用 clamp_to_walkable，否则会被吸附到格心，画面一顿一顿的）
			var push := minf(max_step, (BOSS_MIN_SEPARATION - dist) * 0.5)
			a.global_position -= dir * push
			b.global_position += dir * push


## 场上所有活着的 BOSS（含紫 BOSS / 岩浆 BOSS）所占的格子
func _boss_occupied_cells() -> Dictionary:
	var occupied := {}
	for node in _boss_nodes_all():
		if not is_instance_valid(node) or bool(node.get("is_dead")):
			continue
		var node2d := node as Node2D
		if node2d == null:
			continue
		occupied[arena_cell_at(node2d.global_position)] = true
	return occupied


## 多只 BOSS 同场时，依次取"离玩家最远、且没被占用"的格子，避免叠在一起
func _next_boss_spawn_cell() -> Vector2i:
	var occupied: Dictionary = _boss_occupied_cells()
	var w: int = int(arena_data["width"])
	var h: int = int(arena_data["height"])
	var grid: Array = arena_data["grid"]
	# 以玩家"当前所在格"为参照（不是关卡开局位置），否则玩家跑远了 BOSS 会刷在脸上
	var player_cell: Vector2i = arena_cell_at(player.global_position)
	var min_gap := float(mini(int(arena_data["width"]), int(arena_data["height"]))) * 0.55
	var best := _farthest_spawn_cell_from(player_cell)
	var best_distance := Vector2(best).distance_to(Vector2(player_cell))
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			if int(grid[y * w + x]) != 0:
				continue
			var cell := Vector2i(x, y)
			if occupied.has(cell):
				continue
			var distance := Vector2(cell).distance_to(Vector2(player_cell))
			if distance < min_gap:
				continue                       # 离玩家太近的格子直接不考虑
			if distance > best_distance - 1.0 and distance <= best_distance:
				best = cell
				best_distance = distance
	if occupied.has(best):
		# 最近的空位兜底
		for y in range(1, h - 1):
			for x in range(1, w - 1):
				if int(grid[y * w + x]) != 0:
					continue
				var cell2 := Vector2i(x, y)
				if not occupied.has(cell2):
					return cell2
	return best


## Boss 出生点：优先取"离玩家最远的红门"；若还不够远（不足地图短边的一半），
## 就在全场可通行格里挑离玩家最远的那个 —— 保证一进关卡玩家和 Boss 离得很远。
func _farthest_spawn_cell_from(cell: Vector2i) -> Vector2i:
	var best := _farthest_door_cell_from(cell)
	var best_distance := Vector2(best).distance_to(Vector2(cell))
	var minimum := minf(float(arena_data["width"]), float(arena_data["height"])) * 0.5
	if best_distance < minimum:
		var grid: Array = arena_data["grid"]
		var w: int = arena_data["width"]
		var h: int = arena_data["height"]
		for y in range(1, h - 1):
			for x in range(1, w - 1):
				if int(grid[y * w + x]) != 0:
					continue
				var distance := Vector2(x, y).distance_to(Vector2(cell))
				if distance > best_distance:
					best_distance = distance
					best = Vector2i(x, y)
	return best


## 取"离玩家最远的那道红门"
func _farthest_door_cell_from(cell: Vector2i) -> Vector2i:
	var best: Vector2i = cell
	var best_distance := -1.0
	for door in arena_data["doors"]:
		var door_cell: Vector2i = door["cell"]
		var distance := Vector2(door_cell).distance_to(Vector2(cell))
		if distance > best_distance:
			best_distance = distance
			best = door_cell
	return best


func _on_boss_defeated() -> void:
	_boss_defeated = true
	# BOSS 全部倒下后红门不再刷怪（用户要求）
	if _living_boss_count() == 0:
		var door_timer := get_node_or_null("BossDoorSpawnTimer") as Timer
		if door_timer != null:
			door_timer.stop()
		if enemy_spawn_timer != null:
			enemy_spawn_timer.stop()
		if debug_print:
			print("[Battle] BOSS 全部击败，红门停止刷怪")
	var boss_gain := maxi(gold_per_boss_kill, 0)
	RunState.add_gold(boss_gain)
	_gold_gained += boss_gain

	# 血条的收起改由 _update_time_bar() 每帧按血量处理（第10层还有第二条，不能在这里一起关）
	if debug_print:
		print("[Battle] Boss 已击败, 目标达成判定=%s" % str(LevelGoal.is_satisfied(goal, _goal_state())))


# ---------------- 目标驱动的 HUD 布局（顶部时间条 / 时钟 / 生命值位置） ----------------

## 规则：
##   有时限关卡（survive / elite）：保持原样（时钟 + 绿条 + 生命值在下方）
##   Boss 关：删掉时钟；绿条 → 红条并**横向居中**，绑定 Boss 血量；生命值留在原位（避免压到居中红条）
##   其他无时限关卡（clear_waves）：删掉时钟与绿条；生命值图标 + 文字**整体上移到原时间那一行**（横向不动）
func _apply_goal_hud_layout() -> void:
	var clock_icon := $Player/HUDLayer/TimeIcon as Sprite2D
	var clock_bar := $Player/HUDLayer/TimeBar as Sprite2D
	var life_icon_node := $Player/HUDLayer/LifeIcon as Sprite2D
	var life_label_node := $Player/HUDLayer/LifeCountLabel as Label
	if LevelGoal.time_limit(goal) > 0.0:
		return                                   # 有时限：完全保持原样
	if clock_icon != null:
		clock_icon.visible = false               # 无时限：时钟一律删除
	if goal.get("type", "") == LevelGoal.TYPE_BOSS:
		_prepare_boss_health_bar(clock_bar)
	else:
		if clock_bar != null:
			clock_bar.visible = false            # 其他无时限：绿条也删掉
		_move_life_display_up_to_time_row(life_icon_node, life_label_node, clock_icon, clock_bar)


## Boss 关：绿条 → 红条（居中 + 之后由 _update_time_bar 绑定 Boss 血量）
func _prepare_boss_health_bar(clock_bar: Sprite2D) -> void:
	if clock_bar == null:
		return
	clock_bar.visible = true
	clock_bar.modulate = BOSS_BAR_COLOR
	clock_bar.position.x = 0.0
	# 居中后必须重算左边缘（父类 _setup_hud 是按原位置算的），否则条会往右跑
	if clock_bar.centered:
		time_bar_left_edge_x = clock_bar.position.x - (time_bar_texture_width * time_bar_full_scale_x * 0.5)
	else:
		time_bar_left_edge_x = clock_bar.position.x
	_setup_boss_bar_icons(clock_bar)
	_setup_boss_lock_hud(clock_bar)


## 其他无时限关卡：生命值图标 + 文字整体上移到"原时间那一行"（只改纵向）
func _move_life_display_up_to_time_row(life_icon_node: Sprite2D, life_label_node: Label, clock_icon: Sprite2D, clock_bar: Sprite2D) -> void:
	var time_row_y := 0.0
	if clock_icon != null:
		time_row_y = clock_icon.position.y
	elif clock_bar != null:
		time_row_y = clock_bar.position.y
	else:
		return
	if life_icon_node == null:
		return
	var delta := time_row_y - life_icon_node.position.y
	life_icon_node.position.y += delta
	if life_label_node != null:
		life_label_node.offset_top += delta
		life_label_node.offset_bottom += delta


## 第一条血条的比例（第5层若是紫 BOSS，则本体 + 分身共用一个血池）
func _boss_hp_ratio() -> float:
	return _main_boss_ratio()


## 覆盖父类：Boss 关顶部条 = 每个 BOSS 一条独立血条（有几个 BOSS 就几条）
func _update_time_bar() -> void:
	if goal.get("type", "") != LevelGoal.TYPE_BOSS or time_bar == null:
		super._update_time_bar()
		return
	_refresh_boss_bars()


## 把某条血条按比例缩放（保持左边缘不动，从左往右缩短）
func _apply_boss_bar(sprite: Sprite2D, ratio: float) -> void:
	if sprite == null:
		return
	sprite.scale.x = time_bar_full_scale_x * clampf(ratio, 0.0, 1.0)
	if not sprite.centered:
		sprite.position.x = time_bar_left_edge_x
		return
	var current_width := time_bar_texture_width * sprite.scale.x
	sprite.position.x = time_bar_left_edge_x + (current_width * 0.5)


## 某个 BOSS 的锁血剩余时间（没有锁血机制/已结束 -> 0）
func _lock_left_of(node: Node) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	if not node.has_method("hp_lock_left"):
		return 0.0
	return float(node.call("hp_lock_left"))


## 紫色阵营（本体 + 分身）共用一条血条，锁血也按这条共享血池算
func purple_family_lock_active(family: int = -1) -> bool:
	if family < 0:
		for value in _purple_lock_left_by_family.values():
			if float(value) > 0.0:
				return true
		return false
	return float(_purple_lock_left_by_family.get(family, 0.0)) > 0.0


## 紫色共享血条右侧倒计时读的秒数
func _purple_lock_left() -> float:
	return _purple_family_lock_left


## 紫色阵营共用一份 HP：所有本体/分身的伤害都扣这一份血（用户要求）
## 返回值 = 这次伤害是否真的生效（锁血期间 / 打不动时为 false）
func purple_family_apply_damage(amount: int, family: int = 0) -> bool:
	var fam_max := float(_purple_max_by_family.get(family, 0.0))
	var fam_hp := float(_purple_hp_by_family.get(family, 0.0))
	if amount <= 0 or fam_max <= 0.0 or fam_hp <= 0.0:
		return false
	if float(_purple_lock_left_by_family.get(family, 0.0)) > 0.0:
		return false                                   # 这个家族锁血中：伤害无效
	var deal := amount
	if not bool(_purple_lock_used_by_family.get(family, false)):
		# 会把血条打到 50% 以下的那一击：截断到刚好 50%（避免一发放倒）
		var floor_hp := fam_max * PURPLE_LOCK_RATIO
		if fam_hp > floor_hp:
			deal = mini(deal, int(ceil(fam_hp - floor_hp)))
	if deal <= 0:
		return false
	fam_hp = maxf(fam_hp - float(deal), 0.0)
	_purple_hp_by_family[family] = fam_hp
	if not bool(_purple_lock_used_by_family.get(family, false)) 			and fam_hp <= fam_max * PURPLE_LOCK_RATIO:
		_start_purple_family_lock(family)
	if fam_hp <= 0.0:
		_kill_purple_family(family)
	return true


## 共用血条见底：所有本体 + 分身同时死亡、不掉道具；只在第 5 层出现时给 30 金币
func _kill_purple_family(family: int = -1) -> void:
	if _purple_family_killing:
		return
	_purple_family_killing = true
	var bodies: Array = []
	for node in _purple_nodes():
		if family < 0 or int(node.get("family_id")) == family:
			bodies.append(node)
	for node in bodies:
		if not is_instance_valid(node):
			continue
		node.set("drop_disabled", true)          # 紫 BOSS 不掉道具
		if not bool(node.get("is_dead")):
			node.call("_die")
	_purple_family_killing = false
	if _context_floor() == 5:
		var gain := PURPLE_FLOOR5_GOLD
		RunState.add_gold(gain)
		_gold_gained += gain
		if debug_print:
			print("[Battle] 紫色 BOSS（第 5 层）阵亡：不掉道具，金币 +%d（合计 %d）" % [gain, RunState.gold])
	else:
		# 其它层（第 15 层第二波等）：按普通 BOSS 的金币给，每个家族一份
		var gain2 := maxi(gold_per_boss_kill, 0)
		RunState.add_gold(gain2)
		_gold_gained += gain2
		if debug_print:
			print("[Battle] 紫色家族 %d 阵亡：不掉道具，金币 +%d（合计 %d）" % [
				family, gain2, RunState.gold])


func _start_purple_family_lock(family: int = 0) -> void:
	if bool(_purple_lock_used_by_family.get(family, false)):
		return
	_purple_lock_used_by_family[family] = true
	_purple_lock_left_by_family[family] = PURPLE_LOCK_TIME
	_purple_family_lock_used = true
	_purple_family_lock_left = PURPLE_LOCK_TIME
	print("[Battle] 紫 BOSS 共享血池到 50%%：全家锁血 %.0f 秒（移速 +%.0f%%）" % [
		PURPLE_LOCK_TIME, PURPLE_LOCK_SPEED_BONUS * 100.0])


func _update_purple_family_lock(delta: float) -> void:
	if _purple_nodes().is_empty():
		return
	var longest := 0.0
	for family in _purple_hp_by_family.keys():
		var left := float(_purple_lock_left_by_family.get(family, 0.0))
		if left > 0.0:
			left = maxf(left - delta, 0.0)
			_purple_lock_left_by_family[family] = left
			longest = maxf(longest, left)
	_purple_family_lock_left = longest


## 血条 50% 处画一条刻度线 + 右侧一个倒计时文字（9.5S），提醒"打到这就会锁血"
func _setup_boss_lock_hud(clock_bar: Sprite2D) -> void:
	var hud := get_node_or_null("Player/HUDLayer") as Node2D
	if hud == null or clock_bar == null:
		return
	_boss_lock_marker = _make_boss_lock_marker(hud, clock_bar)
	_boss_lock_label = _make_boss_lock_label(hud, clock_bar)


func _make_boss_lock_marker(hud: Node2D, bar: Sprite2D) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = "BossLockMarker"
	rect.color = Color(1.0, 1.0, 1.0, 0.35)
	rect.size = Vector2(BOSS_LOCK_MARKER_WIDTH, BOSS_LOCK_MARKER_HEIGHT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(rect)
	var center_x := time_bar_left_edge_x + time_bar_texture_width * time_bar_full_scale_x * 0.5
	rect.position = Vector2(center_x - BOSS_LOCK_MARKER_WIDTH * 0.5,
			bar.position.y - BOSS_LOCK_MARKER_HEIGHT * 0.5)
	return rect


func _make_boss_lock_label(hud: Node2D, bar: Sprite2D) -> Label:
	var label := Label.new()
	label.name = "BossLockLabel"
	label.add_theme_font_size_override("font_size", BOSS_LOCK_FONT_SIZE)
	label.add_theme_color_override("font_color", BOSS_BAR_LOCK_COLOR)
	label.add_theme_constant_override("outline_size", 4)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	label.visible = false
	hud.add_child(label)
	# 固定在"满宽血条的右端外侧"（不跟着变短的血条往左跑，否则会跑到血条中间甚至左边）
	var right_x := time_bar_left_edge_x + time_bar_texture_width * time_bar_full_scale_x
	label.position = Vector2(right_x + BOSS_LOCK_LABEL_GAP,
			bar.position.y - BOSS_LOCK_FONT_SIZE * 0.75)
	label.set_meta("anchor_x", label.position.x)
	return label


## 锁血期间：刻度线变金黄、右侧显示剩余秒数（9.5S）；没锁血时隐藏文字、刻度线变淡
func _update_boss_lock_hud(label: Label, marker: ColorRect, lock_left: float,
		bar: Sprite2D = null) -> void:
	if label != null:
		label.visible = lock_left > 0.0
		if lock_left > 0.0:
			label.text = "%.1fS" % lock_left
			# x 固定用满宽血条的右端（建标签时记下来的 anchor_x），血条变短也不左移
			if label.has_meta("anchor_x"):
				label.position.x = float(label.get_meta("anchor_x"))
			elif bar != null:
				label.position.x = (time_bar_left_edge_x
					+ time_bar_texture_width * time_bar_full_scale_x + BOSS_LOCK_LABEL_GAP)
	if marker != null:
		marker.color = BOSS_BAR_LOCK_COLOR if lock_left > 0.0 else Color(1.0, 1.0, 1.0, 0.35)


## 锁血期间的血条表现：金黄色 + 呼吸闪烁（约 3Hz）；没锁血就恢复红色
func _apply_boss_lock_visual(sprite: Sprite2D, lock_left: float) -> void:
	if sprite == null:
		return
	if lock_left <= 0.0:
		sprite.modulate = BOSS_BAR_COLOR
		return
	var phase := Time.get_ticks_msec() / 1000.0 * TAU * BOSS_BAR_LOCK_PULSE_HZ
	var pulse := 0.55 + 0.45 * (0.5 + 0.5 * sin(phase))
	sprite.modulate = Color(BOSS_BAR_LOCK_COLOR.r * pulse, BOSS_BAR_LOCK_COLOR.g * pulse,
			BOSS_BAR_LOCK_COLOR.b * pulse, 1.0)


## 场上所有 BOSS 里最长的"锁血剩余时间"（HUD 文字提示用；0 = 没在锁血）
func _boss_lock_left() -> float:
	# 注意：主 BOSS 不在 _boss_nodes 里（那只数组只装紫 BOSS），两边取最大
	return maxf(_lock_left_of(_boss), _purple_lock_left())


## 血条左侧的怪物图片：第一次拿到纹理后就不再改
func _update_boss_bar_icon(icon: Sprite2D, node: Node) -> void:
	if icon == null or node == null:
		return
	var body_id := node.get_instance_id()
	if int(icon.get_meta("body_id", 0)) == body_id and icon.texture != null:
		return
	icon.set_meta("body_id", body_id)
	icon.texture = _boss_icon_texture(node)


## 第一条血条追踪的对象：第5层可能是原 BOSS 或紫 BOSS
func _main_boss_body() -> Node:
	return _boss


## 第二只 BOSS（第 15 层多 BOSS 同场时给第二条血条用）
func _second_boss_body() -> Node:
	for node in _boss_nodes:
		if node != _boss and is_instance_valid(node) and not bool(node.is_dead):
			return node
	return null


## 这个节点是哪种 BOSS：normal / purple / lava；不是 BOSS 返回空串
func _boss_kind_of(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	if not node.has_method("boss_kind"):
		return ""
	return String(node.call("boss_kind"))


func _main_boss_current() -> float:
	if _boss == null or not is_instance_valid(_boss):
		return 0.0
	if _boss_kind_of(_boss) == "purple":
		return _purple_family_current()
	return maxf(float(_boss.current_health), 0.0)


func _main_boss_ratio() -> float:
	if _boss == null or not is_instance_valid(_boss):
		return 0.0
	if _boss_kind_of(_boss) == "purple":
		return _purple_family_ratio()
	if _boss.config == null:
		return 0.0
	return clampf(float(_boss.current_health) / float(maxi(int(_boss.config.max_health), 1)), 0.0, 1.0)


## 紫色阵营（所有本体 + 分身，去掉已死的）
func _purple_nodes() -> Array[Node]:
	var nodes: Array[Node] = []
	for child in enemy_container.get_children():
		if not is_instance_valid(child):
			continue
		if _boss_kind_of(child) == "purple" and not bool(child.get("is_dead")):
			nodes.append(child)
	return nodes


## 共用血条当前值（本体 + 分身同吃这一份）
func _purple_family_current() -> float:
	var total := 0.0
	for value in _purple_hp_by_family.values():
		total += float(value)
	return total


## 某个家族的血条比例 / 当前值 / 锁血剩余
func _purple_family_current_of(family: int) -> float:
	return float(_purple_hp_by_family.get(family, 0.0))


func _purple_family_ratio_of(family: int) -> float:
	var fam_max := float(_purple_max_by_family.get(family, 0.0))
	if fam_max <= 0.0:
		return 0.0
	return clampf(float(_purple_hp_by_family.get(family, 0.0)) / fam_max, 0.0, 1.0)


func _purple_lock_left_of(family: int) -> float:
	return float(_purple_lock_left_by_family.get(family, 0.0))


func _purple_family_ratio() -> float:
	var total_max := 0.0
	for value in _purple_max_by_family.values():
		total_max += float(value)
	if total_max <= 0.0:
		return 0.0
	return clampf(_purple_family_current() / total_max, 0.0, 1.0)


## 显示图片用的紫色本体
func _purple_body() -> Node:
	for node in _boss_nodes:
		if is_instance_valid(node) and not bool(node.get("is_clone")):
			return node
	return null


## 紫色共享血条掉到 75% / 50% / 25% 时，各从一只存活的本体处分裂出 1 个分身（共 3 个）
func _update_purple_splits() -> void:
	# 每个家族各自按自己的血条比例分裂：同一家族的若干只 BOSS 共用一个血池
	for family in _purple_max_by_family.keys():
		var stage := int(_purple_split_stage_by_family.get(family, 0))
		if stage >= PURPLE_SPLIT_THRESHOLDS.size():
			continue
		if _purple_family_ratio_of(family) > PURPLE_SPLIT_THRESHOLDS[stage]:
			continue
		# 家族场上已经有 PURPLE_MAX_BODIES_PER_FAMILY 只就不再分裂（4 = 1 本体 + 3 分身）
		if _alive_bodies_of_family(family) >= PURPLE_MAX_BODIES_PER_FAMILY:
			_purple_split_stage_by_family[family] = stage + 1
			continue
		_purple_split_stage_by_family[family] = stage + 1
		var body := _pick_alive_purple_body(family)
		if body != null and body.has_method("spawn_clone_now"):
			body.spawn_clone_now()
			if debug_print:
				print("[Battle] 紫色家族 %d 血条到 %.0f%%，加 1 个分身" % [
					family, PURPLE_SPLIT_THRESHOLDS[stage] * 100.0])


## 某个家族还活着几只紫 BOSS（本体 + 分身）
func _alive_bodies_of_family(family: int) -> int:
	var count := 0
	for node in _purple_nodes():
		if int(node.get("family_id")) == family:
			count += 1
	return count


## 从某个家族存活的本体里挑一个来生成分身（分身不作为分裂来源）
func _pick_alive_purple_body(family: int = -1) -> Node:
	for node in _boss_nodes:
		if not is_instance_valid(node):
			continue
		if _boss_kind_of(node) != "purple":
			continue                     # 只从紫 BOSS 里挑（普通/岩浆 BOSS 没有家族）
		if family >= 0 and int(node.get("family_id")) != family:
			continue
		if not bool(node.get("is_dead")) and not bool(node.get("is_clone")):
			return node
	return null


## 调试: 出生 1.2 秒后模拟"Boss 被打死"，然后走完整条 结算 -> 确定 链路
func _start_debug_instant_win() -> void:
	var timer := Timer.new()
	timer.wait_time = 1.2
	timer.one_shot = true
	timer.timeout.connect(_debug_instant_win)
	add_child(timer)
	timer.start()


func _on_result_dialog_exit_requested() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false
	_record_run_progress()
	if _last_result_won:
		if goal.get("type", "") == LevelGoal.TYPE_BOSS and RunState.is_final_floor():
			RunState.finish_run(true)          # 最终层 BOSS 通关: 整局结束
			GameFlow.goto_title()
		else:
			RunState.advance_floor()           # 普通关/精英关/中途 BOSS 胜利: 层数 +1
			GameFlow.goto_midmap()                # 回中间地图
	else:
		RunState.finish_run(false)             # 失败: 整局结束
		GameFlow.goto_title()


## 把本场战绩并进整局状态（只并一次）
func _record_run_progress() -> void:
	if _result_recorded:
		return
	_result_recorded = true
	RunState.total_kills += round_kill_count
	RunState.run_elapsed += _get_round_elapsed_time()
	# 生命值跨关卡保留：把这一场打完的血量写回整局状态
	RunState.set_health(_get_player_current_health(), player.max_health)
	# 本关成绩：留给 中间地图 在关卡之间做汇报
	RunState.last_level_report = {
		"floor": RunState.floor_index,
		"node_type": String(goal.get("node_type", "")),
		"goal_text": LevelGoal.describe(goal),
		"won": _last_result_won,
		"kills": round_kill_count,
		"elapsed": _get_round_elapsed_time(),
		"gold_gained": _gold_gained,
		"gold_total": RunState.gold,
		"health": _get_player_current_health(),
		"max_health": player.max_health,
	}
	if debug_print:
		print("[Battle] 离场写回: 生命 %d/%d 金币 %d 本关击杀 %d 用时 %.1f 秒" % [
			RunState.current_health, RunState.max_health, RunState.gold,
			round_kill_count, _get_round_elapsed_time()])


## 通关总结（打在同一个结算弹窗里，多行文本会让弹窗自动放大）
func _build_run_summary() -> String:
	_record_run_progress()
	return "恭喜通关
到达层数: %d / %d
本局总击杀: %d
本局用时: %.1f 秒
金币: %d

按确定返回标题" % [
		RunState.floor_index, RunState.MAX_FLOOR,
		RunState.total_kills, RunState.run_elapsed, RunState.gold]


## 覆盖父类: 多行文本时把弹窗放大，避免被裁掉
func _show_result_dialog(result_title: String, result_message: String) -> void:
	# 显示结算前，先把队友血量/层数写回名册（只写一次）
	if not is_result_displayed:
		_write_back_allies()
	super._show_result_dialog(result_title, result_message)
	if result_message.contains("
") and result_dialog != null:
		result_dialog.popup_centered(Vector2i(460, 260))


### 调试: 模拟击败 Boss 后，直接把"总结文本 + 确定后的整局状态"打出来。
## 说明: 结算弹窗会把 time_scale 设为 0，计时器全部冻结，所以这里不用延时，
##       直接在模拟击杀的同一帧验证流程（等价于玩家点确定）。
func _debug_instant_win() -> void:
	print("[Battle调试] 模拟胜利 目标=%s 层数=%d" % [String(goal.get("type", "?")), RunState.floor_index])
	_last_result_won = true          # 真实路径里由 _check_game_result() 置位，这里手动补上
	if not _boss_defeated:
		_on_boss_defeated()
	print("[Battle调试] 通关总结文本=%s" % _build_run_summary().replace("
", " | "))
	print("[Battle调试] 点确定前: 层数=%d 局进行中=%s 总击杀=%d 用时=%.1f" % [
		RunState.floor_index, str(RunState.is_active), RunState.total_kills, RunState.run_elapsed])
	# 模拟玩家点确定（清掉暂停，避免后续场景切不过去）
	Engine.time_scale = 1.0
	get_tree().paused = false
	_on_result_dialog_exit_requested()
	print("[Battle调试] 点确定后: 层数=%d 局进行中=%s 已通关=%s 总击杀=%d" % [
		RunState.floor_index, str(RunState.is_active), str(RunState.cleared), RunState.total_kills])


# ---------------- 目标 HUD:屏幕底部居中，纯文字 零美术  ----------------

func _setup_goal_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "GoalHUD"
	add_child(layer)
	_goal_label = _make_bottom_label(-40, 20, Color(1.0, 0.87, 0.55))
	_detail_label = _make_bottom_label(-14, 14, Color(0.85, 0.85, 0.85))
	layer.add_child(_goal_label)
	layer.add_child(_detail_label)


## 贴屏幕底部的居中文本；加黑描边，保证在任何深色地砖上都读得清
func _make_bottom_label(bottom_offset: int, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	label.offset_top = bottom_offset - font_size - 8
	label.offset_bottom = bottom_offset
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _refresh_goal_hud(force: bool = false) -> void:
	if _goal_label == null or _detail_label == null:
		return
	var state := _goal_state()
	var head := LevelGoal.describe(goal)
	var detail := LevelGoal.progress_text(goal, state)
	var key := "%s|%s|%d" % [head, detail, int(stage_time_left)]
	if not force and key == _last_hud_key:
		return
	_last_hud_key = key
	_goal_label.text = head
	var suffix := ""
	if LevelGoal.time_limit(goal) > 0.0:
		suffix = " 剩余 %.0f 秒" % maxf(stage_time_left, 0.0)
	_detail_label.text = "第 %d 层 ， %s%s" % [int(goal.get("floor", 1)), detail, suffix]


# ---------------- 胜负判定:覆盖父类，改成按 LevelGoal 的 ALL 语义 ----------------

func _goal_state() -> Dictionary:
	return {
		"kills": round_kill_count,
		"time_left": stage_time_left,
		"waves_done": _waves_done,
		"waves_total": _waves.size(),
		"boss_defeated": _living_boss_count() == 0 and _boss_waves_finished(),
		"boss_hp_ratio": _boss_hp_ratio(),          # M3:Boss 死亡时由 Boss 置真
		"guard_alive": _guard_target != null and is_instance_valid(_guard_target) and not _guard_target.is_dead,
		"push_arrived": _push_arrived,
		"push_progress": int(_push_box.moved_cells()) if _push_box != null and is_instance_valid(_push_box) else 0,
		"push_total": int(_push_box.total_cells()) if _push_box != null and is_instance_valid(_push_box) else 0,
		"alive_enemies": _get_alive_enemy_count(),
		"maze_exited": _maze_exited,
		"maze_elapsed": _maze_elapsed,
	}


func _check_game_result() -> void:
	if is_result_displayed:
		return
	if _get_player_current_health() <= 0:
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, RESULT_MESSAGE_LOSE)
		return
	if goal.get("type", "") == LevelGoal.TYPE_DEFEND and (_guard_target == null or not is_instance_valid(_guard_target) or _guard_target.is_dead):
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, "守护对象被击破了")
		return
	var state := _goal_state()
	if LevelGoal.is_satisfied(goal, state):
		_last_result_won = true
		if goal.get("type", "") == LevelGoal.TYPE_BOSS and RunState.is_final_floor():
			_show_result_dialog("通关", _build_run_summary())      # 最终层: 显示整局总结
		elif goal.get("type", "") == LevelGoal.TYPE_BOSS:
			_show_result_dialog("BOSS 击破", "第 %d 层 BOSS 已被击败 回中间地图" % RunState.floor_index)
		elif goal.get("type", "") == LevelGoal.TYPE_PUSH:
			var reward := _temp_ally_reward_gold()
			if reward > 0:
				RunState.add_gold(reward)
			_show_result_dialog("推车成功",
				"箱子抵达终点，撤离奖励 %d 金币（临时友方）" % reward)
		else:
			_show_result_dialog(RESULT_TITLE_WIN, "本层目标达成 回中间地图")
		return
	if LevelGoal.is_timed_out(goal, state):
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, "时间到，目标未完成")


# ---------------- 开发自检 M1/M2 验收用，稳定后可删  ----------------

func _start_self_check() -> void:
	var probe := Timer.new()
	probe.name = "SelfCheckTimer"
	probe.wait_time = 1.6
	probe.one_shot = true
	probe.timeout.connect(_self_check)
	add_child(probe)
	probe.start()


func _self_check() -> void:
	var alive := _get_alive_enemy_count()
	var first_enemy: Node2D = null
	for child in enemy_container.get_children():
		if child is Enemy:
			first_enemy = child
			break
	var door_distance := INF
	if first_enemy != null:
		var generator = ArenaGen.new()
		for door in arena_data["doors"]:
			door_distance = minf(door_distance, first_enemy.global_position.distance_to(
				generator.spawn_world_position(door)))
	print("[Battle自检] 场上敌人=%d Overlay(红门)格=%d 地面格=%d 波次=%d/%d 击杀=%d 目标达成=%s%s" % [
		alive, $OverlayTileMapLayer.get_used_cells().size(), $GroundTileMapLayer.get_used_cells().size(),
		_waves_done, _waves.size(), round_kill_count,
		str(LevelGoal.is_satisfied(goal, _goal_state())),
		("" if first_enemy == null else "；首个敌人距最近红门 %.1f px" % door_distance)])
	var _hud_bar := $Player/HUDLayer/TimeBar as Sprite2D
	var _hud_life := $Player/HUDLayer/LifeIcon as Sprite2D
	var _hud_icon_time := $Player/HUDLayer/TimeIcon as Sprite2D
	print("[Battle自检] HUD布局: 时钟可见=%s 条可见=%s 条X=%.0f 条色=%s 生命Y=%.0f" % [
		str(_hud_icon_time.visible), str(_hud_bar.visible), _hud_bar.position.x,
		str(_hud_bar.modulate), _hud_life.position.y])
	print("[Battle自检] HUD第一行=%s ， HUD第二行=%s" % [_goal_label.text, _detail_label.text])

# ---------------- 三重 BOSS（第 5 层 50/50 / 第 10 层 3 只 + 家族血条） ----------------

const DefendTargetScene := preload("res://scene/entities/objectives/defend_target.tscn")
const SHOOTER_CONFIG := preload("res://resources/config/enemy_shooter.tres")
## 守护关：在场敌人上限从 0 线性放到 DEFEND_MAX_ALIVE，DEFEND_RAMP_TIME 秒时到顶
const DEFEND_MAX_ALIVE := 30
const DEFEND_RAMP_TIME := 90.0
const PURPLE_BOSS_SCENE := "res://scene/entities/bosses/boss_purple.tscn"
const LavaBossScene := preload("res://scene/entities/bosses/boss_lava.tscn")
const PURPLE_SPLIT_THRESHOLDS: Array[float] = [0.75, 0.50, 0.25]  ## 共享血条掉到这些比例各加 1 个分身
## 一个紫色家族场上最多几只（本体 + 分身）：1 本体时正好分裂 3 个分身 = 4 只
const PURPLE_MAX_BODIES_PER_FAMILY := 4
const BOSS_ICON_ATLAS := "res://resources/texture/源石虫.png"
const NORMAL_BOSS_ICON_ROW_Y := 32    ## 原 BOSS 的血条图片用源石虫.png 第 2 排（用户指定）
const BOSS_BAR_SPACING := 16.0        ## 第10层第二条血条相对第一条下移的世界单位（相机4倍 -> 屏幕64px）
const BOSS_ICON_SCALE := 1.0          ## 血条左侧怪物图片的缩放（32x32 -> 32 世界单位，用户要求放大一倍）
const BOSS_ICON_GAP := 24.0
## BOSS 血条颜色：平时红色；半血锁血期间变金黄色 + 呼吸闪烁（提醒这段时间打不动）
const BOSS_BAR_COLOR := Color(1.0, 0.28, 0.28)
const BOSS_BAR_LOCK_COLOR := Color(1.0, 0.86, 0.25)
const BOSS_BAR_LOCK_PULSE_HZ := 3.0
## 紫色阵营共用血池：掉到 50% 时"全家"锁血 10 秒、移速 +20%（本体 + 分身算一个整体）
const PURPLE_LOCK_TIME := 10.0
const PURPLE_LOCK_RATIO := 0.5
const PURPLE_LOCK_SPEED_BONUS := 0.2
## 紫色 BOSS 在第 5 层出现时，阵亡只给这些金币（不掉道具）
const PURPLE_FLOOR5_GOLD := 30
## 锁血倒计时文字（放在血条右侧，格式 9.5S）/ 50% 刻度线
const BOSS_LOCK_LABEL_GAP := 6.0
const BOSS_LOCK_FONT_SIZE := 13
const BOSS_LOCK_MARKER_WIDTH := 2.0
const BOSS_LOCK_MARKER_HEIGHT := 11.0           ## 怪物图片中心到血条左边缘的距离（图片变大后同步拉远，避免压住血条）


## 第 10 层 = 原 BOSS + 2 只紫 BOSS；其它 BOSS 层 = 50/50 随机一只
## 用「每局随机种子 run_seed」参与：每局进同一层都可能不同（真随机 50/50），
## 同一局内重进该层结果固定（可复现）。
func _spawn_bosses_for_floor() -> void:
	_boss_nodes.clear()
	var floor_now := _context_floor()
	if floor_now == 10:
		_spawn_boss()
		# 两只紫 BOSS 用同一个家族号：共用一个血池 = 一条血条（和拆家族之前的表现一致）
		_spawn_purple_boss(1)
		_spawn_purple_boss(1)
		print("[Battle] 第 10 层：三重 BOSS（原 BOSS + 紫 BOSS x2）")
		_spawn_final_floor_shooters(4)      # 开局再放 4 个持枪敌人（用户要求）
	elif RunState.is_final_floor() or floor_now >= RunState.MAX_FLOOR:
		# 第 15 层：交给波次系统（_update_boss_waves 里按三波依次放 BOSS）
		print("[Battle] 第 %d 层：三波 BOSS 演出（普通 x2 -> 紫 x2 -> 岩浆 x2）" % floor_now)
	else:
		var rng := RandomNumberGenerator.new()
		rng.seed = RunState.run_seed + floor_now * 7919   # 加入本局随机种子：每局都可能出紫 BOSS
		if rng.randf() < 0.5:
			print("[Battle] 第 %d 层 BOSS 抽到：原 BOSS" % floor_now)
			_spawn_boss()
		else:
			print("[Battle] 第 %d 层 BOSS 抽到：紫色 BOSS" % floor_now)
			_spawn_purple_boss(0)


## 第 10 层开局固定放出 count 个持枪敌人（用户要求 4 个）
func _spawn_final_floor_shooters(count: int) -> void:
	var cfg := _shooter_config_from_pool()
	if cfg == null:
		return
	var spawned := 0
	for _index in range(count):
		var spawn_point := _pick_spawn_point()
		if spawn_point == null:
			break
		var spawn_scene := enemy_scene
		if cfg.scene_override != null:
			spawn_scene = cfg.scene_override
		var shooter := spawn_scene.instantiate() as Enemy
		if shooter == null:
			continue
		enemy_container.add_child(shooter)
		shooter.global_position = spawn_point.global_position
		shooter.setup(cfg, player)
		if not shooter.died.is_connected(_on_enemy_died):
			shooter.died.connect(_on_enemy_died)
		spawned += 1
	if debug_print:
		print("[Battle] 第 10 层开局放出 %d 个持枪敌人" % spawned)


## 从刷怪池里取"持枪敌人"的配置（已按层数缩放血量）
func _shooter_config_from_pool() -> EnemyConfig:
	for cfg in available_enemy_configs:
		if cfg == null or cfg.scene_override == null:
			continue
		if cfg.scene_override == SHOOTER_CONFIG.scene_override:
			return cfg
	return SHOOTER_CONFIG


func _spawn_purple_boss(family: int) -> void:
	var purple = load(PURPLE_BOSS_SCENE).instantiate()
	if purple == null:
		return
	enemy_container.add_child(purple)
	purple.add_to_group(BOSS_GROUP)        # 不占"普通敌人"名额
	var spawn_cell: Vector2i = _spawn_cell_for_family(arena_cell_at(player.global_position), family)
	purple.global_position = cell_to_world(spawn_cell)
	purple.setup(_boss_config_for_purple(), player)
	if "family_id" in purple:
		purple.family_id = family
	_boss_nodes.append(purple)
	if _boss == null:
		_boss = purple
	if not purple.died.is_connected(_on_enemy_died):
		purple.died.connect(_on_enemy_died)
	purple.died.connect(_on_purple_boss_died)
	# 紫色阵营共用一个血池：本体先记一份 max，之后每生成一个分身再加它那份
	if purple.config != null:
		# 同一家族的紫 BOSS 共用一份血：每个本体贡献一份血，分身不再加血
		var fam_max := (float(_purple_max_by_family.get(family, 0.0))
			+ float(purple.config.max_health))
		_purple_max_by_family[family] = fam_max
		_purple_hp_by_family[family] = fam_max
		_purple_shared_max = fam_max
		_purple_shared_hp = fam_max
	if purple.has_signal("clone_spawned"):
		purple.clone_spawned.connect(_on_purple_clone_spawned)
	if debug_print:
		print("[Battle] 紫色 BOSS 已放出（家族 %d）出生格=%s 共用血条 %.0f/%.0f" % [
			family, str(spawn_cell), _purple_shared_hp, _purple_shared_max])


## 紫 BOSS 分裂：分身的血量也加进共享血池的上限，这样血条不会因为分身出现而突然多一截
func _on_purple_clone_spawned(clone: Node) -> void:
	# 共用一份 HP：分身只是"多个可以被攻击的受体"，不给血条加血（用户要求）
	if is_instance_valid(clone) and debug_print:
		print("[Battle] 紫 BOSS 分身加入（共用血条仍为 %.0f/%.0f）" % [
			_purple_shared_hp, _purple_shared_max])


func _on_purple_boss_died() -> void:
	if not is_inside_tree():
		return
	if _purple_family_killing:
		return                    # 紫 BOSS 家族：金币由 _kill_purple_family 统一给
	var gain := maxi(gold_per_boss_kill, 0)
	RunState.add_gold(gain)
	_gold_gained += gain
	if debug_print:
		print("[Battle] 紫色 BOSS 阵亡 金币 +%d（合计 %d）" % [gain, RunState.gold])


## 场上所有 BOSS：原 BOSS + 紫色 BOSS 本体 + 紫色 BOSS 的分身
func _boss_nodes_all() -> Array[Node]:
	var nodes: Array[Node] = []
	for child in enemy_container.get_children():
		var node := child as Node
		if node == null:
			continue
		if node == _boss or _boss_kind_of(node) != "" or _boss_nodes.has(node):
			nodes.append(node)
	return nodes


## 还活着的 BOSS 数量（含分身）—— 归零才算过关
func _living_boss_count() -> int:
	var count := 0
	for node in _boss_nodes_all():
		if is_instance_valid(node) and not bool(node.get("is_dead")):
			count += 1
	return count


## （旧的三条家族血条已删除：改成第10层两条旧样式血条，见 _setup_boss_bar_icons / _update_time_bar）


func _boss_icon_texture(body: Node) -> Texture2D:
	if body == null:
		return null
	# 紫 BOSS / 岩浆 BOSS 用各自的精灵帧（紫=第3排，岩浆=偏红的那只）
	for path in ["AnimatedSprite2D", "AnimatedSprite", "BodySprite"]:
		var own_sprite := body.get_node_or_null(path) as AnimatedSprite2D
		if own_sprite == null or own_sprite.sprite_frames == null:
			continue
		var own_names := own_sprite.sprite_frames.get_animation_names()
		if own_names.is_empty():
			continue
		# 优先用站立/移动动画的第一帧（岩浆 BOSS 还有一套 death 动画，按名字排序会先取到死亡帧）
		var anim_name: String = own_names[0]
		for candidate in ["default", "idle", "walk", "move"]:
			if own_sprite.sprite_frames.has_animation(candidate):
				anim_name = candidate
				break
		var own_tex := own_sprite.sprite_frames.get_frame_texture(anim_name, 0)
		# 紫 BOSS / 岩浆 BOSS 用自己的精灵帧；普通 BOSS 下面统一用固定素材
		if own_tex != null and _boss_kind_of(body) != "normal":
			return own_tex
		break
	# 原 BOSS：血条图片固定用源石虫.png 第 2 排（用户指定，不用它自己的素材）
	if _boss_kind_of(body) == "normal":
		var atlas := load(BOSS_ICON_ATLAS) as Texture2D
		if atlas != null:
			var frame := AtlasTexture.new()
			frame.atlas = atlas
			frame.region = Rect2(0, NORMAL_BOSS_ICON_ROW_Y, 32, 32)
			return frame
	# 紫 BOSS：用它自己第 3 排的素材
	for path in ["AnimatedSprite2D", "AnimatedSprite", "BodySprite"]:
		var sprite := body.get_node_or_null(path) as AnimatedSprite2D
		if sprite == null or sprite.sprite_frames == null:
			continue
		var names := sprite.sprite_frames.get_animation_names()
		if names.is_empty():
			continue
		return sprite.sprite_frames.get_frame_texture(names[0], 0)
	return null


## 取"第 index 远"的红门格：多只 BOSS 时不要全挤在同一个格子上
## 紫 BOSS 出生点：优先用"离玩家最远的红门"，同一家族第二只自动错开到别的门
func _spawn_cell_for_family(from_cell: Vector2i, index: int) -> Vector2i:
	var doors: Array = arena_data.get("doors", [])
	if doors.is_empty():
		return _next_boss_spawn_cell()
	var occupied := _boss_occupied_cells()
	var player_cell: Vector2i = arena_cell_at(player.global_position)
	var min_gap := float(mini(int(arena_data["width"]), int(arena_data["height"]))) * 0.4
	var cells: Array[Vector2i] = []
	for i in range(doors.size()):
		var door: Dictionary = doors[(i + index) % doors.size()]
		var cell: Vector2i = door["cell"]
		if occupied.has(cell):
			continue                             # 已经有 BOSS 站这儿了，换下一个门
		if Vector2(cell).distance_to(Vector2(player_cell)) < min_gap:
			continue                             # 离玩家太近的门不用，免得 BOSS 刷在脸上
		cells.append(cell)
	if cells.is_empty():
		return _next_boss_spawn_cell()
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a).distance_to(Vector2(from_cell)) \
			> Vector2(b).distance_to(Vector2(from_cell)))
	return cells[0]






## 守护关：地图中心放一个不动的守护对象
func _spawn_defend_target() -> void:
	_guard_target = DefendTargetScene.instantiate()
	add_child(_guard_target)
	_guard_target.global_position = Vector2(
		float(arena_data["width"]) * float(ArenaGen.TILE_SIZE) * 0.5,
		float(arena_data["height"]) * float(ArenaGen.TILE_SIZE) * 0.5)
	if _guard_target.has_signal("health_changed"):
		_guard_target.health_changed.connect(_on_guard_health_changed)
	_setup_defend_hud()


## 守护关刷怪：开场不刷，在场上限随时间线性放开（90 秒到 30 只），
## 出怪间隔 0.5s（比上限增速快，被杀了也能补回来）
func _configure_defend_spawn() -> void:
	max_alive_enemies = 0
	spawn_interval = 0.5
	min_spawn_interval = 0.5
	initial_spawn_count = 0
	spawn_count_per_tick = 1


## 守护关：按已进行时间更新"在场敌人上限"（0 -> 30，90 秒到顶）
func _update_defend_spawn_cap() -> void:
	if goal.get("type", "") != LevelGoal.TYPE_DEFEND:
		return
	var elapsed := maxf(LevelGoal.DEFEND_DURATION - stage_time_left, 0.0)
	max_alive_enemies = _defend_alive_cap_for(elapsed)


func _defend_alive_cap_for(elapsed: float) -> int:
	return clampi(int(floor(DEFEND_MAX_ALIVE * minf(elapsed / DEFEND_RAMP_TIME, 1.0))),
		0, DEFEND_MAX_ALIVE)


## 第 5 层之后才允许出现守护关 / 持枪敌人（用户要求）
func _after_floor_5() -> bool:
	return _context_floor() > 5


## 自检用：当前刷怪池里是否含持枪敌人（按 scene_override 判断，血量缩放复制过也认）
func debug_pool_has_shooter() -> bool:
	for cfg in available_enemy_configs:
		if cfg != null and cfg.scene_override == SHOOTER_CONFIG.scene_override:
			return true
	return false


## 守护对象血量：悬停在它头顶（复用原来那块淡蓝样式的文字，不再占右侧面板）
func _setup_defend_hud() -> void:
	if _guard_target == null or not is_instance_valid(_guard_target):
		return
	var head := Label.new()
	head.name = "GuardHeadHud"
	head.z_index = 90
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", room_prompt_font_size)
	head.add_theme_color_override("font_color", Color(0.70, 0.90, 1.0))
	head.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	head.add_theme_constant_override("outline_size", 2)
	head.position = Vector2(-40.0, -40.0)
	head.size = Vector2(80.0, 18.0)
	_guard_target.add_child(head)
	_guard_hud_hp = head
	_refresh_guard_hud()


func _guard_icon_texture() -> Texture2D:
	if _guard_target == null or not is_instance_valid(_guard_target):
		return null
	var sprite := _guard_target.get_node_or_null("Sprite2D") as AnimatedSprite2D
	if sprite == null or sprite.sprite_frames == null:
		return null
	var names := sprite.sprite_frames.get_animation_names()
	if names.is_empty():
		return null
	return sprite.sprite_frames.get_frame_texture(names[0], 0)


func _refresh_guard_hud() -> void:
	if _guard_hud_hp == null or _guard_target == null or not is_instance_valid(_guard_target):
		return
	_guard_hud_hp.text = "守护对象 %d / %d" % [
		int(_guard_target.current_health), int(_guard_target.MAX_HEALTH)]


func _on_guard_health_changed(_current: int, _maximum: int) -> void:
	_refresh_guard_hud()


## 推车关：初始化房间（黑幕 / 门碰撞 / 交互 UI / 预生成标记）
func _setup_push_rooms() -> void:
	_room_states.clear()
	_room_masks.clear()
	_room_door_bodies.clear()
	_room_enemies.clear()
	_room_ever_opened.clear()
	for room in arena_data.get("rooms", []):
		var state: Dictionary = (room as Dictionary).duplicate(true)
		var locked := bool(state.get("locked", false))
		state["opened"] = not locked          # 敞开的房间一开始就是开的
		state["spawned"] = false
		state["activated"] = false
		state["interact_left"] = room_interact_seconds
		_room_states.append(state)
		_room_ever_opened.append(not locked)
		_room_enemies.append([])
	_build_room_masks()
	_build_room_door_bodies()
	_build_room_interact_ui()
	_map_room_spawn_markers()
	for i in range(_room_states.size()):
		_apply_room_state(i)
	if debug_print:
		var locked_count := 0
		for state in _room_states:
			if bool(state.get("locked", false)):
				locked_count += 1
		print("[Battle] 推车关房间 %d 个（上锁 %d 个）" % [_room_states.size(), locked_count])


## 把每个房间和它的红门出怪点（Marker2D）对上号：门关着 → 这个出怪点不刷怪
func _map_room_spawn_markers() -> void:
	_room_spawn_markers.clear()
	for _i in range(_room_states.size()):
		_room_spawn_markers.append(null)
	var doors: Array = arena_data.get("doors", [])
	var markers: Array = enemy_spawn_points_root.get_children()
	var count: int = mini(doors.size(), markers.size())
	for i in range(count):
		var door: Dictionary = doors[i]
		if not door.has("room"):
			continue
		var room_index := int(door["room"])
		if room_index >= 0 and room_index < _room_spawn_markers.size():
			_room_spawn_markers[room_index] = markers[i]


## 门开着才把这个房间的红门放进刷怪点池，关上就移出去
func _update_room_spawn_marker(index: int, opened: bool) -> void:
	if index < 0 or index >= _room_spawn_markers.size():
		return
	var marker = _room_spawn_markers[index]
	if marker == null or not is_instance_valid(marker):
		return
	var listed := enemy_spawn_points.has(marker)
	if opened and not listed:
		enemy_spawn_points.append(marker)
	elif not opened and listed:
		enemy_spawn_points.erase(marker)


## 全部房间按当前开关状态重新同步一遍出怪点
func _refresh_room_spawn_markers() -> void:
	for i in range(_room_states.size()):
		_update_room_spawn_marker(i, bool(_room_states[i]["opened"]))


## 关着的房间内部涂黑。
## 注意：必须放在"世界空间"里（Node2D + 高 z_index），
## 之前挂在 CanvasLayer 上用的是屏幕坐标，位置和大小都会错。
func _build_room_masks() -> void:
	var holder := Node2D.new()
	holder.name = "RoomMasks"
	holder.z_index = 40
	add_child(holder)
	for state in _room_states:
		var rect: Rect2i = state["rect"]
		var mask := ColorRect.new()
		mask.name = "Mask"
		mask.color = Color(0, 0, 0, 1)
		mask.position = Vector2(rect.position) * float(ArenaGen.TILE_SIZE)
		mask.size = Vector2(rect.size) * float(ArenaGen.TILE_SIZE)
		mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(mask)
		_room_masks.append(mask)


## 关着的门要挡住玩家和敌人：每个门口格一个碰撞矩形
func _build_room_door_bodies() -> void:
	for state in _room_states:
		var body := StaticBody2D.new()
		body.name = "RoomDoor"
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
		var shapes: Array[CollisionShape2D] = []
		for cell in state["door_cells"]:
			var shape := RectangleShape2D.new()
			shape.size = Vector2(ArenaGen.TILE_SIZE, ArenaGen.TILE_SIZE)
			var collider := CollisionShape2D.new()
			collider.shape = shape
			collider.position = cell_to_world(cell)
			body.add_child(collider)
			shapes.append(collider)
		_room_door_bodies.append(shapes)


## 门口的「按住 E 交互」提示（仿中间地图的头顶提示）+ 玩家头顶的时钟倒计时
func _build_room_interact_ui() -> void:
	# ① 每个房间门口一个提示，靠近才显示
	_door_prompts.clear()
	for state in _room_states:
		var prompt := Label.new()
		prompt.name = "DoorPrompt"
		prompt.z_index = 80          # 盖在黑幕（z 40）之上，不然上方开门时提示会被挡
		prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		prompt.add_theme_font_size_override("font_size", room_prompt_font_size)
		prompt.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
		prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		prompt.add_theme_constant_override("outline_size", 2)
		var cells: Array = state["door_cells"]
		var center := Vector2.ZERO
		for cell in cells:
			center += cell_to_world(cell)
		center /= float(maxi(cells.size(), 1))
		prompt.position = center + room_prompt_offset
		prompt.size = Vector2(80.0, 18.0)
		prompt.visible = false
		add_child(prompt)
		_door_prompts.append(prompt)

	# ② 时钟 + 倒计时挂在玩家头顶（跟着角色走，不和关卡目标抢位置）
	_room_clock_icon = Sprite2D.new()
	_room_clock_icon.name = "RoomClockIcon"
	_room_clock_icon.z_index = 80
	var atlas := AtlasTexture.new()
	atlas.atlas = load("res://resources/texture/道具ui.png")
	atlas.region = Rect2(0, 0, 16, 16)
	_room_clock_icon.texture = atlas
	_room_clock_icon.scale = Vector2(1.1, 1.1)
	_room_clock_icon.position = room_clock_offset
	_room_clock_icon.visible = false
	player.add_child(_room_clock_icon)

	_room_clock_label = Label.new()
	_room_clock_label.name = "RoomClockLabel"
	_room_clock_label.z_index = 80
	var font := load("res://resources/font/IPix.ttf") as Font
	if font != null:
		_room_clock_label.add_theme_font_override("font", font)
	_room_clock_label.add_theme_font_size_override("font_size", room_prompt_font_size)
	_room_clock_label.add_theme_color_override("font_color", Color(1, 0.95, 0.7, 1))
	_room_clock_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_room_clock_label.add_theme_constant_override("outline_size", 2)
	_room_clock_label.position = room_clock_text_offset
	_room_clock_label.visible = false
	player.add_child(_room_clock_label)


## 房间里的道具：直接摆在地上，玩家走过去就能拿
func _spawn_room_pickup(cell: Vector2i) -> void:
	var config = ROOM_PICKUP_CONFIGS[randi() % ROOM_PICKUP_CONFIGS.size()]
	var pickup := PickupScene.instantiate() as Pickup
	if pickup == null:
		return
	pickup.config = config
	add_child(pickup)
	pickup.global_position = cell_to_world(cell)
	# 房间里摆的道具不消失（场景默认 5 秒自毁，玩家开门前就没了）
	if pickup.lifetime_timer != null:
		pickup.lifetime_timer.stop()
		pickup.is_expiring = false


## 房间里的临时友方：外形用队友、2 血、伤害固定 2、射速按住持枪敌人；
## 带走后守在箱子附近跟着走；超过 2 名就不再老实待着（会跑出去打）
func _spawn_temp_ally(cell: Vector2i) -> void:
	var ally = AllyScene.instantiate()
	add_child(ally)
	var body := player.get_node_or_null("BodySprite") as AnimatedSprite2D
	# 第一个参数是"跟着谁"：这里传箱子，队友就不会先跑向玩家再折回来了；
	# 第二个参数仍传玩家的 BodySprite，用来共用本体动画
	var follow_node: Node2D = _push_box if (_push_box != null and is_instance_valid(_push_box)) else player
	ally.setup(follow_node, body, TEMP_ALLY_DAMAGE, TEMP_ALLY_FIRE_INTERVAL, enemy_container)
	ally.global_position = cell_to_world(cell)
	ally.fire_interval = TEMP_ALLY_FIRE_INTERVAL
	ally.current_health = TEMP_ALLY_MAX_HEALTH
	ally.set_state(ally.STATE_GUARD)
	ally.set_physics_process(false)          # 没被带走之前站着不动
	ally.died.connect(_on_temp_ally_died.bind(ally))
	_temp_ally_candidates.append(ally)
	# 头顶提示（走近才显示，和门口提示同风格）
	var prompt := Label.new()
	prompt.name = "AllyPrompt"
	prompt.text = "按 E 交谈"
	prompt.z_index = 80
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_font_size_override("font_size", room_prompt_font_size)
	prompt.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	prompt.add_theme_constant_override("outline_size", 2)
	prompt.position = (ally as Node2D).global_position + Vector2(-24.0, -34.0)
	prompt.visible = false
	add_child(prompt)
	_temp_ally_prompts.append({"ally": ally, "label": prompt})


## 临时友方阵亡：在原地生成一只持枪敌人（算普通敌人，掉金币、计击杀）
func _on_temp_ally_died(ally) -> void:
	var cell := arena_cell_at((ally as Node2D).global_position)
	_spawn_shooter_enemy_at(cell)
	if debug_print:
		print("[Battle] 临时友方阵亡，位置 %s 生成持枪敌人" % str(cell))


func _spawn_shooter_enemy_at(cell: Vector2i) -> void:
	if SHOOTER_CONFIG == null:
		return
	var scene := enemy_scene
	if SHOOTER_CONFIG.scene_override != null:
		scene = SHOOTER_CONFIG.scene_override      # 持枪敌人有自己的场景
	var enemy := scene.instantiate() as Enemy
	if enemy == null:
		return
	enemy_container.add_child(enemy)
	enemy.global_position = cell_to_world(cell)
	enemy.setup(SHOOTER_CONFIG, player)
	enemy.died.connect(_on_enemy_died)


## 临时友方交互：靠近 + 按一次交互键 -> 弹出「带走 / 不带」；再按一次确认带走
func _update_temp_ally_interaction() -> void:
	# 对话开着 / 没有待招募的队友时，把所有头顶提示都收掉（之前会残留）
	if _temp_ally_dialogue != null and _temp_ally_dialogue.is_open():
		_hide_all_temp_ally_prompts()
		return
	if _temp_ally_candidates.is_empty():
		_hide_all_temp_ally_prompts()
		return
	var nearest := -1
	var nearest_distance := INF
	for i in range(_temp_ally_candidates.size()):
		var ally = _temp_ally_candidates[i]
		if not is_instance_valid(ally) or bool(ally.is_dead):
			continue
		var distance := player.global_position.distance_to((ally as Node2D).global_position) / float(ArenaGen.TILE_SIZE)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = i
	_refresh_temp_ally_prompts(nearest if nearest_distance <= room_reach_cells else -1)
	if nearest_distance > room_reach_cells:
		return
	if Input.is_action_just_pressed("interact"):
		_temp_ally_pick = nearest
		_open_temp_ally_dialogue()


## 把所有临时队友头顶提示都藏起来
func _hide_all_temp_ally_prompts() -> void:
	for entry in _temp_ally_prompts:
		var label := entry["label"] as Label
		if label != null and is_instance_valid(label):
			label.visible = false


## 只给"最近的那名临时队友"显示头顶提示，其它的隐藏
func _refresh_temp_ally_prompts(nearest: int) -> void:
	var target = null
	if nearest >= 0 and nearest < _temp_ally_candidates.size():
		target = _temp_ally_candidates[nearest]
	for entry in _temp_ally_prompts:
		var label := entry["label"] as Label
		var ally = entry["ally"]
		if label == null or not is_instance_valid(label):
			continue
		if ally == target and is_instance_valid(ally) and not bool(ally.get("is_dead")):
			label.position = (ally as Node2D).global_position + Vector2(-24.0, -34.0)
			label.visible = true
		else:
			label.visible = false


## 弹出正式对话框：问玩家要不要带走这名临时队友（选"先不用"还能再来一次）
func _open_temp_ally_dialogue() -> void:
	if _temp_ally_dialogue == null:
		_temp_ally_dialogue = DialogueBoxScript.new()
		add_child(_temp_ally_dialogue)
		_temp_ally_dialogue.option_selected.connect(_on_temp_ally_dialogue_option)
		_temp_ally_dialogue.closed.connect(_on_temp_ally_dialogue_closed)
	if player != null and is_instance_valid(player):
		player.set_physics_process(false)          # 对话期间先别动、别开枪
	_temp_ally_dialogue.show_dialogue("临时队友",
		["要带走这名队友吗？", "带走后它会守在箱子附近；它只有 2 点生命，阵亡会引来持枪敌人。"],
		["带走", "先不用"])


func _on_temp_ally_dialogue_option(index: int) -> void:
	if index == 0 and _temp_ally_pick >= 0 and _temp_ally_pick < _temp_ally_candidates.size():
		_recruit_temp_ally(_temp_ally_pick)
	_temp_ally_pick = -1


func _on_temp_ally_dialogue_closed() -> void:
	_temp_ally_pick = -1
	if player != null and is_instance_valid(player):
		player.set_physics_process(true)


func _recruit_temp_ally(index: int) -> void:
	var ally = _temp_ally_candidates[index]
	_temp_ally_candidates.remove_at(index)
	if not is_instance_valid(ally):
		return
	ally.set_physics_process(true)
	ally.set_state(ally.STATE_GUARD)
	# 招募成功：把它头顶的提示删掉
	for entry in _temp_ally_prompts.duplicate():
		if entry["ally"] == ally:
			var old_label := entry["label"] as Label
			if old_label != null and is_instance_valid(old_label):
				old_label.queue_free()
			_temp_ally_prompts.erase(entry)
	# 活动范围：以箱子为中心的 5x5 格正方形（半径 2 格 = 32 像素）
	if _push_box != null and is_instance_valid(_push_box):
		ally.set_leash(_push_box, float(TEMP_ALLY_LEASH_CELLS) * float(ArenaGen.TILE_SIZE),
			TEMP_ALLY_RETURN_OFFSET)
	_recruited_allies.append(ally)
	_sync_box_temp_allies()
	if debug_print:
		print("[Battle] 带走临时友方，当前 %d 名" % _recruited_allies.size())


## 撤离时按"带走且仍然活着"的人数给金币
func _temp_ally_reward_gold() -> int:
	var alive := 0
	for ally in _recruited_allies:
		if is_instance_valid(ally) and not bool(ally.is_dead):
			alive += 1
	return alive * TEMP_ALLY_REWARD_GOLD


## 让被带走的临时友方把"守卫点"指向箱子（守在箱子附近跟着走）
func _update_temp_ally_follow() -> void:
	if _push_box == null or not is_instance_valid(_push_box):
		return
	for ally in _recruited_allies:
		if not is_instance_valid(ally) or bool(ally.is_dead):
			continue
	_sync_box_temp_allies()


## 把"被带走的临时友方"列表交给箱子：它们在 5x5 范围内也算在推车
func _sync_box_temp_allies() -> void:
	if _push_box == null or not is_instance_valid(_push_box):
		return
	_push_box.temp_allies = _recruited_allies


## 超过 2 名之后，多出来的临时友方会自己跑出去（开门 / 探路 / 主动打）
func _update_temp_ally_wander(delta: float) -> void:
	if _recruited_allies.size() <= TEMP_ALLY_FOLLOW_LIMIT:
		return
	_temp_ally_wander_left = maxf(_temp_ally_wander_left - delta, 0.0)
	if _temp_ally_wander_left > 0.0:
		return
	_temp_ally_wander_left = 5.0
	for idx in range(TEMP_ALLY_FOLLOW_LIMIT, _recruited_allies.size()):
		var ally = _recruited_allies[idx]
		if not is_instance_valid(ally) or bool(ally.is_dead):
			continue
		if randf() < 0.3:
			ally.set_state(ally.STATE_ATTACK)


## 把房间状态同步到画面上：门瓦片 / 门碰撞 / 黑幕
func _apply_room_state(index: int) -> void:
	var state: Dictionary = _room_states[index]
	var opened := bool(state["opened"])
	var overlay := $OverlayTileMapLayer as TileMapLayer
	for cell in state["door_cells"]:
		if opened:
			overlay.erase_cell(cell)
		else:
			overlay.set_cell(cell, ArenaGen.ROOM_DOOR_SOURCE, ArenaGen.ROOM_DOOR_TILE)
	var shapes: Array = _room_door_bodies[index]
	for collider in shapes:
		(collider as CollisionShape2D).disabled = opened
	var mask := _room_masks[index] as ColorRect
	# 门关着就把房间内部涂黑（用户要求：关上后门内渲染涂黑）
	mask.visible = not opened
	_update_room_spawn_marker(index, opened)


## 每帧：预生成附近房间的敌人 + 处理门的按住交互
func _update_push_rooms(delta: float) -> void:
	if _room_states.is_empty():
		return
	if _temp_ally_dialogue != null and _temp_ally_dialogue.is_open():
		return                                   # 队友对话开着时先不处理门
	# 房间内容改成"玩家按下交互键的那一刻"才生成（见 _tick_room_interaction）
	_tick_room_interaction(delta, Input.is_action_pressed("interact"))
	_update_temp_ally_interaction()
	_update_temp_ally_follow()
	_update_temp_ally_wander(delta)


## 按住累计开门/关门；松开或离开就清零重来
func _tick_room_interaction(delta: float, pressed: bool) -> void:
	var target := _find_room_door_target()
	_refresh_door_prompts(target)
	if target != _room_interact_target:
		_room_interact_target = target
		for state in _room_states:
			state["interact_left"] = room_interact_seconds
	if target < 0:
		_set_room_clock_visible(false)
		return
	var state: Dictionary = _room_states[target]
	if not pressed:
		state["interact_left"] = room_interact_seconds
		_room_needs_release = false         # 松开了，下次按住可以重新累计
		_set_room_clock_visible(false)
		return
	if _room_needs_release:
		# 刚开关过门但玩家还按着不放 -> 不累计，必须松手再按
		state["interact_left"] = room_interact_seconds
		_set_room_clock_visible(false)
		return
	# 玩家按下交互键的那一刻就开始生成房间内容（敌人先不活动，开门后才敌对）
	_spawn_room_content(target)
	state["interact_left"] = maxf(float(state["interact_left"]) - delta, 0.0)
	_set_room_clock_visible(true)
	if float(state["interact_left"]) <= 0.0:
		_toggle_room(target)
		state["interact_left"] = room_interact_seconds
		_room_needs_release = true          # 开/关完必须松手，避免一直按着又触发一次
		_set_room_clock_visible(false)


## 门口提示：靠近的那道门显示「按住 E 开门 / 关门」，其它隐藏
func _refresh_door_prompts(target: int) -> void:
	for i in range(_door_prompts.size()):
		var prompt := _door_prompts[i] as Label
		if prompt == null:
			continue
		if i != target:
			prompt.visible = false
			continue
		var state: Dictionary = _room_states[i]
		prompt.text = "按住 E %s" % ("关门" if bool(state["opened"]) else "开门")
		prompt.visible = true


## 找玩家脚边最近的门（超过 room_reach_cells 就返回 -1）
func _find_room_door_target() -> int:
	if player == null or not is_instance_valid(player):
		return -1
	var best := -1
	var best_distance := INF
	for i in range(_room_states.size()):
		var state: Dictionary = _room_states[i]
		for cell in state["door_cells"]:
			var door_position := cell_to_world(cell)
			var distance := player.global_position.distance_to(door_position) / float(ArenaGen.TILE_SIZE)
			if distance < best_distance:
				best_distance = distance
				best = i
	if best_distance <= room_reach_cells:
		return best
	return -1


## 开/关门
func _toggle_room(index: int) -> void:
	var state: Dictionary = _room_states[index]
	var will_open := not bool(state["opened"])
	if not will_open:
		# 关门时如果玩家正站在门瓦片上，按他相对门的位置把他挤出去
		_expel_player_from_door(state)
	state["opened"] = will_open
	_room_states[index] = state
	_apply_room_state(index)
	if will_open:
		_spawn_room_content(index)
		_activate_room_enemies(index)
	if debug_print:
		print("[Battle] 房间%d %s（内容=%s）" % [
			index, "打开" if will_open else "关上", String(state["content"])])


## 玩家按下交互键 / 开门时把房间内容摆出来（敌人先静止，门开了再激活）
func _spawn_room_content(index: int) -> void:
	var state: Dictionary = _room_states[index]
	if bool(state["spawned"]):
		return
	state["spawned"] = true
	_room_states[index] = state
	var cells := _room_spawn_cells(state)
	if cells.is_empty():
		return
	match String(state["content"]):
		"enemy":
			for i in range(int(state["enemy_count"])):
				_spawn_room_enemy(index, cells[i % cells.size()])
		"item":
			for i in range(maxi(int(state["item_count"]), 1)):
				_spawn_room_pickup(cells[(i * 2 + 1) % cells.size()])
		"ally":
			_spawn_temp_ally(cells[cells.size() / 2])


func _room_spawn_cells(state: Dictionary) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var rect: Rect2i = state["rect"]
	var door_cells: Array = state["door_cells"]
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var cell := Vector2i(x, y)
			if door_cells.has(cell):
				continue
			cells.append(cell)
	return cells


func _spawn_room_enemy(index: int, cell: Vector2i) -> void:
	var config := _pick_enemy_config()
	if config == null:
		return
	var scene := enemy_scene
	if config.scene_override != null:
		scene = config.scene_override
	var enemy := scene.instantiate() as Enemy
	if enemy == null:
		return
	enemy_container.add_child(enemy)
	enemy.global_position = cell_to_world(cell)
	enemy.setup(config, player)
	enemy.died.connect(_on_enemy_died)
	enemy.set_ai_suspended(true)          # 开门前不活动、不敌对
	enemy.modulate = Color(1, 1, 1, 1)
	(_room_enemies[index] as Array).append(enemy)


## 开门后房间里的敌人开始活动并锁定玩家
func _activate_room_enemies(index: int) -> void:
	var state: Dictionary = _room_states[index]
	if bool(state["activated"]):
		return
	state["activated"] = true
	_room_states[index] = state
	for enemy in _room_enemies[index]:
		if is_instance_valid(enemy) and not (enemy as Enemy).is_dead:
			(enemy as Enemy).set_ai_suspended(false)


## 关门时把站在门瓦片上的玩家挤到房间内或房间外
func _expel_player_from_door(state: Dictionary) -> void:
	if player == null or not is_instance_valid(player):
		return
	var door_cells: Array = state["door_cells"]
	var rect: Rect2i = state["rect"]
	var player_cell := arena_cell_at(player.global_position)
	# 关上门后房间内部会被涂黑，所以站在房间里的人也要被请出去
	var inside_room := rect.has_point(player_cell)
	if not door_cells.has(player_cell) and not inside_room:
		return
	# 判断玩家该往房间内挤还是往外挤：看门格相对房间中心的方向
	var room_center := Vector2(rect.position) + Vector2(rect.size) * 0.5
	var outward := (Vector2(player_cell) - room_center)
	var inside_target := player_cell
	var outside_target := player_cell
	if absf(outward.x) > absf(outward.y):
		var step_x := 1 if outward.x < 0.0 else -1        # 朝房间中心
		inside_target = player_cell + Vector2i(-step_x, 0)
		outside_target = player_cell + Vector2i(step_x, 0)
	else:
		var step_y := 1 if outward.y < 0.0 else -1
		inside_target = player_cell + Vector2i(0, -step_y)
		outside_target = player_cell + Vector2i(0, step_y)
	# 在房间内部时优先往外挤（否则关门后玩家会被黑幕盖住看不见）
	if inside_room and _is_walkable_cell(outside_target):
		player.global_position = cell_to_world(outside_target)
	elif _is_walkable_cell(inside_target):
		player.global_position = cell_to_world(inside_target)
	elif _is_walkable_cell(outside_target):
		player.global_position = cell_to_world(outside_target)


func _is_walkable_cell(cell: Vector2i) -> bool:
	var grid: Array = arena_data.get("grid", [])
	var w: int = int(arena_data.get("width", 0))
	var h: int = int(arena_data.get("height", 0))
	if cell.x < 0 or cell.y < 0 or cell.x >= w or cell.y >= h:
		return false
	if grid.is_empty():
		return false
	return int(grid[cell.y * w + cell.x]) == ArenaGen.CELL_FLOOR


func arena_cell_at(world_position: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_position.x / float(ArenaGen.TILE_SIZE))),
		int(floor(world_position.y / float(ArenaGen.TILE_SIZE))))


## 玩家头顶的时钟 + 倒计时（跟着角色走）
func _set_room_clock_visible(visible_now: bool) -> void:
	if _room_clock_icon == null or _room_clock_label == null:
		return
	_room_clock_icon.visible = visible_now
	_room_clock_label.visible = visible_now
	if not visible_now:
		return
	if _room_interact_target < 0 or _room_interact_target >= _room_states.size():
		return
	var state: Dictionary = _room_states[_room_interact_target]
	_room_clock_label.text = "%.1fS" % maxf(float(state["interact_left"]), 0.0)
	# 门在角色上方就让倒计时跑到角色下方，反之亦然（跟着遮挡自动换边）
	var door_center := Vector2.ZERO
	var door_cells: Array = state["door_cells"]
	for cell in door_cells:
		door_center += cell_to_world(cell)
	door_center /= float(maxi(door_cells.size(), 1))
	var door_above := door_center.y < player.global_position.y - 4.0
	_room_clock_icon.position = room_clock_offset_below if door_above else room_clock_offset
	_room_clock_label.position = room_clock_text_offset_below if door_above else room_clock_text_offset


## 推车关限时按警戒线长度自动算：格数 x 每格 2 秒 x 1.4 余量，最少 180 秒
func _apply_push_time_limit() -> void:
	var cells := maxi((arena_data.get("push_path", []) as Array).size() - 1, 1)
	var limit := maxf(LevelGoal.PUSH_DURATION_MIN, float(cells) * 2.0 * 1.4)
	goal["time_limit"] = limit
	stage_duration = limit
	stage_time_left = limit
	if debug_print:
		print("[Battle] 推车关限时 %.0f 秒（警戒线 %d 格）" % [limit, cells])


## 推车关：把箱子放到起点 3x3，沿警戒线走
func _spawn_push_box() -> void:
	var path_cells: Array = arena_data.get("push_path", [])
	if path_cells.size() < 2:
		return
	var cells: Array[Vector2i] = []
	for cell in path_cells:
		cells.append(cell)
	_push_box = PushBoxScene.instantiate()
	add_child(_push_box)
	_push_box.setup(cells, player, enemy_container)
	# 临时友方推车的范围和它们闲逛的范围保持一致
	_push_box.ally_near_cells = TEMP_ALLY_LEASH_CELLS
	_push_box.arrived.connect(_on_push_box_arrived)
	_push_box.status_changed.connect(_on_push_box_status_changed)
	_push_arrived = false
	if debug_print:
		print("[Battle] 推车关: 警戒线 %d 格，箱子已在起点 %s" % [cells.size(), str(cells[0])])


func _on_push_box_arrived() -> void:
	_push_arrived = true
	if debug_print:
		print("[Battle] 箱子抵达终点，目标达成")


func _on_push_box_status_changed(new_status: String) -> void:
	if debug_print:
		print("[Battle] 箱子状态 -> %s（进度 %d/%d）" % [
			new_status, int(_push_box.moved_cells()), int(_push_box.total_cells())])


## 岩浆地面：玩家和敌人都会被烧。计时只看"是否站在岩浆上"，跨不同岩浆瓦片继续累计 ——
## 从 A 格岩浆走到相邻的 B 格岩浆不会重新从 0 开始，只有真正离开岩浆才清零（用户要求）。
func _update_lava_damage(delta: float) -> void:
	_update_player_lava(delta)
	_update_enemy_lava(delta)
	_update_ally_lava(delta)


func _update_player_lava(delta: float) -> void:
	if player == null or not is_instance_valid(player) or player.is_dead:
		_lava_stand_time = 0.0
		return
	if not is_lava_at(player.global_position):
		_lava_stand_time = 0.0
		return
	_lava_stand_time += delta
	if _lava_stand_time < maxf(lava_damage_interval, 0.05):
		return
	# 正处在受伤无敌帧里就先攒着，无敌一结束立刻结算，不会白扣一次
	if not player.apply_damage(lava_damage):
		return
	_lava_stand_time = 0.0
	if debug_print:
		print("[Battle] 岩浆灼烧玩家 -%d 血量，剩余 %d/%d" % [
			lava_damage, player.current_health, player.max_health])


## 队友（雇来的 + 临时友方）踩岩浆同样掉血：每个队友各算一份计时
func _update_ally_lava(delta: float) -> void:
	var alive_ids := {}
	for node in get_tree().get_nodes_in_group("ally"):
		if not (node is Node2D) or not is_instance_valid(node):
			continue
		if bool(node.get("is_dead")):
			continue
		var ally_id: int = node.get_instance_id()
		alive_ids[ally_id] = true
		if not is_lava_at((node as Node2D).global_position):
			_ally_lava_time.erase(ally_id)
			continue
		var stood := float(_ally_lava_time.get(ally_id, 0.0)) + delta
		if stood < maxf(lava_damage_interval, 0.05):
			_ally_lava_time[ally_id] = stood
			continue
		var applied: bool = bool(node.call("apply_damage", lava_damage)) if node.has_method("apply_damage") else false
		_ally_lava_time[ally_id] = 0.0 if applied else stood
	for ally_id in _ally_lava_time.keys():
		if not alive_ids.has(ally_id):
			_ally_lava_time.erase(ally_id)


## 敌人（含 BOSS / 紫 BOSS）踩岩浆同样掉血：每只敌人各算一份计时
func _update_enemy_lava(delta: float) -> void:
	if enemy_container == null:
		return
	var alive_ids := {}
	for child in enemy_container.get_children():
		if not (child is Enemy):
			continue
		var enemy: Enemy = child
		if not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var id := enemy.get_instance_id()
		alive_ids[id] = true
		# 自爆敌人整体免疫岩浆地板伤害（它们本来就在岩浆里活动）
		if enemy.is_lava_immune():
			_enemy_lava_time.erase(id)
			continue
		# 刚由岩浆 BOSS 从岩浆里放出来的自爆兵，先给它 1 秒免疫（否则冒头就被烧死）
		if enemy.has_meta("lava_immune_left"):
			var immune_left := float(enemy.get_meta("lava_immune_left")) - delta
			enemy.set_meta("lava_immune_left", immune_left)
			if immune_left > 0.0:
				_enemy_lava_time.erase(id)
				continue
			enemy.remove_meta("lava_immune_left")
		if not is_lava_at(enemy.global_position):
			_enemy_lava_time.erase(id)
			continue
		var stood := float(_enemy_lava_time.get(id, 0.0)) + delta
		if stood < maxf(lava_enemy_damage_interval, 0.05):
			_enemy_lava_time[id] = stood
			continue
		# 打不动（锁血/无敌）就先攒着，等能掉了立刻结算
		_enemy_lava_time[id] = 0.0 if enemy.apply_damage(lava_enemy_damage) else stood
	# 清理已经死亡/离场的敌人
	for id in _enemy_lava_time.keys():
		if not alive_ids.has(id):
			_enemy_lava_time.erase(id)


## 世界坐标是否落在岩浆瓦片上（直接问地面图层，最可靠）
func is_lava_at(world_position: Vector2) -> bool:
	var ground := $GroundTileMapLayer as TileMapLayer
	if ground == null:
		return false
	return is_lava_cell(ground.local_to_map(ground.to_local(world_position)))


func is_lava_cell(cell: Vector2i) -> bool:
	var ground := $GroundTileMapLayer as TileMapLayer
	if ground == null:
		return false
	if ground.get_cell_source_id(cell) != ArenaGen.GROUND_SOURCE:
		return false
	return ground.get_cell_atlas_coords(cell) == ArenaGen.TILE_FLOOR_LAVA


## 兜底空气墙：按当前关卡尺寸在地图外侧围一圈不可见碰撞体
## 背景：红门那格会被挖成地板，若门后没有墙体瓦片，玩家能顺红门跑出地图
func _setup_arena_bounds() -> void:
	var tile := float(ArenaGen.TILE_SIZE)
	var width := float(arena_data["width"]) * tile
	var height := float(arena_data["height"]) * tile
	var body := StaticBody2D.new()
	body.name = "ArenaBounds"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var thickness := 16.0
	_add_bound_shape(body, Vector2(width * 0.5, -thickness * 0.5), Vector2(width + thickness * 2.0, thickness))
	_add_bound_shape(body, Vector2(width * 0.5, height + thickness * 0.5), Vector2(width + thickness * 2.0, thickness))
	_add_bound_shape(body, Vector2(-thickness * 0.5, height * 0.5), Vector2(thickness, height + thickness * 2.0))
	_add_bound_shape(body, Vector2(width + thickness * 0.5, height * 0.5), Vector2(thickness, height + thickness * 2.0))
	if debug_print:
		print("[Battle] 兜底空气墙已就位: 地图 %dx%d 格（%dx%d px）" % [int(arena_data["width"]), int(arena_data["height"]), int(width), int(height)])


func _add_bound_shape(body: StaticBody2D, center: Vector2, size: Vector2) -> void:
	var shape := RectangleShape2D.new()
	shape.size = size
	var collider := CollisionShape2D.new()
	collider.shape = shape
	collider.position = center
	body.add_child(collider)


# ============================ 迷宫关运行时 ============================

@export_group("迷宫关")
## 多少秒后开始给指引 + 开始岩浆化
@export var maze_guide_seconds: float = 60.0
## 多少秒后除指引线以外全部变成岩浆
@export var maze_lava_seconds: float = 120.0

var _maze_elapsed: float = 0.0
var _maze_exited: bool = false
var _maze_exit_cells: Array[Vector2i] = []
var _maze_guide_cells: Array[Vector2i] = []
var _maze_lava_order: Array[Vector2i] = []
var _maze_lava_index: int = 0
var _maze_guide_done: bool = false
var _maze_exit_marker: Sprite2D = null      ## 出口上漂浮发光的箱子
var _maze_marker_time: float = 0.0


## 迷宫关：60 秒画出玩家->出口的最短路径（警戒地板），
## 60~120 秒把其它地板从离玩家最远处开始一格格变成岩浆，120 秒全烧完。
func _setup_maze() -> void:
	_maze_elapsed = 0.0
	_maze_exited = false
	_maze_guide_done = false
	_maze_lava_index = 0
	_maze_guide_cells.clear()
	_maze_lava_order.clear()
	_maze_exit_cells.clear()
	for cell in arena_data.get("maze_exit_cells", []):
		_maze_exit_cells.append(cell)
	_spawn_maze_exit_marker()
	if debug_print:
		print("[Battle] 迷宫关: 出口 %d 格，怪物待刷（等敌人配置就绪）" % _maze_exit_cells.size())


## 真正把迷宫里的怪物摆出来。
## 必须等 _collect_enemy_configs() 跑完之后再调用，否则敌人配置还是空的，一只都刷不出来。
func _spawn_maze_enemies() -> void:
	var spawn_points: Array = arena_data.get("spawns", [])
	if spawn_points.is_empty() or available_enemy_configs.is_empty():
		return
	var spawned := 0
	for spawn_cell in spawn_points:
		var config := _pick_enemy_config()
		if config == null:
			break
		var scene := enemy_scene
		if config.scene_override != null:
			scene = config.scene_override
		var enemy := scene.instantiate() as Enemy
		if enemy == null:
			continue
		enemy_container.add_child(enemy)
		enemy.global_position = cell_to_world(spawn_cell)
		enemy.setup(config, player)
		enemy.vision_mode = true          # 迷宫关：视野被墙挡住就看不见玩家
		enemy.directional_damage_enabled = true   # 迷宫关：正面减伤 / 背面加伤
		enemy.died.connect(_on_enemy_died)
		spawned += 1
	if debug_print:
		print("[Battle] 迷宫关: 摆出怪物 %d 只（可用配置 %d 种）" % [spawned, available_enemy_configs.size()])


## 出口上放一个漂浮发光的箱子，玩家一眼就能认出出口在哪
func _spawn_maze_exit_marker() -> void:
	if _maze_exit_cells.is_empty():
		return
	var center := Vector2.ZERO
	for cell in _maze_exit_cells:
		center += cell_to_world(cell)
	center /= float(_maze_exit_cells.size())
	_maze_exit_marker = Sprite2D.new()
	_maze_exit_marker.name = "MazeExitMarker"
	_maze_exit_marker.texture = load("res://resources/texture/瓦片.png")
	_maze_exit_marker.region_enabled = true
	_maze_exit_marker.region_rect = Rect2(32, 48, 16, 16)      # 箱子那格图块
	_maze_exit_marker.scale = Vector2(1.8, 1.8)
	_maze_exit_marker.z_index = 30
	_maze_exit_marker.position = center
	add_child(_maze_exit_marker)
	_maze_marker_time = 0.0


func _update_maze(delta: float) -> void:
	_maze_elapsed += delta
	# 出口箱子上下漂浮 + 发光呼吸
	if _maze_exit_marker != null and is_instance_valid(_maze_exit_marker):
		_maze_marker_time += delta
		_maze_exit_marker.position.y += sin(_maze_marker_time * 2.4) * 6.0 * delta
		var glow := 0.75 + 0.25 * sin(_maze_marker_time * 3.6)
		_maze_exit_marker.modulate = Color(1.0, 0.95 + 0.05 * glow, 0.55 + 0.3 * glow, 1.0)
	if not _maze_exited and player != null and is_instance_valid(player):
		var player_cell := arena_cell_at(player.global_position)
		if _maze_exit_cells.has(player_cell):
			_maze_exited = true
			if debug_print:
				print("[Battle] 走出迷宫，用时 %.1f 秒" % _maze_elapsed)
	if not _maze_guide_done and _maze_elapsed >= maze_guide_seconds:
		_draw_maze_guide()
		_maze_guide_done = true
	if _maze_guide_done:
		var span := maxf(maze_lava_seconds - maze_guide_seconds, 1.0)
		var ratio := clampf((_maze_elapsed - maze_guide_seconds) / span, 0.0, 1.0)
		var target := int(round(ratio * float(_maze_lava_order.size())))
		while _maze_lava_index < target and _maze_lava_index < _maze_lava_order.size():
			var cell: Vector2i = _maze_lava_order[_maze_lava_index]
			_maze_lava_index += 1
			_set_ground_tile(cell, ArenaGen.TILE_FLOOR_LAVA)


## 从玩家到出口算一次最短路径，铺成警戒地板；同时准备好岩浆化的顺序
func _draw_maze_guide() -> void:
	if player == null or not is_instance_valid(player) or _maze_exit_cells.is_empty():
		return
	var w: int = int(arena_data["width"])
	var h: int = int(arena_data["height"])
	var grid: Array = arena_data["grid"]
	var start := arena_cell_at(player.global_position)
	if not _is_walkable_cell(start):
		return
	var dist := {}
	var queue: Array[Vector2i] = []
	for cell in _maze_exit_cells:
		dist[cell] = 0
		queue.append(cell)
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = cell + dir
			if next.x < 0 or next.y < 0 or next.x >= w or next.y >= h:
				continue
			if dist.has(next) or int(grid[next.y * w + next.x]) != ArenaGen.CELL_FLOOR:
				continue
			dist[next] = int(dist[cell]) + 1
			queue.append(next)
	if not dist.has(start):
		return
	var walk := start
	var guard_order: Array[Vector2i] = []
	for _step in range(int(dist[start]) + 1):
		guard_order.append(walk)
		_set_ground_tile(walk, ArenaGen.TILE_FLOOR_GUARD)
		var best := int(dist[walk])
		var next_cell := walk
		for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var probe: Vector2i = walk + dir
			if dist.has(probe) and int(dist[probe]) == best - 1:
				next_cell = probe
				break
		if next_cell == walk:
			break
		walk = next_cell
	_maze_guide_cells = guard_order
	var lava_list: Array[Vector2i] = []
	var guard_lookup := {}
	for cell in _maze_guide_cells:
		guard_lookup[cell] = true
	for y in range(h):
		for x in range(w):
			var cell2 := Vector2i(x, y)
			if int(grid[y * w + x]) != ArenaGen.CELL_FLOOR or guard_lookup.has(cell2):
				continue
			lava_list.append(cell2)
	lava_list.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a).distance_to(Vector2(start)) > Vector2(b).distance_to(Vector2(start)))
	_maze_lava_order = lava_list
	_maze_lava_index = 0
	if debug_print:
		print("[Battle] 迷宫指引线 %d 格，待岩浆化 %d 格" % [_maze_guide_cells.size(), lava_list.size()])


## 直接改地面图层的某个格子（实时画警戒线 / 铺岩浆）
func _set_ground_tile(cell: Vector2i, tile: Vector2i) -> void:
	var ground := $GroundTileMapLayer as TileMapLayer
	if ground == null:
		return
	ground.set_cell(cell, ArenaGen.GROUND_SOURCE, tile)


# ============================ 守护关：建造模式 ============================

@export_group("守护关建造模式")
## 建造模式给玩家的箱子数量（能挡路，会干扰敌人寻路）
@export var build_box_count: int = 15
## 建造模式给玩家的岩浆地面数量（陷阱道具，允许用来堵路）
@export var build_lava_count: int = 4

var _build_mode: bool = false
var _defend_started: bool = false
var _build_cursor: Vector2i = Vector2i(-1, -1)
var _build_selected: int = 0
var _build_ghost: Sprite2D = null
var _build_hud: CanvasLayer = null
var _build_rows: Array = []
var _build_box_left: int = 0
var _build_lava_left: int = 0
var _build_placed: Array = []
var _build_toast: Label = null
var _build_toast_left: float = 0.0
var _build_hold_time: float = 0.0
var _guard_dialogue = null
var _build_hint: Label = null
var _guard_prompt: Label = null
var _build_frame: Node2D = null
## 正常模式 / 建造模式下的操作提示
const BUILD_HINT_NORMAL := "按 F 切换为建造模式，或与守护对象对话开始战斗"
const BUILD_HINT_BUILD := "WASD 移动光标   方向键/1 2 切换材料   E 放置   Q 拆除   按 F 返回"


## 进入守护关：先进入建造模式（不刷怪、不计时）
func _setup_defend_build() -> void:
	_defend_started = false
	_build_box_left = build_box_count
	_build_lava_left = build_lava_count
	_build_selected = 0
	_build_placed.clear()
	_build_cursor = arena_cell_at(player.global_position)
	_build_ghost = Sprite2D.new()
	_build_ghost.name = "BuildGhost"
	_build_ghost.texture = load("res://resources/texture/瓦片.png")
	_build_ghost.region_enabled = true
	_build_ghost.scale = Vector2(1.0, 1.0)
	_build_ghost.z_index = 70
	_build_ghost.visible = false
	add_child(_build_ghost)
	_build_cursor_frame()
	_build_hud = CanvasLayer.new()
	_build_hud.name = "BuildHud"
	_build_hud.layer = 7
	add_child(_build_hud)
	var box := VBoxContainer.new()
	box.position = Vector2(16.0, 120.0)
	box.add_theme_constant_override("separation", 6)
	_build_hud.add_child(box)
	_build_rows.clear()
	for i in range(2):
		var row := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.05, 0.08, 0.12, 0.75)
		style.border_color = Color(0.55, 0.80, 1.0, 0.95)
		style.set_border_width_all(2)
		style.set_content_margin_all(6)
		row.add_theme_stylebox_override("panel", style)
		box.add_child(row)
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		row.add_child(hbox)
		var num := Label.new()
		num.text = "%d" % (i + 1)
		num.add_theme_font_size_override("font_size", 18)
		num.add_theme_color_override("font_color", Color(1, 0.95, 0.7))
		hbox.add_child(num)
		var icon := TextureRect.new()
		icon.texture = _build_icon_texture(i)
		icon.custom_minimum_size = Vector2(28, 28)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		hbox.add_child(icon)
		var count_label := Label.new()
		count_label.add_theme_font_size_override("font_size", 18)
		count_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
		hbox.add_child(count_label)
		_build_rows.append({"panel": row, "count": count_label, "style": style})
	# 顶部提示（白框 + 淡黑底）
	_build_toast = Label.new()
	_build_toast.name = "BuildToast"
	_build_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_build_toast.add_theme_font_size_override("font_size", 22)
	_build_toast.add_theme_color_override("font_color", Color(1, 1, 1))
	_build_toast.add_theme_stylebox_override("normal", _build_toast_style())
	_build_toast.position = Vector2(240.0, 32.0)
	_build_toast.size = Vector2(320.0, 44.0)
	_build_toast.visible = false
	_build_hud.add_child(_build_toast)
	_refresh_build_hud()
	_set_build_mode(false)                 # 进关先是正常模式，按 F 才进建造模式
	# 守护对象头顶的「按 E 交谈」提示（走近才显示）
	if _guard_target != null and is_instance_valid(_guard_target):
		var guard_prompt := Label.new()
		guard_prompt.name = "GuardPrompt"
		guard_prompt.text = "按 E 交谈"
		guard_prompt.z_index = 90
		guard_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		guard_prompt.add_theme_font_size_override("font_size", room_prompt_font_size)
		guard_prompt.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
		guard_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		guard_prompt.add_theme_constant_override("outline_size", 2)
		guard_prompt.position = Vector2(-28.0, -54.0)
		guard_prompt.visible = false
		_guard_target.add_child(guard_prompt)
		_guard_prompt = guard_prompt
	_build_hud.visible = false
	# 模式提示：贴在「目标：」那一行正上方，蓝色字
	var goal_layer := get_node_or_null("GoalHUD") as CanvasLayer
	if goal_layer == null:
		goal_layer = get_node_or_null("BattleHud") as CanvasLayer
	_build_hint = _make_bottom_label(-62, 16, Color(0.55, 0.80, 1.0))
	_build_hint.name = "BuildHint"
	_build_hint.text = BUILD_HINT_NORMAL
	if goal_layer != null:
		goal_layer.add_child(_build_hint)
	# 守护对象为中心的九宫格铺成警戒地面（标示出要守的区域）
	if _guard_target != null and is_instance_valid(_guard_target):
		var center := arena_cell_at(_guard_target.global_position)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var cell := center + Vector2i(int(dx), int(dy))
				if cell.x > 0 and cell.y > 0 and cell.x < int(arena_data["width"]) - 1 						and cell.y < int(arena_data["height"]) - 1:
					_set_ground_tile(cell, ArenaGen.TILE_FLOOR_GUARD)


func _build_toast_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.border_color = Color(1, 1, 1, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	return style


func _build_icon_texture(index: int) -> Texture2D:
	var atlas := AtlasTexture.new()
	atlas.atlas = load("res://resources/texture/瓦片.png")
	atlas.region = Rect2(32, 48, 16, 16) if index == 0 else Rect2(32, 32, 16, 16)
	return atlas


func _refresh_build_hud() -> void:
	for i in range(_build_rows.size()):
		var row: Dictionary = _build_rows[i]
		var count_label := row["count"] as Label
		count_label.text = "x%d" % (_build_box_left if i == 0 else _build_lava_left)
		var style := (row["style"] as StyleBoxFlat).duplicate()
		style.border_color = Color(1.0, 0.9, 0.4, 0.95) if i == _build_selected else Color(0.55, 0.80, 1.0, 0.95)
		(row["panel"] as PanelContainer).add_theme_stylebox_override("panel", style)
		row["style"] = style
	if _build_ghost != null:
		_build_ghost.region_rect = Rect2(32, 48, 16, 16) if _build_selected == 0 else Rect2(32, 32, 16, 16)


func _set_build_mode(enabled: bool) -> void:
	if _defend_started and enabled:
		return                                # 正式开始后不能再造
	# 进建造模式：光标一定从玩家当前位置开始（不管上次退到哪）
	if enabled and player != null and is_instance_valid(player):
		_build_cursor = arena_cell_at(player.global_position)
	_build_mode = enabled
	if player != null and is_instance_valid(player):
		player.visible = not enabled
		player.set_physics_process(not enabled)
		player.damage_immune = enabled          # 建造模式下玩家完全免疫伤害
	if _build_ghost != null:
		_build_ghost.visible = enabled
	if _build_frame != null:
		_build_frame.visible = enabled
	if _build_hint != null:
		_build_hint.text = BUILD_HINT_BUILD if enabled else BUILD_HINT_NORMAL
	if _build_hud != null:
		_build_hud.visible = enabled
	if not enabled and player != null and is_instance_valid(player):
		# 退出建造模式：把玩家放到光标格；若那格站不了（墙里/有箱子）就自动挪到最近的空地
		var spot := _find_standable_cell(_build_cursor)
		if spot != Vector2i(-1, -1):
			player.global_position = cell_to_world(spot)
			_build_cursor = spot
		if _build_frame != null:
			_build_frame.visible = false
	if debug_print:
		print("[Battle] 建造模式 %s" % ("开启" if enabled else "关闭"))


func _update_defend_build(delta: float) -> void:
	if _build_toast_left > 0.0:
		_build_toast_left = maxf(_build_toast_left - delta, 0.0)
		if _build_toast_left <= 0.0 and _build_toast != null:
			_build_toast.visible = false
	if Input.is_action_just_pressed("build_mode"):
		_set_build_mode(not _build_mode)
		return
	if _guard_dialogue != null and _guard_dialogue.is_open():
		return                                   # 对话里的按键由 _unhandled_input 转发
	if not _build_mode:
		_update_guard_prompt()
		_try_guard_dialogue()
		return
	# 光标位置
	if _build_cursor == Vector2i(-1, -1):
		_build_cursor = arena_cell_at(player.global_position)
	var move := Vector2i.ZERO
	if Input.is_action_pressed("move_left"):
		move = Vector2i.LEFT
	elif Input.is_action_pressed("move_right"):
		move = Vector2i.RIGHT
	elif Input.is_action_pressed("move_up"):
		move = Vector2i.UP
	elif Input.is_action_pressed("move_down"):
		move = Vector2i.DOWN
	if move == Vector2i.ZERO:
		_build_hold_time = 0.0
	elif Input.is_action_just_pressed("move_left") or Input.is_action_just_pressed("move_right") \
			or Input.is_action_just_pressed("move_up") or Input.is_action_just_pressed("move_down"):
		_build_cursor += move
		_build_hold_time = 0.0
	else:
		_build_hold_time += delta
		if _build_hold_time >= 0.14:
			_build_hold_time = 0.0
			_build_cursor += move
	_build_cursor.x = clampi(_build_cursor.x, 1, int(arena_data["width"]) - 2)
	_build_cursor.y = clampi(_build_cursor.y, 1, int(arena_data["height"]) - 2)
	if _build_ghost != null:
		_build_ghost.position = cell_to_world(_build_cursor)
	if _build_frame != null:
		_build_frame.position = cell_to_world(_build_cursor)
	if player != null and is_instance_valid(player):
		# 摄像机是跟玩家节点的，所以建造模式下把隐藏的玩家挪到光标处，镜头就会跟着走
		player.global_position = cell_to_world(_build_cursor)
	# 切换材料：方向键 / 数字键
	if Input.is_action_just_pressed("shoot_up") or Input.is_action_just_pressed("shoot_left"):
		_build_selected = wrapi(_build_selected - 1, 0, 2)
		_refresh_build_hud()
	elif Input.is_action_just_pressed("shoot_down") or Input.is_action_just_pressed("shoot_right"):
		_build_selected = wrapi(_build_selected + 1, 0, 2)
		_refresh_build_hud()
	if Input.is_physical_key_pressed(KEY_1):
		_build_selected = 0
		_refresh_build_hud()
	elif Input.is_physical_key_pressed(KEY_2):
		_build_selected = 1
		_refresh_build_hud()
	if Input.is_action_just_pressed("interact"):
		_build_place()
	if Input.is_physical_key_pressed(KEY_Q):
		_build_remove()


## 放置当前选中的方块
func _build_place() -> void:
	var cell := _build_cursor
	if not _is_buildable_cell(cell):
		_build_toast_msg("这里不能放置")
		return
	if not _find_placed_at(cell).is_empty():
		_build_toast_msg("这格已经有东西了")
		return
	if _build_selected == 0:
		if _build_box_left <= 0:
			_build_toast_msg("箱子用完了")
			return
		# 箱子不能把路堵死
		if not _box_keeps_path_open(cell):
			_build_toast_msg("不能堵死道路")
			_flash_blocked_region(cell)
			return
		_build_box_left -= 1
		var body := StaticBody2D.new()
		body.name = "BuildBox"
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(16.0, 16.0)
		shape.shape = rect
		body.add_child(shape)
		var sprite := Sprite2D.new()
		sprite.texture = load("res://resources/texture/瓦片.png")
		sprite.region_enabled = true
		sprite.region_rect = Rect2(32, 48, 16, 16)
		body.add_child(sprite)
		add_child(body)
		body.global_position = cell_to_world(cell)
		_build_placed.append({"type": "box", "cell": cell, "node": body})
		# 把这一格标成实心，敌人寻路才会绕开它
		var pf = EnemyPathfinder.instance
		if pf != null:
			pf.mark_blocked(cell)
	else:
		if _build_lava_left <= 0:
			_build_toast_msg("岩浆用完了")
			return
		if _is_next_to_guard(cell):
			_build_toast_msg("岩浆不能贴着守护对象")
			return
		_build_lava_left -= 1
		_set_ground_tile(cell, ArenaGen.TILE_FLOOR_LAVA)
		_build_placed.append({"type": "lava", "cell": cell, "node": null})
	_refresh_build_hud()


## 拆掉光标所在格的方块，材料返还
func _build_remove() -> void:
	var entry: Dictionary = _find_placed_at(_build_cursor)
	if entry.is_empty():
		return
	var node = entry["node"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	if String(entry["type"]) == "box":
		_build_box_left += 1
		var pf2 = EnemyPathfinder.instance
		if pf2 != null:
			pf2.unmark_blocked(_build_cursor)
	else:
		_build_lava_left += 1
		_set_ground_tile(_build_cursor, ArenaGen.TILE_FLOOR_PLAIN)
	_build_placed.erase(entry)
	_refresh_build_hud()


func _find_placed_at(cell: Vector2i) -> Dictionary:
	for entry in _build_placed:
		if (entry["cell"] as Vector2i) == cell:
			return entry
	return {}


## 能不能在这个格放东西（通用禁止项）
func _is_buildable_cell(cell: Vector2i) -> bool:
	var w: int = int(arena_data["width"])
	var h: int = int(arena_data["height"])
	if cell.x <= 0 or cell.y <= 0 or cell.x >= w - 1 or cell.y >= h - 1:
		return false                              # 最外圈墙
	var grid: Array = arena_data["grid"]
	if int(grid[cell.y * w + cell.x]) != ArenaGen.CELL_FLOOR:
		return false
	for door in arena_data.get("doors", []):
		var door_cell: Vector2i = door["cell"]
		if door_cell == cell or door_cell + Vector2i(0, 1) == cell:
			return false                          # 红门格
	var spawn_cell: Vector2i = arena_data.get("player_spawn", Vector2i(-1, -1))
	if cell == spawn_cell:
		return false                              # 玩家出生格
	if _guard_target != null and is_instance_valid(_guard_target):
		if arena_cell_at(_guard_target.global_position) == cell:
			return false                          # 守护对象格
	return true


func _is_next_to_guard(cell: Vector2i) -> bool:
	if _guard_target == null or not is_instance_valid(_guard_target):
		return false
	var guard_cell := arena_cell_at(_guard_target.global_position)
	return absi(guard_cell.x - cell.x) <= 1 and absi(guard_cell.y - cell.y) <= 1


## 放一个箱子之后，守护对象是不是还连得到至少一个红门
func _box_keeps_path_open(cell: Vector2i) -> bool:
	var w: int = int(arena_data["width"])
	var h: int = int(arena_data["height"])
	var grid: Array = arena_data["grid"]
	var blocked := {}
	blocked[cell] = true
	for entry in _build_placed:
		if String(entry["type"]) == "box":
			blocked[entry["cell"]] = true
	if _guard_target == null or not is_instance_valid(_guard_target):
		return true
	var start := arena_cell_at(_guard_target.global_position)
	var door_cells := {}
	for door in arena_data.get("doors", []):
		door_cells[door["cell"]] = true
	var visited := {start: true}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		if door_cells.has(cur):
			return true
		for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = cur + dir
			if next.x <= 0 or next.y <= 0 or next.x >= w - 1 or next.y >= h - 1:
				continue
			if visited.has(next) or blocked.has(next):
				continue
			if int(grid[next.y * w + next.x]) != ArenaGen.CELL_FLOOR:
				continue
			visited[next] = true
			queue.append(next)
	return false


## 把会被封死的区域用警戒地面闪一下，告诉玩家不能放
func _flash_blocked_region(cell: Vector2i) -> void:
	var w: int = int(arena_data["width"])
	var h: int = int(arena_data["height"])
	var grid: Array = arena_data["grid"]
	var blocked := {cell: true}
	for entry in _build_placed:
		if String(entry["type"]) == "box":
			blocked[entry["cell"]] = true
	if _guard_target == null or not is_instance_valid(_guard_target):
		return
	var start := arena_cell_at(_guard_target.global_position)
	var visited := {start: true}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = cur + dir
			if next.x <= 0 or next.y <= 0 or next.x >= w - 1 or next.y >= h - 1:
				continue
			if visited.has(next) or blocked.has(next):
				continue
			if int(grid[next.y * w + next.x]) != ArenaGen.CELL_FLOOR:
				continue
			visited[next] = true
			queue.append(next)
	for c in visited.keys():
		_set_ground_tile(c, ArenaGen.TILE_FLOOR_GUARD)
	await get_tree().create_timer(1.5).timeout
	for c in visited.keys():
		if _find_placed_at(c).is_empty():
			_set_ground_tile(c, ArenaGen.TILE_FLOOR_PLAIN)


func _build_toast_msg(text: String) -> void:
	if _build_toast == null:
		return
	_build_toast.text = text
	_build_toast.visible = true
	_build_toast.position = Vector2(get_viewport().get_visible_rect().size.x * 0.5 - 160.0, 32.0)
	_build_toast_left = 1.6


## 守护对象头顶提示：走近且还没开战时显示
func _update_guard_prompt() -> void:
	if _guard_prompt == null or not is_instance_valid(_guard_prompt):
		return
	if _defend_started or _guard_target == null or not is_instance_valid(_guard_target):
		_guard_prompt.visible = false
		return
	var distance := player.global_position.distance_to(_guard_target.global_position) / float(ArenaGen.TILE_SIZE)
	_guard_prompt.visible = distance <= 2.0


## 和守护对象对话：选「开始关卡」才正式开局
## 守护对象对话框的按键：事件驱动转发给对话框（以前是每帧轮询 Input，偶尔会漏按键）
func _unhandled_input(event: InputEvent) -> void:
	if _guard_dialogue == null or not is_instance_valid(_guard_dialogue):
		return
	if not _guard_dialogue.is_open():
		return
	if _guard_dialogue.handle_input_event(event):
		var viewport := get_viewport()
		if viewport != null:
			viewport.set_input_as_handled()


## 建好守护对象的对话框（懒加载，只建一次）
func _ensure_guard_dialogue() -> void:
	if _guard_dialogue != null:
		return
	_guard_dialogue = DialogueBoxScript.new()
	add_child(_guard_dialogue)
	_guard_dialogue.option_selected.connect(_on_guard_dialogue_option)
	_guard_dialogue.closed.connect(_on_guard_dialogue_closed)
	_guard_dialogue.set_process_unhandled_input(false)   # 输入由 battle 转发，避免处理两次


func _try_guard_dialogue() -> void:
	if _defend_started:
		return
	if _guard_target == null or not is_instance_valid(_guard_target):
		return
	if _guard_dialogue != null and _guard_dialogue.is_open():
		return
	var distance := player.global_position.distance_to(_guard_target.global_position) / float(ArenaGen.TILE_SIZE)
	if distance > 2.0:
		return
	if not Input.is_action_just_pressed("interact"):
		return
	_ensure_guard_dialogue()
	player.set_physics_process(false)
	_guard_dialogue.show_dialogue("守护对象",
		["准备好的话就开始吧。", "开始之后就不能再回来改建了。"],
		["开始关卡", "再想想"])


func _on_guard_dialogue_option(index: int) -> void:
	if index == 0:
		_start_defend_level()
	player.set_physics_process(true)


func _on_guard_dialogue_closed() -> void:
	if player != null and is_instance_valid(player):
		player.set_physics_process(true)


func _start_defend_level() -> void:
	if _defend_started:
		return
	_defend_started = true
	_build_mode = false
	if _build_ghost != null:
		_build_ghost.visible = false
	if _build_hud != null:
		_build_hud.visible = false
	stage_time_left = stage_duration               # 倒计时从现在开始
	_spawn_initial_enemies()
	_start_enemy_spawn_timer()
	if debug_print:
		print("[Battle] 守护关正式开始：倒计时 %.0f 秒" % stage_duration)


## 找一个能站人的格子：优先自己，不行就在周围 5 格内找最近的地板格
func _find_standable_cell(cell: Vector2i) -> Vector2i:
	if _is_walkable_cell(cell) and _find_placed_at(cell).is_empty():
		return cell
	for radius in range(1, 6):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var probe := cell + Vector2i(int(dx), int(dy))
				if _is_walkable_cell(probe) and _find_placed_at(probe).is_empty():
					return probe
	return Vector2i(-1, -1)


## 建造模式下光标格的白色光边（突出显示玩家要放的位置）
func _build_cursor_frame() -> void:
	_build_frame = Node2D.new()
	_build_frame.name = "BuildCursorFrame"
	_build_frame.z_index = 75
	_build_frame.visible = false
	add_child(_build_frame)
	var size_px := 16.0
	var thickness := 2.0
	var fill := ColorRect.new()
	fill.color = Color(1, 1, 1, 0.12)
	fill.size = Vector2(size_px, size_px)
	fill.position = Vector2(-size_px, -size_px) * 0.5
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_frame.add_child(fill)
	var bars := [
		[Vector2(-size_px * 0.5, -size_px * 0.5), Vector2(size_px, thickness)],
		[Vector2(-size_px * 0.5, size_px * 0.5 - thickness), Vector2(size_px, thickness)],
		[Vector2(-size_px * 0.5, -size_px * 0.5), Vector2(thickness, size_px)],
		[Vector2(size_px * 0.5 - thickness, -size_px * 0.5), Vector2(thickness, size_px)],
	]
	for bar_data in bars:
		var bar := ColorRect.new()
		bar.color = Color(1, 1, 1, 0.95)
		bar.position = bar_data[0]
		bar.size = bar_data[1]
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_build_frame.add_child(bar)


# ============================ 暂时岩浆地板 + 第 15 层波次 ============================

@export_group("BOSS 岩浆与波次")
## 暂时岩浆持续多少秒后恢复原材质
@export var temp_lava_seconds: float = 8.0
## 波次之间（第 15 层）的缓冲秒数
@export var boss_wave_gap_seconds: float = 10.0

## 暂时岩浆按"格子"记账：同一格被多只岩浆 BOSS 反复点着时，只记第一次变岩浆前的材质，
## 剩余时间取更长的那个，避免互相覆盖导致"永久岩浆"或"提前恢复"
var _temp_lava_origin: Dictionary = {}    ## cell(Vector2i) -> 原地面材质(Vector2i)
var _temp_lava_left: Dictionary = {}      ## cell(Vector2i) -> 剩余秒数
var _boss_wave: int = 0                   ## 第 15 层当前波次（1/2/3）
var _boss_wave_gap_left: float = 0.0      ## 波次缓冲剩余秒数
var _boss_wave_pending: bool = false


## 把世界坐标夹到地图内最近的可行走格（防止敌人生成到地图外）
func clamp_to_walkable(world_position: Vector2) -> Vector2:
	var w: int = int(arena_data["width"])
	var h: int = int(arena_data["height"])
	var grid: Array = arena_data["grid"]
	var cell := Vector2i(clampi(int(floor(world_position.x / 16.0)), 1, w - 2),
		clampi(int(floor(world_position.y / 16.0)), 1, h - 2))
	if int(grid[cell.y * w + cell.x]) == 0:
		return cell_to_world(cell)
	for radius in range(1, 8):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var probe := cell + Vector2i(int(dx), int(dy))
				if probe.x <= 0 or probe.y <= 0 or probe.x >= w - 1 or probe.y >= h - 1:
					continue
				if int(grid[probe.y * w + probe.x]) == 0:
					return cell_to_world(probe)
	return cell_to_world(cell)


## 把一片格子暂时变成岩浆，到点恢复成原来的地面材质
func temp_lava(cells: Array, duration: float = -1.0, skip_corners: bool = false) -> void:
	var ground := $GroundTileMapLayer as TileMapLayer
	if ground == null or cells.is_empty():
		return
	var use_time := duration if duration > 0.0 else temp_lava_seconds
	var w: int = int(arena_data["width"])
	var h: int = int(arena_data["height"])
	var touched := 0
	for cell in cells:
		var c: Vector2i = cell
		if skip_corners and _is_box_corner(cells, c):
			continue                              # 5x5 砸地的四角保持正常地板
		if c.x <= 0 or c.y <= 0 or c.x >= w - 1 or c.y >= h - 1:
			continue
		if not _temp_lava_origin.has(c):
			# 只记第一次变岩浆前的真实材质，之后的重叠都沿用这一份
			_temp_lava_origin[c] = ground.get_cell_atlas_coords(c)
		_temp_lava_left[c] = maxf(float(_temp_lava_left.get(c, 0.0)), use_time)
		_set_ground_tile(c, ArenaGen.TILE_FLOOR_LAVA)
		touched += 1
	if touched == 0:
		return


func _is_box_corner(cells: Array, cell: Vector2i) -> bool:
	if cells.size() != 25:
		return false
	var min_x := 99999
	var min_y := 99999
	var max_x := -99999
	var max_y := -99999
	for c in cells:
		min_x = mini(min_x, (c as Vector2i).x)
		max_x = maxi(max_x, (c as Vector2i).x)
		min_y = mini(min_y, (c as Vector2i).y)
		max_y = maxi(max_y, (c as Vector2i).y)
	var at_x_edge: bool = cell.x == min_x or cell.x == max_x
	var at_y_edge: bool = cell.y == min_y or cell.y == max_y
	return at_x_edge and at_y_edge


func _update_temp_lava(delta: float) -> void:
	if _temp_lava_left.is_empty():
		return
	var ground := $GroundTileMapLayer as TileMapLayer
	for cell in _temp_lava_left.keys():
		var left := float(_temp_lava_left[cell]) - delta
		if left > 0.0:
			_temp_lava_left[cell] = left
			continue
		_temp_lava_left.erase(cell)
		var origin = _temp_lava_origin.get(cell)
		_temp_lava_origin.erase(cell)
		if ground != null and origin != null:
			ground.set_cell(cell, ArenaGen.GROUND_SOURCE, origin)


## 以某个格子为中心的 5x5 区块（给岩浆 BOSS 砸地用）
func cells_around_cell(center: Vector2i) -> Array:
	var out: Array = []
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var cell := center + Vector2i(int(dx), int(dy))
			if cell.x <= 0 or cell.y <= 0:
				continue
			if cell.x >= int(arena_data["width"]) - 1 or cell.y >= int(arena_data["height"]) - 1:
				continue
			out.append(cell)
	return out


## 第 15 层三波是否已经全部打完（其它层直接返回 true）
func _boss_waves_finished() -> bool:
	if _context_floor() != RunState.MAX_FLOOR:
		return true
	return _boss_wave >= 3 and not _boss_wave_pending


## 第 15 层的波次推进
func _update_boss_waves(delta: float) -> void:
	if _context_floor() != RunState.MAX_FLOOR:
		return
	if _boss_wave_pending:
		_boss_wave_gap_left = maxf(_boss_wave_gap_left - delta, 0.0)
		if _boss_wave_gap_left <= 0.0:
			_boss_wave_pending = false
			_start_boss_wave(_boss_wave + 1)
		return
	if _living_boss_count() > 0:
		return
	if _boss_wave >= 3:
		return                               # 三波都打完，等清场
	if _boss_wave == 0:
		return                               # 第一波在 _ready 里已经开过了
	# 本波 BOSS 全灭：前两波顺手清场（不给金币），然后进入缓冲
	if _boss_wave < 3:
		_clear_field_without_reward()
	_boss_wave_pending = true
	_boss_wave_gap_left = boss_wave_gap_seconds
	if debug_print:
		print("[Battle] 第 %d 波结束，%.0f 秒后第 %d 波" % [_boss_wave, boss_wave_gap_seconds, _boss_wave + 1])


func _start_boss_wave(wave: int) -> void:
	_boss_wave = wave
	match wave:
		1:
			print("[Battle] 第 15 层 第 1 波：两只普通 BOSS")
			_spawn_boss()
			_spawn_boss()
			_spawn_final_floor_shooters(4)
		2:
			print("[Battle] 第 15 层 第 2 波：四只紫 BOSS（家族 0 x2 + 家族 1 x2，两条血条）")
			_spawn_purple_boss(0)
			_spawn_purple_boss(0)
			_spawn_purple_boss(1)
			_spawn_purple_boss(1)
		_:
			print("[Battle] 第 15 层 第 3 波：两只岩浆 BOSS")
			_spawn_lava_boss(0)
			_spawn_lava_boss(1)


## 生成一只岩浆 BOSS（第 15 层第三波）
func _spawn_lava_boss(index: int) -> void:
	var boss = LavaBossScene.instantiate()
	enemy_container.add_child(boss)
	var spawn_cell := _next_boss_spawn_cell()
	boss.global_position = cell_to_world(spawn_cell)
	var config: EnemyConfig = BossConfig.duplicate()
	config.max_health = maxi(int(round(
		float(BossConfig.max_health) * LAVA_BOSS_HP_BONUS * _boss_hp_multiplier())), 1)
	boss.setup(config, player)
	if boss.has_method("set_arena"):
		boss.set_arena(arena_data["grid"], int(arena_data["width"]), int(arena_data["height"]))
	if "debug_fast_skills" in boss:
		boss.debug_fast_skills = debug_fast_boss
	if boss.has_signal("boss_defeated"):
		boss.boss_defeated.connect(_on_boss_defeated)
	if not boss.died.is_connected(_on_enemy_died):
		boss.died.connect(_on_enemy_died)
	_boss_nodes.append(boss)
	if debug_print:
		print("[Battle] 岩浆 BOSS #%d 已放出：血量 %d，位置 %s" % [index, config.max_health, str(spawn_cell)])


## 从岩浆里爬出来的自爆兵：血量和移速各提升 50%
const LAVA_BOMBER_STAT_BOOST := 1.5


## 从"暂时岩浆"格子里刷 1 只自爆兵（岩浆 BOSS 锁血期间用）
## 不用 _try_spawn_enemy：那条路会被场上普通敌人上限卡住，这里直接放行
func spawn_bomber_at_lava(fallback_center: Vector2i = Vector2i(-1, -1)) -> Node:
	var bomber: Enemy = preload("res://scene/entities/enemies/enemy.tscn").instantiate() as Enemy
	if bomber == null:
		return null
	# 优先从"暂时岩浆"的格子里钻出来
	var lava_cells: Array = []
	for cell in _temp_lava_left.keys():
		lava_cells.append(cell)
	var spawn_cell := Vector2i(-1, -1)
	if not lava_cells.is_empty():
		spawn_cell = lava_cells[randi() % lava_cells.size()]
	elif fallback_center != Vector2i(-1, -1):
		spawn_cell = fallback_center
	if spawn_cell == Vector2i(-1, -1):
		return null
	# 刚从岩浆里爬出来：先打标记再入树（入树信号里就能认出它是"岩浆里刷的"），
	# 并给它 1 秒岩浆免疫，否则一冒头就被自己脚下的岩浆烧掉
	bomber.set_meta("lava_immune_left", 1.0)
	enemy_container.add_child(bomber)
	var jitter := Vector2(randf_range(-5.0, 5.0), randf_range(-5.0, 5.0))
	bomber.global_position = clamp_to_walkable(cell_to_world(spawn_cell) + jitter)
	# 从岩浆里爬出来的自爆兵更强：血量 +50%、移速 +50%（用户要求）
	var cfg: EnemyConfig = preload("res://resources/config/enemy_bomber.tres").duplicate()
	cfg.max_health = maxi(int(round(float(cfg.max_health) * LAVA_BOMBER_STAT_BOOST)), 1)
	cfg.move_speed = float(cfg.move_speed) * LAVA_BOMBER_STAT_BOOST
	bomber.setup(cfg, player)
	bomber.died.connect(_on_enemy_died)
	return bomber


## 把场上其他敌人直接干掉，但不给金币、不算击杀
func _clear_field_without_reward() -> void:
	for child in enemy_container.get_children():
		if not (child is Enemy):
			continue
		var enemy: Enemy = child
		if enemy.is_dead or enemy.has_method("set_arena"):
			continue                                  # 跳过 BOSS 本体
		enemy.drop_disabled = true
		enemy.current_health = 0
		enemy.queue_free()
	if debug_print:
		print("[Battle] 波次切换：清掉场上杂兵（不给金币、不计击杀）")


# ============================ 多条 BOSS 血条（有几个 BOSS 就有几条） ============================

## 每一条血条一行：{bar, marker, label, icon}
var _boss_bars: Array = []


## 按需要补齐血条行数（第一行用现成的 time_bar，其余复制它）
func _ensure_boss_bars(count: int) -> void:
	if time_bar == null:
		return
	if _boss_bars.is_empty():
		_boss_bars.append({
			"bar": time_bar,
			"marker": _boss_lock_marker,
			"label": _boss_lock_label,
			"icon": _boss_icon_main,
		})
	while _boss_bars.size() < count:
		var row_index := _boss_bars.size()
		var bar := time_bar.duplicate() as Sprite2D
		bar.name = "BossBar%d" % row_index
		bar.position = Vector2(time_bar.position.x,
			time_bar.position.y + BOSS_BAR_SPACING * float(row_index))
		time_bar.get_parent().add_child(bar)
		bar.visible = true
		bar.scale = Vector2(time_bar_full_scale_x, time_bar.scale.y)
		bar.modulate = time_bar.modulate
		bar.z_index = time_bar.z_index
		if debug_print:
			print("[Battle] 新建 BOSS 血条 #%d（位置 %s）" % [row_index, str(bar.position)])
		var hud := $Player/HUDLayer as Node2D
		var marker: ColorRect = null
		var label: Label = null
		var icon: Sprite2D = null
		if hud != null:
			marker = _make_boss_lock_marker(hud, bar)
			label = _make_boss_lock_label(hud, bar)
			icon = Sprite2D.new()
			icon.name = "BossBarIcon%d" % row_index
			icon.position = Vector2(time_bar_left_edge_x - BOSS_ICON_GAP, bar.position.y)
			hud.add_child(icon)
		_boss_bars.append({"bar": bar, "marker": marker, "label": label, "icon": icon})
		if not _boss_bars_shifted:
			_boss_bars_shifted = true
			_move_life_display_down(BOSS_BAR_SPACING)   # 给第二条血条腾位置


## 场上还活着的 BOSS（紫 BOSS 家族共用一个血池，只算一条）
func _live_boss_entries() -> Array:
	var out: Array = []
	var purple_families: Dictionary = {}
	# 用统一的 BOSS 列表（含紫 BOSS、岩浆 BOSS），而不是只看 enemy_container 的直接子节点
	for child in _boss_nodes_all():
		if not (child is Enemy):
			continue
		var boss: Enemy = child
		if boss.is_dead:
			continue
		if _boss_kind_of(boss) == "purple":
			# 紫 BOSS 按家族出条：同一家族的若干只共用一个血池 = 一条血条
			var family := int(boss.get("family_id"))
			if purple_families.has(family):
				continue
			purple_families[family] = true
			out.append({"node": boss, "ratio": _purple_family_ratio_of(family),
				"lock": _purple_lock_left_of(family)})
		else:
			var ratio := 0.0
			if boss.config != null:
				ratio = clampf(float(boss.current_health)
					/ float(maxi(int(boss.config.max_health), 1)), 0.0, 1.0)
			var lock := float(boss.get("_hp_lock_left")) if "_hp_lock_left" in boss else 0.0
			out.append({"node": boss, "ratio": ratio, "lock": lock})
	return out


## 刷新全部 BOSS 血条：有几只活 BOSS 就显示几条，各自独立掉血
func _refresh_boss_bars() -> void:
	var entries := _live_boss_entries()
	_ensure_boss_bars(maxi(entries.size(), 1))
	for i in range(_boss_bars.size()):
		var row: Dictionary = _boss_bars[i]
		var bar := row["bar"] as Sprite2D
		# 第 0 行的白线/文字/图标是 _setup_boss_bar_icons 里后建的，
		# 这里每帧重新取一次，避免一开始抓到 null 就再也显示不出来
		if i == 0:
			row["marker"] = _boss_lock_marker
			row["label"] = _boss_lock_label
			row["icon"] = _boss_icon_main
		var marker := row["marker"] as ColorRect
		var label := row["label"] as Label
		var icon := row["icon"] as Sprite2D
		if bar == null:
			continue
		if i >= entries.size():
			bar.visible = false
			if marker != null:
				marker.visible = false
			if label != null:
				label.visible = false
			if icon != null:
				icon.visible = false
			# 第 15 层两波之间的缓冲：在血条原来的位置显示倒计时
			if i == 0 and _boss_wave_pending and label != null:
				label.visible = true
				label.text = "下一波 %.1fS" % maxf(_boss_wave_gap_left, 0.0)
				label.position = Vector2(time_bar.position.x - 40.0, bar.position.y - 8.0)
			continue
		var entry: Dictionary = entries[i]
		var node = entry["node"]
		var ratio := float(entry["ratio"])
		var lock := float(entry["lock"])
		_apply_boss_bar(bar, ratio)
		_apply_boss_lock_visual(bar, lock)
		bar.position.y = time_bar.position.y + BOSS_BAR_SPACING * float(i)
		bar.visible = true
		if marker != null:
			marker.visible = true
			marker.color = BOSS_BAR_LOCK_COLOR if lock > 0.0 else Color(1.0, 1.0, 1.0, 0.35)
		if label != null:
			label.visible = lock > 0.0
			if lock > 0.0:
				label.text = "%.1fS" % lock
		if icon != null:
			_update_boss_bar_icon(icon, node)
			icon.visible = icon.texture != null
