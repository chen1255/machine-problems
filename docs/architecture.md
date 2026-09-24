# 架构说明

本文讲清楚三件事：这个仓库**是什么**、它如何**挂载**到 DeerFlow 运行时、以及开发中实测到的两个关键机制与坑。

## 1. 定位：资产包，不是框架的 fork

DeerFlow 提供运行时（LangGraph agent 工厂、模型接入、工具系统、技能加载、MCP 客户端、子智能体、Web/网关）。
本仓库只提供运行在其上的**行业内容与配置**，不含框架代码：

| 关注点 | 归属 |
|---|---|
| Agent 运行循环、模型调用、工具执行、MCP/stdio、Web UI、鉴权 | DeerFlow 框架 |
| 行业人设、领域技能、领域库结构与数据、安全复核子智能体、安装器 | **本仓库（原创）** |

好处：框架可独立升级；本仓库通过 DeerFlow 既有扩展点装配，不改框架源码。

## 2. 四个挂载点（安装器做的事）

```
machine-problems（源）                         DeerFlow 实例（目标）
─────────────────────                         ──────────────────────
persona/SOUL.md                          ─►   用户空间 agents/machine-problems/（SOUL.md）
config/agent.config.yaml                 ─►   用户空间 agents/machine-problems/（config.yaml）
skills/*/SKILL.md (+templates/)          ─►   users/<uid>/skills/custom/<name>/
integrations/machine-db/schema.sql       ─►   backend/.deer-flow/data/machines.db（建库+种子）
integrations/machine-db/mcp.example.json ─►   deer-flow/extensions_config.json（mcpServers + skills）
subagents/safety-reviewer.yaml (标记块)   ─►   deer-flow/config.yaml 顶层 subagents.custom_agents
```

- 所有写入都是**幂等**的：技能整目录覆盖；MCP/技能开关按键合并；子智能体用 `# BEGIN/END machine-problems managed block` 正则替换；数据库仅在空库时灌种子。
- 安装前会备份被改动的 `config.yaml` 与 `extensions_config.json`（同目录 `*.bak_<时间戳>`）。
- 目标路径以 `scripts/install.ps1` 为准（它负责解析用户空间、写入本机绝对路径与环境变量）。

## 3. 运行时组件与一次高危请求的时序

```
Human
  │  “电已断，帮我换 CNC-01 主轴皮带，出 LOTO 作业票并把安全关”
  ▼
machine-problems（lead agent, temperature=0.2, memory=off）
  │  按需加载技能（read_file 读取 SKILL.md 后进入 skill_context）
  │  ├─ machine-db_*      只读：核对设备档案（液压卡盘/尾座 → 液压能）
  │  ├─ loto-safety 技能   产出能量隔离清单
  │  └─ task(subagent_type="safety-reviewer", prompt=<方案+能量源+拟议措施>)
  ▼
safety-reviewer（custom_agent）
  • tools=[]（零外部工具，纯推理）   • disallowed_tools=["task"]（禁止再嵌套）
  • model=inherit  max_turns=12  timeout=300s
  • 固定输出：结论(三档) / 能量源表 / 编号隔离措施 / 资质 / 修改意见
  ▼
lead 把复核结论并入最终答复，并用 write_file 落盘 LOTO 作业票
```

主 Agent 的 `allowed_subagents: [safety-reviewer]` 是**白名单**：既看不到内置通用子智能体，也不能自行扩权。子智能体零工具 + 禁 `task`，保证它只能在给定方案上做安全推理，无法联网、查库或再分派。

### Agent 配置的两个取舍

- `temperature: 0.2`、`thinking_enabled: false`：现场诊断要确定性、低发散、答案直接。
- `memory_enabled: false`：关闭跨会话长期记忆，避免多设备/多班组之间的信息串扰；设备与维修事实统一以 `machine-db` 为准。

## 4. 领域库 machine-db

5 张表（完整 DDL 见 [schema.sql](../integrations/machine-db/schema.sql)），围绕「复发诊断」关联：

- `machines 1—n work_orders`（设备—工单）
- `work_orders.alarm_code / fault_cases.alarm_code ↔ alarms`（报警码字典）
- `work_orders.fault_case_id → fault_cases.id`（工单闭环后沉淀为案例）
- `pm_records`（按设备的分级保养记录与到期）

MCP server：`uvx --with mcp==1.2.1 mcp-server-sqlite --db-path <abs>`，工具经
`tool_name_prefix` 暴露为 `machine-db_list_tables / describe_table / read_query / write_query / create_table / append_insight`。
技能白名单按最小权限只放行需要的工具（诊断/报警/安全为只读三件套，工单/PM 额外放行 `write_query`；不向业务技能开放 `create_table`）。

## 5. 两个必须知道的机制（实测踩坑）

### 5.1 技能 `allowed-tools` 是精确白名单，YAML 列表不做别名归一化

技能被加载进 `skill_context` 后，`SkillToolPolicyMiddleware` 把模型可见工具裁剪为
「所有激活技能 `allowed-tools` 的并集」∪「始终可用内置工具」，并在工具执行时再次拦截，
匹配方式是**工具名精确相等**。

`deerflow/skills/parser.py` 里的别名表（`Read→read_file`、`WebSearch→web_search` 等）
**只对“空格分隔字符串”形式生效；写成 YAML 列表时逐项原样保留**。因此列表里写 `Read/Write/WebSearch`
不会匹配到任何运行时工具。本仓库技能统一在列表中写真实名：

```yaml
allowed-tools:
  - read_file
  - write_file
  - web_search
  - web_fetch
  - machine-db_list_tables
  - machine-db_describe_table
  - machine-db_read_query
  - task          # 需要委托安全复核的技能才放行（fault-triage / loto-safety）
```

注意 `task` 不在“始终可用内置工具”内，不显式放行，技能激活后就无法触发子智能体委托。

### 5.2 Windows 中文系统：MCP 子进程必须强制 UTF-8

现象：`list_tables`/`describe_table`（纯 ASCII）正常，`read_query` 返回含中文的行时
客户端报 `UnicodeDecodeError('utf-8', ... 'invalid continuation byte')`，上层表现为 60s 超时。

根因：`mcp-server-sqlite` 子进程在中文 Windows 默认按 GBK(cp936) 写 stdout，MCP 客户端按 UTF-8 解码失败。
修复：在该 MCP server 的 `env` 中设置 `PYTHONUTF8=1`（外加 `PYTHONIOENCODING=utf-8`），
并补齐 `UV_CACHE_DIR` / `UV_DEFAULT_INDEX` / `RUST_LOG`。安装器已自动注入；手工安装务必照做。

（锁定 `mcp==1.2.1`：新版 MCP SDK 移除了旧 sqlite server 依赖的 `Server.list_resources`。）

## 6. 如何用嵌入式客户端自测

不必走 HTTP 鉴权即可在进程内跑通完整链路（DeerFlow 提供 `DeerFlowClient`）：

```python
from deerflow.client import DeerFlowClient

client = DeerFlowClient(
    agent_name="machine-problems",
    subagent_enabled=True,     # 必须开启，否则不挂载 task 工具
    thinking_enabled=False,
)
for ev in client.stream(
    "CNC-01 偶发 X 轴 414，晃拖链可复现，上月犯过，帮我查记录判断原因",
    thread_id="smoke-1",
    user_id="<your-deerflow-user-id>",   # 技能/Agent 装在哪个用户空间就传谁
):
    d = ev.data or {}
    if ev.type == "messages-tuple" and d.get("type") == "ai":
        if d.get("content"):
            print(d["content"], end="")
        for tc in d.get("tool_calls") or []:
            print("\n[call]", tc["name"], tc.get("args"))
```

判断要点：`machine-db_*` 调用应返回数据而非 policy/timeout 错误；高危作业应出现一次
`name == "task"` 的委托，并能在对应工具结果里看到三档安全结论。

## 7. 本地实测记录（摘要）

- 复发诊断：9 次只读查询全部成功、0 次拒绝；命中在途工单 WO-20260920-04 与复发案例
  「X 轴编码器线缆随拖链弯折致芯线疲劳虚接（复发故障）」。
- 高危委托：`task(safety-reviewer)` 返回「补充措施后可进行」，要求把重力/回弹机械支撑
  从“必要时”升级为不开工红线，并补齐“一人一锁一牌”等。
- 违章请求：不带电作业请求被主助手直接拒绝（安全第一道闸门未因子智能体而被绕过）。
