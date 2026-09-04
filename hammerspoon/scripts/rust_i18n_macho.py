#!/usr/bin/env python3
"""Extract a rust-i18n 4.x translation backend from an arm64 Mach-O binary."""

import json
import re
import subprocess
import sys

STACK_BASE = 0x700000000000


def output(*args):
    return subprocess.check_output(args, text=True, errors="replace")


def symbol_info(binary):
    symbols = []
    for line in output("nm", "-nm", binary).splitlines():
        match = re.match(r"([0-9a-f]+).*\s(\S+)$", line)
        if match:
            symbols.append((int(match.group(1), 16), match.group(2)))
    for index, (address, name) in enumerate(symbols):
        if "_RUST_I18N_BACKEND" in name:
            stop = next(value for value, _ in symbols[index + 1:] if value > address)
            return address, stop, name
    raise RuntimeError("rust-i18n backend initializer symbol not found; binary may be stripped")


def segment_info(binary):
    segments = []
    current = {}
    for line in output("otool", "-l", binary).splitlines():
        match = re.match(r"\s*(vmaddr|vmsize|fileoff|filesize) (0x[0-9a-f]+|\d+)$", line)
        if match:
            current[match.group(1)] = int(match.group(2), 0)
            if len(current) == 4:
                segments.append(current)
                current = {}
    return segments


def disassemble(binary, symbol, stop):
    process = subprocess.Popen(
        ["otool", "-arch", "arm64", "-tvV", "-p", symbol, binary],
        stdout=subprocess.PIPE, text=True, errors="replace")
    instructions = []
    try:
        for line in process.stdout:
            match = re.match(r"([0-9a-f]{16})\t([^\t]+)\t?(.*)$", line.rstrip())
            if not match:
                continue
            address = int(match.group(1), 16)
            if address >= stop:
                break
            instructions.append((address, match.group(2), match.group(3)))
    finally:
        process.terminate()
        process.wait()
    return instructions


class Emulator:
    def __init__(self, binary, segments):
        with open(binary, "rb") as file:
            self.binary = file.read()
        self.segments = segments
        self.registers = {"sp": STACK_BASE}
        self.vectors = {}
        self.stack = {}
        self.translations = {}
        self.current_pairs = []

    def reg(self, name):
        if name in ("xzr", "wzr"):
            return 0
        if name.startswith("w"):
            name = "x" + name[1:]
        return self.registers.get(name)

    def set_reg(self, name, value):
        if name in ("xzr", "wzr"):
            return
        if name.startswith("w"):
            name = "x" + name[1:]
            value = None if value is None else value & 0xFFFFFFFF
        elif value is not None:
            value &= 0xFFFFFFFFFFFFFFFF
        self.registers[name] = value

    def static_offset(self, address):
        for segment in self.segments:
            start = segment["vmaddr"]
            if start <= address < start + segment["filesize"]:
                return segment["fileoff"] + address - start

    def read(self, address, size):
        if address is None:
            return None
        if STACK_BASE - 0x10000 <= address < STACK_BASE + 0x10000:
            values = [self.stack.get(address + offset) for offset in range(size)]
            return None if None in values else bytes(values)
        offset = self.static_offset(address)
        if offset is None:
            return None
        return self.binary[offset:offset + size]

    def write(self, address, value):
        if address is None or value is None:
            return
        if STACK_BASE - 0x10000 <= address < STACK_BASE + 0x10000:
            for offset, byte in enumerate(value):
                self.stack[address + offset] = byte

    def scalar_bytes(self, register):
        value = self.reg(register)
        size = 4 if register.startswith("w") else 8
        if value is not None and size == 4:
            value &= 0xFFFFFFFF
        return None if value is None else value.to_bytes(size, "little", signed=False)

    def vector_bytes(self, register):
        return self.vectors.get("q" + register[1:])

    def address(self, expression):
        match = re.match(r"\[(\w+)(?:, #(-?0x[0-9a-f]+|-?\d+))?\](!)?", expression)
        if not match:
            return None, None
        base_name, offset, preindex = match.groups()
        base = self.reg(base_name)
        offset = int(offset, 0) if offset else 0
        address = None if base is None else base + offset
        if preindex and address is not None:
            self.set_reg(base_name, address)
        return address, base_name

    def cow(self, address):
        raw = self.read(address, 24)
        if raw is None:
            return None
        pointer = int.from_bytes(raw[8:16], "little")
        length = int.from_bytes(raw[16:24], "little")
        value = self.read(pointer, length)
        if value is None:
            return None
        try:
            return value.decode("utf-8")
        except UnicodeDecodeError:
            return None

    def execute(self, mnemonic, operands):
        args = [part.strip() for part in operands.split(",")]

        if mnemonic == "adrp":
            match = re.search(r"; (0x[0-9a-f]+)", operands)
            self.set_reg(args[0], int(match.group(1), 16) if match else None)
        elif mnemonic in ("add", "sub") and len(args) >= 3:
            left = self.reg(args[1])
            immediate = re.match(r"#(-?0x[0-9a-f]+|-?\d+)", args[2])
            right = int(immediate.group(1), 0) if immediate else self.reg(args[2])
            if len(args) > 3 and args[3] == "lsl #12" and right is not None:
                right <<= 12
            value = None if left is None or right is None else (
                left + right if mnemonic == "add" else left - right)
            self.set_reg(args[0], value)
        elif mnemonic == "mov" and len(args) == 2:
            immediate = re.match(r"#(-?0x[0-9a-f]+|-?\d+)", args[1])
            value = int(immediate.group(1), 0) if immediate else self.reg(args[1])
            if value is not None:
                value &= 0xFFFFFFFFFFFFFFFF
            self.set_reg(args[0], value)
        elif mnemonic == "movi.2d" and len(args) == 2:
            value = int(args[1].lstrip("#"), 0) & 0xFFFFFFFFFFFFFFFF
            self.vectors["q" + args[0][1:]] = value.to_bytes(8, "little") * 2
        elif mnemonic in ("str", "stur") and len(args) >= 2:
            address, _ = self.address(", ".join(args[1:]))
            value = self.vector_bytes(args[0]) if args[0][0] in "qv" else self.scalar_bytes(args[0])
            self.write(address, value)
        elif mnemonic == "stp" and len(args) >= 3:
            address, _ = self.address(", ".join(args[2:]))
            first = self.vector_bytes(args[0]) if args[0][0] in "qv" else self.scalar_bytes(args[0])
            second = (self.vector_bytes(args[1]) if args[1][0] in "qv"
                      else self.scalar_bytes(args[1]))
            self.write(address, first)
            self.write(None if address is None or first is None else address + len(first), second)
        elif mnemonic in ("ldr", "ldur") and len(args) >= 2:
            address, _ = self.address(", ".join(args[1:]))
            if args[0][0] in "qv":
                self.vectors["q" + args[0][1:]] = self.read(address, 16)
            else:
                size = 4 if args[0].startswith("w") else 8
                raw = self.read(address, size)
                self.set_reg(args[0], None if raw is None else int.from_bytes(raw, "little"))
        elif mnemonic == "ldp" and len(args) >= 3:
            address, _ = self.address(", ".join(args[2:]))
            size = 16 if args[0][0] in "qv" else 8
            next_address = None if address is None else address + size
            values = [self.read(address, size), self.read(next_address, size)]
            for register, raw in zip(args[:2], values):
                if register[0] in "qv":
                    self.vectors["q" + register[1:]] = raw
                else:
                    self.set_reg(register, None if raw is None else int.from_bytes(raw, "little"))
        elif mnemonic == "bl":
            if "HashMap" in operands and "insert" in operands:
                key = self.cow(self.reg("x2"))
                value = self.cow(self.reg("x3"))
                if key is not None and value is not None:
                    self.current_pairs.append((key, value))
            elif "SimpleBackend" in operands and "add_translations" in operands:
                locale = self.cow(self.reg("x1"))
                if locale is not None:
                    self.translations[locale] = dict(self.current_pairs)
                self.current_pairs = []


def main(binary):
    _, stop, symbol = symbol_info(binary)
    instructions = disassemble(binary, symbol, stop)
    index_by_address = {address: index for index, (address, _, _) in enumerate(instructions)}
    emulator = Emulator(binary, segment_info(binary))
    index = 0
    while index < len(instructions):
        _, mnemonic, operands = instructions[index]
        emulator.execute(mnemonic, operands)
        if mnemonic == "ret":
            break
        if mnemonic == "b":
            target = re.fullmatch(r"0x[0-9a-f]+", operands)
            if target:
                target_index = index_by_address.get(int(target.group(), 16))
                if target_index is not None:
                    index = target_index
                    continue
        index += 1
    if not emulator.translations:
        raise RuntimeError("no rust-i18n translations extracted")
    print(json.dumps(emulator.translations, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1])
