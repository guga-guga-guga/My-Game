extends CanvasLayer
## 通用对话框（M4-3）：底部对话框 + 打字机 + 选项列表。纯代码构建，自动用项目默认像素字体。
## 用法：show_dialogue(标题, [正文...], [选项...])；玩家选完发 option_selected(index)。

signal option_selected(index: int)
signal closed

const TYPE_SPEED := 45.0          # 打字速度（字/秒）

var _panel: PanelContainer = null
var _title: Label = null
var _text: Label = null
var _option_box: VBoxContainer = null
var _lines: Array[String] = []
var _line_index := 0
var _typed := 0.0
var _options: Array[String] = []
var _open := false


func is_open() -> bool:
	return _open


func _ready() -> void:
	layer = 10
	_build_ui()
	visible = false
	set_process(false)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_left = 48.0
	_panel.offset_right = -48.0
	_panel.offset_top = -132.0
	_panel.offset_bottom = -10.0
	add_child(_panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.93)
	style.border_color = Color(1.0, 0.87, 0.55, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	_panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	_panel.add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 16)
	_title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	box.add_child(_title)
	_text = Label.new()
	_text.add_theme_font_size_override("font_size", 14)
	_text.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.custom_minimum_size = Vector2(0, 32)
	box.add_child(_text)
	_option_box = VBoxContainer.new()
	_option_box.add_theme_constant_override("separation", 2)
	box.add_child(_option_box)


func show_dialogue(title_text: String, lines: Array, options: Array) -> void:
	if _open:
		return
	_open = true
	_lines.clear()
	for line in lines:
		_lines.append(String(line))
	if _lines.is_empty():
		_lines.append("……")
	_line_index = 0
	_typed = 0.0
	_title.text = title_text
	_text.text = _lines[0]
	_text.visible_characters = 0
	_options.clear()
	for option in options:
		_options.append(String(option))
	_rebuild_options()
	_option_box.visible = false          # 先打完字再给选项
	visible = true
	set_process(true)


func _rebuild_options() -> void:
	for child in _option_box.get_children():
		child.queue_free()
	for index in range(_options.size()):
		var button := Button.new()
		button.text = _options[index]
		button.add_theme_font_size_override("font_size", 14)
		button.pressed.connect(_on_option_pressed.bind(index))
		_option_box.add_child(button)


func _process(delta: float) -> void:
	# 打字机：按 TYPE_SPEED 逐字显示；按 interact / ui_accept 可跳过
	if _text.visible_characters < _text.text.length():
		var skip := Input.is_action_just_pressed("interact") or Input.is_action_just_pressed("ui_accept")
		if skip:
			_text.visible_characters = -1
		else:
			_typed += delta * TYPE_SPEED
			_text.visible_characters = int(_typed)
		if _text.visible_characters < _text.text.length():
			return
	# 打完字：显示选项并聚焦第一个
	if not _option_box.visible:
		_option_box.visible = true
		if _option_box.get_child_count() > 0:
			(_option_box.get_child(0) as Button).grab_focus()


func _on_option_pressed(index: int) -> void:
	var selected := index
	_close()
	option_selected.emit(selected)


func _close() -> void:
	_open = false
	visible = false
	set_process(false)
	closed.emit()
