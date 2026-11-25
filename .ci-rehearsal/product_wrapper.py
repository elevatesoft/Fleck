"""Generate a shadow-only SwiftBuild test-product wrapper; never alter source."""
import hashlib
import pathlib
import sys

SOURCE_SHA256 = "dff819449df5b18d4e105e746f5d6f2bab27d23de3d0e8c54dedef733ea1c8b6"
TARGET = "FleckAgentProtocolTests"
REPLACEMENTS = (
    ('build_arguments=(build --target "$test_target" --disable-automatic-resolution)',
     'build_arguments=(build --product "$test_target" --disable-automatic-resolution)'),
    ('bin_arguments=(build --show-bin-path --target "$test_target" --disable-automatic-resolution)',
     'bin_arguments=(build --show-bin-path --product "$test_target" --disable-automatic-resolution)'),
    ('readonly package_root="$1"',
     '''[[ "$target_selected" == 1 && "$test_target" == FleckAgentProtocolTests &&
    "${FLECK_TEST_SWIFT_BUILD_SYSTEM:-}" == swiftbuild &&
    -n "$2" && ! -e "$2" && ! -L "$2" ]] || {
  printf '%s\\n' 'error: shadow product requires its known target and fresh scratch' >&2; exit 1
}
readonly package_root="$1"'''),
    ('  bundle_path="$bin_path/$test_target.xctest"',
     '''  python3 -B "$script_dir/product_wrapper.py" verify-output "$bin_path" || exit 1
  bundle_path="$bin_path/$test_target.xctest"'''),
)

def transformed(data):
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise ValueError("AppKit source wrapper is not the reviewed base")
    text = data.decode()
    for old, new in REPLACEMENTS:
        if text.count(old) != 1:
            raise ValueError("reviewed wrapper anchor is missing or duplicated")
        text = text.replace(old, new, 1)
    return text

def verify_output(root):
    if not root.is_dir() or root.is_symlink():
        raise ValueError("missing or unsafe test product output root")
    bundles = sorted(str(p.relative_to(root)) for p in root.rglob("*.xctest"))
    if bundles != [f"{TARGET}.xctest"]:
        raise ValueError(f"expected only the selected native test bundle; observed {bundles}")
    unrelated = ("FleckApp", "FleckAgentBridge", "FleckModelEvaluation", "FleckCaptureLab",
                 "CFleckEventHTTP")
    extra = sorted(str(p.relative_to(root)) for p in root.rglob("*")
                   if p.name in (*unrelated, "Fleck", "fleck-agent")
                   or any(p.name.startswith(n + ".") for n in unrelated))
    if extra:
        raise ValueError(f"unrelated app/bridge artifacts in fresh scoped output: {extra[:8]}")
    print(f"shadow product inventory: {TARGET}.xctest only; no unrelated app/bridge outputs")

if __name__ == "__main__":
    if sys.argv[1] == "generate" and len(sys.argv) == 4:
        src, dest = map(pathlib.Path, sys.argv[2:])
        with dest.open("x", encoding="utf-8") as out:
            out.write(transformed(src.read_bytes()))
    elif sys.argv[1] == "verify-output" and len(sys.argv) == 3:
        verify_output(pathlib.Path(sys.argv[2]))
    else:
        raise ValueError("expected generate SOURCE DEST or verify-output BIN_PATH")
