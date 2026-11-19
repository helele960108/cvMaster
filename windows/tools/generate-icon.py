"""兼容旧入口：从共享 SVG 重新生成两端图标。"""
from pathlib import Path
import runpy
import sys


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("图标重生成需要 macOS 的 sips 和 iconutil；Windows 构建直接使用已生成资源。")
    runpy.run_path(str(Path(__file__).resolve().parents[2] / "native/scripts/generate-icons.py"),
                   run_name="__main__")
