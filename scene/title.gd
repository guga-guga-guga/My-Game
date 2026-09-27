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

#标题字体留 null 就用 Godot 默认字体 结算弹窗用的也是它，能显示中文 
#项目自带的 IPix.ttf 是像素字体，若它包含你需要的汉字，改成下面这样就能换成像素风:
#const CUSTOM_FONT: Font = preload("res://resources/font/IPix.ttf")
const CUSTOM_FONT: Font = null

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
func _build_ui() -> void:
	_add_background()
	
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	
	if SHOW_TITLE_TEXT:
		box.add_child(_make_label(TITLE_TEXT, FONT_SIZE_TITLE, COLOR_TITLE))
	box.add_child(_make_label(DESCRIPTION_TEXT, FONT_SIZE_BODY, COLOR_TEXT))
	box.add_child(_make_spacer(16))
	
	var run_button := _make_button("开始新局，闯关", "StartRunButton")
	run_button.pressed.connect(_on_start_run_button_pressed)
	box.add_child(run_button)

	var start_button := _make_button("经典模式，单关", "StartButton")
	start_button.pressed.connect(_on_start_button_pressed)
	box.add_child(start_button)

	var boss_button := _make_button("调试: 直接打 Boss", "DebugBossButton")
	boss_button.pressed.connect(_on_debug_boss_pressed)
	box.add_child(boss_button)
	
	var quit_button := _make_button("退出游戏", "QuitButton")
	quit_button.pressed.connect(_on_quit_button_pressed)
	box.add_child(quit_button)
	
	box.add_child(_make_spacer(22))
	box.add_child(_make_label("最近 10 局战绩", FONT_SIZE_SUBTITLE, COLOR_TITLE))
	box.add_child(_make_label(
		_build_records_text(), FONT_SIZE_SMALL, COLOR_HINT, HORIZONTAL_ALIGNMENT_LEFT))
	
	#让键盘 / 手柄也能直接开始:内置动作 ui_accept 回车，空格 会触发当前聚焦的按钮
	run_button.grab_focus()


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
		var state := "未通关"
		if bool(record_data.get("won", false)):
			state = "通关"
		lines.append("第 %d 局  存活 %s 秒  击杀 %d  %s" % [
			int(record_data.get("index", 0)),
			_format_seconds(float(record_data.get("elapsed", 0.0))),
			int(record_data.get("kills", 0)),
			state,
		])
	
	if lines.is_empty():
		return "还没有战绩，先来一局吧"
	
	#String.join 只接受 PackedStringArray，这里手动拼，避免类型转换出问题
	var text := ""
	for line in lines:
		if not text.is_empty():
			text += "\n"
		text += line
	return text


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
