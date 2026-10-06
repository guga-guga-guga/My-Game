extends CanvasLayer
## 调试菜单（只在调试构建里用；由 F1 调试面板的「调试关卡」按钮打开）
## 一级弹窗：调试队友关卡 / 调试BOSS关卡 / 取消
## 选「调试BOSS关卡」-> 弹出第二个弹窗：第 5 关 BOSS / 第 10 关 三重 BOSS，底部居中一个「返回」按钮

signal option_selected(option: String)
signal closed
## 用「取消 / 返回 / ESC」关掉菜单时额外发一次（F1 面板靠它重新弹回来）
signal cancelled

const FONT_TITLE := 32
const FONT_BODY := 26
const FONT_HINT := 18

## 一级弹窗
const MAIN_OPTIONS: Array[Dictionary] = [
	{"id": "ally", "text": "调试队友关卡", "hint": "第 1 层普通关 + 固定一只队友"},
	{"id": "boss", "text": "调试BOSS关卡", "hint": "选一只 BOSS 单独试打"},
	{"id": "cancel", "text": "取消", "hint": "关掉这个窗口"},
]

## 二级弹窗（调试 BOSS 关卡）
const BOSS_OPTIONS: Array[Dictionary] = [
	{"id": "boss_floor5", "text": "第 5 关 BOSS", "hint": "原 BOSS / 紫 BOSS 随机一只"},
	{"id": "boss_floor10", "text": "第 10 关 三重 BOSS", "hint": "同场 3 只 BOSS"},
]

var _rows: Array[Label] = []          ## 一级选项文字
var _boss_rows: Array[Label] = []     ## 二级选项文字
var _main_panel: PanelContainer = null
var _boss_panel: PanelContainer = null
var _back_button: Button = null
var _level := 1                       ## 1=一级弹窗 2=二级弹窗
var _selected := 0
var _open := false
var _open_frame := -1
var _paused_before := false


func is_open() -> bool:
	return _open


func _ready() -> void:
	layer = 25
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


## 造一个居中的半透明弹窗面板（一级/二级各一个）
func _make_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.96)
	style.border_color = Color(0.75, 0.80, 0.88, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_title(text: String) -> Label:
	var title := Label.new()
	title.text = text
	title.add_theme_font_size_override("font_size", FONT_TITLE)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return title


func _make_hint(text: String) -> Label:
	var hint := Label.new()
	hint.text = text
	hint.add_theme_font_size_override("font_size", FONT_HINT)
	hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.70))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return hint


func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# ---- 一级弹窗 ----
	_main_panel = _make_panel()
	var main_box := VBoxContainer.new()
	main_box.add_theme_constant_override("separation", 8)
	main_box.custom_minimum_size = Vector2(460.0, 0.0)
	_main_panel.add_child(main_box)
	main_box.add_child(_make_title("调试"))
	for index in range(MAIN_OPTIONS.size()):
		var row := Label.new()
		row.add_theme_font_size_override("font_size", FONT_BODY)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_on_row_gui_input.bind(index))
		main_box.add_child(row)
		_rows.append(row)
		main_box.add_child(_make_hint("    " + String(MAIN_OPTIONS[index]["hint"])))
	main_box.add_child(_make_hint("W/S 选择   E 确定   ESC 取消"))

	# ---- 二级弹窗（选「调试BOSS关卡」后弹出）----
	_boss_panel = _make_panel()
	var boss_box := VBoxContainer.new()
	boss_box.add_theme_constant_override("separation", 12)
	boss_box.custom_minimum_size = Vector2(460.0, 0.0)
	_boss_panel.add_child(boss_box)
	boss_box.add_child(_make_title("调试 BOSS 关卡"))
	var boss_row_box := HBoxContainer.new()
	boss_row_box.alignment = BoxContainer.ALIGNMENT_CENTER
	boss_row_box.add_theme_constant_override("separation", 28)
	boss_box.add_child(boss_row_box)
	for index in range(BOSS_OPTIONS.size()):
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 4)
		column.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		boss_row_box.add_child(column)
		var boss_row := Label.new()
		boss_row.add_theme_font_size_override("font_size", FONT_BODY)
		boss_row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		boss_row.mouse_filter = Control.MOUSE_FILTER_STOP
		boss_row.gui_input.connect(_on_boss_row_gui_input.bind(index))
		column.add_child(boss_row)
		_boss_rows.append(boss_row)
		column.add_child(_make_hint(String(BOSS_OPTIONS[index]["hint"])))
	# 底部居中：返回上一级
	_back_button = Button.new()
	_back_button.name = "BackButton"
	_back_button.text = "返回"
	_back_button.custom_minimum_size = Vector2(160, 42)
	_back_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_back_button.focus_mode = Control.FOCUS_NONE
	_back_button.add_theme_font_size_override("font_size", FONT_BODY)
	_back_button.pressed.connect(_back)
	boss_box.add_child(_back_button)
	boss_box.add_child(_make_hint("W/S 选择   E 确定   ESC 返回"))

	_refresh()


func open() -> void:
	if _open:
		return
	_open = true
	_open_frame = Engine.get_process_frames()
	_level = 1
	_selected = 0
	# 菜单开着时保持整局暂停：既不会在背后继续跑，游戏界面也不会抢 W/S/E
	_paused_before = get_tree().paused
	get_tree().paused = true
	visible = true
	_refresh()
	print("[DebugMenu] 已打开（游戏暂停）")


## 当前弹窗层级对应的选项 / 文字行
func _current_options() -> Array[Dictionary]:
	if _level == 1:
		return MAIN_OPTIONS
	return BOSS_OPTIONS


func _current_rows() -> Array[Label]:
	if _level == 1:
		return _rows
	return _boss_rows


func _refresh() -> void:
	var options := _current_options()
	var rows := _current_rows()
	for index in range(rows.size()):
		var chosen := index == _selected
		rows[index].text = ("> " if chosen else "  ") + String(options[index]["text"])
		rows[index].add_theme_color_override("font_color", Color(1.0, 0.87, 0.55) if chosen else Color(0.88, 0.89, 0.92))
	# 一次只显示一个弹窗
	_main_panel.visible = _level == 1
	_boss_panel.visible = _level == 2


func _close(option: String) -> void:
	if not _open:
		return
	_open = false
	visible = false
	get_tree().paused = _paused_before     # 关掉时恢复原来的暂停状态
	closed.emit()
	if option == "cancel":
		cancelled.emit()
	else:
		option_selected.emit(option)


func _confirm() -> void:
	var options := _current_options()
	var id := String(options[_selected]["id"])
	# 一级选到「调试BOSS关卡」-> 弹出第二个弹窗，不关闭菜单
	if _level == 1 and id == "boss":
		_level = 2
		_selected = 0
		_refresh()
		return
	_close(id)


## 供 F1 面板调用：二级退回一级，一级才真的关闭
func close_menu() -> void:
	_back()


## 返回键 / 二级的「返回」按钮：二级退回一级，一级才真的关闭
func _back() -> void:
	if _level == 2:
		_level = 1
		_selected = 1   # 回到一级的「调试BOSS关卡」，方便再改
		_refresh()
		return
	_close("cancel")


func _move(step: int) -> void:
	var options := _current_options()
	_selected = wrapi(_selected + step, 0, options.size())
	_refresh()


func _on_row_gui_input(event: InputEvent, index: int) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	_selected = index
	_refresh()
	_confirm()


func _on_boss_row_gui_input(event: InputEvent, index: int) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	_selected = index
	_refresh()
	_confirm()


func _unhandled_input(event: InputEvent) -> void:
	if not _open or Engine.get_process_frames() == _open_frame:
		return
	if (event.is_action_pressed("move_up") or event.is_action_pressed("ui_up")
			or event.is_action_pressed("move_left") or event.is_action_pressed("ui_left")):
		_move(-1)
	elif (event.is_action_pressed("move_down") or event.is_action_pressed("ui_down")
			or event.is_action_pressed("move_right") or event.is_action_pressed("ui_right")):
		_move(1)
	elif event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		_confirm()
	elif event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		_back()
	else:
		return
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


# ---------------- 供 headless 自检调用 ----------------

func debug_level() -> int:
	return _level


func debug_selected_id() -> String:
	var options := _current_options()
	return String(options[_selected]["id"])


func debug_row_texts() -> Array[String]:
	var texts: Array[String] = []
	for row in _current_rows():
		texts.append(row.text)
	return texts


func debug_main_row_texts() -> Array[String]:
	var texts: Array[String] = []
	for row in _rows:
		texts.append(row.text)
	return texts


func debug_boss_row_texts() -> Array[String]:
	var texts: Array[String] = []
	for row in _boss_rows:
		texts.append(row.text)
	return texts
