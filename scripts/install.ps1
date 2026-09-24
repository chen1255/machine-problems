<#
.SYNOPSIS
    将 machine-problems（CNC 车床诊断 Agent：人设 + 5 个 Skill + machine-db MCP
    + safety-reviewer 安全复核子智能体）一键安装到本地 DeerFlow 实例。

.DESCRIPTION
    1. 复制 persona/SOUL.md、config/agent.config.yaml 到用户空间 agents/machine-problems/
    2. 复制 skills/* 到用户空间 skills/custom/
    3. 合并 machine-db MCP 与 5 个 skill 开关到 deer-flow/extensions_config.json（写入本机绝对路径）
    4. 创建 machines.db（5 表）并仅在空库时灌入演示种子数据
    5. 在 deer-flow/config.yaml 注入 safety-reviewer 自定义子智能体（BEGIN/END 标记块，幂等，不改动其它配置）
    6. 将免 key 的 web_search 后端由 tavily 切换为 DuckDuckGo（ddgs），使 web 工具组可用
    完成后提示重启 Gateway。

.PARAMETER DeerFlowRoot
    deer-flow 项目根目录（含 backend/、config.yaml）。

.PARAMETER UserId
    DeerFlow 用户 ID（backend/.deer-flow/users/ 下目录名）。不指定且只有一个用户时自动选择。

.PARAMETER UseDuckDuckGo
    是否把 web_search 切换到免 API key 的 DuckDuckGo（默认 $true）。配置了 TAVILY_API_KEY 时可传 -UseDuckDuckGo:$false。

.PARAMETER SkipSubagent
    跳过 safety-reviewer 子智能体注入（仅调试用；旗舰功能默认安装）。

.EXAMPLE
    .\scripts\install.ps1
    .\scripts\install.ps1 -DeerFlowRoot "D:\deer-flow" -UserId "abc-123"
#>
[CmdletBinding()]
param(
    [string]$DeerFlowRoot = "d:\ROG魔霸新锐\Documents\deepflow\deer-flow",
    [string]$UserId = "",
    [bool]$UseDuckDuckGo = $true,
    [switch]$SkipSubagent
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-Path($path, $label) {
    if (-not (Test-Path $path)) { throw "$label 不存在：$path" }
}
function Write-Utf8($path, $text) { [System.IO.File]::WriteAllText($path, $text, $Utf8NoBom) }
function Read-Utf8($path) { [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }

Assert-Path $DeerFlowRoot "DeerFlow 根目录"
Assert-Path (Join-Path $DeerFlowRoot "backend") "DeerFlow backend 目录"

# --- 1. 定位用户空间 ---
$usersDir = Join-Path $DeerFlowRoot "backend\.deer-flow\users"
Assert-Path $usersDir "用户空间目录（请确认 DeerFlow 已初始化并创建过管理员账号）"
if (-not $UserId) {
    $userDirs = Get-ChildItem $usersDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName "memory.json") }
    if ($userDirs.Count -eq 1) { $UserId = $userDirs[0].Name }
    else { throw "无法自动确定用户 ID，请用 -UserId 指定。候选：$((Get-ChildItem $usersDir -Directory).Name -join ', ')" }
}
$userHome = Join-Path $usersDir $UserId
Assert-Path $userHome "用户目录"
Write-Host "[1/6] 目标用户：$UserId" -ForegroundColor Cyan

# --- 2. 复制 Agent 与 5 个 Skill ---
$agentDir = Join-Path $userHome "agents\machine-problems"
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
Copy-Item (Join-Path $ProjectRoot "persona\SOUL.md") (Join-Path $agentDir "SOUL.md") -Force
Copy-Item (Join-Path $ProjectRoot "config\agent.config.yaml") (Join-Path $agentDir "config.yaml") -Force

$customSkillsDir = Join-Path $userHome "skills\custom"
New-Item -ItemType Directory -Force -Path $customSkillsDir | Out-Null
# 注意：复制目录“内容”用 skills\*，避免产生 skills\skills 嵌套
Copy-Item (Join-Path $ProjectRoot "skills\*") $customSkillsDir -Recurse -Force
Write-Host "[2/6] Agent 与 5 个 Skill（fault-triage/alarm-decode/pm-planner/loto-safety/work-order）已复制" -ForegroundColor Cyan

# --- 3. 合并 MCP 与 skill 开关 ---
$extPath = Join-Path $DeerFlowRoot "extensions_config.json"
$ext = if (Test-Path $extPath) { Get-Content $extPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ middlewares = @(); mcpServers = [pscustomobject]@{}; skills = [pscustomobject]@{} } }
if (-not $ext.mcpServers) { $ext | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force }
if (-not $ext.skills) { $ext | Add-Member -NotePropertyName skills -NotePropertyValue ([pscustomobject]@{}) -Force }

$dataDir = Join-Path $DeerFlowRoot "backend\.deer-flow\data"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$dbAbsPath = Join-Path $dataDir "machines.db"

$uvxCmd = $null
$uvx = Get-Command uvx.exe -ErrorAction SilentlyContinue
if ($uvx) { $uvxCmd = $uvx.Source }
elseif (Test-Path (Join-Path $env:USERPROFILE ".local\bin\uvx.exe")) { $uvxCmd = Join-Path $env:USERPROFILE ".local\bin\uvx.exe" }
else { throw "未找到 uvx.exe，请先安装 uv（pip install uv）或用完整路径手工配置 MCP" }

$uvCacheDir = Join-Path (Split-Path $DeerFlowRoot -Parent) ".uv-cache"
$mcpServer = [ordered]@{
    enabled              = $true
    type                 = "stdio"
    command              = $uvxCmd
    args                 = @("--with", "mcp==1.2.1", "mcp-server-sqlite", "--db-path", $dbAbsPath)
    cwd                  = Join-Path $DeerFlowRoot "backend"
    # Windows 中文系统必须强制子进程 UTF-8：否则 sqlite server 按 GBK 写 stdout，
    # 含中文的查询结果被 MCP client 按 UTF-8 解码失败，表现为 read_query 60s 超时
    # （list_tables/describe_table 因输出纯 ASCII 不受影响）。
    env                  = [ordered]@{
        UV_CACHE_DIR     = $uvCacheDir
        UV_DEFAULT_INDEX = "https://pypi.tuna.tsinghua.edu.cn/simple"
        RUST_LOG         = "error"
        PYTHONUTF8       = "1"
        PYTHONIOENCODING = "utf-8"
    }
    tool_name_prefix     = $true
    session_init_timeout = 120
    tool_call_timeout    = 60
    description          = "本地 SQLite 设备维修领域库：设备台账、报警码字典、故障案例库、维修工单、PM 保养记录五表关联"
    capability           = [ordered]@{ id = "machine-db" }
    routing              = [ordered]@{ mode = "prefer"; priority = 70; keywords = @("设备", "机床", "车床", "CNC", "报警码", "报警", "故障案例", "工单", "报修", "维修记录", "保养", "点检", "PM", "停机", "数据库", "SQL", "台账") }
}
$ext.mcpServers | Add-Member -NotePropertyName "machine-db" -NotePropertyValue ([pscustomobject]$mcpServer) -Force
foreach ($s in @("fault-triage", "alarm-decode", "pm-planner", "loto-safety", "work-order")) {
    $ext.skills | Add-Member -NotePropertyName $s -NotePropertyValue ([pscustomobject]@{ enabled = $true }) -Force
}
Write-Utf8 $extPath ($ext | ConvertTo-Json -Depth 12)
Write-Host "[3/6] extensions_config.json 已合并 machine-db（command=$uvxCmd）与 5 个 skill 开关" -ForegroundColor Cyan

# --- 4. 建库（5 表）+ 仅空库灌种子 ---
$schemaPath = Join-Path $ProjectRoot "integrations\machine-db\schema.sql"
$seedPath = Join-Path $ProjectRoot "integrations\machine-db\seed.sql"
Assert-Path $schemaPath "schema.sql"
Assert-Path $seedPath "seed.sql"

$py = @"
import pathlib, sqlite3, sys
db, schema, seed = sys.argv[1], sys.argv[2], sys.argv[3]
con = sqlite3.connect(db)
con.executescript(pathlib.Path(schema).read_text(encoding='utf-8'))
n = con.execute('SELECT COUNT(*) FROM machines').fetchone()[0]
if n == 0:
    con.executescript(pathlib.Path(seed).read_text(encoding='utf-8'))
    print('seed loaded')
else:
    print('seed skipped (machines already has %d rows)' % n)
con.commit()
con.close()
print('db ready:', db)
"@
$tmpPy = Join-Path $env:TEMP "_machine_problems_init_db.py"
Write-Utf8 $tmpPy $py
$uvExe = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
Push-Location (Join-Path $DeerFlowRoot "backend")
try {
    if (Test-Path $uvExe) { & $uvExe run --no-sync python $tmpPy $dbAbsPath $schemaPath $seedPath }
    else { python $tmpPy $dbAbsPath $schemaPath $seedPath }
}
finally { Pop-Location }
Write-Host "[4/6] machines.db 五表就绪（$dbAbsPath）" -ForegroundColor Cyan

# --- 5. 注入 safety-reviewer 子智能体（标记块，幂等）---
$cfgPath = Join-Path $DeerFlowRoot "config.yaml"
Assert-Path $cfgPath "全局 config.yaml"
$cfg = Read-Utf8 $cfgPath
$blockBegin = "# BEGIN machine-problems managed block"
$blockEnd = "# END machine-problems managed block"
if ($SkipSubagent) {
    Write-Host "[5/6] 已按 -SkipSubagent 跳过子智能体注入" -ForegroundColor Yellow
}
else {
    $subText = Read-Utf8 (Join-Path $ProjectRoot "subagents\safety-reviewer.yaml")
    $b = $subText.IndexOf($blockBegin); $e = $subText.IndexOf($blockEnd)
    if ($b -lt 0 -or $e -lt 0) { throw "safety-reviewer.yaml 缺少 BEGIN/END 标记" }
    $block = $subText.Substring($b, $e - $b + $blockEnd.Length).TrimEnd()
    # 移除旧块（含标记行与尾随换行）
    $cfg = [regex]::Replace($cfg, "(?m)^# BEGIN machine-problems managed block\r?\n.*?^# END machine-problems managed block\r?\n?", "", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $cfg.EndsWith("`n")) { $cfg += "`n" }
    $cfg = $cfg.TrimEnd() + "`n`n" + $block + "`n"
    Write-Host "[5/6] 已注入 safety-reviewer 子智能体（幂等标记块；如需多智能体，确认 subagents 运行时启用后重启）" -ForegroundColor Cyan
}

# --- 6. web_search 切换到免 key 的 DuckDuckGo ---
if ($UseDuckDuckGo) {
    if ($cfg -match 'deerflow\.community\.ddg_search\.tools:web_search_tool') {
        Write-Host "[6/6] web_search 已指向 DuckDuckGo，无需改动" -ForegroundColor Cyan
    }
    elseif ($cfg -match 'use:\s*deerflow\.community\.tavily\.tools:web_search_tool') {
        $cfg = [regex]::Replace($cfg, 'deerflow\.community\.tavily\.tools:web_search_tool', 'deerflow.community.ddg_search.tools:web_search_tool')
        Write-Host "[6/6] web_search 已由 tavily（需 key）切换为 DuckDuckGo（免 key）" -ForegroundColor Cyan
    }
    else {
        Write-Host "[6/6] 未找到 tavily web_search 配置行，跳过搜索后端切换（请自行确认 web_search 后端可用）" -ForegroundColor Yellow
    }
}
else {
    Write-Host "[6/6] 按参数保留原 web_search 后端" -ForegroundColor Yellow
}
Write-Utf8 $cfgPath $cfg

Write-Host ""
Write-Host "安装完成。剩余步骤：" -ForegroundColor Green
Write-Host "  1) 确认 $DeerFlowRoot\config.yaml 中 agents_api.enabled = true"
if (-not $SkipSubagent) { Write-Host "  2) 多智能体：subagents.custom_agents.safety-reviewer 已注入；主 Agent config 已含 allowed_subagents" }
Write-Host "  3) 重启 Gateway（停掉旧 uvicorn 再启动），新会话选择「CNC车床诊断助手」"
Write-Host "  4) 卸载子智能体：删除 config.yaml 中 $blockBegin 与 $blockEnd 之间的内容后重启"
