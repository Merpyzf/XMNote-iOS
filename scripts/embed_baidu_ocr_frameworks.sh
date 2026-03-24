#!/bin/sh
set -eu

if [ "${PLATFORM_NAME:-}" = "iphonesimulator" ]; then
  echo "Skipping Baidu OCR embed for simulator build."
  exit 0
fi

SRC_DIR="${SRCROOT}/Vendor/BaiduOCRSDK"
DST_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

mkdir -p "${DST_DIR}"

copy_and_thin_framework() {
  FRAMEWORK_NAME="$1"
  SRC_FRAMEWORK="${SRC_DIR}/${FRAMEWORK_NAME}.framework"
  DST_FRAMEWORK="${DST_DIR}/${FRAMEWORK_NAME}.framework"
  BINARY_PATH="${DST_FRAMEWORK}/${FRAMEWORK_NAME}"

  if [ ! -d "${SRC_FRAMEWORK}" ]; then
    echo "error: Missing ${SRC_FRAMEWORK}"
    exit 1
  fi

  rm -rf "${DST_FRAMEWORK}"
  rsync -a "${SRC_FRAMEWORK}/" "${DST_FRAMEWORK}/"

  if [ -f "${BINARY_PATH}" ] && [ -n "${ARCHS:-}" ]; then
    THIN_OUTPUT="${BINARY_PATH}.thin"
    EXTRACT_ARGS=""

    for ARCH in ${ARCHS}; do
      if lipo -info "${BINARY_PATH}" | grep -q " ${ARCH} "; then
        EXTRACT_ARGS="${EXTRACT_ARGS} -extract ${ARCH}"
      fi
    done

    if [ -n "${EXTRACT_ARGS}" ]; then
      # shellcheck disable=SC2086
      lipo "${BINARY_PATH}" ${EXTRACT_ARGS} -output "${THIN_OUTPUT}"
      mv "${THIN_OUTPUT}" "${BINARY_PATH}"
    fi
  fi

  if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --preserve-metadata=identifier,entitlements --timestamp=none "${DST_FRAMEWORK}"
  fi
}

copy_and_thin_framework "AipBase"
copy_and_thin_framework "IdcardQuality"
copy_and_thin_framework "AipOcrSdk"
