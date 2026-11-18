# Text2SQL + 结果校验（语义层 Demo）

> **这不是"AI 工具 demo"，而是"语义层 + 校验"的工程 demo。**
>
> 核心观点：Text2SQL 的准确率瓶颈不在模型能力，而在**语义层有没有把业务口径讲清楚**。
> 本 demo 用「同一批 20 条问题 + 两种 schema 描述」做对照实验，量化语义层对准确率的影响。

---

## 目录结构

```
nl2sql/
├─ semantic_layer/
│  └─ tables.yaml          # ★ 核心资产：8 张 ADS + 4 张 DWS 的语义描述
├─ golden_set/
│  └─ questions.yaml       # 评测集：20 条问题 + 人工标准 SQL（含口径陷阱/应拒绝题）
├─ runner/
│  ├─ common.py            # 数据库连接、结果集归一化、比对逻辑
│  ├─ check_golden.py      # 校验标准 SQL 是否可执行
│  ├─ dump_prompts.py      # 导出 Prompt（无 API key 时手工贴）
│  └─ run_eval.py          # ★ 主脚本：生成 → 执行 → 比对 → 报告
├─ prompts/                # 导出的 Prompt（naive / semantic 两套）
├─ generated/              # 模型生成的 SQL（provider=file 模式用）
├─ results/                # 评测结果 JSON
└─ REPORT.md               # 实验报告（跑完填数字）
```

---

## 快速开始

### 第 0 步：环境

```powershell
$env:MYSQL_PWD = '你的MySQL密码'      # 数据库密码
python -m pip install pymysql pyyaml
```

> 本项目 MySQL 在 `127.0.0.1:3307`，库名 `edu_dw`。
> 改连接信息可通过环境变量：`NL2SQL_DB_HOST` / `NL2SQL_DB_PORT` / `NL2SQL_DB_USER` / `NL2SQL_DB_NAME`。

### 第 1 步：校验评测集（确认 20 条标准 SQL 都能跑）

```powershell
cd nl2sql
python runner/check_golden.py
```

**期望输出**：`可执行 18 条 | 失败 0 条 | 应拒绝 2 条 | 合计 20 条`

> 18 条是因为有 2 条是"应拒绝"题（没有标准 SQL，期望模型输出 `INSUFFICIENT_SCHEMA`）。

### 第 2 步：跑对照实验（需要 DeepSeek API key）

```powershell
$env:DEEPSEEK_API_KEY = 'sk-你的key'

python runner/run_eval.py --mode naive    --provider deepseek
python runner/run_eval.py --mode semantic --provider deepseek
```

**两条命令的唯一差别是 `--mode`**：
- `naive`：只给表名 + 字段名 + 类型（等价 `SHOW COLUMNS`）
- `semantic`：完整语义层（字段含义 + 口径 + 枚举值 + 表间关系）

结果分别写入 `results/naive.json` 和 `results/semantic.json`。

### 第 3 步：填 REPORT.md

把两次运行的「执行成功率 / 结果一致率 / 按题型」填进 [REPORT.md](REPORT.md)。

---

## 没有 API key 怎么办

### 方案 A：申请一个（推荐，5 分钟，成本 <1 元）

1. 打开 <https://platform.deepseek.com>
2. 注册 → 左侧「API keys」→ 创建
3. 复制 `sk-xxxx`（只显示一次）
4. 新用户通常有免费额度；本项目 20 题 × 2 组 ≈ **不到 1 元**

### 方案 B：手工贴（完全免费，但慢）

```powershell
python runner/dump_prompts.py --mode semantic
```

然后打开 `prompts/semantic/Q01.txt`，把 **User 那一段**（从「## User」之后）整体复制，贴给任意对话模型（ChatGPT / Claude / DeepSeek 网页版 / 豆包…）。

拿回 SQL 后，存成：

```
generated/semantic/Q01.sql
generated/naive/Q01.sql
```

20 条都存好后运行：

```powershell
python runner/run_eval.py --mode semantic --provider file
```

> `--provider file` 表示"从文件读模型的答案"，不调 API。

---

## 评测方法（三层校验）

只看"SQL 能不能跑"是不够的——**跑通但口径错，是数据开发最危险的情况**。

| 层 | 检查什么 | 失败标记 |
|---|---|---|
| **1. 可执行性** | SQL 语法正确、字段存在、能返回结果 | `EXEC_FAIL` |
| **2. 结果一致性** | 与人工标准 SQL **结果集比对** | `RESULT_MISMATCH` |
| **3. 口径正确性** | 通过结果值体现（用错字段 → 数值不同 → 判错） | 同上 |

### 结果集比对怎么做到公平

生成 SQL 和标准 SQL 写法可能不同（别名不同、`ORDER BY` 有无、`ROUND` 位数不同），直接字符串比会误判。所以做**归一化**：

```
1. 数值统一保留 4 位小数（0.1048 == 0.10480）
2. 忽略行顺序（结果行按内容排序后再比）
3. 允许"宽松通过"：生成结果多返回了列，但标准答案的每个值都能找到 → PASS_LENIENT
```

代码见 `runner/common.py` 的 `normalize_rows()` 和 `compare_results()`。

---

## 评测集的 6 类题型

| 类型 | 条数 | 考察点 |
|---|---|---|
| 单表聚合 | 5 | 能否定位到正确的表 |
| 分组排序 | 4 | GROUP BY / ORDER BY / LIMIT |
| 明细查询 | 3 | 条件过滤的精确性 |
| 趋势对比 | 3 | 是否知道用 `ads_term_trend` 并按 `seq_no` 排序 |
| **口径陷阱** | 3 | ⭐ 最高分口径 vs 正考口径、通过率 vs 挂科率 |
| **应拒绝** | 2 | ⭐ 敏感字段的数据安全意识 |

### 口径陷阱长什么样

**Q17**：`学号 S013172 的【正考口径】平均分是多少？`

- 最高分口径 `avg_score` = **87.71**（4 门补考都过了）
- 正考口径 `avg_first` = **64.86**
- **差 22.85 分**——选错字段就是完全错误的答案

**Q18**：`全校通过率是多少？`
- 表里**没有** `pass_rate` 字段，只有 `fail_rate`
- 正确解法：`ROUND(1 - fail_rate, 4)`
- 模型容易幻觉出不存在的 `pass_rate` 列

---

## 语义层为什么是关键

对比两种 schema 给模型看到的信息：

**naive 模式（3.4k 字符）**
```
ads_term_kpi: term_id(int), term_name(varchar), avg_score(decimal), fail_rate(decimal), ...
```
模型不知道：`term_id=202601` 是哪学期、`avg_score` 是什么口径、`fail_rate` 是不是正考。

**semantic 模式（13.2k 字符）**
```yaml
- name: avg_score
  caliber: 同一学生同一班次取【最高分】口径
- name: fail_rate
  caliber: 【正考】成绩<60 的比例
- name: term_id
  enum: {202601: 2025-2026学年第二学期（春）, ...}
grain: 每学期一行（共 3 行）
use_for: 全校层面的学期汇总指标
notes:
  - avg_score（最高分口径）与 fail_rate（正考口径）口径不同，不能互相推导
```

**多出的 9.8k 字符，就是"业务知识"。**

---

## 常见问题

**Q：`EXEC_FAIL` 和 `RESULT_MISMATCH` 的区别？**
> 前者是 SQL 跑不通（语法/字段名错）；后者是能跑但结果不对（选错表/选错字段/口径错）。
> **后者更危险**——能跑通会让人误以为是对的。

**Q：为什么只测 20 条？**
> 20 条足够看出趋势（尤其分类看），且能手工逐条检查标准答案正确性。
> 更大的评测集应该用自动化生成的，但那样标准答案本身就不可靠。

**Q：这个 demo 能证明什么？**
> 证明三件事：① 你知道怎么把业务口径写给机器看；② 你会做结果集比对而不是"跑通就算对"；③ 你做过对照实验而不是拍脑袋。

---

## 安全约束

- 只执行 **单条 SELECT / WITH** 查询（`common.is_safe_select()` 拦截写操作和多语句）
- 查询结果最多取 10000 行，避免误查大表拖垮实例
- 数据库密码通过环境变量传入，**不写进代码**
