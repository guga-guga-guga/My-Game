extends RefCounted
## 关卡目标 M2 —— 把"这一关要做什么"变成**数据 + 纯函数**，方便 headless 测试
##
## 四种目标类型:
##   survive      撑满倒计时 限时内不死 
##   kill         击杀指定数量敌人
##   clear_waves  清空全部波次
##   boss         击败 Boss M3 接上 
##
## ⚠️ 语义按你的决定:一关多个条件时是 **ALL 全部达成才算过关 **
##
## 节点类型 到 目标类型 这样路线图的节点选择就有了玩法差异 :
##   battle 普通战斗  到 clear_waves  清空 2~5 波
##   elite 精英       到 kill + survive 两个条件，正好体现 ALL 
##   boss Boss        到 boss

const TYPE_SURVIVE := "survive"
const TYPE_KILL := "kill"
const TYPE_CLEAR_WAVES := "clear_waves"
const TYPE_BOSS := "boss"

## 没有限时的目标也给一个宽松上限:让倒计时条仍有意义，且战绩里的用时算得准
const DEFAULT_TIME_CAP := 600.0


## 按"层数 + 节点类型"生成目标forced_type 非空时强制指定类型 调试用 
static func build(floor_index: int, node_type: String, forced_type: String = "") -> Dictionary:
	var floor_num := maxi(floor_index, 1)
	var type := forced_type
	# 强制值必须是合法目标类型；否则 例如误把节点类型 "elite" 填进来 回落到按节点类型推断，
	# 避免出现"条件为空，永远打不过"的关卡
	if not is_valid_type(type):
		if node_type == "boss":
			type = TYPE_BOSS
		elif node_type == "elite":
			type = TYPE_KILL
		else:
			type = TYPE_CLEAR_WAVES

	var goal := {
		"floor": floor_num,
		"node_type": node_type,
		"type": type,
		"conditions": [],
		"time_limit": 0.0,
		"waves": [],
		"message": "",
	}

	if type == TYPE_SURVIVE:
		var duration := 60.0 + float(floor_num) * 8.0
		goal["time_limit"] = duration
		goal["conditions"].append({"type": TYPE_SURVIVE, "target": duration, "label": "撑满 %.0f 秒" % duration})

	elif type == TYPE_KILL:
		# 精英:击杀 + 存活，两个条件 ALL 
		var target := 12 + floor_num * 6
		var limit := 50.0 + float(floor_num) * 6.0
		goal["time_limit"] = limit
		goal["conditions"].append({"type": TYPE_KILL, "target": target, "label": "击杀 %d 个敌人" % target})
		goal["conditions"].append({"type": TYPE_SURVIVE, "target": limit, "label": "撑满 %.0f 秒" % limit})

	elif type == TYPE_CLEAR_WAVES:
		var wave_count := clampi(2 + int(floor_num / 2.0), 2, 6)
		var per_wave := 5 + floor_num * 2
		var interval := maxf(0.9 - float(floor_num) * 0.05, 0.35)
		for index in range(wave_count):
			goal["waves"].append({
				"count": per_wave + index * 2,
				"interval": interval,
				"delay": maxf(1.4 - float(floor_num) * 0.05, 0.8),
			})
		goal["conditions"].append({"type": TYPE_CLEAR_WAVES, "target": wave_count, "label": "清空 %d 波敌人" % wave_count})

	elif type == TYPE_BOSS:
		goal["conditions"].append({"type": TYPE_BOSS, "target": 1, "label": "击败 Boss"})

	return goal


## 本关是否有波次表 有则战斗场景不再启动无限刷怪计时器 
static func has_waves(goal: Dictionary) -> bool:
	return not goal.get("waves", []).is_empty()


## 限时 秒 ；0 表示没有硬限时
static func time_limit(goal: Dictionary) -> float:
	return float(goal.get("time_limit", 0.0))


## 倒计时条使用的时长 没有限时就给宽松上限 
static func stage_duration(goal: Dictionary) -> float:
	var limit := time_limit(goal)
	return limit if limit > 0.0 else DEFAULT_TIME_CAP


## 屏幕底部第一行:本关目标
static func describe(goal: Dictionary) -> String:
	var parts: Array[String] = []
	for condition in goal.get("conditions", []):
		parts.append(String(condition.get("label", "?")))
	var text := " + ".join(parts)
	var limit := time_limit(goal)
	if limit > 0.0:
		text += "，限时 %.0f 秒" % limit
	return "目标: " + text


## 屏幕底部第二行的进度
static func progress_text(goal: Dictionary, state: Dictionary) -> String:
	var parts: Array[String] = []
	for condition in goal.get("conditions", []):
		var type := String(condition.get("type", ""))
		var target := float(condition.get("target", 0.0))
		if type == TYPE_KILL:
			parts.append("击杀 %d / %d" % [int(state.get("kills", 0)), int(target)])
		elif type == TYPE_SURVIVE:
			var survived := target - float(state.get("time_left", target))
			parts.append("存活 %.0f / %.0f 秒" % [maxf(survived, 0.0), target])
		elif type == TYPE_CLEAR_WAVES:
			parts.append("波次 %d / %d" % [int(state.get("waves_done", 0)), int(target)])
		elif type == TYPE_BOSS:
			parts.append("BOSS %s" % ("已击败" if bool(state.get("boss_defeated", false)) else "存活"))
	return " ".join(parts)


## ALL 语义:所有条件都达成才算过关
static func is_satisfied(goal: Dictionary, state: Dictionary) -> bool:
	var conditions: Array = goal.get("conditions", [])
	if conditions.is_empty():
		return false
	for condition in conditions:
		var type := String(condition.get("type", ""))
		var target := float(condition.get("target", 0.0))
		if type == TYPE_KILL:
			if int(state.get("kills", 0)) < int(target):
				return false
		elif type == TYPE_SURVIVE:
			if float(state.get("time_left", target)) > 0.0:
				return false
		elif type == TYPE_CLEAR_WAVES:
			if int(state.get("waves_done", 0)) < int(target):
				return false
		elif type == TYPE_BOSS:
			if not bool(state.get("boss_defeated", false)):
				return false
	return true


## 有限时且时间已到，但目标未完成 到 判负
static func is_timed_out(goal: Dictionary, state: Dictionary) -> bool:
	if time_limit(goal) <= 0.0:
		return false
	if is_satisfied(goal, state):
		return false
	return float(state.get("time_left", 0.0)) <= 0.0


## 是否是合法的目标类型 build 的强制参数校验用 
static func is_valid_type(type: String) -> bool:
	return type == TYPE_SURVIVE or type == TYPE_KILL or type == TYPE_CLEAR_WAVES or type == TYPE_BOSS
