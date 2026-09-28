extends CanvasLayer
## 暂停菜单（ESC）：继续游戏 / 回到主界面
## 打开时暂停整棵场景树（战斗倒计时/时间条都停住），菜单自己 PROCESS_MODE_ALWAYS 继续响应。
## 操作：W/S 或上下键选择，E 或回车确认，ESC 直接继续游戏；鼠标点击选项也能用。
## 只有在"没有别的界面打开"时才会被叫出来（商店/对话/汇报的 ESC 优先关它们自己）。

signal closed
signal quit_to_title_requested

const FONT_TITLE := 40
const FONT_BODY := 28
const FONT_HINT := 20
const OPTIONS: Array[String] = ["继续游戏", "回到主界面"]

var _rows: Array[Label] = []
var _selected := 0
var _open := false
var _open_frame := -1


func is_open() -> bool:
	return _open


func _ready() -> void:
	layer = 20
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
	box.add_theme_constant_override("separation", 10)
	box.custom_minimum_size = Vector2(420.0, 0.0)
	panel.add_child(box)

	var title := Label.new()
	title.text = "暂停"
	title.add_theme_font_size_override("font_size", FONT_TITLE)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	for index in range(OPTIONS.size()):
		var label := Label.new()
		label.add_theme_font_size_override("font_size", FONT_BODY)
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.gui_input.connect(_on_row_gui_input.bind(index))
		box.add_child(label)
		_rows.append(label)

	var hint := Label.new()
	hint.text = "W/S 选择   E 确定   ESC 继续游戏"
	hint.add_theme_font_size_override("font_size", FONT_HINT)
	hint.add_theme_color_override("font_color", Color(0.66, 0.70, 0.74))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	_refresh()


func open() -> void:
	if _open:
		return
	_open = true
	_open_frame = Engine.get_process_frames()
	_selected = 0
	visible = true
	_refresh()
	get_tree().paused = true                 # 暂停整局：倒计时也停
	print("[Pause] 暂停菜单打开（游戏已暂停）")


func _refresh() -> void:
	for index in range(_rows.size()):
		var chosen := index == _selected
		_rows[index].text = ("> " if chosen else "  ") + OPTIONS[index]
		_rows[index].add_theme_color_override("font_color",
			Color(1.0, 0.87, 0.55) if chosen else Color(0.88, 0.89, 0.92))


func _close(quit_to_title: bool) -> void:
	if not _open:
		return
	_open = false
	visible = false
	get_tree().paused = false
	closed.emit()
	print("[Pause] 暂停菜单关闭（回到主界面=%s）" % str(quit_to_title))
	if quit_to_title:
		quit_to_title_requested.emit()


func _confirm() -> void:
	_close(_selected == 1)


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
		_close(false)
	else:
		return
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


# ---------------- 供 headless 自检调用 ----------------

func debug_selected_index() -> int:
	return _selected


func debug_row_texts() -> Array[String]:
	var texts: Array[String] = []
	for row in _rows:
		texts.append(row.text)
	return texts
