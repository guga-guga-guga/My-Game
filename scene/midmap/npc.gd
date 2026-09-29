extends Area2D
## 中间地图 上的可交互角色（M4-2）：全部用代码构建，复用现有素材，零新美术。
## kind: "battle"(普通关) / "elite"(精英关) / "shop"(商店)
## 走近会显示头顶提示；按 E 的交互逻辑在 M4-3 接对话框。

const PROMPT_FONT_SIZE := 8          # 世界空间会被相机放大 4 倍
const INTERACT_RANGE := 18.0

var kind := "battle"
var title := ""
var _prompt: Label = null
var _player: Player = null
var _in_range := false


func setup(p_kind: String, p_title: String, frames: SpriteFrames, tint: Color, player_node: Player) -> void:
	kind = p_kind
	title = p_title
	_player = player_node

	# 交互范围（物理层 8 = Interactable，M0 已加；只关心 Player 层 2）
	collision_layer = 128
	collision_mask = 2
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = INTERACT_RANGE
	shape.shape = circle
	add_child(shape)

	# 角色图形：直接用敌人的 SpriteFrames，颜色区分类型
	if frames != null:
		var sprite := AnimatedSprite2D.new()
		sprite.name = "Body"
		sprite.sprite_frames = frames
		var names := frames.get_animation_names()
		if names.size() > 0:
			sprite.animation = names[0]
		sprite.play()
		sprite.modulate = tint
		add_child(sprite)

	# 头顶提示（默认隐藏，走近才显示）
	_prompt = Label.new()
	_prompt.name = "Prompt"
	_prompt.text = "%s\n按 E 交互" % p_title
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", PROMPT_FONT_SIZE)
	_prompt.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_prompt.add_theme_constant_override("outline_size", 2)
	_prompt.position = Vector2(-34.0, -40.0)
	_prompt.visible = false
	add_child(_prompt)

	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func is_player_in_range() -> bool:
	return _in_range


func _on_body_entered(body: Node2D) -> void:
	if body != _player:
		return
	_in_range = true
	if _prompt != null:
		_prompt.visible = true
	print("[MidMap] 走近 [%s]" % title)


func _on_body_exited(body: Node2D) -> void:
	if body != _player:
		return
	_in_range = false
	if _prompt != null:
		_prompt.visible = false
