# -*- coding: utf-8 -*-
"""从 information_schema 导出的 TSV 生成数据字典（Markdown + Excel）"""
import csv, os
from collections import defaultdict, OrderedDict
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

BASE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.join(os.path.dirname(BASE), 'tmp')
OUT_MD = os.path.join(os.path.dirname(BASE), '阶段1-数据字典.md')
OUT_XLSX = os.path.join(os.path.dirname(BASE), '数据字典.xlsx')


def read_tsv(name):
    p = os.path.join(TMP, name)
    rows = []
    with open(p, encoding='utf-8-sig') as f:
        r = csv.reader(f, delimiter='\t')
        header = next(r)
        for line in r:
            if not line:
                continue
            rows.append(dict(zip(header, line)))
    return rows


cols = [c for c in read_tsv('cols.tsv') if c['TABLE_NAME'] not in ('nums','sp_result')]
tables = read_tsv('tables.tsv')
indexes = read_tsv('indexes.tsv')
parts = read_tsv('partitions.tsv')

# 组织数据
tab_info = {(t['TABLE_SCHEMA'], t['TABLE_NAME']): t for t in tables}
idx_by_tab = defaultdict(list)
for i in indexes:
    idx_by_tab[(i['TABLE_SCHEMA'], i['TABLE_NAME'])].append(i)
part_by_tab = {}
for p in parts:
    part_by_tab[(p['TABLE_SCHEMA'], p['TABLE_NAME'])] = p

cols_by_tab = OrderedDict()
for c in cols:
    cols_by_tab.setdefault((c['TABLE_SCHEMA'], c['TABLE_NAME']), []).append(c)
SCHEMA_ORDER = {'edu_normal': 0, 'edu_online': 1, 'edu_dw': 2}
cols_by_tab = OrderedDict(sorted(cols_by_tab.items(), key=lambda kv: (SCHEMA_ORDER.get(kv[0][0], 9), kv[0][1])))

SCHEMA_CN = {'edu_normal': '主数据库（主数据）', 'edu_online': '业务库（高频业务）', 'edu_dw': '数仓层'}
KEY_CN = {'PRI': 'PK', 'UNI': 'UK', 'MUL': 'IDX', '': ''}


def fmt_default(v):
    if v == '~NULL~':
        return '—'
    if v.startswith('CURRENT_TIMESTAMP'):
        return 'CURRENT_TIMESTAMP'
    return v


def fmt_extra(v):
    v = (v or '').replace('DEFAULT_GENERATED', '').replace('on update CURRENT_TIMESTAMP', 'ON UPDATE').strip()
    if 'STORED GENERATED' in v:
        return '生成列(STORED)'
    return v


# ============ 生成 Markdown ============
lines = []
lines.append('# 数据字典（自动生成）\n')
lines.append('> 生成时间：2026-11-13 ｜ 来源：`information_schema` 直接导出')
lines.append('> 说明：键标记 `PK`=主键、`UK`=唯一键、`IDX`=普通索引；逻辑外键在字段说明里以「→ 表.字段」标注。\n')

# 概览
lines.append('\n## 一、表清单概览\n')
lines.append('| # | 库 | 表名 | 中文说明 | 行数 | 分区 | 索引数 |')
lines.append('|---|---|---|---|---|---|---|')
idx = 1
for (sch, tab), cs in cols_by_tab.items():
    info = tab_info.get((sch, tab), {})
    p = part_by_tab.get((sch, tab))
    part_str = f"{p['PART_CNT']} 个（{p['PART_MIN']}~{p['PART_MAX']}）" if p else '—'
    comment = info.get('CMT', '') or ''
    rows = info.get('TABLE_ROWS', '0') or '0'
    try:
        rows = f"≈{int(rows):,}"
    except ValueError:
        pass
    lines.append(f"| {idx} | `{sch}` | `{tab}` | {comment} | {rows} | {part_str} | {len(idx_by_tab[(sch,tab)])} |")
    idx += 1

# 逐表字段
lines.append('\n## 二、字段明细\n')
cur_schema = None
for (sch, tab), cs in cols_by_tab.items():
    if sch != cur_schema:
        cur_schema = sch
        lines.append(f'\n### {SCHEMA_CN.get(sch, sch)}：`{sch}`\n')
    info = tab_info.get((sch, tab), {})
    comment = info.get('CMT', '') or tab
    rows = info.get('TABLE_ROWS', '0') or '0'
    try:
        rows = f"≈{int(rows):,}"
    except ValueError:
        pass
    lines.append(f'#### `{tab}` — {comment}')
    lines.append(f'行数 {rows}')
    lines.append('')
    lines.append('| # | 字段 | 类型 | 可空 | 默认 | 键 | 说明 |')
    lines.append('|---|---|---|---|---|---|---|')
    for c in cs:
        key = KEY_CN.get(c['COLUMN_KEY'], c['COLUMN_KEY'])
        extra = fmt_extra(c['EXTRA'])
        note = c['CMT'] or ''
        if extra:
            note = (note + ' ' if note else '') + f'【{extra}】'
        lines.append(f"| {c['ORDINAL_POSITION']} | `{c['COLUMN_NAME']}` | {c['COLUMN_TYPE']} | "
                     f"{'Y' if c['IS_NULLABLE']=='YES' else 'N'} | {fmt_default(c['DEF'])} | "
                     f"{key} | {note} |")
    # 索引
    if idx_by_tab[(sch, tab)]:
        lines.append('')
        lines.append('**索引**：')
        for i in idx_by_tab[(sch, tab)]:
            kind = 'UNIQUE' if i['NON_UNIQUE'] == '0' else 'INDEX'
            lines.append(f"- `{i['INDEX_NAME']}` ({kind}) — ({i['COLS']})")
    lines.append('')

with open(OUT_MD, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))

# ============ 生成 Excel ============
wb = Workbook()
ws0 = wb.active
ws0.title = '表清单'
thin = Side(style='thin', color='DDDDDD')
border = Border(left=thin, right=thin, top=thin, bottom=thin)
hdr_fill = PatternFill('solid', fgColor='1A73E8')
hdr_font = Font(color='FFFFFF', bold=True, size=11)

def style_header(ws, ncol):
    for c in range(1, ncol + 1):
        cell = ws.cell(row=1, column=c)
        cell.fill = hdr_fill
        cell.font = hdr_font
        cell.alignment = Alignment(horizontal='center', vertical='center')
    ws.freeze_panes = 'A2'

ws0.append(['#', '库', '表名', '中文说明', '行数', '分区', '索引数'])
style_header(ws0, 7)
i = 1
for (sch, tab), cs in cols_by_tab.items():
    info = tab_info.get((sch, tab), {})
    p = part_by_tab.get((sch, tab))
    part_str = f"{p['PART_CNT']} 分区 {p['PART_MIN']}~{p['PART_MAX']}" if p else '—'
    rows = info.get('TABLE_ROWS', '0') or '0'
    try:
        rows = int(rows)
    except ValueError:
        rows = 0
    ws0.append([i, sch, tab, info.get('CMT', ''), rows, part_str, len(idx_by_tab[(sch, tab)])])
    i += 1
for col, w in zip('ABCDEFG', [5, 14, 26, 30, 12, 28, 9]):
    ws0.column_dimensions[col].width = w

ws1 = wb.create_sheet('字段明细')
ws1.append(['库', '表名', '中文说明', '序号', '字段', '类型', '可空', '默认值', '键', '额外', '说明', '索引'])
style_header(ws1, 12)
for (sch, tab), cs in cols_by_tab.items():
    info = tab_info.get((sch, tab), {})
    idx_desc = '；'.join(
        f"{x['INDEX_NAME']}{'(UK)' if x['NON_UNIQUE']=='0' else ''}"
        f"({x['COLS']})"
        for x in idx_by_tab[(sch, tab)]
    )
    for c in cs:
        ws1.append([sch, tab, info.get('CMT', ''), int(c['ORDINAL_POSITION']),
                    c['COLUMN_NAME'], c['COLUMN_TYPE'],
                    'Y' if c['IS_NULLABLE'] == 'YES' else 'N',
                    fmt_default(c['DEF']), KEY_CN.get(c['COLUMN_KEY'], c['COLUMN_KEY']),
                    fmt_extra(c['EXTRA']), c['CMT'], idx_desc])
for col, w in zip('ABCDEFGHIJKL', [13, 24, 26, 6, 22, 22, 6, 20, 6, 16, 40, 60]):
    ws1.column_dimensions[col].width = w

wb.save(OUT_XLSX)
print('MD  :', OUT_MD)
print('XLSX:', OUT_XLSX)
print('表数:', len(cols_by_tab), '字段数:', sum(len(v) for v in cols_by_tab.values()))
