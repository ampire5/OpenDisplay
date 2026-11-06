#!/usr/bin/env bash
# Integration checks against locally built frameworks. Default checks do not change settings.
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCTS="${OPENDISPLAY_PRODUCTS_DIR:-$PWD/build/local/Build/Products/Release}"
CHECKS="$PRODUCTS/Checks"
mkdir -p "$CHECKS"
LINK=(-F "$PRODUCTS" -Xlinker -rpath -Xlinker "$PRODUCTS")
swiftc Apps/OpenDisplay/Sources/ColorProfileService.swift Tests/macOS/ColorProfileChecks.swift -o "$CHECKS/profiles"
"$CHECKS/profiles"
swiftc -parse-as-library "${LINK[@]}" -framework DisplayDomain -framework ProviderInterfaces -framework TopologyCore \
  Providers/CoreGraphicsProvider/Sources/CoreGraphicsProvider.swift Tests/macOS/TopologyStreamChecks.swift -o "$CHECKS/topology"
"$CHECKS/topology"
swiftc -parse-as-library "${LINK[@]}" -framework ExperimentalLifecycleProvider \
  Tests/macOS/SystemColorChecks.swift -o "$CHECKS/system-colors"
swiftc -parse-as-library "${LINK[@]}" -framework DisplayDomain -framework TopologyCore \
  Apps/OpenDisplay/Sources/MediaKeyTap.swift Tests/macOS/MediaKeyTapChecks.swift -o "$CHECKS/media-keys"
"$CHECKS/media-keys"
if [[ "${1:-}" == "--exercise-modes" ]]; then "$CHECKS/system-colors" --exercise; else "$CHECKS/system-colors"; fi
if [[ "${1:-}" == "--show-huds" ]]; then
  for SOURCE in SystemHUDChecks ModernHUDChecks; do
    swiftc -parse-as-library "${LINK[@]}" -framework DisplayDomain -framework TopologyCore -framework ExperimentalLifecycleProvider \
      Apps/OpenDisplay/Sources/OSDHUDController.swift "Tests/macOS/$SOURCE.swift" -o "$CHECKS/$SOURCE"
    "$CHECKS/$SOURCE"
  done
fi

swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  Providers/ExperimentalLifecycleProvider/Sources/SystemColorControls.swift \
  Providers/ExperimentalLifecycleProvider/Sources/NightShiftStatus.swift \
  Tests/macOS/SystemColorTransportChecks.swift -o "$CHECKS/system-color-transport"
"$CHECKS/system-color-transport"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Providers/ExperimentalLifecycleProvider/Sources/DDCTransactionGate.swift \
  Tests/macOS/DDCCancellationChecks.swift -o "$CHECKS/ddc-cancellation"
"$CHECKS/ddc-cancellation"
