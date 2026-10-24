"""Fix numeric ownership in the pinned dm.pl non-fakeroot packaging path."""
import os
from pathlib import Path

path = Path(os.environ["THEOS"]) / "vendor/dm.pl/dm.pl"
source = path.read_text()
before = '$tf->chown("root", "wheel");'
assert source.count(before) == 1, "Pinned dm.pl fallback changed; review ownership handling"
source = source.replace(before, before + '\n\t\t\t\t\t$tf->uid(0); $tf->gid(0);')
path.write_text(source)
print("Patched dm.pl non-fakeroot fallback: explicitly set numeric uid=0 gid=0")
