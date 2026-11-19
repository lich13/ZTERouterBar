from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

from verify_android import (
    EM_AARCH64,
    ELFCLASS64,
    ELFDATA2LSB,
    ELF_MAGIC,
    PT_LOAD,
    verify_apk_archive_and_manifest,
)


def make_elf64_so(p_align: int = 0x4000, machine: int = EM_AARCH64, extra_payload: bytes = b"") -> bytes:
    e_ident = ELF_MAGIC + bytes([ELFCLASS64, ELFDATA2LSB, 1]) + b"\x00" * 9
    ehdr = e_ident + struct.pack(
        "<HHIQQQIHHHHHH",
        3,          # ET_DYN
        machine,
        1,
        0,
        64,         # e_phoff
        0,
        0,
        64,
        56,         # e_phentsize
        1,          # e_phnum
        0,
        0,
        0,
    )
    phdr = struct.pack("<IIQQQQQQ", PT_LOAD, 5, 0, 0, 0, 120, 120, p_align)
    return ehdr + phdr + extra_payload


class VerifyAndroidTests(unittest.TestCase):
    def _build_apk(self, entries: dict[str, bytes]) -> Path:
        tmp = tempfile.NamedTemporaryFile(suffix=".apk", delete=False)
        tmp.close()
        path = Path(tmp.name)
        with zipfile.ZipFile(path, "w") as zf:
            for name, content in entries.items():
                zf.writestr(name, content)
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        return path

    def test_accepts_arm64_apk_with_16k_aligned_so(self):
        apk = self._build_apk({
            "classes.dex": b"dex\n039\x00clean-bytecode",
            "lib/arm64-v8a/libandroidx.graphics.path.so": make_elf64_so(0x4000),
        })
        badging = "sdkVersion:'31'\ntargetSdkVersion:'36'\nnative-code: 'arm64-v8a'\n"
        count = verify_apk_archive_and_manifest(apk, badging)
        self.assertEqual(count, 1)

    def test_accepts_pure_dex_apk_when_no_native_code_declared(self):
        apk = self._build_apk({
            "classes.dex": b"dex\n039\x00clean-kotlin-compose",
        })
        badging = "minSdkVersion:'31'\ntargetSdkVersion:'36'\n"
        count = verify_apk_archive_and_manifest(apk, badging)
        self.assertEqual(count, 0)

    def test_rejects_4k_elf_alignment_non_arm64_abi_and_build_home_paths(self):
        apk_4k = self._build_apk({
            "classes.dex": b"dex\n039\x00ok",
            "lib/arm64-v8a/libbad.so": make_elf64_so(0x1000),
        })
        with self.assertRaisesRegex(ValueError, "4 KB ELF"):
            verify_apk_archive_and_manifest(
                apk_4k,
                "sdkVersion:'31'\ntargetSdkVersion:'36'\nnative-code: 'arm64-v8a'\n",
            )

        apk_x86 = self._build_apk({
            "classes.dex": b"dex\n039\x00ok",
            "lib/x86_64/libfoo.so": make_elf64_so(0x4000),
        })
        with self.assertRaisesRegex(ValueError, "non-arm64-v8a"):
            verify_apk_archive_and_manifest(
                apk_x86,
                "sdkVersion:'31'\ntargetSdkVersion:'36'\nnative-code: 'arm64-v8a' 'x86_64'\n",
            )

        apk_leaked_dex = self._build_apk({
            "classes.dex": b"dex\n039\x00/home/fixture-runner/work/ZTERouterBar/app",
        })
        with self.assertRaises(ValueError) as raised:
            verify_apk_archive_and_manifest(
                apk_leaked_dex,
                "sdkVersion:'31'\ntargetSdkVersion:'36'\n",
            )
        self.assertNotIn("fixture-runner", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
