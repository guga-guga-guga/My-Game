extends "res://scene/game.gd"
## Battle:程序化场地 + 关卡目标 M2 
##
## 只覆盖三个钩子，其余全部复用 game.gd:
##   _ready()              插入"生成地形 到 铺瓦片 到 建红门出怪点 到 重建寻路"
##   _process(delta)       追加"波次推进 + 目标 HUD 刷新"
##   _check_game_result()  改为按 LevelGoal 判定胜负 ALL 语义 
## ⚠️ 因为覆盖了这三处，game.gd 里对应位置日后新增的逻辑需要同步到这里

const ArenaGen = preload("res://scene/arena/arena_generator.gd")
const LevelGoal = preload("res://scene/battle/level_goal.gd")
const BossScene = preload("res://scene/boss.tscn")
const BossConfig = preload("res://resources/config/enemy_boss.tres")
const AllyScene = preload("res://scene/ally.tscn")
const AllyIcon := preload("res://resources/texture/icon.png")
const PauseMenuScript = preload("res://scene/ui/pause_menu.gd")
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

@export_group("调试")
## 强制目标类型 survive / kill / clear_waves / boss ；空 = 按节点类型自动
@export var debug_goal_type: String = ""
## 打印目标与场地概要
@export var debug_print: bool = true
## 调试: 加快 Boss 技能节奏（headless 自检用）
@export var debug_fast_boss: bool = false
## Boss 关：红门每隔多少秒涌出一只普通敌人
@export var boss_door_spawn_interval: float = 5.0
## Boss 关：场上小怪（不含 Boss）上限
@export var boss_door_alive_cap: int = 5
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

var _goal_label: Label
var _detail_label: Label
var _last_hud_key := ""

# 波次推进
var _waves: Array = []
var _wave_index := 0
var _waves_done := 0
var _waves_finished := false
var _wave_timer_left := 0.0
var _boss_defeated := false
var _boss: Enemy = null
var _boss_nodes: Array[Node] = []
var _boss_bars: Array[Dictionary] = []
var _multi_boss_bar_logged := false
var _boss_title_label: Label = null
var _debug_win_started := false
var _ally = null
var _pause_menu = null
var _hud_gold: Label = null
var _hud_ally_box: Control = null
var _hud_ally_hp: Label = null
var _hud_ally_state: Label = null
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
	random_generator.randomize()

	# ① 目标必须先算:限时决定倒计时条长度 stage_duration 由 _setup_hud 读取 
	goal = LevelGoal.build(_context_floor(), _context_node_type(), debug_goal_type)
	if goal.get("type", "") == LevelGoal.TYPE_BOSS:
		MusicManager.play_boss()          # BOSS 战曲
	else:
		MusicManager.play_stage()         # 普通关/精英关曲
	stage_duration = LevelGoal.stage_duration(goal)
	_waves = goal.get("waves", [])

	_configure_result_dialog()
	_setup_hud()
	_setup_goal_hud()
	_setup_battle_hud()
	_setup_pause_menu()
	_apply_goal_hud_layout()

	# ② 场地数据 到 ③ 铺瓦片 红门在 Overlay 层 到 ④ 出怪点与红门成对创建
	var use_seed := arena_seed if arena_seed != 0 else random_generator.randi()
	var generator = ArenaGen.new()
	var arena_mode := ArenaGen.MODE_BOSS if goal["type"] == LevelGoal.TYPE_BOSS else ArenaGen.MODE_NORMAL
	arena_data = generator.generate(arena_width, arena_height, use_seed, arena_mode)
	generator.apply_to_layers($GroundTileMapLayer, $OverlayTileMapLayer, arena_data)
	generator.create_spawn_markers($EnemySpawnPoints, arena_data)
	player.global_position = cell_to_world(arena_data["player_spawn"])
	_apply_run_state_to_player()

	# ⑤ 顺序关键:铺完瓦片之后才能重建寻路网格
	_setup_enemy_pathfinder()
	_collect_enemy_spawn_points()
	_warn_spawn_points_inside_walls()
	_spawn_ally_if_hired()
	_collect_enemy_configs()
	_apply_floor_scaling_to_enemy_configs()
	_configure_enemy_spawn_timer()
	_keep_player_centered()

	# ⑥ 刷怪:有波次表的关卡走波次推进；其余沿用父类的无限刷怪
	if goal["type"] == LevelGoal.TYPE_BOSS:
		_spawn_bosses_for_floor()
		_start_boss_door_spawner()
	elif _waves.is_empty():
		_spawn_initial_enemies()
		_start_enemy_spawn_timer()
	else:
		_wave_timer_left = 0.6

	_refresh_goal_hud(true)
	if debug_print:
		print("[Battle] 目标=%s 条件=%d 限时=%.0f 波次=%d | 场地 %dx%d seed=%d 房间=%d 红门=%d 寻路=%s 玩家出生=%s" % [
			goal["type"], goal["conditions"].size(), LevelGoal.time_limit(goal), _waves.size(),
			arena_data["width"], arena_data["height"], arena_data["seed"], arena_data["room_count"],
			arena_data["doors"].size(),
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


## M6 平衡：最终 BOSS 更肉（半路 BOSS 保持不变）
func _boss_config_for_floor() -> EnemyConfig:
	if not RunState.is_final_floor():
		return BossConfig
	var copy: EnemyConfig = BossConfig.duplicate()
	copy.max_health = maxi(int(round(float(BossConfig.max_health) * 1.65)), 1)
	if debug_print:
		print("[Battle] 最终 BOSS 血量 %d -> %d" % [BossConfig.max_health, copy.max_health])
	return copy


## 整局生命值变化时（例如商店买血）同步到玩家节点
func _on_run_state_health_changed(current: int, maximum: int) -> void:
	if player == null:
		return
	player.max_health = maxi(maximum, 1)
	player.current_health = clampi(current, 1, player.max_health)


## 右上角：金币（用户要求战斗里也显示）+ 队友头像/名字/血量/状态
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

	# 队友面板：头像 + 名字 + 血量 + 状态
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
	name_label.text = ALLY_NAME
	name_label.add_theme_font_size_override("font_size", HUD_FONT_NAME)
	name_label.add_theme_color_override("font_color", Color(0.85, 0.93, 1.0))
	info.add_child(name_label)
	_hud_ally_hp = Label.new()
	_hud_ally_hp.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	_hud_ally_hp.add_theme_color_override("font_color", Color(1.0, 0.55, 0.55))
	info.add_child(_hud_ally_hp)
	_hud_ally_state = Label.new()
	_hud_ally_state.add_theme_font_size_override("font_size", HUD_FONT_SMALL)
	_hud_ally_state.add_theme_color_override("font_color", Color(0.70, 0.85, 1.0))
	info.add_child(_hud_ally_state)
	_hud_ally_box = ally_panel

	if not RunState.gold_changed.is_connected(_on_hud_gold_changed):
		RunState.gold_changed.connect(_on_hud_gold_changed)
	_refresh_hud_gold()
	_hud_ally_box.visible = false
	_setup_boss_family_bars()


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
	if _hud_ally_box == null:
		return
	if _ally == null or not is_instance_valid(_ally):
		_hud_ally_box.visible = false
		return
	_hud_ally_box.visible = true
	if _ally.is_dead:
		_hud_ally_hp.text = "0 / %d" % _ally.MAX_HEALTH
		_hud_ally_state.text = "阵亡"
		return
	_hud_ally_hp.text = "%d / %d" % [_ally.current_health, _ally.MAX_HEALTH]
	_hud_ally_state.text = String(_ally.state_name())


func _on_ally_state_changed(_state: String) -> void:
	_refresh_ally_hud()


func _on_ally_health_changed(_current: int, _maximum: int) -> void:
	_refresh_ally_hud()


## 商店里雇了队友的话，这一关开场把他放出来（只在本关有效）
func _spawn_ally_if_hired() -> void:
	if not RunState.ally_pending:
		return
	RunState.ally_pending = false          # 用完即清：下一关要重新雇
	var ally = AllyScene.instantiate()          # 不用类型注解：队友脚本没有全局类名
	if ally == null:
		return
	add_child(ally)
	var body := player.get_node_or_null("BodySprite") as AnimatedSprite2D
	# 把玩家的 AnimatedSprite2D 交给队友：共用同一套 SpriteFrames 并镜像动画
	ally.setup(player, body, RunState.get_player_damage(), RunState.get_player_fire_interval(),
		$EnemyContainer)
	_ally = ally
	ally.health_changed.connect(_on_ally_health_changed)
	ally.state_changed.connect(_on_ally_state_changed)
	_refresh_ally_hud()
	ally.global_position = _ally_spawn_position()      # 别生成到墙里（原来固定放玩家右侧 22px）
	if debug_print:
		var spawn_cell := Vector2i(int(ally.global_position.x / float(ArenaGen.TILE_SIZE)),
			int(ally.global_position.y / float(ArenaGen.TILE_SIZE)))
		var spawn_is_floor := false
		var grid_now: Array = arena_data.get("grid", [])
		var width_now: int = int(arena_data.get("width", 0))
		if not grid_now.is_empty() and width_now > 0:
			spawn_is_floor = int(grid_now[spawn_cell.y * width_now + spawn_cell.x]) == 0
		print("[Battle] 队友出生位置=%s 格=%s 该格是地板=%s" % [
			str(ally.global_position), str(spawn_cell), str(spawn_is_floor)])
		print("[Battle] 队友已出场: 伤害 %d 开火间隔 %.3f（玩家 %.3f 的七折射速）状态=%s" % [
			ally.damage, ally.fire_interval, RunState.get_player_fire_interval(), ally.state_name()])
		print("[Battle自检] 右上角 HUD: %s / 队友 %s %s %s" % [
			_hud_gold.text, ALLY_NAME, _hud_ally_hp.text, _hud_ally_state.text])


## 失去焦点时自动暂停。
## 网页里把游戏嵌进 iframe 后，玩家点到作品集的其它项目 / 浏览器其它标签页时，
## 游戏会在后台继续跑（可能被打死）。这里在失焦时自动叫出暂停菜单，
## 玩家切回来时仍停在暂停界面，点"继续游戏"即可。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_auto_pause_on_focus_lost()


func _auto_pause_on_focus_lost() -> void:
	if not is_inside_tree():
		return
	if _pause_menu == null or _pause_menu.is_open() or is_result_displayed:
		return
	_pause_menu.open()


## ESC 暂停菜单（关卡里也能叫出来；结算弹窗期间不响应）
func _setup_pause_menu() -> void:
	_pause_menu = PauseMenuScript.new()
	add_child(_pause_menu)
	_pause_menu.quit_to_title_requested.connect(_on_quit_to_title_requested)


## 给队友找一个"玩家附近、且是地板"的出生点（避免生成到地形里卡住）
## 用生成器留下的 arena_data.grid：0=地板 1=墙 2=外墙
func _ally_spawn_position() -> Vector2:
	var grid: Array = arena_data.get("grid", [])
	var width: int = int(arena_data.get("width", 0))
	var height: int = int(arena_data.get("height", 0))
	var tile := float(ArenaGen.TILE_SIZE)
	var player_cell := Vector2i(int(floor(player.global_position.x / tile)), int(floor(player.global_position.y / tile)))
	if grid.is_empty() or width <= 0:
		return player.global_position
	for radius in range(0, 7):
		for offset_y in range(-radius, radius + 1):
			for offset_x in range(-radius, radius + 1):
				var cell := player_cell + Vector2i(offset_x, offset_y)
				if cell.x < 1 or cell.y < 1 or cell.x >= width - 1 or cell.y >= height - 1:
					continue
				if int(grid[cell.y * width + cell.x]) != 0:
					continue
				return cell_to_world(cell)
	if debug_print:
		push_warning("[Battle] 队友没找到空地，直接放在玩家身上")
	return player.global_position


func _check_pause_input() -> void:
	if _pause_menu == null or _pause_menu.is_open() or is_result_displayed:
		return
	if Input.is_action_just_pressed("pause"):
		_pause_menu.open()


func _on_quit_to_title_requested() -> void:
	print("[Battle] 回到主界面（放弃本局，不留战绩）")
	GameFlow.goto_title()


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
	_check_pause_input()
	_refresh_boss_bars()
	_update_waves(delta)
	_refresh_goal_hud()


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
	var boss_alive := 0
	if _boss != null and is_instance_valid(_boss) and not _boss.is_dead:
		boss_alive = 1
	if _get_alive_enemy_count() - boss_alive >= boss_door_alive_cap:
		return
	if _try_spawn_enemy() and debug_print:
		print("[Battle] 红门涌出一只敌人（场上共 %d）" % _get_alive_enemy_count())


## 在红条左边加「BOSS」字样（和血条同层、世界空间，跟着角色走）
func _add_boss_health_title(clock_bar: Sprite2D) -> void:
	if _boss_title_label != null and is_instance_valid(_boss_title_label):
		return
	var boss_hud := $Player/HUDLayer as Node2D
	if boss_hud == null:
		return
	var label := Label.new()
	label.name = "BossHealthTitle"
	label.text = "BOSS"
	label.add_theme_font_size_override("font_size", 10)          # 世界空间会被相机放大 4 倍
	label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 2)
	boss_hud.add_child(label)
	label.position = Vector2(time_bar_left_edge_x - 34.0, clock_bar.position.y - 7.0)
	_boss_title_label = label


## Boss 关：从"离玩家最远的那个红门"里放出一只 Boss（复用出怪口的语义）
## 把整局成长（生命/伤害/射速）应用到玩家身上
func _apply_run_state_to_player() -> void:
	player.max_health = RunState.max_health
	player.current_health = clampi(RunState.current_health, 1, RunState.max_health)
	player.fire_interval = RunState.get_player_fire_interval()
	if not RunState.health_changed.is_connected(_on_run_state_health_changed):
		RunState.health_changed.connect(_on_run_state_health_changed)
	if debug_print:
		print("[Battle] 进场: 生命 %d/%d 子弹伤害 %d 射击间隔 %.3f 金币 %d" % [
			player.current_health, player.max_health, RunState.get_player_damage(),
			player.fire_interval, RunState.gold])


## 金币只来自敌人掉落
func _on_enemy_died() -> void:
	super._on_enemy_died()
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
	_boss = boss
	var spawn_cell := _farthest_spawn_cell_from(arena_data["player_spawn"])
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
	var boss_gain := maxi(gold_per_boss_kill, 0)
	RunState.add_gold(boss_gain)
	_gold_gained += boss_gain

	var bar := $Player/HUDLayer/TimeBar as Sprite2D
	if bar != null:
		bar.visible = false          # Boss 死后收起红条
	if _boss_title_label != null and is_instance_valid(_boss_title_label):
		_boss_title_label.visible = false
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
	clock_bar.modulate = Color(1.0, 0.28, 0.28)
	clock_bar.position.x = 0.0
	# 居中后必须重算左边缘（父类 _setup_hud 是按原位置算的），否则条会往右跑
	if clock_bar.centered:
		time_bar_left_edge_x = clock_bar.position.x - (time_bar_texture_width * time_bar_full_scale_x * 0.5)
	else:
		time_bar_left_edge_x = clock_bar.position.x
	_add_boss_health_title(clock_bar)


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


## Boss 血量比例（0~1）
func _boss_hp_ratio() -> float:
	if _boss == null or not is_instance_valid(_boss) or _boss.config == null:
		return 1.0
	return clampf(float(_boss.current_health) / float(maxi(_boss.config.max_health, 1)), 0.0, 1.0)


## 覆盖父类：Boss 关顶部条 = Boss 血量条；其余关卡沿用倒计时
func _update_time_bar() -> void:
	if goal.get("type", "") != LevelGoal.TYPE_BOSS or time_bar == null:
		super._update_time_bar()
		return
	var fill_ratio := 0.0
	if not _boss_defeated:
		fill_ratio = _boss_hp_ratio()
	time_bar.scale.x = time_bar_full_scale_x * fill_ratio
	if not time_bar.centered:
		time_bar.position.x = time_bar_left_edge_x
		return
	var current_width := time_bar_texture_width * time_bar.scale.x
	time_bar.position.x = time_bar_left_edge_x + (current_width * 0.5)


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
		"boss_defeated": _living_boss_count() == 0,   # 三重 BOSS：全部家族归零才算达成
		"boss_hp_ratio": _boss_hp_ratio(),          # M3:Boss 死亡时由 Boss 置真
	}


func _check_game_result() -> void:
	if is_result_displayed:
		return
	if _get_player_current_health() <= 0:
		_last_result_won = false
		_show_result_dialog(RESULT_TITLE_LOSE, RESULT_MESSAGE_LOSE)
		return
	var state := _goal_state()
	if LevelGoal.is_satisfied(goal, state):
		_last_result_won = true
		if goal.get("type", "") == LevelGoal.TYPE_BOSS and RunState.is_final_floor():
			_show_result_dialog("通关", _build_run_summary())      # 最终层: 显示整局总结
		elif goal.get("type", "") == LevelGoal.TYPE_BOSS:
			_show_result_dialog("BOSS 击破", "第 %d 层 BOSS 已被击败 回中间地图" % RunState.floor_index)
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

const PURPLE_BOSS_SCENE := "res://scene/boss_purple.tscn"
const BOSS_FAMILY_COUNT := 3
const BOSS_BAR_WIDTH := 220.0


## 第 10 层 = 原 BOSS + 2 只紫 BOSS；其它 BOSS 层 = 50/50 随机一只（层数做种子，同层不变）
func _spawn_bosses_for_floor() -> void:
	_boss_nodes.clear()
	var floor_now := _context_floor()
	if RunState.is_final_floor() or floor_now >= RunState.MAX_FLOOR:
		_spawn_boss()
		_spawn_purple_boss(1)
		_spawn_purple_boss(2)
		print("[Battle] 第 10 层：三重 BOSS（原 BOSS + 紫 BOSS x2）")
	else:
		var rng := RandomNumberGenerator.new()
		rng.seed = floor_now * 7919
		if rng.randf() < 0.5:
			print("[Battle] 第 %d 层 BOSS 抽到：原 BOSS" % floor_now)
			_spawn_boss()
		else:
			print("[Battle] 第 %d 层 BOSS 抽到：紫色 BOSS" % floor_now)
			_spawn_purple_boss(0)


func _spawn_purple_boss(family: int) -> void:
	var purple = load(PURPLE_BOSS_SCENE).instantiate()
	if purple == null:
		return
	enemy_container.add_child(purple)
	var spawn_cell: Vector2i = _spawn_cell_for_family(arena_data["player_spawn"], family)
	purple.global_position = cell_to_world(spawn_cell)
	purple.setup(BossConfig, player)
	if "family_id" in purple:
		purple.family_id = family
	_boss_nodes.append(purple)
	if _boss == null:
		_boss = purple
	if not purple.died.is_connected(_on_enemy_died):
		purple.died.connect(_on_enemy_died)
	purple.died.connect(_on_purple_boss_died)
	if debug_print:
		print("[Battle] 紫色 BOSS 已放出（家族 %d）出生格=%s" % [family, str(spawn_cell)])


func _on_purple_boss_died() -> void:
	if not is_inside_tree():
		return
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
		if node == _boss or node.has_method("debug_splits_done"):
			nodes.append(node)
	return nodes


## 还活着的 BOSS 数量（含分身）—— 归零才算过关
func _living_boss_count() -> int:
	var count := 0
	for node in _boss_nodes_all():
		if is_instance_valid(node) and not bool(node.get("is_dead")):
			count += 1
	return count


func _node_family(node: Node) -> int:
	var value = node.get("family_id")
	return int(value) if value != null else 0


## 某个家族（本体 + 它的分身）的合计血量；满血基准 = 本体最大血量 x2（本体 + 4 个 1/4 血分身）
func _family_hp(family: int) -> Dictionary:
	var current := 0
	for node in _boss_nodes_all():
		if is_instance_valid(node) and _node_family(node) == family:
			current += int(node.get("current_health"))
	var body := _boss_body_of_family(family)
	var total := 1
	if body != null:
		total = maxi(int(body.get("max_health")) * 2, 1)
	return {"current": current, "total": total}


func _boss_body_of_family(family: int) -> Node:
	for node in _boss_nodes:
		if is_instance_valid(node) and not bool(node.get("is_clone")):
			if _node_family(node) == family:
				return node
	if family == 0 and is_instance_valid(_boss):
		return _boss
	return null


## 屏幕上方：每组 = 红色血条 + 右侧 BOSS 一帧图像（用户可以一眼分清三条是谁）
func _setup_boss_family_bars() -> void:
	var layer := get_node_or_null("BattleHud") as CanvasLayer
	if layer == null or not _boss_bars.is_empty():
		return
	var row := HBoxContainer.new()
	row.name = "BossFamilyBars"
	row.set_anchors_preset(Control.PRESET_CENTER_TOP)
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	row.offset_top = 14.0
	row.add_theme_constant_override("separation", 26)
	layer.add_child(row)
	for family in range(BOSS_FAMILY_COUNT):
		var group := HBoxContainer.new()
		group.add_theme_constant_override("separation", 6)
		group.visible = false
		row.add_child(group)
		var bar_bg := ColorRect.new()
		bar_bg.color = Color(0.16, 0.06, 0.06, 0.85)
		bar_bg.custom_minimum_size = Vector2(BOSS_BAR_WIDTH, 18.0)
		group.add_child(bar_bg)
		var fill := ColorRect.new()
		fill.color = Color(1.0, 0.28, 0.28, 1.0)
		fill.size = Vector2(BOSS_BAR_WIDTH, 18.0)
		bar_bg.add_child(fill)
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(32.0, 32.0)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		group.add_child(icon)
		_boss_bars.append({"group": group, "fill": fill, "icon": icon, "family": family})


func _refresh_boss_bars() -> void:
	_sync_single_boss_bar()
	if _boss_bars.is_empty():
		return
	for entry in _boss_bars:
		var family: int = int(entry["family"])
		var group := entry["group"] as Control
		var body := _boss_body_of_family(family)
		if body == null:
			group.visible = false
			continue
		var hp := _family_hp(family)
		var alive := int(hp["current"]) > 0
		group.visible = alive
		if not alive:
			continue
		var fill := entry["fill"] as ColorRect
		fill.size = Vector2(BOSS_BAR_WIDTH * clampf(float(hp["current"]) / float(hp["total"]), 0.0, 1.0), 18.0)
		var icon := entry["icon"] as TextureRect
		if icon.texture == null:
			icon.texture = _boss_icon_texture(body)


func _boss_icon_texture(body: Node) -> Texture2D:
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
func _spawn_cell_for_family(from_cell: Vector2i, index: int) -> Vector2i:
	var doors: Array = arena_data.get("doors", [])
	if doors.is_empty():
		return _farthest_spawn_cell_from(from_cell)
	var cells: Array[Vector2i] = []
	for door in doors:
		cells.append(door["cell"])
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2(a).distance_to(Vector2(from_cell)) \
			> Vector2(b).distance_to(Vector2(from_cell)))
	return cells[clampi(index, 0, cells.size() - 1)]


## 第 10 层有多只 BOSS 时，隐藏原来那条单 BOSS 血条与「BOSS」标题（避免和三条家族血条重复）
## 只做隐藏、不做恢复：单 BOSS 层和死亡后的隐藏仍由原有逻辑负责
func _sync_single_boss_bar() -> void:
	if _living_boss_count() <= 1:
		return
	var hud := get_node_or_null("Player/HUDLayer")
	if hud == null:
		return
	var bar := hud.get_node_or_null("TimeBar") as Sprite2D
	var title := hud.get_node_or_null("BossHealthTitle") as Label
	if bar != null and bar.visible:
		bar.visible = false
		if not _multi_boss_bar_logged:
			_multi_boss_bar_logged = true
			print("[Battle] 多 BOSS：已隐藏旧的单条血条与 BOSS 标题")
	if title != null and title.visible:
		title.visible = false
