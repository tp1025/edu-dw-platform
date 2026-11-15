# 阶段1 交付：ER 图 + 范式论证

> 项目：高校学情数据平台 ｜ 库：`edu_normal`（主数据）+ `edu_online`（高频业务）
> 说明：**本项目按设计不建物理外键**（分区表不支持 + 大表写入性能），所以下面的 ER 图是**逻辑关系图**，
> 引用完整性由「应用层校验 + 每日孤儿巡检」保证。这一点在面试里要主动说明。

---

## 一、ER 图

### 1.1 可直接渲染的源码（Mermaid）

> 用法：把下面代码粘到 <https://mermaid.live> 或 draw.io 的「插入 → 高级 → Mermaid」里，导出 PNG/SVG。

```mermaid
erDiagram
  %% ===== 主数据（edu_normal）=====
  COLLEGE ||--o{ MAJOR : "1:N 开设"
  COLLEGE ||--o{ TEACHER : "1:N 任职"
  MAJOR   ||--o{ CLASS : "1:N 包含"
  TEACHER ||--o{ CLASS : "1:N 担任班主任"
  CLASS   ||--o{ STUDENT : "1:N 就读"
  COURSE  ||--o{ COURSE_PREREQ : "1:N 作为先修课"
  COURSE  ||--o{ COURSE_PREREQ : "1:N 需要先修课"
  STUDENT ||--o{ STATUS_CHANGE : "1:N 发生异动"
  STUDENT ||--o{ REWARD_PUNISH : "1:N 获得奖惩"

  %% ===== 业务（edu_online）=====
  COURSE  ||--o{ COURSE_SCHEDULE : "1:N 开课"
  TEACHER ||--o{ COURSE_SCHEDULE : "1:N 授课"
  COURSE_SCHEDULE ||--o{ SCHEDULE_TIME : "1:N 排课时段"
  COURSE_SCHEDULE ||--o{ COURSE_SESSION : "1:N 每次课"
  CLASSROOM ||--o{ SCHEDULE_TIME : "1:N 使用"
  CLASSROOM ||--o{ COURSE_SESSION : "1:N 使用"
  STUDENT ||--o{ SELECTION : "1:N 选课"
  COURSE_SCHEDULE ||--o{ SELECTION : "1:N 被选"
  STUDENT ||--o{ SCORE : "1:N 得分"
  COURSE_SCHEDULE ||--o{ SCORE : "1:N 产生成绩"
  STUDENT ||--o{ ATTENDANCE : "1:N 考勤"
  COURSE_SESSION ||--o{ ATTENDANCE : "1:N 逐次点名"
  COURSE_SCHEDULE ||--o{ ATTENDANCE : "1:N 按班次统计"

  COLLEGE {
    bigint college_id PK
    varchar college_code UK
    varchar college_name
  }
  MAJOR {
    bigint major_id PK
    bigint college_id FK
    varchar major_code UK
    varchar major_name
  }
  TEACHER {
    bigint teacher_id PK
    bigint college_id FK
    varchar teacher_no UK
    varchar teacher_name
    varchar title
  }
  CLASS {
    bigint class_id PK
    bigint major_id FK
    bigint teacher_id FK
    varchar class_no UK
    int enroll_year
  }
  STUDENT {
    bigint student_id PK
    bigint class_id FK
    varchar student_no UK
    varchar student_name
    tinyint gender
    char id_card_hash UK
    varbinary id_card_cipher
  }
  COURSE {
    bigint course_id PK
    varchar course_code UK
    varchar course_name
    decimal credit
    tinyint course_type
  }
  COURSE_PREREQ {
    bigint id PK
    bigint course_id FK
    bigint prerequisite_course_id FK
  }
  CLASSROOM {
    bigint id PK
    varchar building_name UK
    varchar room_no UK
    int capacity
  }
  STATUS_CHANGE {
    bigint id PK
    bigint student_id FK
    tinyint change_type
    tinyint old_status
    tinyint new_status
    datetime operate_time
  }
  REWARD_PUNISH {
    bigint id PK
    bigint student_id FK
    int term_id
    tinyint rp_type
    decimal amount
  }
  COURSE_SCHEDULE {
    bigint schedule_id PK
    int term_id PK
    bigint course_id FK
    bigint teacher_id FK
    tinyint class_no
    int max_count
    int current_count
  }
  SCHEDULE_TIME {
    bigint st_id PK
    bigint schedule_id FK
    tinyint week
    tinyint begin_section
    tinyint end_section
    bigint classroom_id FK
  }
  COURSE_SESSION {
    bigint session_id PK
    int term_id
    bigint schedule_id FK
    smallint session_no
    date session_date
    bigint classroom_id FK
  }
  SELECTION {
    bigint selection_id PK
    int term_id PK
    bigint student_id FK
    bigint schedule_id FK
    tinyint select_status
    tinyint active_flag
  }
  SCORE {
    bigint score_id PK
    int term_id PK
    bigint student_id FK
    bigint schedule_id FK
    tinyint exam_type
    decimal total_score
  }
  ATTENDANCE {
    bigint att_id PK
    int term_id PK
    bigint student_id FK
    bigint session_id FK
    bigint schedule_id FK
    tinyint att_status
  }
```

### 1.2 关系清单（文字版，供文档正文使用）

| 关系 | 基数 | 说明 |
|---|---|---|
| college → major | 1:N | 一个学院开多个专业 |
| college → teacher | 1:N | 教师归属一个学院 |
| major → class | 1:N | 专业下多个行政班 |
| teacher → class | 1:N | 一位教师可当多个班班主任 |
| class → student | 1:N | 班级含多名学生 |
| **course ↔ course（先修）** | **M:N（自引用）** | 一门课可有多个先修课，也可作为多门课的先修课 |
| student → student_status_change | 1:N | 一名学生多次异动 |
| student → reward_punish | 1:N | 一名学生多条奖惩记录 |
| course → course_schedule | 1:N | 一门课在多个学期、多个班次开课 |
| teacher → course_schedule | 1:N | 一位教师带多个班次 |
| course_schedule → schedule_time | 1:N | 一个班次多个上课时段（周一 3-4 节、周三 5-6 节） |
| course_schedule → course_session | 1:N | 一个班次 16 次课（每次有具体日期） |
| classroom → schedule_time / course_session | 1:N | 教室被多个时段/课次使用 |
| **student ↔ course_schedule** | **M:N（通过 selection）** | 选课关系，携带选课状态与时间 |
| student ↔ course_schedule（成绩） | M:N（通过 score） | 携带成绩、考试类型 |
| student ↔ course_session | M:N（通过 attendance） | 携带考勤状态 |

### 1.3 三个建模要点（面试必讲）

**① 选课选的是"班次"而不是"课程"**
```
course（课程：高等数学）
   └─ course_schedule（班次：2026春-高数-张老师-1班）  ← 学生选的是这个
        ├─ schedule_time（周一 3-4 节、周三 5-6 节）   ← 排课模板
        └─ course_session（第 1 次课 2026-03-02、第 2 次课 2026-03-09 …） ← 每次课
```
如果选课直接挂 `course`，就无法表达"同一门课多个学期、多个老师、多个班"。

**② 先修关系是自引用 M:N，必须用关联表**
`course` 表里放一个 `pre_course_id` 字段**不够**——一门课可能有多个先修课（高数 + 线代 → 概率论），所以用 `course_prerequisite(course_id, prerequisite_course_id)`。

**③ 三张"课次"表的职责严格分离**
| 表 | 粒度 | 一句话 |
|---|---|---|
| `schedule_time` | 班次 × 周期时段 | **排课模板**：每周一 3-4 节 |
| `course_session` | 班次 × 一次课 | **具体课次**：2026-03-02 周一 3-4 节 |
| `attendance` | 学生 × 一次课 | **点名记录**：张三在 3-02 这次课出勤 |

> 这三层分开后，"2026-03-02 高数 1 班谁缺勤"这条查询只需 `course_session → attendance`，不用猜日期。

---

## 二、范式论证

### 2.1 论证方法

对每张表依次检查：
1. **1NF**：所有属性是否原子（不可再分）
2. **2NF**：非主属性是否完全依赖于候选键（消除部分依赖）
3. **3NF**：非主属性之间是否存在传递依赖

### 2.2 逐表函数依赖

> 记法：`A → B` 表示 A 决定 B。代理键表用 `id` 表示自增主键。

#### edu_normal（主数据侧）

| 表 | 候选键 | 主要函数依赖 | 范式判定 |
|---|---|---|---|
| **college** | `college_id`（代理键）/ `college_code` | `college_id → college_code, college_name` | **3NF** |
| **major** | `major_id` / `major_code` | `major_id → major_code, major_name, college_id` | **3NF** |
| **teacher** | `teacher_id` / `teacher_no` | `teacher_id → teacher_no, teacher_name, title, college_id, phone_hash` | **3NF** |
| **class** | `class_id` / `class_no` | `class_id → class_no, class_name, major_id, teacher_id, enroll_year` | **3NF** |
| **student** | `student_id`（学号，业务主键） | `student_id → student_no, student_name, gender, class_id, id_card_hash, id_card_cipher` | **3NF** |
| **course** | `course_id` / `course_code` | `course_id → course_code, course_name, credit, course_type` | **3NF** |
| **course_prerequisite** | `id` / `(course_id, prerequisite_course_id)` | `(course_id, prerequisite_course_id) → id` | **3NF**（M:N 关联表） |
| **classroom** | `id` / `(building_name, room_no)` | `id → building_name, room_no, capacity, room_type` | **3NF** |
| **sys_dict** | `id` / `(dict_type, dict_value)` | `id → dict_type, dict_value, dict_label, sort` | **3NF** |
| **student_status_change** | `id` | `id → student_id, change_type, old_status, new_status, operate_time` | **3NF** |
| **reward_punish** | `id` | `id → student_id, term_id, rp_type, rp_level, amount, rp_date` | **3NF** |

#### edu_online（高频业务侧）

| 表 | 候选键 | 主要函数依赖 | 范式判定 |
|---|---|---|---|
| **course_schedule** | `(schedule_id, term_id)` / `(term_id, course_id, class_no)` | `schedule_id → course_id, teacher_id, class_no, term_id, max_count, current_count` | **3NF**（`current_count` 是刻意的派生冗余，见 2.4） |
| **schedule_time** | `st_id` / `(schedule_id, week, begin_section)` | `st_id → schedule_id, week, begin_section, end_section, classroom_id` | **3NF** |
| **course_session** | `session_id` / `(term_id, schedule_id, session_no)` | `session_id → term_id, schedule_id, session_no, week_no, session_date, classroom_id` | **3NF** |
| **selection** | `(selection_id, term_id)` | `selection_id → student_id, schedule_id, term_id, select_status` | ⚠️ **term_id 传递依赖**（见 2.3-①） |
| **score** | `(score_id, term_id)` | `score_id → student_id, schedule_id, term_id, exam_type, total_score` | ⚠️ **term_id 传递依赖** |
| **attendance** | `(att_id, term_id)` | `att_id → student_id, session_id, schedule_id, term_id, att_status` | ⚠️ **schedule_id + term_id 传递依赖** |

### 2.3 三处刻意的传递依赖（必须能解释）

#### ① 分区表的 `term_id` 冗余 —— 数据库强制要求
```sql
course_schedule: schedule_id → term_id
selection      : schedule_id → term_id（但 selection 也存了 term_id）
```
**逻辑上** `term_id` 由 `schedule_id` 决定，存在传递依赖，不满足严格 3NF。
**但**：MySQL 要求**分区表的所有唯一键必须包含分区列**。为了按 `term_id` 做 RANGE 分区，`term_id` 必须物理存在。

> 面试话术："这是**数据库物理约束倒逼的冗余**，不是设计错误。真实数仓里维度表也会为了分区裁剪而冗余日期列。"

#### ② `attendance.schedule_id` —— 只读冗余，换取免 JOIN
```sql
attendance: session_id → schedule_id（course_session 里已有）
           但 attendance 也存了 schedule_id
```
**理由**：统计"某班次出勤率"时不用再 JOIN `course_session`（该表百万级，JOIN 开销大）。
**安全性**：`schedule_id` 一旦写入**永不变化**（课次属于哪个班次是固定的），所以不存在更新异常。

> 对比反例：如果把 `course_schedule.max_count` 冗余进 `attendance`，容量一改就要更新几十万行——**"会变的字段不能冗余"是这里的判据**。

#### ③ 软删除 + 唯一键方案引入的 `deleted_at`
```sql
college: college_code → uk_college_code(college_code, deleted_at)
```
`deleted_at` 不属于业务键，但为了"软删除后能重建同编码记录"，必须让它参与唯一键。
这属于**技术字段参与约束**，不影响业务属性的 3NF 判定。

### 2.4 三处刻意的反范式（有明确收益）

| # | 位置 | 冗余了什么 | 收益 | 一致性如何保证 |
|---|---|---|---|---|
| **1** | `course_schedule.current_count` | 已选人数（本可由 `COUNT(selection)` 算出） | 选课时用一条原子 UPDATE 判断容量，避免每次 COUNT 百万行 | 选课/退课事务内同步更新 + `CHECK (current_count <= max_count)` 兜底 + 每日对账 |
| **2** | `course_schedule.class_no` | 班次号（可从 schedule_id 推出） | 唯一键用业务语义 `(term_id, course_id, class_no)`，可读且稳定 | 写入时由教务分配，唯一键约束防重 |
| **3** | `selection.active_flag` | 生成列：有效选课=1，其余=NULL | 让唯一键只约束"有效选课"，实现"退课后可重选" | **数据库生成列自动计算**，不存在人工维护不一致 |

### 2.5 数仓层（edu_dw）为什么不追求 3NF

| 层 | 范式态度 | 理由 |
|---|---|---|
| ODS | 刻意"无范式" | 全字符串贴源，连类型约束都去掉，只为原样留痕 |
| DWD | 星型模型（部分反范式） | 事实表冗余 `course_id`/`teacher_id` 免 JOIN；维度表冗余 `college_name` 等层级名 |
| DWS | 宽表（反范式） | 一行一个"学生×学期"，把 8 门课的成绩聚合进来，必然非规范化 |
| ADS | 指标表（完全反范式） | 一行一个指标，就是给报表直读的 |

> **一句话**：OLTP 力求 3NF（避免更新异常），OLAP 力求反范式（避免 JOIN、提升查询速度）。**这是两种不同的设计目标，不是谁对谁错。**

---

## 三、范式检查结论汇总

| 判定 | 表 | 数量 |
|---|---|---|
| 严格 3NF | college、major、teacher、class、student、course、course_prerequisite、classroom、sys_dict、student_status_change、reward_punish、course_schedule（除派生列）、schedule_time、course_session | **14 张** |
| 有**刻意的**传递依赖 | selection、score、attendance（都是分区列/只读冗余） | **3 张** |
| 刻意反范式 | course_schedule（`current_count`）、selection（`active_flag` 生成列） | **2 处** |

**结论**：19 张业务表全部满足 1NF 与 2NF；14 张严格满足 3NF；5 张存在**有明确技术理由**的传递依赖或派生冗余，理由逐条记录在 2.3 / 2.4。

---

## 四、面试预设问题

**Q：为什么不用物理外键？**
> "三个原因：① MySQL 分区表不支持外键；② 大表（考勤 192 万）每次写入都要校验外键，影响写入性能；③ 数仓同步时外键会阻碍批量导入。代价是引用完整性要靠应用层校验 + 每日孤儿巡检 SQL。"

**Q：`selection.term_id` 不是冗余吗？**
> "是冗余，但有两个不可替代的作用：① 分区列必须存在；② 唯一键必须包含分区列，否则建不了表。这是物理约束，不是设计缺陷。"

**Q：`current_count` 冗余了，怎么保证不脏？**
> "三重保障：① 选课/退课在同一事务里原子更新；② `CHECK (current_count <= max_count)` 数据库兜底；③ 每日对账 SQL 比对 `current_count` 与实际流水数，不一致就告警。"

**Q：为什么先修关系不用自引用字段？**
> "一门课可能有多个先修课（高数+线代→概率论），一个字段放不下；而且一门课也可能是多门课的先修课，属于 M:N，必须用关联表。"
