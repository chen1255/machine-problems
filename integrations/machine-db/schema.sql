-- ============================================================================
-- machine-db 设备维修领域库表结构（mcp-server-sqlite 使用）
-- 初始化：sqlite3 .deer-flow/data/machines.db < schema.sql
-- 设计为 5 张互相关联的表：设备台账 / 报警码字典 / 故障案例库 / 维修工单 / 保养记录。
-- 比单表演示更进一步：工单与案例通过设备、报警码关联，支撑"复发诊断""停机统计"。
-- 隐私最小化：只记录工号/班组等作业信息，不含个人手机号等敏感字段，不做个人评价。
-- ============================================================================

-- 1) 设备台账 ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS machines (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  machine_code    TEXT NOT NULL UNIQUE,        -- 资产编号，如 CNC-01
  model           TEXT,                        -- 机型，如 CK6140
  manufacturer    TEXT,                        -- 机床厂，如 沈阳机床
  cnc_system      TEXT,                        -- 数控系统，如 FANUC 0i-TF
  workshop        TEXT,                        -- 车间
  location        TEXT,                        -- 工位
  commission_date TEXT,                        -- 投用日期 YYYY-MM-DD
  run_hours       REAL DEFAULT 0,              -- 累计运行小时
  shifts_per_day  INTEGER DEFAULT 2,           -- 每天班次
  config_note     TEXT,                        -- 关键配置：液压卡盘/尾座/排屑器等
  status          TEXT DEFAULT 'running' CHECK(status IN ('running','maintenance','idle','scrapped')),
  created_at      TEXT DEFAULT (datetime('now','localtime'))
);

-- 2) 报警码字典 --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alarms (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  alarm_code      TEXT NOT NULL,               -- 报警码，如 414
  cnc_system      TEXT NOT NULL,               -- 适用系统/系列，如 FANUC 0i
  alarm_category  TEXT CHECK(alarm_category IN ('program','servo_encoder','overheat','system','custom_pmc','plc','other')),
  message         TEXT,                        -- 屏幕报警文本（原文）
  meaning         TEXT,                        -- 准确含义
  common_causes   TEXT,                        -- 常见原因（多条以换行分隔）
  action_steps    TEXT,                        -- 处理步骤（多条以换行分隔）
  reset_method    TEXT CHECK(reset_method IN ('soft','after_fix','home_ref','power_cycle','oem_param')),
  severity        TEXT CHECK(severity IN ('info','warning','serious','critical')),
  manual_ref      TEXT,                        -- 手册章节/诊断号
  source          TEXT DEFAULT 'seed' CHECK(source IN ('seed','verified','user')),
  created_at      TEXT DEFAULT (datetime('now','localtime')),
  UNIQUE (alarm_code, cnc_system)
);

-- 3) 故障案例库（经验沉淀，供 fault-triage 检索）-------------------------------
CREATE TABLE IF NOT EXISTS fault_cases (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  machine_code      TEXT,                      -- 设备编号（可空=通用案例）
  system_category   TEXT CHECK(system_category IN ('mechanical','electrical_drive','hydraulic_pneumatic','cooling_lubrication','system_program','process_tool','other')),
  symptom           TEXT NOT NULL,             -- 故障现象
  alarm_code        TEXT,                      -- 伴随报警码（可空）
  root_cause        TEXT NOT NULL,             -- 最终根因
  key_evidence      TEXT,                      -- 关键判据（靠哪一步锁定）
  solution          TEXT,                      -- 解决措施
  downtime_minutes  INTEGER,                   -- 停机时长（分钟）
  keywords          TEXT,                      -- 检索关键词（逗号分隔）
  source_wo_no      TEXT,                      -- 来源工单号
  created_at        TEXT DEFAULT (datetime('now','localtime'))
);

-- 4) 维修工单 ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS work_orders (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  wo_no               TEXT NOT NULL UNIQUE,    -- WO-yyyyMMdd-序号
  machine_code        TEXT NOT NULL,
  symptom             TEXT NOT NULL,
  alarm_code          TEXT,
  severity            TEXT DEFAULT 'medium' CHECK(severity IN ('low','medium','high')),
  reported_by         TEXT,                    -- 报修工号/班组
  shift               TEXT,                    -- 班次
  status              TEXT DEFAULT 'open' CHECK(status IN ('open','diagnosing','resolved','closed','escalated')),
  diagnosis_note      TEXT,                    -- 诊断过程记录
  root_cause          TEXT,                    -- 完工回填根因
  action_taken        TEXT,                    -- 处理措施
  parts_replaced      TEXT,                    -- 更换备件
  loto_required       INTEGER DEFAULT 0,       -- 是否需要 LOTO（0/1）
  loto_ticket_no      TEXT,                    -- 关联 LOTO 作业票
  downtime_minutes    INTEGER,
  fault_case_id       INTEGER,                 -- 沉淀后关联的故障案例
  created_at          TEXT DEFAULT (datetime('now','localtime')),
  resolved_at         TEXT,
  closed_at           TEXT,
  FOREIGN KEY (fault_case_id) REFERENCES fault_cases(id)
);

-- 5) 预防性维护(PM)记录 -------------------------------------------------------
CREATE TABLE IF NOT EXISTS pm_records (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  machine_code    TEXT NOT NULL,
  item            TEXT NOT NULL,               -- 保养项
  pm_level        TEXT CHECK(pm_level IN ('daily','weekly','monthly','quarterly','half_year','yearly')),
  method_standard TEXT,                        -- 方法/判定标准
  executed_by     TEXT,                        -- 执行人/班组
  completed_date  TEXT,                        -- 实际完成日期 YYYY-MM-DD
  next_due_date   TEXT,                        -- 下次到期 YYYY-MM-DD
  findings        TEXT,                        -- 发现的问题
  created_at      TEXT DEFAULT (datetime('now','localtime'))
);

-- 常用检索（Agent 通过 MCP read_query 自主执行）------------------------------
-- 某设备历史工单：SELECT wo_no, created_at, symptom, root_cause, status, downtime_minutes
--                 FROM work_orders WHERE machine_code='CNC-01' ORDER BY created_at DESC;
-- 复发预警：SELECT root_cause, COUNT(*) c FROM work_orders
--           WHERE machine_code='CNC-01' AND root_cause IS NOT NULL GROUP BY root_cause HAVING c>1;
-- 按系统分类统计故障：SELECT system_category, COUNT(*) FROM fault_cases GROUP BY system_category;
-- 停机时长 Top：SELECT machine_code, SUM(downtime_minutes) FROM work_orders
--               WHERE status='closed' GROUP BY machine_code ORDER BY 2 DESC;
-- 按报警码查案例：SELECT machine_code, symptom, root_cause, solution FROM fault_cases WHERE alarm_code='414';
-- 即将到期保养：SELECT machine_code,item,next_due_date FROM pm_records WHERE date(next_due_date)<=date('now','+7 day');
