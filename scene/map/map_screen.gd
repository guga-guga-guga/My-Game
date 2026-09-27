extends Control
## 爬塔路线图 M0 骨架版 —— Autoload 名:无，由 GameFlow 切进来
##
## M0 目标:跑通 title 到 MapScreen 到 战斗 到 MapScreen 的流程，并验证层数/金币能跨场景保留
## M3 会把 DEMO_NODES 换成 RunMap 生成的随机路线图，并让节点类型决定关卡目标
## UI 全部由代码生成 沿用 title.gd 的既有约定 ，所以 .tscn 里只有一个 Control 根节点

const COLOR_BACKGROUND := Color(0.0588, 0.0588, 0.0588)
const COLOR_TITLE := Color(1.0, 0.87, 0.55)
const COLOR_TEXT := Color(0.85, 0.85, 0.85)
const COLOR_HINT := Color(0.55, 0.55, 0.55)

const FONT_SIZE_TITLE := 44
const FONT_SIZE_SUBTITLE := 20
const FONT_SIZE_BODY := 16
const FONT_SIZE_SMALL := 14

## M0 临时:本层固定展示 3 个节点M3 由 RunMap 随机生成
const DEMO_NODES := [
	{"type": "battle", "label": "战斗"},
	{"type": "elite", "label": "精英"},
	{"type": "shop", "label": "商店"},
]

var _status_label: Label


func _ready() -> void:
	# 兜底:直接从编辑器单跑这个场景时，没有进行中的一局就先开一局
	if not RunState.is_active:
		RunState.reset()
	RunState.gold_changed.connect(_on_state_changed)
	RunState.floor_changed.connect(_on_state_changed)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _on_state_changed(_value: int = 0) -> void:
	_refresh_status()


func _build_ui() -> void:
	var base := ColorRect.new()
	base.color = COLOR_BACKGROUND
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(base)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	box.add_child(_make_label("路线图", FONT_SIZE_TITLE, COLOR_TITLE))
	_status_label = _make_label("", FONT_SIZE_BODY, COLOR_TEXT)
	box.add_child(_status_label)
	box.add_child(_make_spacer(10))
	box.add_child(_make_label("选择一个节点前进", FONT_SIZE_SUBTITLE, COLOR_TITLE))

	var node_row := HBoxContainer.new()
	node_row.alignment = BoxContainer.ALIGNMENT_CENTER
	node_row.add_theme_constant_override("separation", 12)
	box.add_child(node_row)
	for node_data in DEMO_NODES:
		var node_type := String(node_data.get("type", ""))
		var node_button := _make_button(String(node_data.get("label", "?")), "Node_" + node_type)
		node_button.pressed.connect(_on_node_pressed.bind(node_type))
		node_row.add_child(node_button)

	box.add_child(_make_spacer(10))
	var debug_button := _make_button("调试: 模拟过关 到 下一层", "DebugAdvanceButton")
	debug_button.pressed.connect(_on_debug_advance_pressed)
	box.add_child(debug_button)

	var back_button := _make_button("返回标题", "BackButton")
	back_button.pressed.connect(_on_back_pressed)
	box.add_child(back_button)

	box.add_child(_make_spacer(14))
	box.add_child(_make_label(
		"M0 骨架:节点尚未接入真正的关卡目标与随机地图，将在 M1~M5 逐步替换",
		FONT_SIZE_SMALL, COLOR_HINT))

	_refresh_status()
	if node_row.get_child_count() > 0:
		(node_row.get_child(0) as Button).grab_focus()


func _refresh_status() -> void:
	if _status_label == null:
		return
	_status_label.text = "第 %d 层 / 共 %d 层  金币 %d  本局击杀 %d" % [
		RunState.floor_index, RunState.MAX_FLOOR, RunState.gold, RunState.total_kills,
	]


func _on_node_pressed(node_type: String) -> void:
	match node_type:
		"battle", "elite", "boss":
			# M1/M2 建好 battle.tscn 后，GameFlow 会自动切到新战斗场景；现在先落到经典战斗场景
			GameFlow.start_battle({"floor": RunState.floor_index, "node_type": node_type})
		"shop":
			push_warning("商店还没实装 计划 M5 ")
		_:
			push_warning("未知节点类型:%s" % node_type)


func _on_debug_advance_pressed() -> void:
	# M2 起改为"战斗胜利后由 Battle 调用 RunState.advance_floor()"
	RunState.advance_floor()


func _on_back_pressed() -> void:
	RunState.is_active = false
	GameFlow.goto_title()


func _make_label(
		text: String,
		font_size: int,
		color: Color,
		alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = alignment
	label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _make_button(text: String, node_name: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(260, 42)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	return button


func _make_spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer
