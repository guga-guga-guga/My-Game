# godot-mcp 引号 bug 补丁说明（2026-09-27 由 Agent 修复并验证）

## 症状
所有"走 GDScript 工具脚本"的 MCP 工具在 **Windows** 上全部失败
（`create_scene` / `add_node` / `save_scene` / `load_sprite` / `get_uid` / `export_mesh_library` / `update_project_uids`）：

```
Failed to parse JSON parameters: '{scene_path:scene/map/map_screen.tscn,root_node_type:Control}'
```

注意：本该是合法 JSON 的参数里，**双引号全被吃掉了**。

## 根因
`godot-mcp@0.1.0` 的 `build/index.js` 这样拼命令并执行：

```js
const paramsJson = JSON.stringify(snakeCaseParams);
const escapedParams = paramsJson.replace(/'/g, "'\''");
const cmd = [ ..., `'${escapedParams}'` ].join(' ');   // ← 用单引号包住 JSON
const { stdout } = await execAsync(cmd);               // ← 经 cmd.exe 执行
```

Windows 的 `cmd.exe` **不把单引号当引号**，还会剥掉内层双引号 →
Godot 侧 `JSON.parse()` 必然失败。

## 补丁：改用 base64 传参（纯 ASCII，无引号/空格）

### 1) `build/index.js`
```diff
-            const paramsJson = JSON.stringify(snakeCaseParams);
-            // Escape single quotes in the JSON string to prevent command injection
-            const escapedParams = paramsJson.replace(/'/g, "'\''");
+            const escapedParams = Buffer.from(JSON.stringify(snakeCaseParams), 'utf8').toString('base64');
```
```diff
-                `'${escapedParams}'`,
+                escapedParams,
```

### 2) `build/scripts/godot_operations.gd`
```diff
-    var params_json = args[params_index]
+    var params_json = Marshalls.base64_to_utf8(args[params_index].strip_edges())
```

## 生效方式
杀掉 godot-mcp 的 node 进程即可 —— dsh 的 mcp-client 会自动重连并加载新代码（实测有效）。

## 验证记录（2026-09-27）
- 独立测试：直接调 operations 脚本 + base64 参数 → `Scene created successfully at: scene/map/_probe.tscn` ✅
- 通过 MCP：`create_scene` → `_probe2.tscn` 创建成功并校验可加载 ✅
- 通过 MCP：`get_uid(scene/game.gd)` → `uid://pisw83wq5jv7` ✅

## 注意事项
1. **`godot-mcp` 升级/重装会覆盖本补丁** → 按上面两条 diff 重打即可。
2. `create_scene` 仍会打印 `ERROR: Condition "p_owner == this" is true.`（包内把根节点 owner 设成自己），**无害**，场景能正常创建。
3. 记录本次补丁前 PATH 里只有 `G:\gi\Git\cmd`、没有 `G:\gi\Git\bin`；harness 需要的 bash 是通过
   `mklink /J "C:\Program Files\Git" "G:\gi\Git"` 建的目录联接提供的。
