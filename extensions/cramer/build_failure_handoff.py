#!/usr/bin/env python3
"""Append the isolated patch to a freshly retrieved deployed initializer."""
import pathlib
import sys
base, output = map(pathlib.Path, sys.argv[1:3])
source = base.read_bytes()
assert b'module CramerFailureHandoff' not in source, 'Already patched; inspect before rebuilding'
patch = pathlib.Path(__file__).with_name('failure_handoff.rb').read_bytes()
output.write_bytes(source + b'\n# Failure handoff patch 2026-11-07\n' + patch)
assert output.read_bytes().startswith(source)
