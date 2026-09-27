extends CanvasLayer
## 关卡之间的汇报（M4-7）：打完一关回到 Hub 时弹一次「上一关成绩 + 本层通讯」。
## 纯代码构建。操作和对话框/商店一致：E 或回车关闭（ESC 也行）。
## 数据由 Battle 在离场时写进 RunState.last_level_report。

signal closed

const TITLE_FONT_SIZE := 30
const BODY_FONT_SIZE := 26
const STORY_FONT_SIZE := 24
const HINT_FONT_SIZE := 20
const PANEL_MARGIN_X := 180.0
const PANEL_TOP := 70.0

## 每层一段通讯，按"即将打的这一层"取
const STORY_LINES := {
	1: "通讯: 前方是本层的第一个关卡 先熟悉一下敌人的走位",
	2: "通讯: 敌人开始成队出现 别被围在墙角",
	3: "通讯: 侦察到带壳的重甲目标 打不动就绕开它",
	4: "通讯: 这一带走廊很窄 别把自己逼进死路",
	5: "通讯: 前面就是本层 BOSS 左右各有一个补给点 先把钱花掉",
	6: "通讯: 你已经打穿了第一道防线 后面的火力更猛",
	7: "通讯: 敌人开始成群结队 保持移动别停下",
	8: "通讯: 再往前是核心区 把状态补满再进",
	9: "通讯: 最后一段路 撑住",
	10: "通讯: 最终 BOSS 就在前面 打完这一场就结束了",
}

var _panel: PanelContainer = null
var _title: Label = null
var _body: Label = null
var _story: Label = null
var _hint: Label = null
var _open := false
var _open_frame := -1


func is_open() -> bool:
	return _open


func _ready() -> void:
	layer = 12                  # 比对话框(10)/商店(11) 高：回到 Hub 第一眼就看到它
	_build_ui()
	visible = false


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.grow_vertical = Control.GROW_DIRECTION_END
	_panel.offset_left = PANEL_MARGIN_X
	_panel.offset_right = -PANEL_MARGIN_X
	_panel.offset_top = PANEL_TOP
	_panel.offset_bottom = PANEL_TOP
	add_child(_panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.06, 0.95)
	style.border_color = Color(0.65, 0.85, 1.0, 0.9)          # 冷色，和商店/对话框的金色区分开
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	_title.add_theme_color_override("font_color", Color(0.72, 0.88, 1.0))
	box.add_child(_title)

	_body = Label.new()
	_body.add_theme_font_size_override("font_size", BODY_FONT_SIZE)
	_body.add_theme_color_override("font_color", Color(0.92, 0.92, 0.92))
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_body)

	_story = Label.new()
	_story.add_theme_font_size_override("font_size", STORY_FONT_SIZE)
	_story.add_theme_color_override("font_color", Color(0.80, 0.92, 0.85))
	_story.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_story)

	_hint = Label.new()
	_hint.text = "E 继续"
	_hint.add_theme_font_size_override("font_size", HINT_FONT_SIZE)
	_hint.add_theme_color_override("font_color", Color(0.66, 0.70, 0.74))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(_hint)


## report = RunState.last_level_report；current_floor = 即将打的这一层
func show_report(report: Dictionary, current_floor: int) -> void:
	if _open or report.is_empty():
		return
	_open = true
	_open_frame = Engine.get_process_frames()
	_title.text = "第 %d 层 汇报" % current_floor
	_body.text = _build_body(report)
	_story.text = String(STORY_LINES.get(current_floor, "通讯: 继续前进"))
	visible = true


func _build_body(report: Dictionary) -> String:
	var won: bool = bool(report.get("won", false))
	var prev_floor: int = int(report.get("floor", 0))
	var kind_title := RunState.kind_title(String(report.get("node_type", "")))
	var lines: Array[String] = []
	lines.append("上一关 第 %d 层 %s  %s" % [prev_floor, kind_title, "目标达成" if won else "未达成"])
	lines.append(String(report.get("goal_text", "")))
	lines.append("击杀 %d 只    用时 %.1f 秒" % [int(report.get("kills", 0)), float(report.get("elapsed", 0.0))])
	lines.append("金币 +%d    总计 %d    生命 %d / %d" % [
		int(report.get("gold_gained", 0)), int(report.get("gold_total", 0)),
		int(report.get("health", 0)), int(report.get("max_health", 0))])
	return "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if not _open or Engine.get_process_frames() == _open_frame:
		return                              # 开面板那一下的 E 不要立刻吃掉
	var close_now := (event.is_action_pressed("interact")
		or event.is_action_pressed("ui_accept")
		or event.is_action_pressed("pause")
		or event.is_action_pressed("ui_cancel"))
	if not close_now:
		return
	_close()
	# 关闭后本节点可能已经被切走：取 viewport 前判空（踩过这个坑）
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

func debug_body() -> String:
	return _body.text


func debug_title() -> String:
	return _title.text


func debug_story() -> String:
	return _story.text


func debug_close() -> void:
	_close()
