shader_type canvas_item;
// BOSS 显示（M3）：只负责"技能预警黄闪"。
// 说明：红色外描边已改为"身后叠一层放大版红色剪影"（boss.gd::_setup_outline），
//       因为用 shader 采样邻域 alpha 画描边时，贴图如果没有透明留白就会采样到边界外，
//       被 clamp 后算不出 edge，描边会消失。

uniform vec4 flash_color : source_color = vec4(1.0, 0.88, 0.2, 1.0);
uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = tex;
	// 预警期间整体向黄色混色（代码用 set_shader_parameter 驱动脉冲）
	COLOR.rgb = mix(COLOR.rgb, flash_color.rgb, flash_amount * tex.a);
}
