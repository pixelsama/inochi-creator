# Agent 建模接口

本分支把 Inochi2D 模型制作开放为可编程的工具链。输入是分层 PSD，输出是可继续编辑的 INX；不提供 Cubism `.moc3` 导出。接口能力允许针对角色设计网格、关键形态和参数组合，成品质量仍需以实际运动画面验收。

## 构建与测试

Apple Silicon macOS，默认部署目标为 macOS 13.0。需要 DUB、Xcode 命令行工具以及 LDC 1.41.0。默认 LDC 路径沿用本项目配置，可通过 `INOCHI_AGENT_TOOLCHAIN` 指定工具链根目录。

```sh
./build-aux/osx/AgentCliBuild.sh test --config=application
./build-aux/osx/AgentCliBuild.sh build --config=application
python3 -m unittest discover -s tests -v
```

`build` 默认使用 release 构建（CPU 渲染器在 debug 构建下约慢 3 倍），可显式传入 `--build=debug`。脚本可从任意工作目录通过绝对路径调用。它从 `agent-cli` 注册修补过的 Inochi2D 0.8.7，防止误用未修补的 registry SDK；编译器包装脚本固定 deployment triple，并保留 DUB 的 unittest/release 构建设置。首次运行可能下载依赖。当前验证范围为 macOS arm64 的 CLI，GUI、Windows、Linux 的构建不属于本轮验收。

## 推荐调用流程

所有自动化调用使用 `--json`，并检查进程退出状态与 `ok`：

```sh
agent-cli/inochi-agent --json capabilities
agent-cli/inochi-agent --json schema rig
agent-cli/inochi-agent --json psd-inspect character.psd psd-report.json
agent-cli/inochi-agent --json psd-import character.psd base.inx
agent-cli/inochi-agent --json model-describe base.inx
agent-cli/inochi-agent --json rig-validate base.inx rig.json
agent-cli/inochi-agent --json rig-apply base.inx rigged.inx rig.json
agent-cli/inochi-agent --json pose-sample rigged.inx poses.json
agent-cli/inochi-agent --json pose-render rigged.inx poses.json previews
```

保留 `base.inx`，便于重新生成完整 Rig。日常调整可以在已绑定模型上用 `rig-apply` 按同名参数替换关键帧，但不要重复提交已经建立的 group/physics 创建请求；该命令是有序的编辑操作，不是任意整份规格的幂等同步。

`model-describe` 返回节点路径、UUID、原始 PSD 路径、网格、变换、蒙版、参数、绑定关键值和物理配置。Agent 应先读取这些结构，再生成编辑请求。`inspect` 保留简短计数摘要。`schema rig` 返回编译进程序的 JSON Schema，不依赖当前工作目录；跨字段、模型引用和 SDK 的限制仍由 `rig-validate` 检查。

真实 PSD 可能包含同名兄弟图层。路径存在歧义时，可从 `model-describe` 获取 UUID，使用 `node-rename input.inx output.inx UUID NewName` 为导入后的节点命名。它不修改原 PSD，不改变 UUID、绑定、网格或纹理，保留原 `psdLayerPath`；之后用新的场景路径定位该节点。禁止与兄弟节点重名以及包含 `/` 的名称，根节点不在重命名范围内。

`rig-validate` 在独立临时目录生成候选并交给真实 SDK 加载，返回与 `rig-apply` 相同的 `rig`、`sdk` 统计，随后清理候选，不发布模型。

机器模式下，每次调用的 stdout 是一个 JSON 对象：

```json
{"protocol_version":1,"ok":true,"result":{}}
```

失败返回 `ok:false`、`error.code`、`error.message`。退出码 2 表示 `USAGE_ERROR`；退出码 1 表示 `INVALID_JSON`、`IO_ERROR` 或 `VALIDATION_ERROR`。错误消息保留参数名、路径、字段或关键帧位置。非 `--json` 的旧命令保持 result-only 输出，供已有脚本使用；新脚本应依赖机器模式的单对象协议。

## Rig v1

顶层可包含 `schema_version:1`、`groups`、`parts`、`masks`、`meshes`、`parameters`、`physics`、`automation`，按此顺序应用。未知字段、重复参数名、同参数内重复目标属性、无效范围与错误维度会被拒绝。

### 一维与二维参数

一维参数延续原来的格式：

```json
{
  "name":"Blink",
  "min":0,"max":1,"default":0,"keys":[0,0.5,1],
  "bindings":[{"path":"/Eyes/Iris","property":"opacity","values":[1,0.5,0]}]
}
```

二维参数使用两个 `axes` 对象；`values[x][y]` 是 **X 优先** 的关键值表，X/Y 的关键点数不必相同。例如下面的表有 3 列、2 行：

```json
{
  "schema_version":1,
  "parameters":[{
    "name":"HeadXY",
    "axes":[
      {"min":-1,"max":1,"default":0,"keys":[-1,0,1]},
      {"min":0,"max":1,"default":0,"keys":[0,1]}
    ],
    "bindings":[{
      "path":"/Iris","property":"transform.t.x",
      "interpolation":"Linear","values":[[0,8],[2,10],[4,12]]
    }]
  }]
}
```

二维参数可以独立定义转头与抬头的组合形态，包含数值属性或逐顶点形变。它必须在运行时由两个输入轴驱动；两个独立的一维参数不会自动转换成二维联动。第三个以上独立因素的联合形态、表达式驱动和跨参数修正网络尚未提供通用接口。

关键点必须递增并覆盖完整 min/max；默认值必须在范围内。数字必须有限并适合 SDK float，归一化关键点不能在 float 精度下重合。各轴缺省 min/max/default 为 0/1/0。

支持的绑定属性：

- `transform.t.x/y/z`：相对节点原始变换的位移。任意节点。
- `transform.r.x/y/z`：旋转增量，单位为弧度。任意节点。
- `transform.s.x/y`：缩放乘数，1 表示不改变。任意节点。
- `zSort`：叠加到节点绘制顺序上的偏移，任意节点；数值越大越靠后。用于转头时耳朵、侧发前后切换，手臂交叉等。
- `opacity`：Part 或 Composite 不透明度乘数，关键值范围 `[0,1]`。
- `tint.r/g/b`：Part 或 Composite 的乘色乘数（≥0），与静态 tint 相乘后截断到 `[0,1]`。用于脸红、阴影变色。
- `screenTint.r/g/b`：滤色叠加偏移 `[-1,1]`，与静态 screen tint 相加后截断到 `[0,1]`。
- `deform`：Part 或 MeshGroup 每个顶点的局部位移。

SDK 的 `alphaThreshold` 与 `emissionStrength` 参数偏移在 0.8.7 中实现有误（前者恒为 0，后者默认值被重复叠加），因此不开放绑定。

每个 binding 可选择 `Linear`（默认）、`Nearest`、`Cubic`；三者使用 SDK 实际插值。Cubic 可能在关键点之间产生过冲，需要检查中间姿态，不能只验证端点。

### 网格与自由形变

规则网格：`{"path":"/Iris","columns":7,"rows":5}`，行列表示顶点数。

自定义网格：

```json
{
  "path":"/Iris",
  "mesh":{
    "verts":[-2,-2,-2,2,2,-2,2,2],
    "uvs":[0,0,0,1,1,0,1,1],
    "indices":[0,1,2,2,1,3],
    "origin":[0,0]
  }
}
```

`verts` 和 `uvs` 是平铺的坐标对，`indices` 是三角形顶点索引；输入三角形绕序会规范化。最多 65536 个顶点。不允许重复顶点构成的三角形、退化三角形和越界索引。自定义 Rig 网格需要 UV；更换网格与建立新绑定可以在同一份 Rig 中完成。

`deform` 的一个关键值可以是：

- `null`：所有顶点位移为零。
- `{"offsets":[[0,2],[0,0],[0,2],[0,0]]}`：按当前网格顶点顺序逐点指定 `(dx,dy)`，长度必须精确匹配网格。这是精修眼睑、嘴角、脸型和复杂转面的主要入口。
- `{"profiles":[{"type":"tipX","amount":2}]}`：预设形变的叠加。支持 translate、archX/Y、shearX/Y、tipX/Y、scaleX/Y、pinchX/Y、curveMorph。

`curveMorph` 支持 widthScale、thicknessScale、offsetY、curvatureY、slopeY、amount。`anchorLeft`/`anchorRight` 表示 `[0,1]` 的锚定渐变宽度，用 smoothstep 平滑过渡；0 不锚定。图像的视觉语义不会自动产生这些关键值，需由 Agent 针对实际素材设计。

#### 按 alpha 自动网格

```json
{"path":"/Hair/Front","auto":{"spacing":16,"margin":2,"alpha_threshold":8,"max_vertices":4000}}
```

根据 Part 贴图的 alpha 生成贴合轮廓的三角网格：边界点间距为 `spacing/2`，内部点间距为 `spacing`（纹理像素），Delaunay 三角化后丢弃轮廓外的三角形。所有 alpha ≥ `alpha_threshold` 的像素及其一像素双线性过滤范围都保证被覆盖，`margin` 是在此之外额外保留的边距。生成后静止画面与原四边形逐像素一致。目标 Part 当前网格的 UV 必须与顶点线性对应（导入的四边形和规则网格都满足）。`auto` 与 `mesh`、`columns/rows` 三选一。

已绑定的 Part 同样可以用 `mesh-retopologize-path` 迁移到自动网格，请求文件写 `{"auto":{...}}` 即可，已有关键帧会按 UV 重心坐标重采样。

已绑定网格的普通替换只允许保持拓扑。需要增删顶点时使用显式迁移：

```sh
agent-cli/inochi-agent --json mesh-retopologize-path rigged.inx refined.inx /Iris refined-mesh.json
```

此命令依据旧 UV 三角形的重心坐标，重采样该 Part 的所有 deformation binding、所有 X/Y 关键帧；保留参数身份、插值设置、其他绑定和纹理。新 UV 必须落在旧 UV 覆盖范围内；不支持无 UV、无法覆盖的区域和含歧义的重叠。新三角形的连接方式仍可能改变插值表面，迁移成功后必须重新渲染关键帧与中间姿态。

### 层级、MeshGroup、Composite

`groups` 按数组顺序在模型根下建立节点并将 `paths` 指定的节点移入，`pivot:[x,y]` 设置旋转中心，`zsort` 设置排序。可以先建立局部组，再将组放入共同父组。路径从模型根开始，省略根节点名称。`type` 决定节点类型：

- `Node`（默认）：普通层级节点。
- `MeshGroup`：变形笼（对应 Cubism 的弯曲变形器）。默认在子节点静止外包框外扩 `margin`（默认 8 像素）后铺 `columns`×`rows`（默认 5×5）规则网格，也可以用 `mesh` 给出自定义网格；`dynamic` 对应 SDK 的 `dynamic_deformation`（默认 false）。对 MeshGroup 绑定 `deform` 后，其下所有 Part（以及嵌套的 MeshGroup）都随笼子变形，这是整体转面、脸型变化的主要手段。自动外包框要求中间节点没有旋转和缩放。
- `Composite`：先在离屏缓冲中绘制其下所有 Part，再以 `blend_mode`、`opacity`、`tint`、`screen_tint` 一次性合成，重叠部分不会重复叠加透明度。SDK 会把嵌套的 Composite 拍平，因此禁止嵌套。

```json
{"groups":[
  {"name":"FaceWarp","type":"MeshGroup","paths":["/Face","/Eyes","/Mouth"],"pivot":[0,-300],"columns":6,"rows":6},
  {"name":"Sleeve","type":"Composite","paths":["/SleeveBase","/SleeveShade"],"opacity":0.8}
]}
```

PSD 导入时，混合模式不是穿透/正常、或不透明度低于 100% 的图层组会导入为 Composite；需要嵌套 Composite 的 PSD 会被拒绝。

### 部件外观

`parts` 设置 Part 或 Composite 的静态外观：`blend_mode`、`opacity`、`tint:[r,g,b]`、`screen_tint:[r,g,b]`（各通道 `[0,1]`）。参数绑定的 tint 在此基础上相乘、screen tint 在此基础上相加。

混合模式可用 Normal、Multiply、Screen、Overlay、Darken、Lighten、ColorDodge、LinearDodge、AddGlow、ColorBurn、HardLight、SoftLight、Difference、Exclusion、Subtract、Inverse、DestinationIn、ClipToLower、SliceFromLower。macOS 的 OpenGL 不支持 advanced blending，Overlay、Darken、ColorBurn、HardLight、SoftLight、Difference 在 macOS 运行时按 Normal 绘制；CPU 预览遵循同样的规则，并在渲染报告的 `legacyBlendFallbacks` 中列出使用这些模式的节点。

### 蒙版、物理、自动化

`masks` 使用 `target`、`source` 的 Part 路径与 `mode:mask/dodge_mask`。蒙版不等于补图：眼白、眼睑和被遮挡内容必须具有足够的有效像素。

`physics` 使用 `name`、`parent`、`parameter`、`model_type`、`map_mode`；支持 Pendulum / SpringPendulum，以及 length、frequency、gravity、angle_damping、length_damping、output_scale、local_only。参数需在模型中存在或在本次 Rig 创建。

`automation` 建立正弦自动化，例如呼吸和待机摆动：

```json
{"automation":[{"name":"Breathing","speed":2,"wave":"sin","bindings":[{"parameter":"Breath","axis":0,"range":[0,1]}]}]}
```

`speed` 为弧度/秒，`wave` 为 `sin` 或 `cos`，`range` 必须在参数范围内。波形以参数的 Additive 合并方式叠加到面捕值上；同名自动化会被替换。0.8.7 SDK 读取 automation 的 `range` 时有错误，本分支通过 `inochi2d-serialization-fixes.patch` 修复，Agent Session 使用同一份 SDK。

### 关键帧动画

`animations` 把动作写进模型，是 Inochi2D 中与 Live2D motion 文件对应的数据，由 SDK 的 AnimationPlayer 播放。Inochi Session 可以在加载、空闲或面捕阈值触发时播放它们。

```json
{"animations":[{"name":"Nod","fps":30,"length":60,"lanes":[
  {"parameter":"HeadXY","axis":1,"interpolation":"Cubic","keyframes":[[0,0],[12,-0.8],[24,0.1],[59,0]]}]}]}
```

- 每条 lane 驱动一个参数轴。关键帧写成 `[frame, value]` 或 `[frame, value, tension]`，帧号严格递增。
- 帧号必须在 `[0, length-1]` 内：播放器最后停在第 length-1 帧。
- `interpolation` 可选 Nearest、Linear、Stepped、Cubic（默认）、Bezier。Cubic 是 Catmull-Rom 曲线，可能越过关键值。
- `merge_mode` 默认为 Forced，即覆盖面捕值，关键值必须在参数范围内。`additive:true` 的动画默认用 Additive，值是叠加在面捕值上的偏移。
- `lead_in` / `lead_out` 定义循环区间以外的开头和结尾。
- 不允许以物理驱动的参数为目标：物理每帧都会覆盖它们。请改为给引起摆动的参数做动画。
- 同名动画会被替换。`model-describe` 的 `animations` 列出各条动画的轨道；`rig-apply` 返回的 SDK 统计中含 `animationCount` / `animationLaneCount`，表示 SDK 已加载并解析了每条 lane 的参数。

预览时，在 pose 的 physics 中加 `"animation":{"name":"Nod","loop":false}`，就会按运行时的顺序每帧先更新 AnimationPlayer、再更新 puppet，因此物理也会随动画响应。配合 `capture_every` 可以一次输出整段动作的逐帧图像。

## 姿态验证与渲染

```json
{
  "canvas":{"width":32,"height":32},
  "poses":[
    {"name":"neutral","parameters":{"HeadXY":[0,0]}},
    {"name":"diagonal","parameters":{"HeadXY":[1,1]},"probes":["/Iris"]}
  ]
}
```

一维参数使用数字；二维参数必须使用 `[x,y]`。输入未指定的参数恢复默认值。`pose-sample` 与 `pose-render` 共用输入校验；省略 probes 时采样全部 Part 和 MeshGroup。可显式传入 probes 限制大模型输出量。

`canvas.camera` 与 Inochi2D 相机一致：像素 = (世界坐标 + `position`) × `scale` + 画布尺寸/2，例如 `{"scale":0.5,"position":[0,300]}` 用于全身缩小预览或局部放大。

探针输出包括实际世界顶点、局部顶点位移、位置、旋转、zSort、生效的不透明度与 tint/screenTint、变形幅度，以及局部形变造成的翻转三角形数和塌陷三角形数。位置从渲染矩阵变换原点得到，避免 SDK Transform 分解中的额外偏移。非有限值会报错，不会伪装成零。翻面/塌陷计数是检查线索，例如闭眼可能故意压平局部网格；必须结合具体部件与画面判断。

CPU 预览使用 SDK 参数与网格，按 macOS OpenGL 运行时的规则绘制：全部混合模式（legacy 固定管线公式，只影响部件实际覆盖的像素）、tint 与 screen tint、Composite、MeshGroup（含动态组合）、二值 stencil 蒙版（遮罩源原始 alpha 与其 mask_threshold 比较），以及有限帧物理和自动化模拟。贴图采样与 GPU 相同：texel 中心寻址、透明边框（CLAMP_TO_BORDER）、按三角形屏幕导数选择层级的三线性 mipmap；像素中心恰好落在边上时按 OpenGL（y 轴向上）的规则归属。MeshGroup 使用实际点的三角形归属，并以局部重心坐标插值；变形组与子节点组合已由独立烘焙图像回归检查。半透明三角形共用边只合成一次，避免网格对角线变深。`canvas.supersample` 可选整数 1–4，默认 1 保留原采样结果；2 表示横纵各 2 倍栅格采样，再以预乘 Alpha 降采样到原输出尺寸。蒙版使用相同采样倍率，模型比例、参数与物理步数不变。包含超采样后的内部栅格最多 16777216 像素，例如 1254×1254 支持 1–3 倍，4 倍会明确拒绝。渲染报告返回实际 `supersample`。带蒙版的 Composite 会明确拒绝。CPU 预览不保证与 GPU 每个像素完全相同：驱动自带的 mipmap 生成滤波无法精确复刻，缩小显示时细线处会有轻微差异。

### GPU 验收

`tools/gpu_acceptance.py` 用真实 GPU 复核 CPU 预览：对每个姿态启动 Agent Session（固定姿态、冻结物理与自动化、关闭光照后处理、透明背景）截取帧缓冲，再用相同相机做 CPU 渲染，比较预乘 RGBA，输出差异图和 `gpu-acceptance.json`。

```sh
python3 tools/gpu_acceptance.py rigged.inx poses.json gpu-check --camera-scale 0.5 --camera-position 0 300
```

默认阈值：通道差超过 8 的像素不超过 1%，alpha 覆盖 IoU 不低于 0.98。实测（真实角色模型）1:1 缩放时最大通道差 2，0.5 倍时超阈值像素约 0.2%–0.8%。需要先构建 `../inochi-session-agent` 的 `osx-agent-bundle`，或用 `--session-app` / `INOCHI_AGENT_SESSION` 指定路径。

`pose-sample` 和未声明物理帧的 `pose-render` 只评估静态参数，不推进自动化或物理；显式传入的物理驱动参数也会被应用，静态结果不依赖前一个姿态。`pose-render` 的 pose 可声明 `physics:{"frames":60,"dt":0.0166666667}`，可选 trajectory 数组需与 frames 等长；轨迹每帧是参数对象。渲染结果返回文件路径、像素数量、RGBA hash 与物理统计。 其中 `physicsParameters` 按实际驱动参数名称返回 `[x,y]` 两轴值，可结合轨迹最后一帧的普通参数，独立重放同一画面或用 `pose-sample` 复验几何。旧 `physicsParameterValues` 数组仍保留兼容；其字典遍历顺序不应当作参数身份。

动作预览可在同一 pose 的 physics 中加 `capture_every:N`：在一次模拟中每 N 帧写出一张 `<序号>_<名称>_f<帧号>.png`，路径列在 `frameOutputPaths`，最后仍写出常规结果图。连续动画因此只需模拟一次，而不必为每一帧单独建 pose 并从头模拟。

PSD 导入会跳过没有像素范围的空图层（它们不影响画面），并在结果的 `skippedEmptyLayers` 中列出其路径。

## 写入与兼容性

机器模式下，INX 修改先写入目标目录下的唯一 staging 子目录，通过 SDK 验证后原子 rename；失败保留既有目标文件，且不删除别的调用留下的 `.agent-incomplete` 文件。允许显式原地编辑，但建议保留 base 与重要迭代版本。并发写同一目标仍是最后完成者覆盖，调用方应串行化同一模型的写入。

旧的非机器模式 mesh-replace / roundtrip 延续容器级验证，支持原先的低层工作流；它们同样使用隔离 staging。PSD 导入和 Rig 应用始终使用 SDK 验证。pose-render 的图片目录为逐张写出，调用方应为每轮预览使用新目录；它不是多文件事务。

单元与集成测试使用代码生成的 PSD、纯色部件和人工指定关键帧。GPU 验收另外在少年试作模型和 Gate2 半身 PSD 上运行过（只读，未修改源文件）。输入 PSD 的真实分层、隐藏区域完整度、语义结构和美术质量，需要针对每个角色单独评估。
