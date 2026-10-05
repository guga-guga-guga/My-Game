shader_type canvas_item;
// 紫色残影 / 紫光效果（新 BOSS 用）
// fade: 0 = 刚生成（最亮） -> 1 = 完全消失
// mode: 0 = 残影（本体同款紫色拖尾）；1 = 纯色光柱（瞬移落点预告）
uniform float fade : hint_range(0.0, 1.0) = 0.0;
uniform vec4 tint_color : source_color = vec4(0.70, 0.45, 1.0, 1.0);
uniform float tint_amount : hint_range(0.0, 1.0) = 0.85;
uniform int mode = 0;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	if (mode == 1) {
		// 纯色光柱：不采样纹理，只按 UV 做个中间亮、边缘淡的竖条
		float edge = smoothstep(0.0, 0.35, UV.x) * smoothstep(1.0, 0.65, UV.x);
		float soft = smoothstep(0.0, 0.25, UV.y) * smoothstep(1.0, 0.55, UV.y);
		float alpha = edge * soft * (1.0 - fade);
		COLOR = vec4(tint_color.rgb, alpha * 0.9);
	} else {
		// 残影：本体纹理染紫 + 整体随时间淡出
		vec3 tinted = mix(base.rgb, tint_color.rgb, tint_amount);
		float alpha = base.a * (1.0 - fade);
		COLOR = vec4(tinted, alpha);
	}
}
