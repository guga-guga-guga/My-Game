extends CanvasLayer
## 调试菜单（只在调试构建里由标题上的「调试」按钮打开）
## 两项：调试队友关卡（第 1 层普通关 + 固定一只队友）/ 调试BOSS关卡（第 10 层三重 BOSS）

signal option_selected(option: String)
signal closed

const FONT_TITLE := 32
const FONT_BODY := 26
const FONT_HINT := 18
const OPTIONS: Array[Dictionary] = [
	{"id": "ally", "text": "调试队友关卡", "hint": "第 1 层普通关 + 固定一只队友"},
	{"id": "boss", "text": "调试BOSS关卡", "hint": "第 10 层：原 BOSS + 紫色 BOSS x2"},
	{"id": "cancel", "text": "取消", "hint": "关掉这个窗口"},
]

var _rows: Array[Label] = []
var _selected := 0
var _open := false
var _open_frame := -1


func is_open() -> bool:
	return _open


func _ready() -> void:
	layer = 25
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
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
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size = Vector2(460.0, 0.0)
	panel.add_child(box)
	var title := Label.new()
	title.text = "调试"
	title.add_theme_font_size_override("font_size", FONT_TITLE)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	for index in range(OPTIONS.size()):
		var row := Label.new()
		row.add_theme_font_size_override("font_size", FONT_BODY)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.gui_input.connect(_on_row_gui_input.bind(index))
		box.add_child(row)
		_rows.append(row)
		var hint := Label.new()
		hint.text = "    " + String(OPTIONS[index]["hint"])
		hint.add_theme_font_size_override("font_size", FONT_HINT)
		hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.70))
		box.add_child(hint)
	var foot := Label.new()
	foot.text = "W/S 选择   E 确定   ESC 取消"
	foot.add_theme_font_size_override("font_size", FONT_HINT)
	foot.add_theme_color_override("font_color", Color(0.62, 0.66, 0.70))
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(foot)
	_refresh()


func open() -> void:
	if _open:
		return
	_open = true
	_open_frame = Engine.get_process_frames()
	_selected = 0
	visible = true
	_refresh()
	print("[DebugMenu] 已打开")


func _refresh() -> void:
	for index in range(_rows.size()):
		var chosen := index == _selected
		_rows[index].text = ("> " if chosen else "  ") + String(OPTIONS[index]["text"])
		_rows[index].add_theme_color_override("font_color", Color(1.0, 0.87, 0.55) if chosen else Color(0.88, 0.89, 0.92))


func _close(option: String) -> void:
	if not _open:
		return
	_open = false
	visible = false
	closed.emit()
	if option != "cancel":
		option_selected.emit(option)


func _confirm() -> void:
	_close(String(OPTIONS[_selected]["id"]))


func _move(step: int) -> void:
	_selected = wrapi(_selected + step, 0, OPTIONS.size())
	_refresh()


func _on_row_gui_input(event: InputEvent, index: int) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	_selected = index
	_refresh()
	_confirm()


func _unhandled_input(event: InputEvent) -> void:
	if not _open or Engine.get_process_frames() == _open_frame:
		return
	if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up"):
		_move(-1)
	elif event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
		_move(1)
	elif event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		_confirm()
	elif event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		_close("cancel")
	else:
		return
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


# ---------------- 供 headless 自检调用 ----------------

func debug_selected_id() -> String:
	return String(OPTIONS[_selected]["id"])


func debug_row_texts() -> Array[String]:
	var texts: Array[String] = []
	for row in _rows:
		texts.append(row.text)
	return texts
