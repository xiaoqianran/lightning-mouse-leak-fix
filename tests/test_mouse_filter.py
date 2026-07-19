#!/usr/bin/env python3
"""终端协议安全性及 CLI 功能保留情况的回归测试。"""
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATH = ROOT / "grok-mouse-filter.py"
spec = importlib.util.spec_from_file_location("mouse_filter", PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)


def test_all_mouse_modes_are_disabled_but_focus_is_preserved():
    enabled = b"".join(f"\x1b[?{mode}h".encode() for mode in module.MOUSE_MODES)
    result = module.neutralize_output(enabled + b"\x1b[?1004h\x1b[?25h")
    for mode in module.MOUSE_MODES:
        assert f"\x1b[?{mode}l".encode() in result
        assert f"\x1b[?{mode}h".encode() not in result
    assert b"\x1b[?1004h" in result  # 焦点事件
    assert b"\x1b[?25h" in result  # 光标可见性


def test_mixed_decset_keeps_non_mouse_modes_and_original_action():
    result = module.neutralize_output(b"\x1b[?1006;1049;25h")
    assert result == b"\x1b[?1006l\x1b[?1049;25h"


def test_input_never_deletes_typed_or_pasted_bare_text():
    text = b"80;5M79;5M77;6M; SQL=12;4M; markdown"
    assert module.filter_input(text) == text


def test_only_unambiguous_mouse_reports_are_removed():
    assert module.filter_input(b"a\x1b[<32;80;5Mb") == b"ab"
    assert module.filter_input(b"a\x1b[M !!b") == b"ab"


def test_keyboard_clipboard_and_focus_sequences_are_unchanged():
    keys = b"\x1b\x15\x1b[A\x1b[200~paste\x1b[201~\x1b]52;c;YWJj\x07\x1b[I"
    assert module.filter_input(keys) == keys


if __name__ == "__main__":
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    for test in tests:
        test()
    print(f"{len(tests)} filter regression tests passed")
    sys.exit(0)
