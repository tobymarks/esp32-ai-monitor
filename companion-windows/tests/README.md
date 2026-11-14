# Standalone companion regression checks

`standalone.cjs` mounts the real `Standalone.tsx` component with deferred API mocks.
It checks old-firmware capability gating, stale preview rejection after a device or
settings change, settings edits during installation, responses after reconnect,
overlapping initial/manual status reads, system appearance changes, and recovery
after a rejected stale preview. It never opens a serial port, runs
Tauri or reads application settings.

Install the regular frontend dependencies first (`pnpm install --frozen-lockfile`
in `companion-windows`). From the repository root, supply isolated React test
dependencies without changing the application lockfile:

```sh
STANDALONE_TEST_DEPS="$(mktemp -d)"
npm install --prefix "$STANDALONE_TEST_DEPS" --no-package-lock --ignore-scripts \
  react@18.3.1 react-test-renderer@18.3.1
AIMONITOR_REACT_TEST_DEPS="$STANDALONE_TEST_DEPS" node companion-windows/tests/standalone.cjs
```

The companion upload driver also has four native mock tests:

```sh
cd companion-windows
cargo test -p aimonitor standalone::tests
```

These checks cover desktop state and byte-transfer behavior. They do not establish
physical USB, Wi-Fi, TLS, filesystem or display stability on a board.
