#!/bin/zsh
set -u
set -e

cd "$(dirname "$0")"
rg -q '"point".*Pose\(start: 47, count: 4' Sources main.swift || exit 1
rg -q '"courier".*Pose\(start: 51, count: 4' Sources main.swift || exit 1
python3 check-sprite-clarity.py
swift -module-cache-path /tmp/pixel-cat-swift-cache check-sprite-halo.swift cat-sheet.png
print "PASS: generated task-action frames are wired into the production atlas"
