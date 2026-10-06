extends CanvasLayer
## F1 调试面板（**仅调试构建**）：打开时冻结整个游戏，直接改 RunState 里的数值。
## 操作：W/S 选行，A/D 选这一行里的第几个选项（按钮），E 确定；鼠标也能点。
## 最下面：雇佣队友（点一下加一个，下面缩进一格列出 队友A/B/C 的血量 + 剩余层数）、调试关卡入口。
## 数值行：[-100][-10][-1][+1][+10][+100] + 右侧一个可输入的数值框。
## 战斗中改完会调用 battle.debug_sync_run_values()，玩家/队友/HUD 立刻同步。
##
## 约定：数值都用整数表示
##   移速 = 百分比（100 = 1.0 倍）
##   无敌时间 = 0.1 秒（15 = 1.5 秒）
## 注册为 Autoload 名: DebugPanel

const FONT_TITLE := 28
const FONT_ROW := 22
const FONT_HINT := 16
const FONT_VALUE := 20
const PANEL_WIDTH := 900.0
const SCROLL_HEIGHT := 470.0
const STEP_SMALL := 1
const STEP_MID := 10
const STEP_BIG := 100
const SELECTED_COLOR := Color(1.0, 0.87, 0.55)
const NORMAL_COLOR := Color(0.88, 0.89, 0.92)
const ALLY_INFO_COLOR := Color(0.80, 0.86, 0.94)
const HINT_COLOR := Color(0.66, 0.70, 0.74)
## 队友子行「队友A/B/C」相对「雇佣队友」缩进一格
const ALLY_ROW_INDENT := 28.0
const ALLY_LETTERS: Array[String] = ["A", "B", "C"]
## 长按方向键：按住满 HOLD_REPEAT_DELAY 秒后，开始每隔 HOLD_REPEAT_INTERVAL 秒自动往那个方向挪一格
const HOLD_REPEAT_DELAY := 1.0
const HOLD_REPEAT_INTERVAL := 0.12

## 数值行（顺序即显示顺序）；key 在 _get_value / _set_value 里分发
const ROWS: Array[Dictionary] = [
	{"key": "health", "label": "当前生命(颗)"},
	{"key": "max_health", "label": "生命上限(颗)"},
	{"key": "damage", "label": "子弹伤害(点)"},
	{"key": "fire_rate", "label": "射速等级(级)"},
	{"key": "gold", "label": "金币(金)"},
	{"key": "move_speed", "label": "移速(%)"},
	{"key": "invincibility", "label": "无敌时间(0.1秒)"},
]

var _enabled := false
var _open := false
var _paused_before := false
var _selected := 0                        ## 选中的行（_selectable 的下标）
var _col := 0                             ## 选中行里的第几个按钮（A/D 切换）
var _root: Control = null
var _rows_box: VBoxContainer = null
var _scroll: ScrollContainer = null
var _entries: Array[Dictionary] = []      ## 数值行 {key, name, box, buttons}
var _selectable: Array[Dictionary] = []   ## 可被 W/S 选中的行 {kind, key, deltas, buttons, control}
var _ally_box: VBoxContainer = null       ## 队友A/B/C 信息行容器
var _ally_rows: Array[Control] = []
var _ally_row_entries: Array[Dictionary] = []   ## 动态队友行 {key, buttons, health_box, floors_box}
var _hire_button: Button = null
var _hold_dir := Vector2i.ZERO      ## 当前按住的方向（0 = 没按）
var _hold_time := 0.0
var _hold_repeating := false
var _repeat_elapsed := 0.0
var _debug_menu = null                    ## 两级调试菜单（队友关 / BOSS 关），由本面板打开


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 40
	if not OS.is_debug_build():
		_enabled = false
		set_process_input(false)
		set_process_unhandled_input(false)
		return
	_enabled = true
	_build_ui()
	# 注意：这里不能给 CanvasLayer 设 visible = false，否则整层都渲染不出来。
	# 面板的显隐只靠 _root.visible（_build_ui 里初始化为 false）。


func is_open() -> bool:
	return _open


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_root.add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.07, 0.97)
	style.border_color = Color(0.65, 0.85, 1.0, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	outer.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	panel.add_child(outer)
	var title := Label.new()
	title.text = "调试面板"
	title.add_theme_font_size_override("font_size", FONT_TITLE)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)
	var hint := Label.new()
	hint.text = "W/S 选行    A/D 选这一行里的第几个按钮    E 确定    点方框可输入数值    鼠标也能点    F1 / ESC 关闭"
	hint.add_theme_font_size_override("font_size", FONT_HINT)
	hint.add_theme_color_override("font_color", Color(0.66, 0.70, 0.74))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(hint)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(PANEL_WIDTH, SCROLL_HEIGHT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(_scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 6)
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows_box)

	for index in range(ROWS.size()):
		_build_row(index, ROWS[index])
	_build_hire_row()
	_build_debug_level_row()


## 一行数值：名称 + [-100][-10][-1][+1][+10][+100] + 可输入的数值框
func _build_row(index: int, def: Dictionary) -> void:
	var key := String(def["key"])
	var row := HBoxContainer.new()
	row.name = "Row_%s" % key
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)

	var name_label := Label.new()
	name_label.text = String(def["label"])
	name_label.add_theme_font_size_override("font_size", FONT_ROW)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var entry := {"key": key, "name": name_label, "box": null, "buttons": []}
	# A/D 在这几个按钮之间左右切换，E 按下选中的那个
	var deltas: Array[int] = [-STEP_BIG, -STEP_MID, -STEP_SMALL, STEP_SMALL, STEP_MID, STEP_BIG]
	var buttons: Array[Button] = []
	for delta in deltas:
		var button := Button.new()
		button.text = "%+d" % delta
		button.custom_minimum_size = Vector2(64.0, 34.0)
		button.focus_mode = Control.FOCUS_NONE      # 选中由面板自己管，别让按钮抢焦点
		button.add_theme_font_size_override("font_size", FONT_VALUE)
		button.pressed.connect(_on_step_pressed.bind(key, delta))
		row.add_child(button)
		buttons.append(button)
	var box := LineEdit.new()
	box.custom_minimum_size = Vector2(110.0, 34.0)
	box.add_theme_font_size_override("font_size", FONT_VALUE)
	box.alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.text_submitted.connect(_on_box_submitted.bind(key))
	box.focus_exited.connect(_on_box_focus_exited.bind(key))
	row.add_child(box)
	entry["box"] = box
	entry["buttons"] = buttons
	_entries.append(entry)
	_selectable.append({"kind": "step", "key": key, "deltas": deltas,
			"buttons": buttons, "control": row})


## 「雇佣队友」行 + 下面缩进一格的 队友A/B/C 信息行（点了雇佣才出现）
func _build_hire_row() -> void:
	var row := HBoxContainer.new()
	row.name = "HireRow"
	_rows_box.add_child(row)
	_hire_button = Button.new()
	_hire_button.name = "HireAllyButton"
	_hire_button.text = "雇佣队友"
	_hire_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 靠左，不撑满
	_hire_button.custom_minimum_size = Vector2(150.0, 36.0)
	_hire_button.focus_mode = Control.FOCUS_NONE
	_hire_button.add_theme_font_size_override("font_size", FONT_ROW)
	_hire_button.pressed.connect(_hire_ally)
	row.add_child(_hire_button)
	_selectable.append({"kind": "hire", "key": "hire_ally", "deltas": [],
			"buttons": [_hire_button], "control": row})

	_ally_box = VBoxContainer.new()
	_ally_box.name = "AllyInfoBox"
	_ally_box.add_theme_constant_override("separation", 4)
	_rows_box.add_child(_ally_box)


## 「调试关卡」入口（原主界面「调试」按钮，放在「雇佣队友」下面）
func _build_debug_level_row() -> void:
	var level_box := VBoxContainer.new()
	level_box.name = "DebugLevelBox"
	level_box.add_theme_constant_override("separation", 4)
	_rows_box.add_child(level_box)

	var level_button := Button.new()
	level_button.name = "DebugMenuButton"
	level_button.text = "调试关卡"
	level_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 靠左，不撑满
	level_button.custom_minimum_size = Vector2(150.0, 36.0)
	level_button.focus_mode = Control.FOCUS_NONE
	level_button.add_theme_font_size_override("font_size", FONT_ROW)
	level_button.pressed.connect(_on_debug_menu_button_pressed)
	level_box.add_child(level_button)

	_selectable.append({"kind": "debug_level", "key": "debug_level", "deltas": [],
			"buttons": [level_button], "control": level_box})


func open_panel() -> void:
	if not _enabled or _open:
		return
	_open = true
	_paused_before = get_tree().paused
	get_tree().paused = true
	_root.visible = true
	_selected = 0
	_col = 0
	_reset_hold()
	_refresh_all()
	print("[DebugPanel] 已打开（游戏冻结）")


func close_panel() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	_reset_hold()
	get_tree().paused = _paused_before
	print("[DebugPanel] 已关闭")


func toggle() -> void:
	if _open:
		close_panel()
	else:
		open_panel()


# ---------------- 数值读写 ----------------

func _get_value(key: String) -> int:
	var battle := _current_battle()
	match key:
		"health":
			if battle != null:
				return int(battle.player.current_health)
			return RunState.current_health
		"max_health":
			if battle != null:
				return int(battle.player.max_health)
			return RunState.max_health
		"damage":
			return RunState.get_player_damage()
		"fire_rate":
			return RunState.fire_rate_level
		"gold":
			return RunState.gold
		"move_speed":
			return int(round(RunState.move_speed_multiplier * 100.0))
		"invincibility":
			return int(round(RunState.get_player_invincibility() * 10.0))
		"ally_count":
			return RunState.ally_count()
		"ally_floors":
			return int(RunState.ally_roster[0].get("floors_left", 0)) if not RunState.ally_roster.is_empty() else 0
		"ally_health":
			return int(RunState.ally_roster[0].get("health", 0)) if not RunState.ally_roster.is_empty() else 0
	return 0


func _set_value(key: String, value: int) -> void:
	match key:
		"health":
			RunState.current_health = clampi(value, 0, RunState.max_health)
			RunState.health_changed.emit(RunState.current_health, RunState.max_health)
		"max_health":
			RunState.max_health = clampi(value, 1, 99)
			RunState.current_health = mini(RunState.current_health, RunState.max_health)
			RunState.health_changed.emit(RunState.current_health, RunState.max_health)
		"damage":
			RunState.player_damage = clampi(value, 1, 999)
		"fire_rate":
			RunState.fire_rate_level = clampi(value, 0, 99)
		"gold":
			RunState.gold = clampi(value, 0, 999999)
			RunState.gold_changed.emit(RunState.gold)
		"move_speed":
			RunState.move_speed_multiplier = clampf(float(value) / 100.0, 0.1, 20.0)
		"invincibility":
			RunState.bonus_invincibility = maxf(
				float(value) / 10.0 - RunState.BASE_INVINCIBILITY, -RunState.BASE_INVINCIBILITY)
		"ally_count":
			var want := clampi(value, 0, RunState.MAX_ALLIES)
			while RunState.ally_count() > want:
				RunState.ally_roster.pop_back()
			while RunState.ally_count() < want:
				if not RunState.hire_ally():
					break
		"ally_floors":
			var floors := clampi(value, 1, 9)
			for entry in RunState.ally_roster:
				entry["floors_left"] = floors
		"ally_health":
			var health := clampi(value, 1, RunState.ALLY_MAX_HEALTH)
			for entry in RunState.ally_roster:
				entry["health"] = health
	_sync_to_battle()
	if key.begins_with("ally"):
		var battle := _current_battle()
		if battle != null and battle.has_method("debug_respawn_allies"):
			battle.debug_respawn_allies()


func _sync_to_battle() -> void:
	var battle := _current_battle()
	if battle != null:
		battle.debug_sync_run_values()


func _current_battle() -> Node:
	if get_tree() == null:
		return null
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return _find_battle(scene)


func _find_battle(node: Node) -> Node:
	if node.has_method("debug_sync_run_values"):
		return node
	for child in node.get_children():
		var found := _find_battle(child)
		if found != null:
			return found
	return null


# ---------------- 交互 ----------------

func _on_step_pressed(key: String, delta: int) -> void:
	if key == "ally":
		return
	_set_value(key, _get_value(key) + delta)
	_refresh_all()


func _on_box_submitted(text: String, key: String) -> void:
	_apply_box_text(key, text)


func _on_box_focus_exited(key: String) -> void:
	var entry := _entry_of(key)
	if entry != null and entry["box"] is LineEdit:
		_apply_box_text(key, (entry["box"] as LineEdit).text)


func _apply_box_text(key: String, text: String) -> void:
	var trimmed := text.strip_edges()
	if not trimmed.is_valid_int():
		_refresh_all()
		return
	_set_value(key, int(trimmed))
	_refresh_all()


func _input(event: InputEvent) -> void:
	if not _enabled:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.physical_keycode == KEY_F1 or event.keycode == KEY_F1):
		# 调试菜单开着的时候，F1 先关菜单（不然面板会盖在菜单上面）
		if _debug_menu != null and _debug_menu.is_open():
			_debug_menu.close_menu()
		else:
			toggle()
		_mark_handled()
		return
	if not _open:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		close_panel()
		_mark_handled()
		return
	# 正在数值框里打字时，方向键/WASD 交给输入框，不要抢
	if _value_box_has_focus():
		_reset_hold()
		return
	# 键盘自带的回声重复不要（长按的连续移动由 _process 自己算）
	if event is InputEventKey and (event as InputEventKey).echo:
		_mark_handled()
		return
	var nav := _nav_dir_of(event)
	if nav != Vector2i.ZERO:
		_begin_hold(nav)
		_mark_handled()
		return
	if _end_hold_if_released(event):
		_mark_handled()
		return
	if event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		_activate_selected()
		_mark_handled()
		return
	return


## 这一帧的按键是不是方向键（返回方向向量，不是就返回零）
func _nav_dir_of(event: InputEvent) -> Vector2i:
	if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up"):
		return Vector2i(0, -1)
	if event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
		return Vector2i(0, 1)
	if event.is_action_pressed("move_left") or event.is_action_pressed("ui_left"):
		return Vector2i(-1, 0)
	if event.is_action_pressed("move_right") or event.is_action_pressed("ui_right"):
		return Vector2i(1, 0)
	return Vector2i.ZERO


## 按下方向键：立刻动一格，并开始计时（长按会连续移动 / 满 1 秒执行）
func _begin_hold(dir: Vector2i) -> void:
	_hold_dir = dir
	_hold_time = 0.0
	_hold_repeating = false
	_repeat_elapsed = 0.0
	_move_by_dir(dir)


## 松开方向键：结束长按
func _end_hold_if_released(event: InputEvent) -> bool:
	if _hold_dir == Vector2i.ZERO:
		return false
	var released := false
	if _hold_dir.y < 0:
		released = event.is_action_released("move_up") or event.is_action_released("ui_up")
	elif _hold_dir.y > 0:
		released = event.is_action_released("move_down") or event.is_action_released("ui_down")
	elif _hold_dir.x < 0:
		released = event.is_action_released("move_left") or event.is_action_released("ui_left")
	elif _hold_dir.x > 0:
		released = event.is_action_released("move_right") or event.is_action_released("ui_right")
	if released:
		_reset_hold()
	return released


func _reset_hold() -> void:
	_hold_dir = Vector2i.ZERO
	_hold_time = 0.0
	_hold_repeating = false
	_repeat_elapsed = 0.0


func _move_by_dir(dir: Vector2i) -> void:
	if dir.y != 0:
		_move_row(signi(dir.y))
	else:
		_move_col(signi(dir.x))


## 长按：满 1 秒后开始每隔 0.12 秒往那个方向自动挪一格（松手就停，不会执行/按下按钮）
func _process(delta: float) -> void:
	if not _enabled or not _open:
		return
	if _hold_dir == Vector2i.ZERO or _value_box_has_focus():
		return
	_hold_time += delta
	if not _hold_repeating:
		if _hold_time >= HOLD_REPEAT_DELAY:
			_hold_repeating = true
			_repeat_elapsed = 0.0
			_move_by_dir(_hold_dir)
		return
	_repeat_elapsed += delta
	while _repeat_elapsed >= HOLD_REPEAT_INTERVAL:
		_repeat_elapsed -= HOLD_REPEAT_INTERVAL
		_move_by_dir(_hold_dir)


## 按下 F1 面板里的「调试关卡」：先收起面板（解除暂停），再弹出两级调试菜单
## 点「雇佣队友」：面板里直接雇一个（战斗中会同时把队友放出来），
## 雇完下面缩进一格出现 队友A/B/C 的血量 + 剩余层数
func _hire_ally() -> void:
	if not _enabled:
		return
	var battle := _current_battle()
	if battle != null and battle.has_method("debug_hire_ally"):
		battle.debug_hire_ally()
	elif not RunState.hire_ally():
		print("[DebugPanel] 队友已满（最多 %d 个）" % RunState.MAX_ALLIES)
	_refresh_all()


func _on_debug_menu_button_pressed() -> void:
	if not _enabled:
		return
	if _debug_menu == null:
		_debug_menu = load("res://scene/ui/debug_menu.gd").new()
		add_child(_debug_menu)
		_debug_menu.option_selected.connect(_on_debug_menu_option)
		_debug_menu.cancelled.connect(_on_debug_menu_cancelled)
	if _open:
		close_panel()
	_debug_menu.open()


func _on_debug_menu_option(option: String) -> void:
	debug_start_level(option)


## 调试菜单里点「取消 / 返回」或按 ESC 关掉后，重新回到 F1 面板
func _on_debug_menu_cancelled() -> void:
	if not _open:
		open_panel()


## 队友关的启动数据（只做准备、不切场景，方便自检单独调用）
func debug_build_ally_level() -> Dictionary:
	RunState.reset()
	RunState.floor_index = 1
	RunState.hire_ally()
	return {"floor": 1, "node_type": "battle"}


## 调试：直接进指定关卡（面板按钮 / 调试菜单 / 自检都走这里）
func debug_start_level(level_id: String) -> void:
	match level_id:
		"ally":
			print("[DebugPanel] 调试: 进队友关卡（第 1 层普通关 + 1 只队友）")
			GameFlow.start_battle(debug_build_ally_level())
		"boss_floor5":
			print("[DebugPanel] 调试: 进第 5 层 BOSS 关（原/紫随机一只）")
			RunState.reset()
			RunState.floor_index = 5
			GameFlow.start_battle({"floor": 5, "node_type": "boss"})
		"boss_floor10":
			print("[DebugPanel] 调试: 进第 10 层三重 BOSS 关")
			RunState.reset()
			RunState.floor_index = RunState.MAX_FLOOR
			GameFlow.start_battle({"floor": RunState.MAX_FLOOR, "node_type": "boss"})
		_:
			push_warning("[DebugPanel] 未知的调试关卡: %s" % level_id)


func _mark_handled() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func _value_box_has_focus() -> bool:
	for entry in _entries:
		var box = entry["box"]
		if box is LineEdit and (box as LineEdit).has_focus():
			return true
	for row in _ally_row_entries:
		for field in ["health_box", "floors_box"]:
			var box = row.get(field)
			if box is LineEdit and (box as LineEdit).has_focus():
				return true
	return false


func _selected_row() -> Dictionary:
	if _selectable.is_empty():
		return {}
	return _selectable[clampi(_selected, 0, _selectable.size() - 1)]


## W/S：换行（数值行 / 雇佣队友 / 调试关卡都能选到）
func _move_row(step: int) -> void:
	if _selectable.is_empty():
		return
	_selected = wrapi(_selected + step, 0, _selectable.size())
	var buttons: Array = _selectable[_selected]["buttons"]
	_col = clampi(_col, 0, maxi(buttons.size() - 1, 0))
	_refresh_all()


## A/D：换这一行里的按钮（就是"选项左右的位置"）
func _move_col(step: int) -> void:
	var row := _selected_row()
	if row.is_empty():
		return
	var count: int = (row["buttons"] as Array).size()
	if count <= 0:
		return
	_col = wrapi(_col + step, 0, count)
	_refresh_selection()


## E：按下当前选中的按钮
func _activate_selected() -> void:
	var row := _selected_row()
	if row.is_empty():
		return
	var kind := String(row["kind"])
	if kind == "step":
		var deltas: Array = row["deltas"]
		var buttons: Array = row["buttons"]
		var index := clampi(_col, 0, buttons.size() - 1)
		_on_step_pressed(String(row["key"]), int(deltas[index]))
	elif kind == "hire":
		_hire_ally()
	elif kind == "ally":
		var actions: Array = row.get("ally_actions", [])
		if actions.is_empty():
			return
		var action: Array = actions[clampi(_col, 0, actions.size() - 1)]
		_adjust_ally(int(action[0]), String(action[1]), int(action[2]))
	elif kind == "debug_level":
		_on_debug_menu_button_pressed()


func _refresh_all() -> void:
	for index in range(_entries.size()):
		var entry := _entries[index]
		var key := String(entry["key"])
		var name_label := entry["name"] as Label
		var chosen := _row_index_of_key(key) == _selected
		name_label.add_theme_color_override("font_color",
			SELECTED_COLOR if chosen else NORMAL_COLOR)
		name_label.text = ("> " if chosen else "  ") + String(ROWS[index]["label"])
		var box := entry["box"] as LineEdit
		if box != null and not box.has_focus():
			box.text = str(_get_value(key))
	_refresh_ally_rows()
	_refresh_selection()


## 队友A/B/C 子行：名字 + 血量[-1][框][+1] + 剩余层数[-1][框][+1]
## 这些行也进 W/S 选择，A/D 就在 4 个 ±1 按钮之间切（用户要求）
func _refresh_ally_rows() -> void:
	if _ally_box == null:
		return
	var keep_key := debug_selected_key()
	var keep_col := _col
	for node in _ally_rows:
		if node != null and is_instance_valid(node):
			node.queue_free()
	_ally_rows.clear()
	_ally_row_entries.clear()
	# 先把旧的队友行从"可选中行"里摘掉
	var kept: Array[Dictionary] = []
	for row in _selectable:
		if String(row.get("kind", "")) != "ally":
			kept.append(row)
	_selectable = kept
	# 插入位置：调试关卡那行之前（也就是雇佣队友下面）
	var insert_at := _selectable.size()
	for i in range(_selectable.size()):
		if String(_selectable[i]["key"]) == "debug_level":
			insert_at = i
			break

	for index in range(RunState.ally_count()):
		var letter: String = ALLY_LETTERS[index] if index < ALLY_LETTERS.size() else str(index + 1)
		var line := HBoxContainer.new()
		line.name = "AllyRow_%d" % index
		line.add_theme_constant_override("separation", 6)
		var indent := Control.new()
		indent.custom_minimum_size = Vector2(ALLY_ROW_INDENT, 0.0)   # 多缩进一格
		line.add_child(indent)
		line.add_child(_make_ally_label("队友%s" % letter))
		var dismiss_button := _make_dismiss_button(index)
		line.add_child(dismiss_button)
		var spring := Control.new()
		spring.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 把血量/层数顶到右边
		line.add_child(spring)
		line.add_child(_make_ally_label("血量"))
		var health_box := _make_ally_box(index, "health", _ally_health_of(index))
		var floors_box := _make_ally_box(index, "floors", _floors_of(index))
		var health_minus := _make_ally_button(index, "health", -1)
		var health_plus := _make_ally_button(index, "health", 1)
		var floors_minus := _make_ally_button(index, "floors", -1)
		var floors_plus := _make_ally_button(index, "floors", 1)
		line.add_child(health_minus)      # 左 -1
		line.add_child(health_box)        # 中间可交互的框
		line.add_child(health_plus)       # 右 +1
		line.add_child(_make_ally_label("剩余层数"))
		line.add_child(floors_minus)
		line.add_child(floors_box)
		line.add_child(floors_plus)
		_ally_box.add_child(line)
		_ally_rows.append(line)
		var row_entry := {
			"kind": "ally", "key": "ally_%d" % index, "deltas": [],
			"buttons": [dismiss_button, health_minus, health_plus, floors_minus, floors_plus],
			"ally_actions": [[index, "dismiss", 0], [index, "health", -1], [index, "health", 1],
				[index, "floors", -1], [index, "floors", 1]],
			"health_box": health_box, "floors_box": floors_box, "control": line}
		_selectable.insert(insert_at + index, row_entry)
		_ally_row_entries.append(row_entry)

	# 重建后按 key 把选中项找回来（下标会变）
	var new_index := -1
	for i in range(_selectable.size()):
		if String(_selectable[i]["key"]) == keep_key:
			new_index = i
			break
	if new_index >= 0:
		_selected = new_index
		_col = keep_col
	_selected = clampi(_selected, 0, maxi(_selectable.size() - 1, 0))


func _make_ally_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", FONT_ROW - 2)
	label.add_theme_color_override("font_color", ALLY_INFO_COLOR)
	return label


func _make_ally_button(index: int, field: String, delta: int) -> Button:
	var button := Button.new()
	button.text = "%+d" % delta
	button.custom_minimum_size = Vector2(46.0, 28.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", FONT_HINT)
	button.pressed.connect(_adjust_ally.bind(index, field, delta))
	return button


## 「取消雇佣」按钮（放在队友名字后面）
func _make_dismiss_button(index: int) -> Button:
	var button := Button.new()
	button.name = "DismissAlly_%d" % index
	button.text = "取消雇佣"
	button.custom_minimum_size = Vector2(96.0, 28.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", FONT_HINT)
	button.pressed.connect(_dismiss_ally.bind(index))
	return button


## 取消雇佣：从整局名册里移除这只队友（战斗中同时把场上的撤掉）
func _dismiss_ally(index: int) -> void:
	if not _enabled:
		return
	if index < 0 or index >= RunState.ally_roster.size():
		return
	RunState.ally_roster.remove_at(index)
	var battle := _current_battle()
	if battle != null and battle.has_method("debug_respawn_allies"):
		battle.debug_respawn_allies()
	print("[DebugPanel] 取消雇佣：剩 %d 名队友" % RunState.ally_count())
	_refresh_all()


## 可输入的框（血量和剩余层数各一个）
func _make_ally_box(index: int, field: String, value: int) -> LineEdit:
	var box := LineEdit.new()
	box.text = str(value)
	box.alignment = HORIZONTAL_ALIGNMENT_RIGHT      # 数字靠右
	box.custom_minimum_size = Vector2(64.0, 30.0)
	box.add_theme_font_size_override("font_size", FONT_HINT + 2)
	box.text_submitted.connect(_on_ally_box_submitted.bind(index, field))
	box.focus_exited.connect(_on_ally_box_focus_exited.bind(index, field))
	return box


func _on_ally_box_submitted(text: String, index: int, field: String) -> void:
	_apply_ally_box_text(index, field, text)


func _on_ally_box_focus_exited(index: int, field: String) -> void:
	var box := _ally_box_of(index, field)
	# 行被重建时旧框会被释放，别再往上写一遍（否则会来回刷新）
	if box == null or box.is_queued_for_deletion():
		return
	_apply_ally_box_text(index, field, box.text)


func _apply_ally_box_text(index: int, field: String, text: String) -> void:
	var trimmed := text.strip_edges()
	if not trimmed.is_valid_int():
		_refresh_all()
		return
	if field == "health":
		_set_ally_health(index, int(trimmed))
	else:
		_set_ally_floors(index, int(trimmed))
	_refresh_all()


## 场上队友的实时血量（不在战斗里就读整局名册）
func _ally_health_of(index: int) -> int:
	if index < 0 or index >= RunState.ally_roster.size():
		return 0
	var entry: Dictionary = RunState.ally_roster[index]
	var health := int(entry.get("health", 0))
	var battle := _current_battle()
	if battle != null and "_allies" in battle and index < battle._allies.size():
		var ally = battle._allies[index]
		if ally != null and is_instance_valid(ally):
			health = int(ally.current_health)
	return health


func _floors_of(index: int) -> int:
	if index < 0 or index >= RunState.ally_roster.size():
		return 0
	return int(RunState.ally_roster[index].get("floors_left", 0))


func _ally_box_of(index: int, field: String) -> LineEdit:
	var key := "ally_%d" % index
	for row in _ally_row_entries:
		if String(row.get("key", "")) != key:
			continue
		var box = row.get("health_box") if field == "health" else row.get("floors_box")
		return box as LineEdit
	return null


## 队友行上的 -1/+1：血量 / 剩余层数各自独立调
func _adjust_ally(index: int, field: String, delta: int) -> void:
	if not _enabled:
		return
	if field == "dismiss":
		_dismiss_ally(index)
		return
	if field == "health":
		_set_ally_health(index, _ally_health_of(index) + delta)
	else:
		_set_ally_floors(index, _floors_of(index) + delta)
	_refresh_all()


func _set_ally_health(index: int, value: int) -> void:
	if index < 0 or index >= RunState.ally_roster.size():
		return
	var health := clampi(value, 1, RunState.ALLY_MAX_HEALTH)
	RunState.ally_roster[index]["health"] = health
	# 场上的队友也一起改（不重生，直接改节点血量）
	var battle := _current_battle()
	if battle != null and "_allies" in battle and index < battle._allies.size():
		var ally = battle._allies[index]
		if ally != null and is_instance_valid(ally):
			ally.current_health = health
			if ally.has_signal("health_changed"):
				ally.health_changed.emit(health, RunState.ALLY_MAX_HEALTH)


func _set_ally_floors(index: int, value: int) -> void:
	if index < 0 or index >= RunState.ally_roster.size():
		return
	RunState.ally_roster[index]["floors_left"] = clampi(value, 1, 9)


## 选中的那个按钮高亮（A/D 就是在这几个按钮之间来回切）
func _refresh_selection() -> void:
	for row_index in range(_selectable.size()):
		var row := _selectable[row_index]
		var buttons: Array = row["buttons"]
		for i in range(buttons.size()):
			var button := buttons[i] as Button
			if button == null:
				continue
			var chosen := row_index == _selected and i == clampi(_col, 0, maxi(buttons.size() - 1, 0))
			button.add_theme_color_override("font_color",
				SELECTED_COLOR if chosen else NORMAL_COLOR)
	_ensure_selected_visible()


## 选中的行滚进可视范围（行变多了，别让选中项跑到框外）
func _ensure_selected_visible() -> void:
	if _scroll == null:
		return
	var row := _selected_row()
	if row.is_empty():
		return
	var control := row.get("control") as Control
	if control != null and control.is_inside_tree():
		_scroll.ensure_control_visible(control)


func _row_index_of_key(key: String) -> int:
	for index in range(_selectable.size()):
		if String(_selectable[index]["key"]) == key:
			return index
	return -1


func _entry_of(key: String) -> Dictionary:
	for entry in _entries:
		if String(entry["key"]) == key:
			return entry
	return {}


# ---------------- 供 headless 自检调用 ----------------

func debug_is_enabled() -> bool:
	return _enabled


func debug_row_keys() -> Array[String]:
	var keys: Array[String] = []
	for entry in _entries:
		keys.append(String(entry["key"]))
	return keys


func debug_selected_key() -> String:
	var row := _selected_row()
	return String(row.get("key", ""))


func debug_selected_col() -> int:
	return _col


func debug_selectable_keys() -> Array[String]:
	var keys: Array[String] = []
	for row in _selectable:
		keys.append(String(row["key"]))
	return keys


func debug_adjust(key: String, delta: int) -> void:
	_set_value(key, _get_value(key) + delta)
	_refresh_all()


func debug_set(key: String, value: int) -> void:
	_set_value(key, value)
	_refresh_all()
