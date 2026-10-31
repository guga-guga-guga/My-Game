extends CanvasLayer
## 设置面板（标题页「设置」按钮打开）
##
## 三行设置：
##   1) 分辨率：平时只显示当前值，点一下展开所有选项（含"全屏"），选完自动收起
##   2) 背景音量：-/+ 每次 5%，改完立刻生效
##   3) 射击操作：键盘射击 / 鼠标射击，严格二选一
## 操作：W/S 选行，A/D 或左右键改值，E 展开/确定，ESC 关闭；鼠标也能直接点

signal closed

const CursorEditorScript = preload("res://scene/ui/cursor_editor.gd")

const FONT_TITLE := 34
const FONT_ROW := 22
const FONT_HINT := 16
const PANEL_WIDTH := 760.0
const PANEL_HEIGHT := 420.0
const COLOR_TITLE := Color(1.0, 0.87, 0.55)
const COLOR_TEXT := Color(0.88, 0.89, 0.92)
const COLOR_HINT := Color(0.60, 0.64, 0.68)
const COLOR_SELECTED := Color(1.0, 0.87, 0.55)
const ROW_HEIGHT := 40.0
const FULLSCREEN_OPTION_TEXT := "全屏"
const SHOOT_MODE_TEXTS: Array[String] = ["键盘射击", "鼠标射击"]

var _open := false
var _open_frame := -1
var _root: Control = null
var _panel: PanelContainer = null
var _expansion_box: VBoxContainer = null
var _resolution_label: Label = null
var _volume_label: Label = null
var _shoot_labels: Array[Label] = []
var _shoot_title: Label = null
var _cursor_editor: Node = null        ## 自定义光标编辑器（只有鼠标射击时显示）
var _selected := 0
var _expanded := false
var _expand_selected := 0


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	_open_frame = Engine.get_process_frames()
	_selected = 0
	_expanded = false
	visible = true
	_refresh()
	print("[Settings] 设置面板打开")


func _close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	closed.emit()


# ---------------- 界面 ----------------

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	_panel = PanelContainer.new()
	_panel.name = "SettingsPanel"
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.position = Vector2(-PANEL_WIDTH, -PANEL_HEIGHT) * 0.5
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.07, 0.97)
	style.border_color = Color(0.65, 0.85, 1.0, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(24)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_panel.add_child(box)
	_make_label(box, "设置", FONT_TITLE, COLOR_TITLE)

	# ① 分辨率：折叠时只有一行当前值，点它展开
	var resolution_row := _make_row(box, "分辨率")
	_resolution_label = _make_label(resolution_row, "", FONT_ROW, COLOR_TEXT)
	_resolution_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_resolution_label.gui_input.connect(_on_resolution_clicked)
	_resolution_label.mouse_entered.connect(func() -> void: _hover_row(0))
	var resolution_title := resolution_row.get_child(0) as Label
	if resolution_title != null:
		resolution_title.mouse_filter = Control.MOUSE_FILTER_STOP
		resolution_title.mouse_entered.connect(func() -> void: _hover_row(0))
	_expansion_box = VBoxContainer.new()
	_expansion_box.add_theme_constant_override("separation", 4)
	box.add_child(_expansion_box)

	# ② 背景音量
	var volume_row := _make_row(box, "背景音量")
	var minus := _make_click_label(volume_row, "-",
		func() -> void: _change_volume(-GameSettings.VOLUME_STEP))
	minus.mouse_entered.connect(func() -> void: _hover_row(1))
	_volume_label = _make_label(volume_row, "", FONT_ROW, COLOR_TEXT)
	_volume_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_volume_label.mouse_entered.connect(func() -> void: _hover_row(1))
	var plus := _make_click_label(volume_row, "+", func() -> void: _change_volume(GameSettings.VOLUME_STEP))
	plus.mouse_entered.connect(func() -> void: _hover_row(1))
	var volume_title := volume_row.get_child(0) as Label
	if volume_title != null:
		volume_title.mouse_filter = Control.MOUSE_FILTER_STOP
		volume_title.mouse_entered.connect(func() -> void: _hover_row(1))

	# ③ 射击操作（两个选项，点谁选谁）
	var shoot_row := _make_row(box, "射击操作")
	_shoot_title = shoot_row.get_child(0) as Label
	if _shoot_title != null:
		_shoot_title.mouse_filter = Control.MOUSE_FILTER_STOP
		_shoot_title.mouse_entered.connect(func() -> void: _hover_row(2))
	for index in range(SHOOT_MODE_TEXTS.size()):
		var label := _make_click_label(shoot_row, SHOOT_MODE_TEXTS[index],
			func() -> void: _choose_shoot_mode(index))
		label.mouse_entered.connect(func() -> void: _hover_row(2))
		_shoot_labels.append(label)

	# ③.5 自定义光标编辑器：只有选了「鼠标射击」才显示（会撑高面板）
	_cursor_editor = CursorEditorScript.new()
	_cursor_editor.visible = false
	box.add_child(_cursor_editor)

	# ④ 关闭
	var close_row := _make_row(box, "")
	var close_label := _make_click_label(close_row, "关闭", func() -> void: _close())
	close_label.add_theme_color_override("font_color", COLOR_TEXT)
	close_label.mouse_entered.connect(func() -> void: _hover_row(3))
	close_label.mouse_exited.connect(func() -> void: _refresh())

	_make_label(box, "W/S 选行    A/D 改值    E 展开或确认    ESC 关闭", FONT_HINT, COLOR_HINT)


func _make_row(parent: Node, title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	row.add_theme_constant_override("separation", 26)
	parent.add_child(row)
	if not title.is_empty():
		var label := _make_label(row, title, FONT_ROW, COLOR_HINT)
		label.custom_minimum_size = Vector2(150, 0)
	return row


func _make_label(parent: Node, text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _make_click_label(parent: Node, text: String, on_click: Callable) -> Label:
	var label := _make_label(parent, text, FONT_ROW, COLOR_TEXT)
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			on_click.call())
	return label


# ---------------- 刷新 ----------------

func _refresh() -> void:
	_resolution_label.text = ("v  " if _expanded else ">  ") + GameSettings.display_text()
	_resolution_label.add_theme_color_override("font_color",
		COLOR_SELECTED if _selected == 0 else COLOR_TEXT)
	_volume_label.text = "%d%%" % GameSettings.volume_percent
	_volume_label.add_theme_color_override("font_color",
		COLOR_SELECTED if _selected == 1 else COLOR_TEXT)
	# 射击操作：用方框 [xxx] 表示"当前选择的模式"，文字本身不再变黄（避免和行高亮重复）
	if _shoot_title != null:
		_shoot_title.add_theme_color_override("font_color",
			COLOR_SELECTED if _selected == 2 else COLOR_HINT)
	for index in range(_shoot_labels.size()):
		var chosen: bool = GameSettings.is_mouse_shoot() == (index == 1)
		_shoot_labels[index].text = ("[%s]" % SHOOT_MODE_TEXTS[index]) if chosen else (" %s " % SHOOT_MODE_TEXTS[index])
		_shoot_labels[index].add_theme_color_override("font_color", COLOR_TEXT)
	if _cursor_editor != null:
		var want_editor := GameSettings.is_mouse_shoot()
		_cursor_editor.visible = want_editor
		if want_editor:
			# 腾出空间：面板加高（编辑器 32x32 画布按 12 倍显示 = 384 高 + 若干行）
			_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 620.0)
		else:
			_panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	_rebuild_expansion()


func _rebuild_expansion() -> void:
	for child in _expansion_box.get_children():
		child.queue_free()
	_expansion_box.visible = _expanded
	if not _expanded:
		return
	var options := _resolution_options()
	for index in range(options.size()):
		var label := _make_click_label(_expansion_box,
			("* " if index == _expand_selected else "  ") + options[index],
			func() -> void: _choose_expansion(index))
		label.mouse_entered.connect(func() -> void: _hover_expansion(index))
		label.add_theme_color_override("font_color",
			COLOR_SELECTED if index == _expand_selected else COLOR_TEXT)


## 展开后的选项：先是各档分辨率，最后一项是"全屏"开关
func _resolution_options() -> Array[String]:
	var options: Array[String] = []
	for index in range(GameSettings.RESOLUTIONS.size()):
		var suffix := "（当前）" if index == GameSettings.resolution_index and not GameSettings.fullscreen else ""
		options.append(GameSettings.resolution_text(index) + suffix)
	options.append(FULLSCREEN_OPTION_TEXT)                     # 就写"全屏"，不带括号注释
	return options


func _choose_expansion(index: int) -> void:
	_expand_selected = index
	if index < GameSettings.RESOLUTIONS.size():
		GameSettings.set_fullscreen(false)
		GameSettings.set_resolution_index(index)
	else:
		GameSettings.set_fullscreen(not GameSettings.fullscreen)
	_expanded = false
	_refresh()


## 鼠标移到哪一行，就把"当前选中行"挪过去（这样黄框也会跟着鼠标走）
func _hover_row(row: int) -> void:
	if _expanded and row == 0:
		return                                    # 展开列表时，悬停第一行不收起也不换行
	if _selected == row:
		return
	_selected = row
	_refresh()


## 展开列表里：鼠标悬停哪一项就选哪一项
func _hover_expansion(index: int) -> void:
	if not _expanded or _expand_selected == index:
		return
	_expand_selected = index
	_refresh()


func _change_volume(step: int) -> void:
	GameSettings.set_volume_percent(GameSettings.volume_percent + step)
	_refresh()


func _choose_shoot_mode(index: int) -> void:
	GameSettings.set_shoot_mode(GameSettings.SHOOT_MODE_MOUSE if index == 1
		else GameSettings.SHOOT_MODE_KEYBOARD)
	_refresh()


func _on_resolution_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_selected = 0
		_expanded = not _expanded
		_expand_selected = GameSettings.RESOLUTIONS.size() if GameSettings.fullscreen else GameSettings.resolution_index
		_refresh()


# ---------------- 键盘操作 ----------------

func _handle_event(event: InputEvent) -> bool:
	if not _open:
		return false
	var option_count := _resolution_options().size()
	if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up"):
		if _expanded:
			_expand_selected = wrapi(_expand_selected - 1, 0, option_count)
		else:
			_selected = wrapi(_selected - 1, 0, 4)
		_refresh()
		return true
	if event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
		if _expanded:
			_expand_selected = wrapi(_expand_selected + 1, 0, option_count)
		else:
			_selected = wrapi(_selected + 1, 0, 4)
		_refresh()
		return true
	if event.is_action_pressed("move_left") or event.is_action_pressed("ui_left"):
		if not _expanded and _selected == 1:
			_change_volume(-GameSettings.VOLUME_STEP)
			return true
		if not _expanded and _selected == 2:
			_choose_shoot_mode(0)
			return true
		return false
	if event.is_action_pressed("move_right") or event.is_action_pressed("ui_right"):
		if not _expanded and _selected == 1:
			_change_volume(GameSettings.VOLUME_STEP)
			return true
		if not _expanded and _selected == 2:
			_choose_shoot_mode(1)
			return true
		return false
	if event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		if Engine.get_process_frames() == _open_frame:
			return false                      # 打开面板那一下的 E 不要立刻生效
		if _expanded:
			_choose_expansion(_expand_selected)
		elif _selected == 0:
			_expanded = true
			_expand_selected = GameSettings.RESOLUTIONS.size() if GameSettings.fullscreen \
				else GameSettings.resolution_index
			_refresh()
		elif _selected == 3:
			_close()
		return true
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		if _expanded:
			_expanded = false
			_refresh()
		else:
			_close()
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if not _handle_event(event):
		return
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


# ---------------- 供自检调用 ----------------

func debug_select(row: int) -> void:
	_selected = row
	_refresh()


func debug_expand() -> void:
	_selected = 0
	_expanded = true
	_expand_selected = GameSettings.RESOLUTIONS.size() if GameSettings.fullscreen else GameSettings.resolution_index
	_refresh()


func debug_is_expanded() -> bool:
	return _expanded


func debug_options() -> Array[String]:
	return _resolution_options()


func debug_choose(index: int) -> void:
	_choose_expansion(index)


func debug_selected_row() -> int:
	return _selected


func debug_resolution_text() -> String:
	return _resolution_label.text


func debug_volume_text() -> String:
	return _volume_label.text
