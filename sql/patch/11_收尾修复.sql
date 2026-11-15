-- =====================================================================
-- 收尾修复脚本（3 项）
-- 环境：MySQL 26.10 @ 127.0.0.1:3307
-- 前提：各表 0 行
-- =====================================================================


-- =====================================================================
-- 修复 1【必须】：course_session 是 HASH 分区，改成 RANGE（与其他 4 张表一致）
-- 现状：PARTITION_METHOD=HASH，12 个分区 p0..p11
-- 问题：① 与 course_schedule/selection/score/attendance 的 RANGE 边界不一致
--       ② 无法按学期 DROP PARTITION 归档（阶段4 冷热分层靠这个）
--       ③ 加新学时要重建分区，RANGE 只需 ADD PARTITION
-- =====================================================================
ALTER TABLE edu_online.course_session
  PARTITION BY RANGE (term_id) (
    PARTITION p202501 VALUES LESS THAN (202502),
    PARTITION p202502 VALUES LESS THAN (202601),
    PARTITION p202601 VALUES LESS THAN (202602),
    PARTITION p202602 VALUES LESS THAN (202701),
    PARTITION p_future VALUES LESS THAN MAXVALUE
  );

-- 验证：应为 RANGE / term_id / 5 个分区
SELECT TABLE_NAME, PARTITION_METHOD, PARTITION_EXPRESSION, COUNT(*) parts
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA='edu_online' AND TABLE_NAME='course_session' AND PARTITION_NAME IS NOT NULL
GROUP BY 1,2,3;

-- 验证：裁剪生效（partitions 列应只显示 p202601）
EXPLAIN SELECT * FROM edu_online.course_session WHERE term_id = 202601;


-- =====================================================================
-- 修复 2：清掉冒烟测试残留（classroom 多了一条「立人楼 A401」）
-- =====================================================================
SELECT * FROM edu_normal.classroom;

DELETE FROM edu_normal.classroom WHERE building_name='立人楼' AND room_no='A401';

-- 验证：应为 0
SELECT COUNT(*) AS classroom_rows FROM edu_normal.classroom;


-- =====================================================================
-- 修复 3【必须，灌数前】：填充 sys_dict 种子字典
-- 灌数据前必须先有字典，否则所有 TINYINT 状态值都没人能看懂
-- 注意：dict_type 与业务表字段一一对应，dict_value 存数字字符串
-- =====================================================================
INSERT INTO edu_normal.sys_dict (dict_type, dict_value, dict_label, sort, active_flag, deleted_at) VALUES
-- 学籍状态（student.student_status）
('student_status','1','正常',1,1,'1970-01-01 00:00:00'),
('student_status','2','休学',2,1,'1970-01-01 00:00:00'),
('student_status','3','退学',3,1,'1970-01-01 00:00:00'),
-- 性别（student.gender）
('sex','1','男',1,1,'1970-01-01 00:00:00'),
('sex','2','女',2,1,'1970-01-01 00:00:00'),
-- 选课状态（selection.select_status）
('select_status','1','已选',1,1,'1970-01-01 00:00:00'),
('select_status','2','已退',2,1,'1970-01-01 00:00:00'),
('select_status','3','班次作废',3,1,'1970-01-01 00:00:00'),
-- 考试类型（score.exam_type）
('exam_type','1','正考',1,1,'1970-01-01 00:00:00'),
('exam_type','2','补考',2,1,'1970-01-01 00:00:00'),
('exam_type','3','缓考',3,1,'1970-01-01 00:00:00'),
-- 成绩状态（score.score_status）
('score_status','1','待录入',1,1,'1970-01-01 00:00:00'),
('score_status','2','已录入',2,1,'1970-01-01 00:00:00'),
('score_status','3','已复核',3,1,'1970-01-01 00:00:00'),
-- 考勤状态（attendance.att_status）
('att_status','0','待签到',0,1,'1970-01-01 00:00:00'),
('att_status','1','出勤',1,1,'1970-01-01 00:00:00'),
('att_status','2','迟到',2,1,'1970-01-01 00:00:00'),
('att_status','3','早退',3,1,'1970-01-01 00:00:00'),
('att_status','4','请假',4,1,'1970-01-01 00:00:00'),
('att_status','5','旷课',5,1,'1970-01-01 00:00:00'),
-- 学籍异动类型（student_status_change.change_type）
('status_change_type','1','休学',1,1,'1970-01-01 00:00:00'),
('status_change_type','2','复学',2,1,'1970-01-01 00:00:00'),
('status_change_type','3','退学',3,1,'1970-01-01 00:00:00'),
('status_change_type','4','转专业',4,1,'1970-01-01 00:00:00'),
('status_change_type','5','转班',5,1,'1970-01-01 00:00:00'),
('status_change_type','6','保留学籍',6,1,'1970-01-01 00:00:00'),
('status_change_type','7','恢复学籍',7,1,'1970-01-01 00:00:00'),
-- 奖助奖惩类型（reward_punish.rp_type）
('rp_type','1','奖学金',1,1,'1970-01-01 00:00:00'),
('rp_type','2','助学金',2,1,'1970-01-01 00:00:00'),
('rp_type','3','困难补助',3,1,'1970-01-01 00:00:00'),
('rp_type','4','校级表彰',4,1,'1970-01-01 00:00:00'),
('rp_type','5','处分',5,1,'1970-01-01 00:00:00'),
-- 奖助等级（reward_punish.rp_level）
('rp_level','1','国家级',1,1,'1970-01-01 00:00:00'),
('rp_level','2','省级',2,1,'1970-01-01 00:00:00'),
('rp_level','3','校级',3,1,'1970-01-01 00:00:00'),
('rp_level','4','院级',4,1,'1970-01-01 00:00:00'),
-- 教室类型（classroom.room_type）
('room_type','1','普通教室',1,1,'1970-01-01 00:00:00'),
('room_type','2','机房',2,1,'1970-01-01 00:00:00'),
('room_type','3','实验室',3,1,'1970-01-01 00:00:00'),
-- 课程类型（course.course_type）
('course_type','1','必修',1,1,'1970-01-01 00:00:00'),
('course_type','2','选修',2,1,'1970-01-01 00:00:00');

-- 验证：应为 41 行，11 个 dict_type
SELECT dict_type, COUNT(*) cnt FROM edu_normal.sys_dict
WHERE deleted_at='1970-01-01 00:00:00' GROUP BY dict_type ORDER BY dict_type;

SELECT COUNT(*) AS total FROM edu_normal.sys_dict;


-- =====================================================================
-- 附：两个可选改动（建议在灌数前决定，0 行时最便宜）
-- =====================================================================

-- 可选 A：selection.active_flag 改成生成列（数据库层兜底防重复选课）
--   现状是普通列，靠应用层维护；改成生成列后，应用写错也挡得住
-- ALTER TABLE edu_online.selection
--   MODIFY COLUMN active_flag TINYINT
--     GENERATED ALWAYS AS (IF(select_status = 1, 1, NULL)) STORED;

-- 可选 B：score 补分项成绩（若作业要求平时分/期末分分开录）
-- ALTER TABLE edu_online.score
--   ADD COLUMN usual_score DECIMAL(5,2) NULL COMMENT '平时分' AFTER exam_type,
--   ADD COLUMN final_score DECIMAL(5,2) NULL COMMENT '期末分' AFTER usual_score,
--   ADD CONSTRAINT ck_score_usual CHECK (usual_score IS NULL OR usual_score BETWEEN 0 AND 100),
--   ADD CONSTRAINT ck_score_final CHECK (final_score IS NULL OR final_score BETWEEN 0 AND 100);

-- 可选 C：student_status_change 加查询索引（查某人异动历史）
-- ALTER TABLE edu_normal.student_status_change
--   ADD KEY idx_stu_time (student_id, operate_time);
