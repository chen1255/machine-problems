# MachineProblems · CNC 车床故障诊断 Agent

面向**一线维修工与现场操作员**的 CNC 数控车床技术顾问：把「机器不对劲」这种模糊报修，收敛成
**安全先行、可执行、可验证**的诊断与处置流程；高危作业方案在交付前先由独立的安全复核子智能体把关。

> 这是一个跑在 [DeerFlow](https://github.com/bytedance/deer-flow)（字节跳动开源、基于 LangGraph 的 Agent 框架）**之上的行业 Agent 资产包**。
> 本仓库**不包含、也不是** DeerFlow 框架本体，而是一套可一键挂载到已有 DeerFlow 实例上的「人设 + 技能 + 领域库 + 子智能体」原创配置与内容。运行时、模型调用、工具与 Web UI 均由 DeerFlow 提供。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 它能做什么

| 能力 | 说明 |
|---|---|
| 🩺 结构化故障分诊 | 按「安全前置 → 分诊问诊 → 原因排序 → 分步排查 → 处置建议」收敛，先问清再下结论，不跳步、不臆测 |
| 🚨 报警码解读 | 区分系统品牌/系列与机床厂自定义报警，先查本地报警库；**库里没有的码绝不编造**，转联网或机型手册 |
| 🗓️ 预防性维护 PM | 结合台账运行小时/班次，输出日/周/月/季/半年/年分级保养项、判定标准、耗材与到期提醒 |
| 🔒 LOTO 安全规程 | 识别电、机械惯性、重力、液压、气压、电容余电等能量源，生成可打印的上锁挂牌作业票 |
| 🧾 维修工单流转 | 开单 / 过程更新 / 完工回填 / 复发查询 / 停机统计，闭环案例沉淀进故障案例库 |
| 🛡️ 安全复核子智能体 | 高危拆装/维修方案在交付前，主助手通过 `task` 委托 **safety-reviewer** 独立审查，返回三档结论 |

## 旗舰特性：多智能体安全复核

主诊断助手（lead agent）与一个**零工具、纯安全推理**的 `safety-reviewer` 子智能体协作：

```
现场提问
   │
   ▼
machine-problems（主助手：5 技能 + machine-db + 联网）
   │  形成涉及高危能量源的拆装/维修方案时
   │  通过 task 工具委托（白名单：仅 safety-reviewer）
   ▼
safety-reviewer（资深 EHS 工程师，无任何外部工具）
   │  只审「能量隔离 + 资质合规」，不改判技术诊断
   ▼
三档结论：通过 / 补充措施后可进行 / 不建议自行处理
   │
   ▼
主助手把补充措施或升级建议并入最终答复 / LOTO 作业票
```

对**明确违章**的请求（如「不停电、带电开柜徒手测量」），主助手会直接拒绝并给出合规做法——安全是第一道闸门，子智能体复核是第二道闸门，二者不互相替代。

## 领域知识库（machine-db，5 张关联表）

通过 MCP（`mcp-server-sqlite`）挂载一个本地 SQLite 库，工单与案例按设备/报警码关联，支撑**复发诊断**与停机统计：

```
machines(设备台账)
   │ 1
   │
   │ n            alarms(报警码字典)
work_orders(维修工单) ────── alarm_code
   │ n
   │ FK fault_case_id
fault_cases(故障案例库)          pm_records(PM 保养记录)
```

随库附带一份**完全虚构**的演示种子（4 台设备 / 9 条报警码 / 4 个案例 / 4 张工单 / 3 条保养记录），仅用于演示与自测，请在真实环境替换为自己的数据。

## 目录结构

```
machine-problems/
├─ persona/SOUL.md                      # 人设：角色、行为准则、安全红线、子智能体委托规则
├─ config/agent.config.yaml             # Agent 配置（工具组/技能/MCP/子代理白名单/低发散采样）
├─ skills/                              # 5 个领域技能（SKILL.md + 可填写模板）
│  ├─ fault-triage/                     #   故障分诊（含 diagnosis_template.md）
│  ├─ alarm-decode/                     #   报警码解读（alarm_template.md）
│  ├─ pm-planner/                       #   分级 PM 计划（pm_template.md）
│  ├─ loto-safety/                      #   LOTO 作业票（loto_template.md）
│  └─ work-order/                       #   工单流转（workorder_template.md）
├─ integrations/machine-db/
│  ├─ schema.sql                        # 5 表结构 + 常用检索 SQL
│  ├─ seed.sql                          # 虚构演示数据（仅空库时灌入）
│  └─ mcp.example.json                  # MCP 配置片段（含 Windows UTF-8 关键设置）
├─ subagents/safety-reviewer.yaml       # 安全复核子智能体（带幂等注入标记块）
├─ scripts/install.ps1                  # Windows 一键安装器（6 步，幂等）
├─ examples/                            # 真实本地实测对话节选
└─ docs/architecture.md                 # 架构、挂载点与踩坑记录
```

## 环境要求

- 一个可运行的 [DeerFlow](https://github.com/bytedance/deer-flow) 实例（本仓库在 DeerFlow 主分支后端 + Web 网关上实测）
- Python 3.12、[uv/uvx](https://docs.astral.sh/uv/)（用于拉起 MCP server）
- 一个 LLM API Key（DeerFlow 支持的模型均可；实测使用 DeepSeek，**不需要**联网搜索专用 Key，默认走免 Key 的 DuckDuckGo）
- Windows / macOS / Linux 均可；安装脚本与排障说明主要面向 **Windows + 中文系统**

## 安装

### Windows 一键（推荐）

以普通 PowerShell 运行（脚本默认对接 `d:\...\deepflow\deer-flow`，可用 `-DeerFlowRoot` 覆盖）：

```powershell
.\scripts\install.ps1
# 或指定实例与用户：
.\scripts\install.ps1 -DeerFlowRoot "D:\path\to\deer-flow" -UserId "<your-user-id>"
```

安装器幂等地完成 6 件事：

1. 定位用户空间，复制 Agent（人设 + 配置）与 5 个技能；
2. 合并 `machine-db` MCP server 与技能开关到 `extensions_config.json`（写入本机绝对路径、注入 UTF-8 与 uv 镜像环境变量）；
3. 创建 `machines.db`、建 5 张表，**仅空库时**灌入演示种子；
4. 把 `safety-reviewer` 子智能体以 `BEGIN/END managed block` 标记块幂等注入全局 `config.yaml`；
5. 确认 Agent 的 `allowed_subagents` 白名单；
6. 把免 Key 的 `web_search` 指向 DuckDuckGo（已配置 Tavily Key 时可用 `-UseDuckDuckGo:$false`）。

随后**重启 Gateway**，在新会话中选择「**CNC车床诊断助手**」即可。卸载只需删除 `config.yaml` 中两个标记之间的内容并重启。

### 手工

按 `mcp.example.json` 注释把 `mcpServers.machine-db` 与 `skills` 段合并进 DeerFlow 的 `extensions_config.json`；
把 `subagents/safety-reviewer.yaml` 两个标记之间的顶层 `subagents:` 块追加到 `config.yaml`；技能目录复制到用户空间 `skills/custom/`。详见 [docs/architecture.md](docs/architecture.md)。

## 实测情况（本地端到端）

使用 DeerFlow 的嵌入式客户端以 `machine-problems` 身份跑真实模型，验证过以下链路（节选见 [`examples/`](examples/)）：

- **复发故障诊断**：对「CNC-01 偶发 X 轴 414、晃动拖链可复现、上月犯过一次」，助手依次查询台账 / 报警字典 / 工单 / 案例库（9 次只读查询全部成功、0 次被拦），命中复发案例「X 轴编码器线缆随拖链弯折致芯线疲劳虚接」与在途工单 WO-20260920-04，并主动提示生成 LOTO 作业票。
- **安全复核委托**：对「已断电、更换主轴皮带」的合法高危作业，助手加载 LOTO 技能后委托 `safety-reviewer`，得到「补充措施后可进行」，并将一人一锁一牌、电容放电、重力机械支撑等补充措施并入作业票落盘。
- **违章直接拦截**：对「带电开柜徒手测量编码器线」明确拒绝，改给停机上锁的合规做法。

> 以上为本地功能验证；不同模型在工具调用与委托触发上可能有差异，生产使用前请按自己的机型与制度自行验收。

## 安全与免责（务必阅读）

- 本助手输出的是**通用技术与安全建议**，不能替代你所在单位的作业许可制度、设备厂家维修手册和现场负责人的决定。
- 涉及电气、能量隔离、起吊、进入机械内部等作业，必须由**具备相应资质的人员**按制度执行 LOTO；报警码的精确定义、诊断号、放电时间、扭矩等**一律以具体机型手册为准**，助手对查不到的内容不会编造。
- 演示库中的设备、人员、工单均为虚构；表结构按隐私最小化设计，只记录工号/班组，不含个人敏感信息。
- 本项目以 MIT 许可发布；DeerFlow 框架遵照其各自许可。

## Windows 中文系统排障

- **现象**：MCP `list_tables`/`describe_table` 正常，但 `read_query` 一旦返回中文就 60 秒超时。
  **原因**：`mcp-server-sqlite` 子进程在中文 Windows 默认按 GBK 写 stdout，被 MCP 客户端按 UTF-8 解码失败。
  **解决**：MCP server 的 `env` 必须含 `PYTHONUTF8=1`（安装器已自动配置；手工安装别漏）。
- **现象**：技能加载后 MCP / `task` 工具报 “not allowed by the active skill policy”。
  **原因**：技能 `allowed-tools` 是白名单，且 **YAML 列表形式不会做别名归一化**，要写运行时真实工具名（如 `machine-db_read_query`、`task`、`read_file`），不能只写 `Read/Write/WebSearch`。
- 锁定 `mcp==1.2.1` 是因为新版 MCP SDK 移除了旧 sqlite server 使用的 `Server.list_resources` 接口。

## License

[MIT](LICENSE) © 2026 chen1255
