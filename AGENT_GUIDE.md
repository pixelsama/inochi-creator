# Agent 建模接口

本分支把 Inochi2D 模型制作开放为可编程的工具链。输入是分层 PSD，输出是可继续编辑的 INX；不提供 Cubism `.moc3` 导出。接口能力允许针对角色设计网格、关键形态和参数组合，成品质量仍需以实际运动画面验收。

## 构建与测试

Apple Silicon macOS，默认部署目标为 macOS 13.0。需要 DUB、Xcode 命令行工具以及 LDC 1.41.0。默认 LDC 路径沿用本项目配置，可通过 `INOCHI_AGENT_TOOLCHAIN` 指定工具链根目录。

```sh
./build-aux/osx/AgentCliBuild.sh test --config=application
./build-aux/osx/AgentCliBuild.sh build --config=application
python3 -m unittest discover -s tests -v
```

脚本可从任意工作目录通过绝对路径调用。它从 `agent-cli` 注册修补过的 Inochi2D 0.8.7，防止误用未修补的 registry SDK；编译器包装脚本固定 deployment triple，并保留 DUB 的 unittest/release 构建设置。首次运行可能下载依赖。当前验证范围为 macOS arm64 的 CLI，GUI、Windows、Linux 的构建不属于本轮验收。

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

顶层可包含 `schema_version:1`、`groups`、`meshes`、`masks`、`parameters`、`physics`。未知字段、重复参数名、同参数内重复目标属性、无效范围与错误维度会被拒绝。

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

- `transform.t.x/y/z`：相对节点原始变换的位移。
- `transform.r.x/y/z`：旋转增量，单位为弧度。
- `transform.s.x/y`：缩放乘数，1 表示不改变。
- `opacity`：Part 不透明度乘数，关键值范围 `[0,1]`。
- `deform`：Part 每个顶点的局部位移。

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

已绑定网格的普通替换只允许保持拓扑。需要增删顶点时使用显式迁移：

```sh
agent-cli/inochi-agent --json mesh-retopologize-path rigged.inx refined.inx /Iris refined-mesh.json
```

此命令依据旧 UV 三角形的重心坐标，重采样该 Part 的所有 deformation binding、所有 X/Y 关键帧；保留参数身份、插值设置、其他绑定和纹理。新 UV 必须落在旧 UV 覆盖范围内；不支持无 UV、无法覆盖的区域和含歧义的重叠。新三角形的连接方式仍可能改变插值表面，迁移成功后必须重新渲染关键帧与中间姿态。

### 层级、蒙版、物理

`groups` 按数组顺序建立 Node 并将 `paths` 指定的节点移入，`pivot:[x,y]` 设置旋转中心，`zsort` 设置排序。可以先建立局部组，再将组放入共同父组。路径从模型根开始，省略根节点名称。

`masks` 使用 `target`、`source` 的 Part 路径与 `mode:mask/dodge_mask`。蒙版不等于补图：眼白、眼睑和被遮挡内容必须具有足够的有效像素。

`physics` 使用 `name`、`parent`、`parameter`、`model_type`、`map_mode`；支持 Pendulum / SpringPendulum，以及 length、frequency、gravity、angle_damping、length_damping、output_scale、local_only。参数需在模型中存在或在本次 Rig 创建。

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

一维参数使用数字；二维参数必须使用 `[x,y]`。输入未指定的参数恢复默认值。`pose-sample` 与 `pose-render` 共用输入校验；省略 probes 时采样全部 Part。可显式传入 probes 限制大模型输出量。

探针输出包括实际世界顶点、局部顶点位移、位置、旋转、不透明度、变形幅度，以及局部形变造成的翻转三角形数和塌陷三角形数。位置从渲染矩阵变换原点得到，避免 SDK Transform 分解中的额外偏移。非有限值会报错，不会伪装成零。翻面/塌陷计数是检查线索，例如闭眼可能故意压平局部网格；必须结合具体部件与画面判断。

CPU 预览使用 SDK 参数与网格，支持 Normal 混合、Part 蒙版、MeshGroup（含动态组合）和有限帧物理模拟。MeshGroup 使用实际点的三角形归属，并以局部重心坐标插值；变形组与子节点组合已由独立烘焙图像回归检查。半透明三角形共用边只合成一次，避免网格对角线变深。`canvas.supersample` 可选整数 1–4，默认 1 保留原采样结果；2 表示横纵各 2 倍栅格采样，再以预乘 Alpha 降采样到原输出尺寸。蒙版使用相同采样倍率，模型比例、参数与物理步数不变。包含超采样后的内部栅格最多 16777216 像素，例如 1254×1254 支持 1–3 倍，4 倍会明确拒绝。渲染报告返回实际 `supersample`。复杂混合模式、Composite 节点和非默认 tint 会明确拒绝，避免用错误预览作验收；这些效果需要真实 GPU 运行时复核。CPU 预览也不保证与 GPU 每个采样像素完全相同。

`pose-sample` 和未声明物理帧的 `pose-render` 只评估静态参数，不推进自动化或物理；显式传入的物理驱动参数也会被应用，静态结果不依赖前一个姿态。`pose-render` 的 pose 可声明 `physics:{"frames":60,"dt":0.0166666667}`，可选 trajectory 数组需与 frames 等长；轨迹每帧是参数对象。渲染结果返回文件路径、像素数量、RGBA hash 与物理统计。 其中 `physicsParameters` 按实际驱动参数名称返回 `[x,y]` 两轴值，可结合轨迹最后一帧的普通参数，独立重放同一画面或用 `pose-sample` 复验几何。旧 `physicsParameterValues` 数组仍保留兼容；其字典遍历顺序不应当作参数身份。

## 写入与兼容性

机器模式下，INX 修改先写入目标目录下的唯一 staging 子目录，通过 SDK 验证后原子 rename；失败保留既有目标文件，且不删除别的调用留下的 `.agent-incomplete` 文件。允许显式原地编辑，但建议保留 base 与重要迭代版本。并发写同一目标仍是最后完成者覆盖，调用方应串行化同一模型的写入。

旧的非机器模式 mesh-replace / roundtrip 延续容器级验证，支持原先的低层工作流；它们同样使用隔离 staging。PSD 导入和 Rig 应用始终使用 SDK 验证。pose-render 的图片目录为逐张写出，调用方应为每轮预览使用新目录；它不是多文件事务。

本轮验证使用代码生成的 32×32 PSD、纯色部件和人工指定关键帧，不使用任何旧角色 PSD。输入 PSD 的真实分层、隐藏区域完整度、语义结构和美术质量，需要在收到新 PSD 后单独评估。
