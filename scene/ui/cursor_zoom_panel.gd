extends CanvasLayer
## 光标放大编辑界面：更大的画布（继承当前内容）+ 一横排可滚动的调色板
## 左键上色、右键擦除，按住拖动连续画；滚轮滚调色板；ESC 或「关闭」退出

signal closed
signal edited

const CANVAS_SIZE := 32
const ZOOM := 16                       ## 32x32 -> 512x512
const SWATCH := 26.0
const VISIBLE_SWATCHES := 4            ## 一横排显示 4 个，超出用滚轮滚
const COLOR_TEXT := Color(0.88, 0.89, 0.92)
const COLOR_HINT := Color(0.60, 0.64, 0.68)

var canvas_image: Image = null
var current_color := Color(1, 0, 0, 1)
var palette_colors: Array[Color] = []

var _open := false
var _canvas: Control = null
var _palette_scroll: ScrollContainer = null
var _palette_strip: HBoxContainer = null
var _dragging := false
var _erase_drag := false


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func is_open() -> bool:
	return _open


func open(image: Image, color: Color, palette: Array[Color]) -> void:
	canvas_image = image
	current_color = color
	palette_colors = palette
	_open = true
	visible = true
	_canvas.queue_redraw()
	print("[CursorZoom] 放大编辑界面打开")


func _close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	edited.emit()
	closed.emit()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.75)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.name = "CursorZoomPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-380, -320)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.07, 0.98)
	style.border_color = Color(0.65, 0.85, 1.0, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var title := Label.new()
	title.text = "放大编辑光标（左键上色 / 右键擦除 / 滚轮滚调色板）"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	box.add_child(title)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 18)
	box.add_child(body)

	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(CANVAS_SIZE * ZOOM, CANVAS_SIZE * ZOOM)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_canvas)
	_canvas.gui_input.connect(_on_canvas_input)
	body.add_child(_canvas)

	# 一横排调色板：只露 4 个，超出用滚轮横向滚动
	_palette_scroll = ScrollContainer.new()
	_palette_scroll.custom_minimum_size = Vector2(SWATCH * VISIBLE_SWATCHES + 16.0, SWATCH + 16.0)
	_palette_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_palette_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_palette_scroll.gui_input.connect(_on_palette_wheel)
	body.add_child(_palette_scroll)
	_palette_strip = HBoxContainer.new()
	_palette_strip.add_theme_constant_override("separation", 2)
	_palette_scroll.add_child(_palette_strip)

	var close_row := HBoxContainer.new()
	close_row.add_theme_constant_override("separation", 12)
	box.add_child(close_row)
	var close_button := Button.new()
	close_button.text = "关闭"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.custom_minimum_size = Vector2(130.0, 34.0)
	close_button.pressed.connect(_close)
	close_row.add_child(close_button)


func _process(_delta: float) -> void:
	# 调色板色块按需生成（等打开的瞬间颜色表就位）
	if not _open or _palette_strip.get_child_count() == palette_colors.size():
		return
	for child in _palette_strip.get_children():
		child.queue_free()
	for color in palette_colors:
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(SWATCH - 2.0, SWATCH - 2.0)
		swatch.color = color
		swatch.mouse_filter = Control.MOUSE_FILTER_STOP
		swatch.gui_input.connect(func(event: InputEvent) -> void:
			var mouse := event as InputEventMouseButton
			if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
				current_color = color)
		_palette_strip.add_child(swatch)


## 滚轮 = 横向滚调色板
func _on_palette_wheel(event: InputEvent) -> void:
	var wheel := event as InputEventMouseButton
	if wheel == null or not wheel.pressed:
		return
	if wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_palette_scroll.scroll_horizontal = int(_palette_scroll.scroll_horizontal + SWATCH)
		_palette_scroll.accept_event()
	elif wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
		_palette_scroll.scroll_horizontal = maxi(int(_palette_scroll.scroll_horizontal - SWATCH), 0)
		_palette_scroll.accept_event()


# ---------------- 画布 ----------------

func _draw_canvas() -> void:
	if canvas_image == null:
		return
	for y in range(CANVAS_SIZE):
		for x in range(CANVAS_SIZE):
			var base := Color(0.16, 0.16, 0.18) if (x + y) % 2 == 0 else Color(0.22, 0.22, 0.24)
			var pixel := canvas_image.get_pixel(x, y)
			if pixel.a > 0.01:
				base = pixel
			_canvas.draw_rect(Rect2(x * ZOOM, y * ZOOM, ZOOM, ZOOM), base)
	var mid := CANVAS_SIZE * ZOOM * 0.5
	_canvas.draw_line(Vector2(mid, 0), Vector2(mid, CANVAS_SIZE * ZOOM), Color(1, 1, 1, 0.18))
	_canvas.draw_line(Vector2(0, mid), Vector2(CANVAS_SIZE * ZOOM, mid), Color(1, 1, 1, 0.18))
	_canvas.draw_rect(Rect2(0, 0, CANVAS_SIZE * ZOOM, CANVAS_SIZE * ZOOM),
		Color(0.65, 0.85, 1.0, 0.8), false, 2.0)


func _canvas_cell(local: Vector2) -> Vector2i:
	return Vector2i(int(floor(local.x / ZOOM)), int(floor(local.y / ZOOM)))


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
	if canvas_image == null:
		return
	var cell := _canvas_cell(local)
	if cell.x < 0 or cell.y < 0 or cell.x >= CANVAS_SIZE or cell.y >= CANVAS_SIZE:
		return
	canvas_image.set_pixel(cell.x, cell.y, Color(0, 0, 0, 0) if erase else current_color)
	_canvas.queue_redraw()
	edited.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		_close()
		var viewport := get_viewport()
		if viewport != null:
			viewport.set_input_as_handled()


# ---------------- 供自检调用 ----------------

func debug_canvas_cell_color(cell: Vector2i) -> Color:
	return canvas_image.get_pixel(cell.x, cell.y)


func debug_paint(cell: Vector2i, erase: bool = false) -> void:
	canvas_image.set_pixel(cell.x, cell.y, Color(0, 0, 0, 0) if erase else current_color)
	_canvas.queue_redraw()


func debug_swatch_count() -> int:
	return _palette_strip.get_child_count()


func debug_scroll_palette(steps: int) -> int:
	_palette_scroll.scroll_horizontal = maxi(int(_palette_scroll.scroll_horizontal + steps * SWATCH), 0)
	return int(_palette_scroll.scroll_horizontal)
