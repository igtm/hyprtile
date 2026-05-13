#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: package-macos-app.sh [--version VERSION] [--configuration CONFIG] [--artifact-suffix SUFFIX] [--output-dir DIR]
EOF
}

version=""
configuration="release"
artifact_suffix=""
output_dir="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="$2"
      shift 2
      ;;
    --configuration)
      configuration="$2"
      shift 2
      ;;
    --artifact-suffix)
      artifact_suffix="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repo_root}"

if [[ -z "${version}" ]]; then
  version="$(tr -d '[:space:]' < VERSION)"
fi

if [[ -z "${version}" ]]; then
  echo "ERROR: Failed to determine version" >&2
  exit 1
fi

if [[ -z "${artifact_suffix}" ]]; then
  artifact_suffix="$(uname -m)-apple-darwin"
fi

app_name="Hyprtile"
info_plist_template="Support/Hyprtile-Info.plist"

swift build -c "${configuration}" --product "${app_name}"
bin_dir="$(swift build -c "${configuration}" --product "${app_name}" --show-bin-path)"
binary_path="${bin_dir}/${app_name}"

if [[ ! -x "${binary_path}" ]]; then
  echo "ERROR: Built binary not found at ${binary_path}" >&2
  exit 1
fi

app_bundle="${output_dir}/${app_name}.app"
archive_name="${app_name}_v${version}_${artifact_suffix}.zip"
archive_path="${output_dir}/${archive_name}"

rm -rf "${app_bundle}" "${archive_path}"
mkdir -p "${app_bundle}/Contents/MacOS"

cp "${info_plist_template}" "${app_bundle}/Contents/Info.plist"
cp "${binary_path}" "${app_bundle}/Contents/MacOS/${app_name}"

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${app_name}" "${app_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${app_name}" "${app_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${app_name}" "${app_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${app_bundle}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version}" "${app_bundle}/Contents/Info.plist"

codesign --force --sign - --timestamp=none "${app_bundle}/Contents/MacOS/${app_name}"
codesign --force --sign - --timestamp=none --deep "${app_bundle}"

(
  cd "${output_dir}"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "${archive_name}" "${app_name}.app"
)

echo "app_bundle=${app_bundle}"
echo "archive_path=${archive_path}"
echo "archive_name=${archive_name}"
