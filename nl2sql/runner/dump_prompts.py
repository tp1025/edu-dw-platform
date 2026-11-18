# -*- coding: utf-8 -*-
"""导出 Prompt 到文件——给"没有 API key、想手工贴给任意 LLM"的场景用

用法：
  python runner/dump_prompts.py --mode semantic
  python runner/dump_prompts.py --mode naive

产物：prompts/{mode}/Q01.txt ... Q20.txt
  每个文件包含完整的 system + user 消息（JSON 格式），复制 user 那段贴给任意对话模型即可
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import BASE, load_yaml  # noqa: E402
from run_eval import build_messages  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["naive", "semantic"], default="semantic")
    args = ap.parse_args()

    sem = load_yaml("semantic_layer/tables.yaml")
    questions = load_yaml("golden_set/questions.yaml")["questions"]

    out_dir = os.path.join(BASE, "prompts", args.mode)
    os.makedirs(out_dir, exist_ok=True)

    total_chars = 0
    for q in questions:
        msgs = build_messages(sem, q["question"], args.mode)
        path = os.path.join(out_dir, f"{q['id']}.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# {q['id']}  [{q.get('category','')}]\n")
            f.write(f"# 问题：{q['question']}\n\n")
            f.write("## System\n")
            f.write(msgs[0]["content"] + "\n\n")
            f.write("## User（把下面这段整体贴给 LLM）\n")
            f.write(msgs[1]["content"])
        total_chars += len(msgs[0]["content"]) + len(msgs[1]["content"])

    print(f"已导出 {len(questions)} 个 Prompt 到 {out_dir}")
    print(f"平均每条 Prompt 长度: {total_chars // len(questions)} 字符 "
          f"(约 {total_chars // len(questions) // 2} tokens)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
