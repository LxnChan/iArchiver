# Project workflow

- Perform all compilation and test execution in GitHub Actions. The development workspace is Windows; Apple builds use the `xcode-27` Apple silicon runner.
- Local source editing, static inspection and deterministic project/resource generation are allowed. Do not run local native builds, Swift tests or repository test scripts.
- Follow `.github/workflows/validate.yml`. Inspect the actual run and fix failures before reporting validation as passed. A skipped test is not a pass.
- Preserve both compiled editions and the iOS 18 deployment minimum. Building Duo reserved-region integration requires the public iOS 27.1 SDK or newer.
- Keep signing material outside Git. CI validation products are unsigned; do not describe them as directly installable, signed or App Store ready.
- Regenerate `iArchiver.xcodeproj` with `python Scripts/generate_project.py` after changing target/source membership. Commit the generator and generated project together.
