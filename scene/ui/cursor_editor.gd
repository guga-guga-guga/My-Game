extends VBoxContainer
## 自定义光标编辑器（嵌在设置面板里，只有选了「鼠标射击」才显示）
##
## 左边：32x32 画布，左键上色、右键擦除（按住拖动可以连续画）
## 右边：调色板，颜色全部取自 resources/texture/palette.png
## 下面：「保持设置」（存下来并立刻生效）/「暂存设置」（存成命名预设）/
##        光标选择下拉（第一项是默认倒三角，后面是暂存的光标）

signal canvas_changed

const PALETTE_PATH := "res://resources/texture/palette.png"
const CursorZoomScript := preload("res://scene/ui/cursor_zoom_panel.gd")
const CANVAS_SIZE := 32
const CANVAS_ZOOM := 6                      ## 画布上每个像素显示成 6x6（32x32 -> 192x192）
const PALETTE_COLUMNS := 12
const SWATCH_SIZE := 12.0
const FONT_ROW := 20
const FONT_HINT := 15
const COLOR_TEXT := Color(0.88, 0.89, 0.92)
const COLOR_HINT := Color(0.60, 0.64, 0.68)
const COLOR_SELECTED := Color(1.0, 0.87, 0.55)

var canvas_image: Image = null
var current_color := Color(1.0, 0.0, 0.0, 1.0)
var palette_colors: Array[Color] = []

var _canvas: Control = null
var _palette: Control = null
var _naming_row: HBoxContainer = null
var _name_edit: LineEdit = null
var _message: Label = null
var _cursor_label: Label = null
var _cursor_list: VBoxContainer = null
var _cursor_expanded := false

var _zoom_panel = null
var _dragging := false
var _erase_drag := false


func _ready() -> void:
	_load_palette()
	canvas_image = GameSettings.cursor_canvas_image()
	add_theme_constant_override("separation", 10)
	_build_ui()


func _load_palette() -> void:
	var texture := load(PALETTE_PATH) as Texture2D
	if texture == null:
		palette_colors.append(Color(1, 1, 1, 1))
		return
	var image := texture.get_image()
	if image.is_compressed():
		image.decompress()
	var counts := {}
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := image.get_pixel(x, y)
			if color.a < 0.2:
				continue
			color.a = 1.0
			counts[color] = int(counts.get(color, 0)) + 1
	var keys := counts.keys()
	keys.sort_custom(func(a: Color, b: Color) -> bool: return int(counts[a]) > int(counts[b]))
	for key in keys:
		palette_colors.append(key)


func _build_ui() -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 20)
	add_child(top)

	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(CANVAS_SIZE * CANVAS_ZOOM, CANVAS_SIZE * CANVAS_ZOOM)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_canvas)
	_canvas.gui_input.connect(_on_canvas_input)
	top.add_child(_canvas)

	# 画布右边一列：放大按钮
	var canvas_side := VBoxContainer.new()
	canvas_side.add_theme_constant_override("separation", 8)
	top.add_child(canvas_side)
	var zoom_button := _make_button("放大", _on_zoom)
	zoom_button.custom_minimum_size = Vector2(90.0, 34.0)
	canvas_side.add_child(zoom_button)

	_palette = Control.new()
	_palette.custom_minimum_size = Vector2(PALETTE_COLUMNS * SWATCH_SIZE, 12.0 * SWATCH_SIZE)
	_palette.mouse_filter = Control.MOUSE_FILTER_STOP
	_palette.draw.connect(_draw_palette)
	_palette.gui_input.connect(_on_palette_input)
	top.add_child(_palette)

	# 按钮行
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 18)
	add_child(buttons)
	buttons.add_child(_make_button("保持设置", _on_keep))
	buttons.add_child(_make_button("暂存设置", _on_stash))
	buttons.add_child(_make_button("读取设置", _on_load))

	# 命名行（点「暂存设置」才出现）
	_naming_row = HBoxContainer.new()
	_naming_row.add_theme_constant_override("separation", 12)
	_naming_row.visible = false
	add_child(_naming_row)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "给这个光标起个名字（最多 12 字）"
	_name_edit.max_length = GameSettings.CURSOR_NAME_MAX
	_name_edit.custom_minimum_size = Vector2(320.0, 34.0)
	_naming_row.add_child(_name_edit)
	_naming_row.add_child(_make_button("确定", _on_name_confirm))
	_naming_row.add_child(_make_button("取消", func() -> void: _naming_row.visible = false))

	# 光标选择（折叠式，和分辨率同款交互）
	_cursor_label = Label.new()
	_cursor_label.add_theme_font_size_override("font_size", FONT_ROW)
	_cursor_label.add_theme_color_override("font_color", COLOR_TEXT)
	_cursor_label.mouse_filter = Control.MOUSE_FILTER_STOP
	_cursor_label.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_cursor_expanded = not _cursor_expanded
			_refresh())
	add_child(_cursor_label)
	_cursor_list = VBoxContainer.new()
	_cursor_list.add_theme_constant_override("separation", 2)
	add_child(_cursor_list)

	_message = Label.new()
	_message.add_theme_font_size_override("font_size", FONT_HINT)
	_message.add_theme_color_override("font_color", COLOR_HINT)
	add_child(_message)
	_refresh()


func _make_button(text: String, on_press: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(130.0, 34.0)
	button.add_theme_font_size_override("font_size", FONT_ROW)
	button.pressed.connect(on_press)
	return button


# ---------------- 画布 ----------------

func _draw_canvas() -> void:
	# 棋盘格底 + 已画好的像素
	for y in range(CANVAS_SIZE):
		for x in range(CANVAS_SIZE):
			var base := Color(0.16, 0.16, 0.18) if (x + y) % 2 == 0 else Color(0.22, 0.22, 0.24)
			var pixel := canvas_image.get_pixel(x, y)
			if pixel.a > 0.01:
				base = pixel
			_canvas.draw_rect(Rect2(x * CANVAS_ZOOM, y * CANVAS_ZOOM, CANVAS_ZOOM, CANVAS_ZOOM), base)
	# 中线（画布正中 = 准星热点）
	var mid := CANVAS_SIZE * CANVAS_ZOOM * 0.5
	_canvas.draw_line(Vector2(mid, 0), Vector2(mid, CANVAS_SIZE * CANVAS_ZOOM),
		Color(1.0, 1.0, 1.0, 0.18))
	_canvas.draw_line(Vector2(0, mid), Vector2(CANVAS_SIZE * CANVAS_ZOOM, mid),
		Color(1.0, 1.0, 1.0, 0.18))
	_canvas.draw_rect(Rect2(0, 0, CANVAS_SIZE * CANVAS_ZOOM, CANVAS_SIZE * CANVAS_ZOOM),
		Color(0.65, 0.85, 1.0, 0.8), false, 2.0)


func _canvas_cell(local: Vector2) -> Vector2i:
	return Vector2i(int(floor(local.x / CANVAS_ZOOM)), int(floor(local.y / CANVAS_ZOOM)))


func _in_canvas(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < CANVAS_SIZE and cell.y < CANVAS_SIZE


func _on_canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index == MOUSE_BUTTON_LEFT or mouse.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mouse.pressed
			_erase_drag = mouse.button_index == MOUSE_BUTTON_RIGHT
			if mouse.pressed:
				_paint_at(mouse.position, _erase_drag)
			_canvas.accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_paint_at((event as InputEventMouseMotion).position, _erase_drag)
		_canvas.accept_event()


func _paint_at(local: Vector2, erase: bool) -> void:
	var cell := _canvas_cell(local)
	if not _in_canvas(cell):
		return
	canvas_image.set_pixel(cell.x, cell.y, Color(0, 0, 0, 0) if erase else current_color)
	_canvas.queue_redraw()
	canvas_changed.emit()


# ---------------- 调色板 ----------------

func _draw_palette() -> void:
	for index in range(palette_colors.size()):
		var col := index % PALETTE_COLUMNS
		var row := index / PALETTE_COLUMNS
		var rect := Rect2(col * SWATCH_SIZE, row * SWATCH_SIZE, SWATCH_SIZE, SWATCH_SIZE)
		_palette.draw_rect(rect, palette_colors[index])
		if palette_colors[index].is_equal_approx(current_color):
			_palette.draw_rect(rect, Color(1.0, 1.0, 1.0, 1.0), false, 2.0)


func _on_palette_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	var col := int(floor(mouse.position.x / SWATCH_SIZE))
	var row := int(floor(mouse.position.y / SWATCH_SIZE))
	var index := row * PALETTE_COLUMNS + col
	if index >= 0 and index < palette_colors.size():
		current_color = palette_colors[index]
		_palette.queue_redraw()
	_palette.accept_event()


# ---------------- 保存 / 暂存 / 选择 ----------------

## 保持设置：把画布存成"当前自定义光标"并立刻生效
## 放大：弹出一个更大的画布（同一份 Image，改完自动同步回来）+ 一横排可滚动调色板
func _on_zoom() -> void:
	if _zoom_panel == null:
		_zoom_panel = CursorZoomScript.new()
		add_child(_zoom_panel)
		_zoom_panel.edited.connect(func() -> void: _canvas.queue_redraw())
		_zoom_panel.closed.connect(func() -> void:
			_canvas.queue_redraw()
			canvas_changed.emit())
	_zoom_panel.open(canvas_image, current_color, palette_colors)


func debug_zoom_panel() -> Node:
	return _zoom_panel


func _on_keep() -> void:
	GameSettings.apply_cursor_canvas(canvas_image)
	_message.text = "已保存并应用当前光标"


## 暂存设置：先展开命名输入行
func _on_stash() -> void:
	_naming_row.visible = true
	_name_edit.text = ""
	_name_edit.grab_focus()
	_message.text = "给这个光标起个名字，确定后会存进下拉列表"


## 读取设置：展开下面的光标列表，把之前暂存的光标读回画布
func _on_load() -> void:
	_cursor_expanded = true
	_refresh()
	_message.text = "在下面的列表里选一个暂存的光标读回画布"


func _on_name_confirm() -> void:
	var preset_name := _name_edit.text.strip_edges()
	if preset_name.is_empty():
		_message.text = "名字不能为空"
		return
	if GameSettings.save_cursor_preset(preset_name, canvas_image):
		_naming_row.visible = false
		_message.text = "已暂存：%s" % preset_name.substr(0, GameSettings.CURSOR_NAME_MAX)
		_refresh()


func _refresh() -> void:
	if _cursor_label == null:
		return
	var choices := GameSettings.cursor_choices()
	var index := clampi(GameSettings.cursor_choice_index(), 0, choices.size() - 1)
	_cursor_label.text = ("v  " if _cursor_expanded else ">  ") + "当前光标：%s" % choices[index]
	for child in _cursor_list.get_children():
		child.queue_free()
	_cursor_list.visible = _cursor_expanded
	if not _cursor_expanded:
		return
	for i in range(choices.size()):
		var label := Label.new()
		label.text = ("* " if i == index else "  ") + choices[i]
		label.add_theme_font_size_override("font_size", FONT_ROW)
		label.add_theme_color_override("font_color", COLOR_SELECTED if i == index else COLOR_TEXT)
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				_on_pick_cursor(i))
		_cursor_list.add_child(label)


func _on_pick_cursor(index: int) -> void:
	var choices := GameSettings.cursor_choices()
	if index < 0 or index >= choices.size():
		return
	var preset_name := "" if index == 0 else choices[index]
	GameSettings.select_cursor(preset_name)
	canvas_image = GameSettings.cursor_canvas_image()
	_canvas.queue_redraw()
	_cursor_expanded = false
	_message.text = "切换到：%s" % choices[index]
	_refresh()


# ---------------- 供自检调用 ----------------

func debug_paint(cell: Vector2i, erase: bool = false) -> void:
	canvas_image.set_pixel(cell.x, cell.y, Color(0, 0, 0, 0) if erase else current_color)
	_canvas.queue_redraw()


func debug_pixel(cell: Vector2i) -> Color:
	return canvas_image.get_pixel(cell.x, cell.y)


func debug_pick_color(index: int) -> void:
	if index >= 0 and index < palette_colors.size():
		current_color = palette_colors[index]


func debug_keep() -> void:
	_on_keep()


func debug_stash(preset_name: String) -> bool:
	_name_edit.text = preset_name
	_on_name_confirm()
	return GameSettings.saved_cursors.has(preset_name.strip_edges().substr(0, GameSettings.CURSOR_NAME_MAX))


func debug_choices() -> Array[String]:
	return GameSettings.cursor_choices()


func debug_pick(index: int) -> void:
	_on_pick_cursor(index)
