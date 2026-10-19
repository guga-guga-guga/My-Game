extends CanvasLayer
## 通用对话框（M4-3）：底部对话框 + 打字机 + 选项。纯代码构建，用项目默认像素字体。
##
## 操作（用户指定：交互统一为 E，且用移动键切换选项）：
##   E / 回车     跳过打字 -> 翻下一句 -> 确认当前选项
##   W S / 上下键  切换选项
## 鼠标点击选项同样有效。
## 选完先发 option_selected(index) 再发 closed —— 顺序很重要：
## 中间地图 要在 closed（清空 _active_npc）之前拿到当前角色。

signal option_selected(index: int)
signal closed

const TYPE_SPEED := 45.0             # 打字速度（字/秒）
const TITLE_FONT_SIZE := 30          # 原来 16，用户要求至少翻倍
const BODY_FONT_SIZE := 28           # 原来 14
const OPTION_FONT_SIZE := 28         # 原来 14
const HINT_FONT_SIZE := 20
const BOX_MIN_HEIGHT := 183.0        # 原来 122，用户要求再加高一半
const BOX_SIDE_MARGIN := 80.0
const BOX_BOTTOM_MARGIN := 10.0
const TEXT_MIN_HEIGHT := 48.0        # 正文至少留一行高
const OPTION_WIDTH := 260.0

var _panel: PanelContainer = null
var _title: Label = null
var _text: Label = null
var _option_box: VBoxContainer = null
var _hint: Label = null
var _buttons: Array[Button] = []
var _lines: Array[String] = []
var _line_index := 0
var _typed := 0.0
var _options: Array[String] = []
var _selected := 0
var _options_ready := false
var _open := false
var _open_frame := -1


func is_open() -> bool:
	return _open


func get_selected_index() -> int:
	return _selected


func _ready() -> void:
	layer = 10
	_build_ui()
	visible = false
	set_process(false)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_left = BOX_SIDE_MARGIN
	_panel.offset_right = -BOX_SIDE_MARGIN
	_panel.offset_top = -BOX_MIN_HEIGHT - BOX_BOTTOM_MARGIN
	_panel.offset_bottom = -BOX_BOTTOM_MARGIN
	add_child(_panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.94)
	style.border_color = Color(1.0, 0.87, 0.55, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	_title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	box.add_child(_title)

	_text = Label.new()
	_text.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	_text.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	_text.add_theme_constant_override("line_spacing", 6)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(0, TEXT_MIN_HEIGHT)
	box.add_child(_text)

	_option_box = VBoxContainer.new()
	_option_box.add_theme_constant_override("separation", 4)
	_option_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(_option_box)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", HINT_FONT_SIZE)
	_hint.add_theme_color_override("font_color", Color(0.66, 0.70, 0.74))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(_hint)


func _rebuild_options() -> void:
	for child in _option_box.get_children():
		child.queue_free()
	_buttons.clear()
	_selected = 0
	for index in range(_options.size()):
		var button := Button.new()
		button.add_theme_font_size_override("font_size", OPTION_FONT_SIZE)
		button.focus_mode = Control.FOCUS_NONE      # 焦点导航由本脚本接管（用移动键选）
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(OPTION_WIDTH, 0)
		button.pressed.connect(_on_option_pressed.bind(index))
		_option_box.add_child(button)
		_buttons.append(button)
	_refresh_option_text()


## 选中项前面加 "> " 并高亮（不用 Button 的焦点，避免和移动键双重响应）
func _refresh_option_text() -> void:
	for index in range(_buttons.size()):
		var button := _buttons[index]
		var chosen := index == _selected
		button.text = ("> " if chosen else "  ") + _options[index]
		button.add_theme_color_override("font_color",
			Color(1.0, 0.87, 0.55) if chosen else Color(0.85, 0.86, 0.88))
		button.add_theme_color_override("font_hover_color", Color(1.0, 0.93, 0.70))


func show_dialogue(title_text: String, lines: Array, options: Array) -> void:
	if _open:
		return
	_open = true
	_open_frame = Engine.get_process_frames()
	_lines.clear()
	for line in lines:
		_lines.append(String(line))
	if _lines.is_empty():
		_lines.append("...")
	_line_index = 0
	_typed = 0.0
	_title.text = title_text
	_text.text = _lines[0]
	_text.visible_characters = 0
	_options.clear()
	for option in options:
		_options.append(String(option))
	_rebuild_options()
	_set_options_ready(false)
	_hint.text = "E 跳过"
	visible = true
	set_process(true)


func _set_options_ready(want_ready: bool) -> void:
	if _options_ready == want_ready:
		return
	_options_ready = want_ready
	_option_box.modulate = Color(1, 1, 1, 1) if want_ready else Color(1, 1, 1, 0.30)
	for button in _buttons:
		button.disabled = not want_ready


## 面板高度跟着内容走（至少 BOX_MIN_HEIGHT），从底部往上长
func _fit_height() -> void:
	if _panel == null:
		return
	var needed: float = _panel.get_combined_minimum_size().y + 4.0
	var height := maxf(BOX_MIN_HEIGHT, needed)
	if absf(-_panel.offset_top - BOX_BOTTOM_MARGIN - height) > 0.5:
		_panel.offset_top = -height - BOX_BOTTOM_MARGIN


func _process(delta: float) -> void:
	if not _open:
		return
	_fit_height()
	if _is_typing():
		_typed += delta * TYPE_SPEED
		_text.visible_characters = int(_typed)
		if _is_typing():
			_hint.text = "E 跳过"
			return
		_text.visible_characters = -1
	if _line_index < _lines.size() - 1:
		_hint.text = "E 继续"                 # 还有下一句，等玩家按 E
		_set_options_ready(false)
		return
	_hint.text = "W/S 选择   E 确定" if _options.size() > 0 else "E 关闭"
	_set_options_ready(true)


func _is_typing() -> bool:
	return _text.visible_characters >= 0 and _text.visible_characters < _text.text.length()


## E / 回车：先跳过打字，再翻句，最后确认选项
func _confirm() -> void:
	if not _open:
		return
	if _is_typing():
		_text.visible_characters = -1
		return
	if _line_index < _lines.size() - 1:
		_line_index += 1
		_text.text = _lines[_line_index]
		_text.visible_characters = 0
		_typed = 0.0
		_set_options_ready(false)
		return
	if _options.size() > 0:
		_activate(_selected)
	else:
		_close()


func _activate(index: int) -> void:
	if _options.is_empty():
		_close()
		return
	var chosen := clampi(index, 0, _options.size() - 1)
	_selected = chosen
	SfxPlayer.ui_click()
	option_selected.emit(chosen)      # 先发选项（中间地图 此时还能读到 _active_npc）
	_close()


func _on_option_pressed(index: int) -> void:
	_activate(index)


## W/S、上下键切换选项（循环）
func _move_selection(step: int) -> void:
	if _buttons.is_empty() or not _options_ready:
		return
	_selected = wrapi(_selected + step, 0, _buttons.size())
	_refresh_option_text()


func _unhandled_input(event: InputEvent) -> void:
	if not _open or Engine.get_process_frames() == _open_frame:
		return                              # 开对话那一下的 E 不要立刻被吃掉
	if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up"):
		_move_selection(-1)
	elif event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
		_move_selection(1)
	elif event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		_confirm()
	else:
		return
	# 注意：_confirm() 里可能触发「进入关卡」-> 切场景，本节点会被摘出场景树，
	# 此时 get_viewport() 返回 null。必须判空，否则报错 + 调试器断点会把游戏卡住。
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func _close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	set_process(false)
	closed.emit()


# ---------------- 供 headless 自检调用 ----------------

func debug_confirm() -> void:
	_confirm()


func debug_move(step: int) -> void:
	_move_selection(step)
