# -*- coding: utf-8 -*-
"""从 results/*.json 生成 Markdown 报告表格（不重新调 API）

用法：
  python runner/report_md.py            # 打印到控制台
  python runner/report_md.py > report.txt
"""
import json
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import BASE  # noqa: E402

CATE_ORDER = ["单表聚合", "分组排序", "明细查询", "趋势对比", "口径陷阱", "应拒绝"]


def load(mode):
    p = os.path.join(BASE, "results", f"{mode}.json")
    if not os.path.exists(p):
        sys.exit(f"缺少 {p}，请先跑 run_eval.py --mode {mode}")
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def pct(x):
    return f"{x*100:.1f}%"


def main():
    a, b = load("naive"), load("semantic")
    sa, sb = a["summary"], b["summary"]

    print("## 总体结果\n")
    print("| 指标 | A 组 naive | B 组 semantic | 提升 |")
    print("|---|---|---|---|")
    rows = [
        ("执行成功率", "exec_success_rate"),
        ("结果一致率（严格）", "strict_pass_rate"),
        ("结果一致率（宽松）", "pass_rate_with_lenient"),
    ]
    for label, key in rows:
        va, vb = sa[key], sb[key]
        print(f"| {label} | {pct(va)} | {pct(vb)} | **{(vb-va)*100:+.1f} pp** |")
    print(f"| 通过题数（严格） | {sa['strict_pass']}/{sa['total']} | "
          f"{sb['strict_pass']}/{sb['total']} | — |")

    print("\n## 按题型拆分\n")
    print("| 题型 | 条数 | A naive 严格 | B semantic 严格 | A 宽松 | B 宽松 |")
    print("|---|---|---|---|---|---|")

    def cat_stats(d):
        """直接从 details 重算，不依赖 summary 的字段结构"""
        st = defaultdict(lambda: {"total": 0, "strict": 0, "lenient": 0})
        for x in d["details"]:
            c = x["category"]
            st[c]["total"] += 1
            if x["status"] == "PASS":
                st[c]["strict"] += 1
            if x["status"] in ("PASS", "PASS_LENIENT"):
                st[c]["lenient"] += 1
        return st

    ca, cb = cat_stats(a), cat_stats(b)
    for cat in CATE_ORDER:
        if cat not in ca and cat not in cb:
            continue
        va = ca.get(cat, {"total": 0, "strict": 0, "lenient": 0})
        vb = cb.get(cat, {"total": 0, "strict": 0, "lenient": 0})
        n = va["total"] or vb["total"]
        print(f"| {cat} | {n} | {va['strict']}/{va['total']} | {vb['strict']}/{vb['total']} "
              f"| {va['lenient']}/{va['total']} | {vb['lenient']}/{vb['total']} |")

    print("\n## 失败原因分布\n")
    print("| 失败类型 | A 组 | B 组 |")
    print("|---|---|---|")

    def fail_count(d):
        c = defaultdict(int)
        for x in d["details"]:
            if x["status"] not in ("PASS", "PASS_LENIENT"):
                c[x["status"]] += 1
        return c

    fa, fb = fail_count(a), fail_count(b)
    for k in sorted(set(fa) | set(fb)):
        print(f"| `{k}` | {fa.get(k, 0)} | {fb.get(k, 0)} |")

    print("\n## 未通过的题目明细\n")
    for name, d in (("A naive", a), ("B semantic", b)):
        bad = [x for x in d["details"] if x["status"] != "PASS"]
        if not bad:
            print(f"**{name}**：全部通过\n")
            continue
        print(f"**{name}**（{len(bad)} 条）\n")
        print("| 题号 | 题型 | 状态 | 说明 |")
        print("|---|---|---|---|")
        for x in bad:
            note = x.get("note") or ""
            if not note and x.get("detail"):
                note = json.dumps(x["detail"], ensure_ascii=False, default=str)[:80]
            print(f"| {x['id']} | {x['category']} | `{x['status']}` | {str(note)[:80].replace('|','/')} |")
        print()

    # 归纳：exec_fail 的错误模式
    print("## 执行失败的错误模式（A 组）\n")
    pat = defaultdict(int)
    for x in a["details"]:
        if x["status"] == "EXEC_FAIL":
            n = x.get("note", "")
            if "Unknown column" in n:
                col = n.split("Unknown column '")[1].split("'")[0] if "Unknown column '" in n else "?"
                pat[f"幻觉字段 `{col}`"] += 1
            else:
                pat["其他"] += 1
    for k, v in pat.items():
        print(f"- {k}：**{v}** 次")
    return 0


if __name__ == "__main__":
    sys.exit(main())
