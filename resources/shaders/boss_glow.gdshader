shader_type canvas_item;
// BOSS 专用显示（M3）：
//   1) 红色外圈描边（采样四邻域 alpha 与自身 alpha 之差 → 只亮在轮廓外一圈）
//   2) 技能预警黄色闪光：代码用 set_shader_parameter("flash_amount", 0..1) 做脉冲
// 用法：boss.gd 在 _ready() 里给 AnimatedSprite2D 换上新 ShaderMaterial。

uniform vec4 outline_color : source_color = vec4(1.0, 0.13, 0.13, 1.0);
uniform float outline_width : hint_range(0.0, 8.0) = 1.5;
uniform vec4 flash_color : source_color = vec4(1.0, 0.88, 0.2, 1.0);
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * outline_width;
	vec4 tex = texture(TEXTURE, UV);
	float around = max(
		max(texture(TEXTURE, UV + vec2(px.x, 0.0)).a, texture(TEXTURE, UV - vec2(px.x, 0.0)).a),
		max(texture(TEXTURE, UV + vec2(0.0, px.y)).a, texture(TEXTURE, UV - vec2(0.0, px.y)).a)
	);
	float edge = clamp(around - tex.a, 0.0, 1.0);
	COLOR = tex;
	COLOR.rgb = mix(COLOR.rgb, outline_color.rgb, edge * outline_color.a);
	COLOR.a = max(tex.a, edge * outline_color.a);
	COLOR.rgb = mix(COLOR.rgb, flash_color.rgb, flash_amount * tex.a);
}
