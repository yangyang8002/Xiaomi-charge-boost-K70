#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 module/ 打包成可直接刷入的 zip（v8.8.0-k70 新增）

上游的 releases/*.zip 是手工/外部工具打的，仓库里没有打包脚本。这里补一个可复现的：

    python tools/build-zip.py                # 输出 releases/Micharge-boost_v<version>.zip
    python tools/build-zip.py --out x.zip    # 指定输出
    python tools/build-zip.py --check        # 只校验，不写文件

要点：
- zip 里条目用正斜杠、不带 "./" 前缀（Windows 自带 Compress-Archive 会写反斜杠，安卓解压会出错）
- 权限按安卓的常规给：目录 0755、脚本与 dtbo 二进制 0755、其余 0644
- 条目时间戳固定，同样的源码打出来的 zip 字节一致，方便校验
"""
import argparse
import hashlib
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "module")
FIXED_TIME = (2026, 1, 1, 0, 0, 0)

# 需要 0755 的文件：顶层/各子目录里的 .sh，加上 dtbo 下的原生二进制
EXEC_NAMES = {"dtbopatch", "dtbopatch.bin", "dtbofv", "dtbofv.bin", "dtbomulti",
              "FreePPS", "charge_monitor.apk"}
TEXT_NAMES = {"update-binary", "module.prop"}


def read_version():
    prop = os.path.join(SRC, "module.prop")
    with open(prop, "r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^version=(.+?)\s*$", line)
            if m:
                return m.group(1)
    raise SystemExit("! module.prop 里没有 version=")


def collect():
    """返回 [(绝对路径, zip 内相对路径)]，保持稳定排序。"""
    out = []
    for base, dirs, files in os.walk(SRC):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(base, name)
            rel = os.path.relpath(full, SRC).replace(os.sep, "/")
            out.append((full, rel))
    return out


def mode_for(rel):
    name = rel.rsplit("/", 1)[-1]
    if name.endswith(".sh") or name in EXEC_NAMES:
        return 0o755
    return 0o644


def build(entries, out_path):
    tmp = out_path + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for full, rel in entries:
            info = zipfile.ZipInfo(rel, date_time=FIXED_TIME)
            info.create_system = 3                     # unix，权限位才会被保留
            info.external_attr = (0o100000 | mode_for(rel)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as f:
                z.writestr(info, f.read())
    os.replace(tmp, out_path)


def verify(out_path):
    """刷入前最基本的自检：关键条目在、没有反斜杠、没有 "./" 前缀。"""
    must = ["module.prop", "customize.sh", "service.sh",
            "META-INF/com/google/android/update-binary",
            "META-INF/com/google/android/updater-script",
            "dtbo/apply.sh", "dtbo/dtbopatch.bin", "dtbo/dtbofv.bin", "dtbo/dtbomulti"]
    problems = []
    with zipfile.ZipFile(out_path) as z:
        names = z.namelist()
        nameset = set(names)
        for m in must:
            if m not in nameset:
                problems.append("缺少 %s" % m)
        for n in names:
            if "\\" in n:
                problems.append("条目里有反斜杠: %s" % n)
            if n.startswith("./"):
                problems.append("条目带 ./ 前缀: %s" % n)
        bad = z.testzip()
        if bad:
            problems.append("zip 损坏: %s" % bad)
    return problems, len(names)


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="输出 zip 路径")
    ap.add_argument("--check", action="store_true", help="只校验 module/ 结构并打印清单")
    args = ap.parse_args()

    if not os.path.isdir(SRC):
        raise SystemExit("! 找不到源码目录 %s" % SRC)
    ver = read_version()
    entries = collect()

    if args.check:
        problems, _ = verify_entries_only(entries)
        for full, rel in entries:
            print("%s  %s" % (oct(mode_for(rel))[2:], rel))
        print("\n版本 %s，%d 个文件" % (ver, len(entries)))
        if problems:
            print("! 问题：" + "; ".join(problems))
            return 1
        print("结构检查通过")
        return 0

    out = args.out or os.path.join(ROOT, "releases", "Micharge-boost_%s.zip" % ver)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    build(entries, out)
    problems, count = verify(out)
    size = os.path.getsize(out)
    print("版本   : %s" % ver)
    print("文件数 : %d" % count)
    print("大小   : %d 字节 (%.2f MB)" % (size, size / 1e6))
    print("md5    : %s" % md5(out))
    print("输出   : %s" % out)
    if problems:
        print("! 校验失败：" + "; ".join(problems))
        return 1
    print("校验通过：关键条目齐全，无反斜杠、无 ./ 前缀，zip 完整")
    return 0


def verify_entries_only(entries):
    problems = []
    names = {rel for _, rel in entries}
    for m in ["module.prop", "customize.sh",
              "META-INF/com/google/android/update-binary"]:
        if m not in names:
            problems.append("缺少 %s" % m)
    return problems, len(entries)


if __name__ == "__main__":
    sys.exit(main())
