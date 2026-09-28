extends CanvasLayer
## 商店面板（M4-4）：Hub 里走到商店角色 -> 对话框选「进入」-> 打开这里。
## 纯代码构建。操作遵循用户规则：E 购买/离开，W/S 或上下键选择，鼠标点击也行，ESC 直接退出。
## 价格/等级/购买全部走 RunState（本局内有效，新开一局重置）。

signal closed

const TITLE_FONT_SIZE := 30
const BODY_FONT_SIZE := 26
const HINT_FONT_SIZE := 20
const PANEL_MARGIN_X := 220.0
const PANEL_MARGIN_Y := 60.0
const PRICE_WIDTH := 220.0

## 可选商品的平面顺序（和 RunState.SHOP_SHELVES 一致：道具 -> 加成）
const ITEM_KEYS: Array[String] = ["health", "heal", "fire_rate", "damage"]
const ITEM_TITLES := {
	"health": "生命上限 +1",
	"heal": "恢复血量",
	"fire_rate": "射速 +10%",
	"damage": "子弹伤害 +1",
}
## 类别之间的分隔（用户要求用 --- 隔开）
const SEPARATOR_TEXT := "---"
const CATEGORY_FONT_SIZE := 22

var _panel: PanelContainer = null
var _title: Label = null
var _gold_label: Label = null
var _stat_label: Label = null
var _row_box: VBoxContainer = null
var _message: Label = null
var _hint: Label = null
var _row_names: Array[Label] = []
var _row_prices: Array[Label] = []
var _selected := 0
var _open := false
var _open_frame := -1


func is_open() -> bool:
	return _open


func get_selected_index() -> int:
	return _selected


func _ready() -> void:
	layer = 11
	_build_ui()
	visible = false
	set_process(false)
	if not RunState.gold_changed.is_connected(_on_gold_changed):
		RunState.gold_changed.connect(_on_gold_changed)
	# 生命变化也要刷新：买了「生命上限 +1」后血又满了，「恢复血量」那行要跟着变回"血量已满"
	if not RunState.health_changed.is_connected(_on_health_changed):
		RunState.health_changed.connect(_on_health_changed)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = PANEL_MARGIN_X
	_panel.offset_right = -PANEL_MARGIN_X
	_panel.offset_top = PANEL_MARGIN_Y
	_panel.offset_bottom = -PANEL_MARGIN_Y
	add_child(_panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.95)
	style.border_color = Color(1.0, 0.87, 0.55, 0.9)
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	box.add_child(header)
	_title = Label.new()
	_title.text = "商店"
	_title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	_title.add_theme_color_override("font_color", Color(1.0, 0.87, 0.55))
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	_gold_label = Label.new()
	_gold_label.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	_gold_label.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_gold_label)

	_stat_label = Label.new()
	_stat_label.add_theme_font_size_override("font_size", HINT_FONT_SIZE)
	_stat_label.add_theme_color_override("font_color", Color(0.72, 0.76, 0.80))
	box.add_child(_stat_label)

	_row_box = VBoxContainer.new()
	_row_box.add_theme_constant_override("separation", 4)
	box.add_child(_row_box)
	# 按分类铺货架：分类标题 + 该类的商品行，类别之间用 --- 隔开
	var flat_index := 0
	for shelf_index in range(RunState.SHOP_SHELVES.size()):
		var shelf: Dictionary = RunState.SHOP_SHELVES[shelf_index]
		if shelf_index > 0:
			_make_text_line(SEPARATOR_TEXT, Color(0.42, 0.45, 0.50), BODY_FONT_SIZE)
		_make_text_line(String(shelf.get("title", "")), Color(0.70, 0.85, 1.0), CATEGORY_FONT_SIZE)
		for key in shelf.get("keys", []):
			_make_row(flat_index, String(ITEM_TITLES.get(String(key), String(key))))
			flat_index += 1
	# 「离开」永远在所有类别之后（用户要求：离开和按键提示固定在界面最下方）
	_make_row(ITEM_KEYS.size(), "离开")

	_message = Label.new()
	_message.add_theme_font_size_override("font_size", HINT_FONT_SIZE)
	_message.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	box.add_child(_message)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", HINT_FONT_SIZE)
	_hint.add_theme_color_override("font_color", Color(0.66, 0.70, 0.74))
	_hint.text = "W/S 选择   E 购买   ESC 退出"
	box.add_child(_hint)


## 分类标题 / --- 分隔这类纯文字行（不可选、不可点）
func _make_text_line(text: String, color: Color, font_size: int) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row_box.add_child(label)


## 一行 = 左边名称、右边价格；整行可点（鼠标）
func _make_row(index: int, title_text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(_on_row_gui_input.bind(index))
	_row_box.add_child(row)
	var name_label := Label.new()
	name_label.text = title_text
	name_label.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var price_label := Label.new()
	price_label.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	price_label.custom_minimum_size = Vector2(PRICE_WIDTH, 0)
	row.add_child(price_label)
	_row_names.append(name_label)
	_row_prices.append(price_label)


func open() -> void:
	_open = true
	_open_frame = Engine.get_process_frames()
	_selected = 0
	_message.text = ""
	visible = true
	_refresh()


func _refresh() -> void:
	_gold_label.text = "金币 %d" % RunState.gold
	_stat_label.text = "当前: 生命 %d/%d   伤害 %d   射速 %d%%" % [
		RunState.current_health, RunState.get_player_max_health(),
		RunState.get_player_damage(), int(round((1.0 + 0.1 * float(RunState.fire_rate_level)) * 100.0))]
	for index in range(ITEM_KEYS.size()):
		var key: String = ITEM_KEYS[index]
		var price := RunState.shop_price(key)
		var affordable := RunState.gold >= price
		if key == "heal":
			affordable = affordable and RunState.current_health < RunState.max_health
		var chosen := index == _selected
		var name_color := Color(0.88, 0.89, 0.92)
		var price_color := Color(1.0, 0.90, 0.60)
		if not affordable:
			name_color = Color(0.60, 0.60, 0.64)
			price_color = Color(0.72, 0.42, 0.40)
		if chosen:
			name_color = Color(1.0, 0.87, 0.55)
			price_color = Color(1.0, 0.95, 0.70)
		_row_names[index].text = ("> " if chosen else "  ") + String(ITEM_TITLES[key])
		_row_names[index].add_theme_color_override("font_color", name_color)
		# 恢复血量：血满时显示"血量已满"，省得玩家以为能买
		if key == "heal" and RunState.current_health >= RunState.max_health:
			_row_prices[index].text = "血量已满"
		else:
			_row_prices[index].text = "%d 金" % price
		_row_prices[index].add_theme_color_override("font_color", price_color)
	# 最后一行是「离开」
	var leave_index: int = ITEM_KEYS.size()
	var leave_chosen := _selected == leave_index
	_row_names[leave_index].text = ("> " if leave_chosen else "  ") + "离开"
	_row_names[leave_index].add_theme_color_override("font_color",
		Color(1.0, 0.87, 0.55) if leave_chosen else Color(0.88, 0.89, 0.92))
	_row_prices[leave_index].text = ""


## E / 鼠标点击：选中项购买；选到「离开」就关闭
func _activate_selected() -> void:
	if _selected >= ITEM_KEYS.size():
		_close()
		return
	var key: String = ITEM_KEYS[_selected]
	var price := RunState.shop_price(key)
	if key == "heal" and RunState.current_health >= RunState.max_health:
		_message.text = "血量已满 不用买"
		return
	if not RunState.shop_buy(key):
		_message.text = "金币不够 还差 %d" % maxi(price - RunState.gold, 0)
		return
	_message.text = "已购买 %s" % String(ITEM_TITLES[key])
	_refresh()


func _move_selection(step: int) -> void:
	_selected = wrapi(_selected + step, 0, ITEM_KEYS.size() + 1)
	_refresh()


func _on_row_gui_input(event: InputEvent, index: int) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	_selected = index
	_activate_selected()


func _on_gold_changed(_amount: int) -> void:
	if _open:
		_refresh()


func _on_health_changed(_current: int, _maximum: int) -> void:
	if _open:
		_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not _open or Engine.get_process_frames() == _open_frame:
		return                              # 打开商店那一下的 E 不要立刻被吃掉
	if event.is_action_pressed("move_up") or event.is_action_pressed("ui_up"):
		_move_selection(-1)
	elif event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
		_move_selection(1)
	elif event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		_activate_selected()
	elif event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		_close()
	else:
		return
	# 购买/离开可能触发切场景（不会，但保持一致）：取 viewport 前判空
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func _close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	closed.emit()


# ---------------- 供 headless 自检调用 ----------------

func debug_selected_key() -> String:
	return ITEM_KEYS[_selected] if _selected < ITEM_KEYS.size() else "leave"


func debug_message() -> String:
	return _message.text


## 供自检：内容的最低高度
func debug_content_height() -> float:
	var content := _row_box.get_parent() as Control
	return content.get_combined_minimum_size().y if content != null else 0.0


## 供自检：内容有没有超出面板（加了分类标题和分隔行之后行数变多）
func debug_content_fits() -> bool:
	var content := _row_box.get_parent() as Control
	if content == null:
		return true
	return content.get_combined_minimum_size().y <= _panel.size.y


## 供自检：货架从上往下每行的纯文本（已去掉选中标记），最后一行按键提示
func debug_layout_lines() -> Array[String]:
	var lines: Array[String] = []
	for child in _row_box.get_children():
		if child is Label:
			lines.append((child as Label).text.strip_edges())
		elif child is HBoxContainer:
			var name_label := (child as HBoxContainer).get_child(0) as Label
			if name_label != null:
				lines.append(name_label.text.replace("> ", "").strip_edges())
	lines.append("HINT:" + _hint.text)
	return lines


func debug_row_text(index: int) -> String:
	return _row_names[index].text + " " + _row_prices[index].text
