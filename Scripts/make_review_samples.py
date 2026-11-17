"""Generate original non-sensitive demonstration content using the real host core."""
import importlib.util
import math
import pathlib
import shutil
import struct
import wave
from bootstrap import ROOT

spec = importlib.util.spec_from_file_location("native_test_bridge", ROOT / "Tests" / "native" / "test_archive_core.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
destination = ROOT / "Build" / "ReviewSamples"
content = destination / "Content"
content.mkdir(parents=True, exist_ok=True)
note = content / "Readme.txt"
note.write_text("Original iArchiver demonstration material. No personal data.\n", encoding="utf-8")
image = content / "Preview.png"
shutil.copyfile(ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png", image)
audio = content / "Tone.wav"
with wave.open(str(audio), "wb") as output:
    output.setnchannels(1); output.setsampwidth(2); output.setframerate(22050)
    output.writeframes(b"".join(struct.pack("<h", int(5000 * math.sin(2 * math.pi * 440 * sample / 22050))) for sample in range(22050)))
store, side = module.Bridge(), module.Bridge("sideload")
store.write(destination / "Preview.zip", [(note, "Readme.txt"), (image, "图片/Preview.png"), (audio, "音频/Tone.wav")])
password = b"iArchiver-demo-2026"
store.write(destination / "AES.zip", [(note, "Readme.txt")], password=password)
store.write(destination / "Encrypted.7z", [(note, "Private/Readme.txt")], format=1, password=password)
side.write(destination / "ReadOnly-ISO9660.iso", [(note, "Readme.txt")], format=5)
shutil.copyfile(ROOT / "Tests" / "ArchiveKitTests" / "Fixtures" / "legacy-gb18030.zip", destination / "Legacy-GB18030.zip")
(destination / "Instructions.txt").write_text(
    "iArchiver review samples / 审核演示样本\n"
    "Public sample password / 公开演示密码: iArchiver-demo-2026\n"
    "Legacy-GB18030.zip: select GB18030 filename encoding.\n"
    "Preview.zip: preview PNG and WAV; extract all.\n"
    "AES.zip and Encrypted.7z: open with the sample password.\n"
    "ReadOnly-ISO9660.iso: browse and extract; App Store edition does not create ISO.\n"
    "These files contain only generated, non-sensitive demonstration content.\n", encoding="utf-8")
print(f"Created original review samples: {destination}")
