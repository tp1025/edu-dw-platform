-- =====================================================================
-- 阶段1 完整改造脚本：方案 A（课次模型收敛）+ 方案 Y（迁移到 edu_online）
-- 环境：MySQL 26.10 @ 127.0.0.1:3307  库：edu_normal / edu_online
-- 前提：全部表 0 行、无物理外键、已有 6 张表分区
-- 用法：按【第 0 段 → 第 10 段】顺序逐段执行，每段跑完执行该段的「验证」
-- 注意：DDL 无法回滚，执行前请先做第 0 段快照
-- =====================================================================


-- =====================================================================
-- 第 0 段：执行前快照（先把结果另存，出问题可以对照/重建）
-- =====================================================================
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') ORDER BY 1,2;

SELECT TABLE_NAME, PARTITION_EXPRESSION, COUNT(*) parts
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') AND PARTITION_NAME IS NOT NULL
GROUP BY 1,2;

-- 验证：记录当前 17 张表、6 张分区表（course_schedule/selection/score/attendance/classroom/course_session）


-- =====================================================================
-- 第 1 段：classroom 去学期化（教室是跨学期实体，不该按学期分裂、不该分区）
-- =====================================================================
ALTER TABLE edu_normal.classroom REMOVE PARTITIONING;

ALTER TABLE edu_normal.classroom
  DROP PRIMARY KEY,
  ADD PRIMARY KEY (id),
  DROP INDEX uk_build_room,
  ADD UNIQUE KEY uk_build_room (building_name, room_no, deleted_at);

ALTER TABLE edu_normal.classroom
  DROP COLUMN term_id,
  MODIFY COLUMN room_type TINYINT NOT NULL DEFAULT 1 COMMENT '1普通/2机房/3实验室',
  ADD CONSTRAINT ck_classroom_capacity CHECK (capacity >= 0),
  ADD CONSTRAINT ck_classroom_type     CHECK (room_type IN (1,2,3));

-- 验证：应返回 0 行（classroom 不再分区）
SELECT COUNT(*) AS classroom_parts FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='classroom' AND PARTITION_NAME IS NOT NULL;

-- 验证：主键应为 id；room_type 应为 tinyint；不应再有 term_id
SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='classroom' ORDER BY ORDINAL_POSITION;


-- =====================================================================
-- 第 2 段：schedule_time 用 classroom_id（原来是自由文本，和 classroom 表零关联）
-- =====================================================================
ALTER TABLE edu_normal.schedule_time
  DROP COLUMN classroom,
  ADD COLUMN classroom_id BIGINT NOT NULL COMMENT '教室（逻辑外键→classroom.id）' AFTER end_section,
  ADD KEY idx_room (classroom_id, week, begin_section) COMMENT '教室冲突校验用',
  ADD CONSTRAINT ck_st_week    CHECK (week BETWEEN 1 AND 7),
  ADD CONSTRAINT ck_st_section CHECK (begin_section >= 1 AND end_section >= begin_section);

-- 验证：有 classroom_id、无 classroom
SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='schedule_time' ORDER BY ORDINAL_POSITION;


-- =====================================================================
-- 第 3 段：course_session 改成「一次具体的课」
--   ① term_id bigint → int（与其他分区表一致，否则 JOIN 隐式转换丢索引）
--   ② 删 start_date/end_date（区间不属于一次课）
--   ③ 加 session_no（第几次课）/ week_no（第几周）/ session_date（具体日期）
--   ④ 唯一键：第几次课唯一 + 同一天同节次唯一（都必须含 term_id）
-- =====================================================================
ALTER TABLE edu_normal.course_session
  MODIFY COLUMN term_id INT NOT NULL COMMENT '学期编码，如 202601',
  DROP COLUMN start_date,
  DROP COLUMN end_date,
  ADD COLUMN session_no   SMALLINT NOT NULL DEFAULT 1 COMMENT '第几次课（1..N）' AFTER schedule_id,
  ADD COLUMN week_no      TINYINT  NOT NULL DEFAULT 1 COMMENT '第几教学周' AFTER session_no,
  ADD COLUMN session_date DATE     NOT NULL COMMENT '上课日期' AFTER week_no,
  DROP INDEX uk_schedule_time,
  ADD UNIQUE KEY uk_session_no   (term_id, schedule_id, session_no, deleted_at),
  ADD UNIQUE KEY uk_session_slot (term_id, schedule_id, session_date, start_section, deleted_at),
  ADD CONSTRAINT ck_cs_week CHECK (week_day BETWEEN 1 AND 7),
  ADD CONSTRAINT ck_cs_no   CHECK (session_no >= 1);
-- 说明：原有的 chk_section(end_section >= start_section) 保留，不重复添加

-- 验证：term_id 必须是 int；三个新列都在；两个 uk 都含 term_id
SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='course_session'
  AND COLUMN_NAME IN ('term_id','session_no','week_no','session_date') ORDER BY ORDINAL_POSITION;

SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='course_session' AND NON_UNIQUE=0
GROUP BY INDEX_NAME;


-- =====================================================================
-- 第 4 段：attendance 挂 session_id（原来挂周期模板 → 一学期只能记一条）
--   保留 session_date / schedule_id 作为「只读冗余」（值永不变，省 JOIN）
--   删掉 session_no（能由 session_id 推出）
-- =====================================================================
ALTER TABLE edu_normal.attendance
  ADD COLUMN session_id BIGINT NOT NULL COMMENT '一次具体的课（→course_session.session_id）' AFTER student_id,
  DROP COLUMN schedule_time_id,
  DROP COLUMN session_no,
  DROP INDEX uk_stu_schetime,
  ADD UNIQUE KEY uk_stu_session (term_id, session_id, student_id, deleted_at),
  ADD KEY idx_stu_term_status (student_id, term_id, att_status),
  ADD KEY idx_session (session_id, term_id),
  ADD KEY idx_schedule_term (schedule_id, term_id);

-- 验证：唯一键必须含 term_id；不应再有 schedule_time_id / session_no
SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='attendance' AND NON_UNIQUE=0
GROUP BY INDEX_NAME;

SELECT COLUMN_NAME FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='edu_normal' AND TABLE_NAME='attendance'
  AND COLUMN_NAME IN ('schedule_time_id','session_no','session_id','session_date');


-- =====================================================================
-- 第 5 段：reward_punish 补金额（奖助统计必需）
-- =====================================================================
ALTER TABLE edu_normal.reward_punish
  ADD COLUMN amount DECIMAL(10,2) NULL COMMENT '金额；处分/表彰为 NULL' AFTER rp_level,
  ADD UNIQUE KEY uk_rp (student_id, rp_title, rp_date, deleted_at),
  ADD CONSTRAINT ck_rp_amount CHECK (amount IS NULL OR amount >= 0),
  ADD CONSTRAINT ck_rp_type   CHECK (rp_type IN (1,2,3,4,5)),
  ADD CONSTRAINT ck_rp_level  CHECK (rp_level IS NULL OR rp_level IN (1,2,3,4));


-- =====================================================================
-- 第 6 段：student_status_change 补异动类型（否则转专业无法与「无操作」区分）
--   注意：不要加 old_status <> new_status 的 CHECK（转专业时状态不变）
-- =====================================================================
ALTER TABLE edu_normal.student_status_change
  ADD COLUMN change_type TINYINT NOT NULL DEFAULT 1
      COMMENT '1休学/2复学/3退学/4转专业/5转班/6保留学籍/7恢复学籍' AFTER student_id,
  ADD COLUMN from_class_id BIGINT NULL COMMENT '异动前班级' AFTER change_type,
  ADD COLUMN to_class_id   BIGINT NULL COMMENT '异动后班级' AFTER from_class_id,
  ADD CONSTRAINT ck_ssc_type CHECK (change_type IN (1,2,3,4,5,6,7));


-- =====================================================================
-- 第 7 段：sys_dict 补 CHECK
-- =====================================================================
ALTER TABLE edu_normal.sys_dict
  ADD CONSTRAINT ck_dict_active CHECK (active_flag IN (0,1));


-- =====================================================================
-- 第 8 段：方案 Y —— 6 张高频业务表迁到 edu_online（一条语句，原子操作）
--   迁移后这些表必须用 edu_online.xxx 访问
-- =====================================================================
RENAME TABLE
  edu_normal.course_schedule TO edu_online.course_schedule,
  edu_normal.schedule_time   TO edu_online.schedule_time,
  edu_normal.course_session  TO edu_online.course_session,
  edu_normal.selection       TO edu_online.selection,
  edu_normal.score           TO edu_online.score,
  edu_normal.attendance      TO edu_online.attendance;

-- 验证：edu_online 应有 6 张表，edu_normal 应有 11 张
SELECT TABLE_SCHEMA, COUNT(*) tbls, GROUP_CONCAT(TABLE_NAME ORDER BY TABLE_NAME) names
FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') GROUP BY TABLE_SCHEMA;

-- 验证：迁移后分区仍然存在（RENAME 不会破坏分区）
SELECT TABLE_SCHEMA, TABLE_NAME, COUNT(*) parts
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='edu_online' AND PARTITION_NAME IS NOT NULL GROUP BY 1,2;


-- =====================================================================
-- 第 9 段（可选）：补常用查询索引
--   执行前先跑下面的查询看已有哪些索引，避免 Duplicate key name 报错
-- =====================================================================
SELECT TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='edu_online' GROUP BY 1,2 ORDER BY 1,2;

-- 若上面结果里没有对应索引，再执行下面几条（有就跳过）
ALTER TABLE edu_online.selection
  ADD KEY idx_student  (student_id, term_id, select_status),
  ADD KEY idx_schedule (schedule_id, term_id, select_status);

ALTER TABLE edu_online.score
  ADD KEY idx_student_term  (student_id, term_id),
  ADD KEY idx_schedule_term (schedule_id, term_id);

ALTER TABLE edu_online.course_schedule
  ADD KEY idx_course_term  (course_id, term_id),
  ADD KEY idx_teacher_term (teacher_id, term_id);

ALTER TABLE edu_online.course_session
  ADD KEY idx_schedule_term (schedule_id, term_id);


-- =====================================================================
-- 第 10 段：冒烟测试（证明「课次」链路真的通）
-- =====================================================================
-- ① 教室
INSERT INTO edu_normal.classroom (building_name, room_no, capacity, room_type)
VALUES ('立人楼', 'A401', 60, 1);
SET @room := LAST_INSERT_ID();

-- ② 班次（term_id = 202601）
INSERT INTO edu_online.course_schedule (course_id, teacher_id, term_id, max_count, current_count)
VALUES (1, 1, 202601, 60, 0);
SET @sch := LAST_INSERT_ID();

-- ③ 排课模板：周一 3-4 节
INSERT INTO edu_online.schedule_time (schedule_id, classroom_id, week, begin_section, end_section)
VALUES (@sch, @room, 1, 3, 4);

-- ④ 两次具体的课
INSERT INTO edu_online.course_session
  (term_id, schedule_id, session_no, week_no, session_date, week_day, start_section, end_section, classroom_id)
VALUES (202601, @sch, 1, 1, '2026-03-02', 1, 3, 4, @room),
       (202601, @sch, 2, 2, '2026-03-09', 1, 3, 4, @room);

-- ⑤ 同一学生两次考勤：第一次出勤(1)，第二次旷课(5)
INSERT INTO edu_online.attendance
  (term_id, session_id, student_id, schedule_id, session_date, att_status, check_by, check_time)
SELECT 202601, session_id, 1, @sch, session_date,
       CASE WHEN session_no = 1 THEN 1 ELSE 5 END,
       1, NOW(3)
FROM edu_online.course_session WHERE schedule_id = @sch AND term_id = 202601;

-- ⑥ 关键验证：查「该学生第 2 周缺课」——期望 1 行，week_no=2, date=2026-03-09
SELECT cs.session_no, cs.week_no, cs.session_date, a.att_status
FROM edu_online.attendance a
JOIN edu_online.course_session cs
  ON cs.session_id = a.session_id AND cs.term_id = a.term_id
WHERE a.student_id = 1 AND a.term_id = 202601 AND a.att_status = 5;

-- ⑦ 清理测试数据
DELETE FROM edu_online.attendance      WHERE term_id = 202601 AND student_id = 1;
DELETE FROM edu_online.course_session  WHERE term_id = 202601 AND schedule_id = @sch;
DELETE FROM edu_online.schedule_time   WHERE schedule_id = @sch;
DELETE FROM edu_online.course_schedule WHERE schedule_id = @sch AND term_id = 202601;
DELETE FROM edu_normal.classroom       WHERE id = @room;


-- =====================================================================
-- 第 11 段：最终验收（全部要满足）
-- =====================================================================
-- ① 表分布：edu_normal 11 张、edu_online 6 张
SELECT TABLE_SCHEMA, COUNT(*) tbls FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('edu_normal','edu_online') GROUP BY TABLE_SCHEMA;

-- ② 分区：5 张表（course_schedule/selection/score/attendance/course_session），各 5 个分区
SELECT TABLE_NAME, COUNT(*) parts FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='edu_online' AND PARTITION_NAME IS NOT NULL GROUP BY TABLE_NAME;

-- ③ 分区裁剪生效（partitions 列只显示 p202601）
EXPLAIN SELECT * FROM edu_online.selection  WHERE term_id = 202601;
EXPLAIN SELECT * FROM edu_online.attendance WHERE term_id = 202601;

-- ④ 所有分区表的主键/唯一键都含 term_id
SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) cols
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA='edu_online' AND NON_UNIQUE=0
GROUP BY 1,2,3 ORDER BY 2,3;

-- ⑤ 物理外键仍为 0
SELECT COUNT(*) fk FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA IN ('edu_normal','edu_online') AND CONSTRAINT_TYPE='FOREIGN KEY';

-- ⑥ CHECK 清单（应能看到 ck_classroom_capacity/ck_classroom_type/ck_st_week/ck_st_section/
--    ck_cs_week/ck_cs_no/ck_rp_*/ck_ssc_type/ck_dict_active/attendance_chk_1/score_chk_1/chk_self/chk_section）
SELECT tc.TABLE_SCHEMA, tc.TABLE_NAME, cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE
FROM information_schema.TABLE_CONSTRAINTS tc
JOIN information_schema.CHECK_CONSTRAINTS cc
  USING (CONSTRAINT_SCHEMA, CONSTRAINT_NAME)
WHERE tc.CONSTRAINT_SCHEMA IN ('edu_normal','edu_online') AND tc.CONSTRAINT_TYPE='CHECK'
ORDER BY 1,2,3;
