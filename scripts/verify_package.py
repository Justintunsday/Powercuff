"""Inspect the actual ar/tar payload, metadata, filters and Mach-O load commands."""
import argparse
import hashlib
import io
import json
import plistlib
import struct
import tarfile
from pathlib import Path, PurePosixPath


def require(condition, message):
    if not condition:
        raise ValueError(message)


def ar_members(data):
    require(data[:8] == b"!<arch>\n", "Not a Debian ar archive")
    result, pos = {}, 8
    while pos < len(data):
        header = data[pos:pos + 60]
        require(len(header) == 60 and header[58:] == b"`\n", "Invalid ar header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58])
        pos += 60
        require(name not in result and pos + size <= len(data), "Duplicate/truncated ar member")
        result[name] = data[pos:pos + size]
        pos += size + (size % 2)
    return result


def macho(data, dylib):
    require(data[:4] == b"\xca\xfe\xba\xbe", "Expected universal Mach-O")
    count = struct.unpack_from(">I", data, 4)[0]
    architectures = set()
    for index in range(count):
        cpu, subtype, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + 20 * index)
        require(cpu == 0x100000c, "Non-arm64 slice")
        architectures.add(subtype & 0xffffff)
        thin = data[offset:offset + size]
        require(thin[:4] == b"\xcf\xfa\xed\xfe", "Invalid 64-bit Mach-O slice")
        filetype, ncmds = struct.unpack_from("<II", thin, 12)
        require(filetype == (6 if dylib else 2), "Wrong Mach-O file type")
        pos, minimum, signed, rpaths, dependencies = 32, None, False, [], []
        for _ in range(ncmds):
            cmd, length = struct.unpack_from("<II", thin, pos)
            require(length >= 8 and pos + length <= len(thin), "Invalid load command")
            if cmd == 0x32:
                platform, minimum = struct.unpack_from("<II", thin, pos + 8)
                require(platform == 2, "Not an iOS device binary")
            if cmd == 0x25:
                minimum = struct.unpack_from("<I", thin, pos + 8)[0]
            if cmd == 0x1d:
                signed = True
            if cmd in (0xc, 0x80000018, 0x8000001c, 0xd):
                start = struct.unpack_from("<I", thin, pos + 8)[0]
                value = thin[pos + start:pos + length].split(b"\0", 1)[0].decode()
                if cmd == 0x8000001c:
                    rpaths.append(value)
                elif cmd != 0xd:
                    dependencies.append(value)
            pos += length
        require(minimum == 0x100000, f"Deployment target is not iOS 16.0: {minimum}")
        require(signed, "Missing code signature")
        require(not any(p.startswith("/Library/") or p.startswith("/usr/lib/libsubstrate") for p in dependencies), "Rootful dependency")
        if dylib:
            require(any("substrate" in p.lower() for p in dependencies), "Missing hook library")
            require("/var/jb/usr/lib" in rpaths, "Missing rootless library rpath")
    require(architectures == {0, 2}, f"Expected arm64 and arm64e, got {architectures}")


def verify(path, extract):
    raw = path.read_bytes()
    members = ar_members(raw)
    require(members.get("debian-binary") == b"2.0\n", "Missing Debian format marker")
    control_name = next(n for n in members if n.startswith("control.tar"))
    data_name = next(n for n in members if n.startswith("data.tar"))
    with tarfile.open(fileobj=io.BytesIO(members[control_name]), mode="r:*") as archive:
        files = {m.name.removeprefix("./"): m for m in archive if m.isfile()}
        metadata = archive.extractfile(files["control"]).read().decode()
        require("Architecture: iphoneos-arm64" in metadata, "Wrong Debian architecture")
        require("Package: com.rpetrich.powercuff\n" in metadata, "Wrong package ID")
        require("ellekit (>= 1.2)" in metadata and "firmware (<< 17.0)" in metadata, "Missing compatibility constraints")
        for name in ("postinst", "prerm", "postrm"):
            require(name in files and files[name].mode & 0o111, f"Missing executable {name}")
            script = archive.extractfile(files[name]).read()
            require(b"\r" not in script and script.startswith(b"#!/var/jb/bin/sh\n"), f"Invalid rootless shell interpreter: {name}")
            require(b"rm " not in script, "Removal script deletes preferences")
    expected = {
        "var/jb/Library/MobileSubstrate/DynamicLibraries/Powercuff.dylib",
        "var/jb/Library/MobileSubstrate/DynamicLibraries/Powercuff.plist",
        "var/jb/Library/PreferenceLoader/Preferences/Powercuff/Powercuff.plist",
        "var/jb/usr/bin/powercuffctl",
    }
    with tarfile.open(fileobj=io.BytesIO(members[data_name]), mode="r:*") as archive:
        files = {m.name.removeprefix("./"): m for m in archive if m.isfile()}
        require(expected <= files.keys(), f"Missing payload: {expected - files.keys()}")
        for name, member in files.items():
            require(name.startswith("var/jb/") and ".." not in PurePosixPath(name).parts, f"Unexpected path: {name}")
            require(member.uid == 0 and member.gid == 0, f"Incorrect ownership: {name}")
            payload = archive.extractfile(member).read()
            if extract:
                output = extract / name
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(payload)
            if name.endswith(("Powercuff.dylib", "/powercuffctl")):
                require(member.mode & 0o111, f"Non-executable binary: {name}")
                macho(payload, name.endswith(".dylib"))
            if name.endswith("DynamicLibraries/Powercuff.plist"):
                plist = plistlib.loads(payload)
                require(set(plist["Filter"]["Executables"]) == {"thermalmonitord", "SpringBoard"}, "Wrong injection filter")
            if name.endswith("Preferences/Powercuff/Powercuff.plist"):
                plist = plistlib.loads(payload)
                require(plist["entry"]["icon"].startswith("/var/jb/"), "Rootful icon path")
                mode = next(item for item in plist["items"] if item.get("key") == "PowerMode")
                require(mode["validValues"] == list(range(5)), "Missing thermal modes")
        print(json.dumps({"package": path.name, "sha256": hashlib.sha256(raw).hexdigest(), "files": sorted(files), "result": "PASS"}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    parser.add_argument("--extract", type=Path)
    args = parser.parse_args()
    verify(args.package, args.extract)
