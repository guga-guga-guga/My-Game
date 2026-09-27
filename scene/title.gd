extends Control

## 开始界面:所有 UI 都在代码里生成，title.tscn 只是一个挂了本脚本的 Control 根节点
## 这样不用手写复杂的场景文件，但代价是改版式要动代码

const GAME_SCENE_PATH := "res://scene/game.tscn"

#配色:背景沿用主场景的深灰，两屏观感保持一致
const COLOR_BACKGROUND := Color(0.0588, 0.0588, 0.0588)
const COLOR_TITLE := Color(1.0, 0.87, 0.55)
const COLOR_TEXT := Color(0.85, 0.85, 0.85)
const COLOR_HINT := Color(0.55, 0.55, 0.55)

#字号
const FONT_SIZE_TITLE := 56
const FONT_SIZE_SUBTITLE := 18
const FONT_SIZE_BODY := 16
const FONT_SIZE_SMALL := 14

## 右侧战绩面板（用户要求）+ 底部按钮排的边距
const RECORDS_PANEL_WIDTH := 420.0
const RECORDS_PANEL_MARGIN := 24.0
const TITLE_BUTTON_BOTTOM_MARGIN := 36.0

#标题字体留 null 就用 Godot 默认字体 结算弹窗用的也是它，能显示中文 
#项目自带的 IPix.ttf 是像素字体，若它包含你需要的汉字，改成下面这样就能换成像素风:
#const CUSTOM_FONT: Font = preload("res://resources/font/IPix.ttf")
const CUSTOM_FONT: Font = null

var _records_panel: PanelContainer = null
var _button_bar: VBoxContainer = null

const TITLE_TEXT := "唯时代尔"
const DESCRIPTION_TEXT := "操作说明\nWASD 移动 ， 方向键射击\n\n撑满倒计时即通关，活得越久，杀得越多越好"

#开场背景图Godot 已经为它生成过 .import，正常可以直接加载
const BACKGROUND_TEXTURE_PATH := "res://resources/texture/开场.png"
#背景图上盖一层黑色遮罩的不透明度:图比较花时调大它文字更清楚，改成 0.0 就是完全不要遮罩
const BACKGROUND_SCRIM_ALPHA := 0.35
#如果背景图里已经画好了标题，把这个改成 false，就不会重复显示文字标题
const SHOW_TITLE_TEXT := true


func _ready() -> void:
	#关键:game.gd 在结算时把时间缩放设为 0 并暂停了整棵场景树，
	#切回标题必须复位，否则整个界面会卡死，按钮也点不动
	Engine.time_scale = 1.0
	get_tree().paused = false
	#兜底:即使 title.tscn 里的锚点没设对，也强制让根节点铺满窗口
	set_anchors_preset(Control.PRESET_FULL_RECT)
	
	_build_ui()


#代码生成整个界面:一个纵向容器装下所有内容，整体垂直居中
#代码生成整个界面（用户定的排版）:
#   中部     标题 + 操作说明
#   中间下方  一整排按钮
#   右侧     最近战绩
#代码生成整个界面（用户定的排版）:
#   中部      标题 + 操作说明
#   中间下方   原来的按钮竖排，整组下移（用户要求：保持原排列，只下移）
#   右侧靠下   最近战绩（半透明底，不带边框）
func _build_ui() -> void:
	_add_background()

	# ---- 中部:标题 + 操作说明（比正中间略上，给下面的按钮组让位）----
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	box.offset_bottom = -120.0
	add_child(box)

	if SHOW_TITLE_TEXT:
		box.add_child(_make_label(TITLE_TEXT, FONT_SIZE_TITLE, COLOR_TITLE))
	box.add_child(_make_label(DESCRIPTION_TEXT, FONT_SIZE_BODY, COLOR_TEXT))

	# ---- 中间下方:原来的四个按钮竖排，整组贴在下方（只下移，不改成横排）----
	_button_bar = VBoxContainer.new()
	_button_bar.name = "ButtonBar"
	_button_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_button_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_button_bar.offset_left = 0.0
	_button_bar.offset_right = 0.0
	_button_bar.offset_top = -TITLE_BUTTON_BOTTOM_MARGIN
	_button_bar.offset_bottom = -TITLE_BUTTON_BOTTOM_MARGIN
	_button_bar.add_theme_constant_override("separation", 8)
	add_child(_button_bar)

	var run_button := _make_button("开始新局，闯关", "StartRunButton")
	run_button.pressed.connect(_on_start_run_button_pressed)
	_button_bar.add_child(run_button)

	var start_button := _make_button("经典模式，单关", "StartButton")
	start_button.pressed.connect(_on_start_button_pressed)
	_button_bar.add_child(start_button)

	var boss_button := _make_button("调试: 直接打 Boss", "DebugBossButton")
	boss_button.pressed.connect(_on_debug_boss_pressed)
	_button_bar.add_child(boss_button)

	var quit_button := _make_button("退出游戏", "QuitButton")
	quit_button.pressed.connect(_on_quit_button_pressed)
	_button_bar.add_child(quit_button)

	# ---- 右侧靠下:最近战绩 ----
	_build_records_panel()

	#让键盘 / 手柄也能直接开始:内置动作 ui_accept 回车，空格 会触发当前聚焦的按钮
	run_button.grab_focus()
	_check_title_layout.call_deferred()



#右侧战绩面板（用户要求：战绩放在界面右侧）
func _build_records_panel() -> void:
	_records_panel = PanelContainer.new()
	_records_panel.name = "RecordsPanel"
	_records_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_records_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_records_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN     # 内容多了往上长
	_records_panel.offset_left = -RECORDS_PANEL_WIDTH
	_records_panel.offset_right = -RECORDS_PANEL_MARGIN
	_records_panel.offset_top = -RECORDS_PANEL_MARGIN
	_records_panel.offset_bottom = -RECORDS_PANEL_MARGIN
	add_child(_records_panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.28)                     # 只要半透明底，不要金边（用户要求更透）
	style.set_corner_radius_all(4)
	style.set_content_margin_all(12)
	_records_panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_records_panel.add_child(box)
	box.add_child(_make_label("最近 10 局战绩", FONT_SIZE_SUBTITLE, COLOR_TITLE))
	box.add_child(_make_label(_build_records_text(), FONT_SIZE_SMALL, COLOR_HINT,
		HORIZONTAL_ALIGNMENT_LEFT))


#自检:战绩面板是否在右半屏、按钮排是否在底部中间（headless 也能验）
func _check_title_layout() -> void:
	if _records_panel == null or _button_bar == null:
		return
	var screen := Vector2(get_viewport().get_visible_rect().size)
	var panel := _records_panel.get_global_rect()
	var bar := _button_bar.get_global_rect()
	# 按钮组：横向上取"第一个按钮左边缘 ~ 最后一个按钮右边缘"，纵向取整组范围
	var group_top := INF
	var group_bottom := -INF
	var group_left := INF
	var group_right := -INF
	for child in _button_bar.get_children():
		var button := child as Control
		if button == null:
			continue
		var rect := button.get_global_rect()
		group_left = minf(group_left, rect.position.x)
		group_right = maxf(group_right, rect.end.x)
		group_top = minf(group_top, rect.position.y)
		group_bottom = maxf(group_bottom, rect.end.y)
	print("[Title自检] 样例 闯关: %s" % _format_record_line({"index": 27, "mode": "run", "floor": 10, "gold": 123}))
	print("[Title自检] 样例 经典: %s" % _format_record_line({"index": 26, "mode": "classic", "elapsed": 68.0, "kills": 60}))
	var real_text := _build_records_text().split("
")
	print("[Title自检] 真实存档首行: %s（共 %d 行）" % [real_text[0] if not real_text.is_empty() else "", real_text.size()])
	print("[Title自检] 屏幕 %dx%d | 战绩面板 位置%s 尺寸%dx%d 右边距%d 下边距%d | 按钮组 x %d~%d(中心%d 屏幕中心%d) y %d~%d 距底%d" % [
		int(screen.x), int(screen.y), str(panel.position), int(panel.size.x), int(panel.size.y),
		int(screen.x - panel.end.x), int(screen.y - panel.end.y),
		int(group_left), int(group_right), int((group_left + group_right) * 0.5), int(screen.x * 0.5),
		int(group_top), int(group_bottom), int(screen.y - group_bottom)])



#背景分三层:纯色底 到 开场图 到 半透明遮罩 遮罩保证背景很花时文字依然看得清 
func _add_background() -> void:
	var base := ColorRect.new()
	base.color = COLOR_BACKGROUND
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(base)
	
	var texture := load(BACKGROUND_TEXTURE_PATH) as Texture2D
	if texture == null:
		push_warning("标题界面:背景图加载失败 %s ，已退回纯色背景" % BACKGROUND_TEXTURE_PATH)
	else:
		var image := TextureRect.new()
		image.texture = texture
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		image.set_anchors_preset(Control.PRESET_FULL_RECT)
		#铺满窗口但不拉伸变形，多余的部分裁掉
		#想完整显示，允许留黑边就换成 STRETCH_KEEP_ASPECT_CENTERED；
		#图和窗口比例一致时也可以直接换成 STRETCH_SCALE 强行铺满
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		add_child(image)
	
	if BACKGROUND_SCRIM_ALPHA <= 0.0:
		return
	var scrim := ColorRect.new()
	scrim.color = Color(0.0, 0.0, 0.0, BACKGROUND_SCRIM_ALPHA)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)


#把最近 10 局战绩拼成多行文本；没有记录时给一句提示
func _build_records_text() -> String:
	var data := RoundRecords.load_data()
	var saved_records: Array = data.get("records", [])
	if saved_records.is_empty():
		return "还没有战绩，先来一局吧"
	
	var lines: Array[String] = []
	for record in saved_records:
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var record_data: Dictionary = record
		lines.append(_format_record_line(record_data))
	
	if lines.is_empty():
		return "还没有战绩，先来一局吧"
	
	#String.join 只接受 PackedStringArray，这里手动拼，避免类型转换出问题
	var text := ""
	for line in lines:
		if not text.is_empty():
			text += "\n"
		text += line
	return text


#一行的显示格式（用户要求按模式区分）:
#   闯关模式 -> 到了多少层 + 金币数量
#   经典模式 -> 坚持了多久 + 击杀了多少
#老存档没有 mode 字段，就用 floor>0 推断（那时候只有经典模式）
func _format_record_line(record_data: Dictionary) -> String:
	var index := int(record_data.get("index", 0))
	var mode := String(record_data.get("mode", ""))
	if mode.is_empty():
		mode = "run" if int(record_data.get("floor", 0)) > 0 else "classic"
	if mode == "run":
		return "第 %d 局  闯关模式  到达第 %d 层  金币 %d" % [
			index, maxi(int(record_data.get("floor", 0)), 1), int(record_data.get("gold", 0))]
	return "第 %d 局  经典模式  坚持 %s 秒  击杀 %d" % [
		index, _format_seconds(float(record_data.get("elapsed", 0.0))), int(record_data.get("kills", 0))]



func _format_seconds(seconds: float) -> String:
	return "%.1f" % maxf(seconds, 0.0)


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
	if CUSTOM_FONT != null:
		label.add_theme_font_override("font", CUSTOM_FONT)
	return label


func _make_button(text: String, node_name: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(200, 42)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	if CUSTOM_FONT != null:
		button.add_theme_font_override("font", CUSTOM_FONT)
	return button


#占位用的空白控件，用来拉开行距
func _make_spacer(height: int) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	return spacer


func _on_start_button_pressed() -> void:
	get_tree().change_scene_to_file(GAME_SCENE_PATH)


func _on_quit_button_pressed() -> void:
	get_tree().quit()

func _on_start_run_button_pressed() -> void:
	GameFlow.start_new_run()

func _on_debug_boss_pressed() -> void:
	# 调试用：跳过路线图，直接从最终层（Boss 关）开始
	RunState.reset()
	RunState.floor_index = RunState.MAX_FLOOR
	GameFlow.start_battle({"floor": RunState.floor_index, "node_type": "boss"})
