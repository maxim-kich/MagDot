# Contributing

Contributions are welcome! MagDot currently focuses exclusively on T3 Code agents. Adding support for other agents is a great place to start.

See [Development and implementation](docs/DEVELOPMENT.md) for build requirements, helper setup, and test details. Build with `scripts/build-app.sh` and run the native `--self-test`. No hardware write should occur during ordinary build/test tasks. `tests/hardware.py` is an explicit opt-in administrator hardware test.

Keep SMC access restricted to ACLC. Do not add charging controls, generic privileged execution, or sudo rules. Tests for IPC must use the compile-time fake SMC backend. Document which observations are simulated, API readback, or visually confirmed on hardware.

Use focused PRs. Never include Keychain exports, signing keys, `.env` files, notarization account details, T3 databases, or machine logs. Contributions are under GPL-3.0-only.
