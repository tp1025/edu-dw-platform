# -*- coding: utf-8 -*-
"""绘制 ER 图 PNG（Pillow）— v2 修正排版"""
import math, os
from PIL import Image, ImageDraw, ImageFont

FONT = 'C:/Windows/Fonts/msyh.ttc'
f_title   = ImageFont.truetype(FONT, 32)
f_sub     = ImageFont.truetype(FONT, 17)
f_tab     = ImageFont.truetype(FONT, 19)
f_field   = ImageFont.truetype(FONT, 15)
f_label   = ImageFont.truetype(FONT, 13)
f_cluster = ImageFont.truetype(FONT, 21)

W, H = 2460, 1210
COLORS = {
    'normal': {'hdr': (26, 115, 232), 'body': (233, 241, 254), 'line': (26, 115, 232)},
    'online': {'hdr': (224, 123, 34), 'body': (255, 245, 232), 'line': (224, 123, 34)},
}

# key, 中文名, x, y, 色系, 字段
TABLES = [
    ('college',   '学院',      60, 200, 'normal', ['PK college_id','UK college_code','college_name']),
    ('teacher',   '教师',     430, 200, 'normal', ['PK teacher_id','FK college_id','UK teacher_no','teacher_name','title']),
    ('major',     '专业',     800, 200, 'normal', ['PK major_id','FK college_id','UK major_code','major_name']),
    ('class',     '行政班级',   60, 400, 'normal', ['PK class_id','FK major_id','FK teacher_id','UK class_no','enroll_year']),
    ('course',    '课程',     430, 400, 'normal', ['PK course_id','UK course_code','course_name','credit','course_type']),
    ('classroom', '教室',     800, 400, 'normal', ['PK id','UK building+room','capacity','room_type']),
    ('prereq',    '先修关系',   60, 590, 'normal', ['PK id','FK course_id','FK pre_course_id']),
    ('sysdict',   '字典',     430, 590, 'normal', ['PK id','UK type+value','dict_label','sort']),
    ('student',   '学生',     800, 590, 'normal', ['PK student_id','FK class_id','UK student_no','student_name','gender','id_card_hash','id_card_cipher']),
    ('statuschg', '学籍异动',   60, 850, 'normal', ['PK id','FK student_id','change_type','old_status','new_status','operate_time']),
    ('reward',    '奖助奖惩', 430, 850, 'normal', ['PK id','FK student_id','term_id','rp_type','amount']),

    ('schedule',  '开课班次', 1430, 200, 'online', ['PK schedule_id + term_id','FK course_id','FK teacher_id','class_no','max_count','current_count']),
    ('stime',     '排课时段', 1930, 200, 'online', ['PK st_id','FK schedule_id','FK classroom_id','week','begin_section','end_section']),
    ('session',   '授课场次', 1430, 440, 'online', ['PK session_id','FK schedule_id','FK classroom_id','session_no','week_no','session_date']),
    ('selection', '选课流水', 1930, 440, 'online', ['PK selection_id','FK student_id','FK schedule_id','term_id','select_status','active_flag 生成列']),
    ('score',     '成绩',    1430, 680, 'online', ['PK score_id','FK student_id','FK schedule_id','exam_type','total_score','usual/final_score']),
    ('attendance','考勤',    1930, 680, 'online', ['PK att_id','FK student_id','FK session_id','FK schedule_id','att_status','late_minutes']),
]

RELS = [
    ('college','major'), ('college','teacher'), ('major','class'), ('teacher','class'),
    ('class','student'), ('course','prereq'), ('course','schedule'), ('teacher','schedule'),
    ('schedule','stime'), ('schedule','session'), ('classroom','stime'), ('classroom','session'),
    ('student','selection'), ('schedule','selection'), ('student','score'), ('schedule','score'),
    ('student','attendance'), ('session','attendance'), ('student','statuschg'), ('student','reward'),
]

BOX_W, HDR_H, ROW_H, PAD = 340, 36, 25, 22

img = Image.new('RGB', (W, H), 'white')
d = ImageDraw.Draw(img)

d.text((60, 36), '高校学情数据平台 · ER 图（17 张业务表）', font=f_title, fill=(20, 20, 20))
d.text((60, 84), '逻辑关系图：无物理外键，引用完整性由应用层校验 + 每日孤儿巡检保证（分区表不支持外键）',
       font=f_sub, fill=(110, 110, 110))

# 两个簇的背景
d.rounded_rectangle([40, 165, 1180, 1080], radius=14, outline=(205, 210, 220), width=2)
d.text((62, 172), 'edu_normal（主数据）', font=f_cluster, fill=(26, 115, 232))
d.rounded_rectangle([1400, 165, 2420, 940], radius=14, outline=(205, 210, 220), width=2)
d.text((1422, 172), 'edu_online（高频业务）· 5 张按 term_id RANGE 分区', font=f_cluster, fill=(224, 123, 34))

boxes = {}
for key, cn, x, y, cl, fields in TABLES:
    h = HDR_H + len(fields) * ROW_H + PAD
    boxes[key] = (x, y, BOX_W, h)
    c = COLORS[cl]
    d.rounded_rectangle([x, y, x + BOX_W, y + h], radius=8, fill=c['body'], outline=c['hdr'], width=2)
    d.rounded_rectangle([x, y, x + BOX_W, y + HDR_H], radius=8, fill=c['hdr'])
    d.rectangle([x, y + HDR_H - 12, x + BOX_W, y + HDR_H], fill=c['hdr'])
    d.text((x + 12, y + 7), cn, font=f_tab, fill='white')
    d.text((x + BOX_W - 10, y + 9), key, font=f_field, fill=(255, 255, 255), anchor='ra')
    for i, f in enumerate(fields):
        fy = y + HDR_H + 8 + i * ROW_H
        col = (176, 58, 0) if f.startswith('PK') else (26, 115, 232) if f.startswith('FK') else \
              (110, 60, 160) if f.startswith('UK') else (40, 40, 40)
        d.text((x + 14, fy), f, font=f_field, fill=col)


def edge_point(box, tx, ty):
    x, y, w, h = box
    cx, cy = x + w / 2, y + h / 2
    dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0:
        return cx, cy
    sx = (w / 2) / abs(dx) if dx else 1e9
    sy = (h / 2) / abs(dy) if dy else 1e9
    s = min(sx, sy)
    return cx + dx * s, cy + dy * s


def arrow(p1, p2, color):
    d.line([p1, p2], fill=color, width=2)
    ang = math.atan2(p2[1] - p1[1], p2[0] - p1[0])
    L, spread = 13, 0.40
    for a in (ang + math.pi - spread, ang + math.pi + spread):
        d.line([p2, (p2[0] + L * math.cos(a), p2[1] + L * math.sin(a))], fill=color, width=2)


for a, b in RELS:
    if a not in boxes or b not in boxes:
        continue
    ba, bb = boxes[a], boxes[b]
    ca = (ba[0] + ba[2] / 2, ba[1] + ba[3] / 2)
    cb = (bb[0] + bb[2] / 2, bb[1] + bb[3] / 2)
    p1 = edge_point(ba, *cb)
    p2 = edge_point(bb, *ca)
    same = (ba[0] < 1200) == (bb[0] < 1200)
    color = (COLORS['normal']['line'] if ba[0] < 1200 else COLORS['online']['line']) if same else (150, 150, 150)
    arrow(p1, p2, color)

# 图例
lx, ly = 60, 1120
d.text((lx, ly), '图例：', font=f_field, fill=(20, 20, 20))
items = [('PK 主键', (176, 58, 0)), ('FK 逻辑外键（无物理约束）', (26, 115, 232)),
         ('UK 唯一键', (110, 60, 160)), ('→ 一对多（1:N）', (110, 110, 110))]
xoff = lx + 70
for t, c in items:
    d.text((xoff, ly), t, font=f_field, fill=c)
    xoff += d.textlength(t, font=f_field) + 46

# 右下角说明
nx, ny = 60, 1160
notes = ('排课三层：schedule_time（模板：周一 3-4 节）→ course_session（具体某次课：2026-03-02）'
         '→ attendance（谁来了）；因此可回答“2026-03-02 高数 1 班谁缺勤”')
d.text((nx, ny), notes, font=f_label, fill=(90, 90, 90))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ER图-教务数据平台.png')
img.save(out, 'PNG')
print('saved:', out, img.size)
