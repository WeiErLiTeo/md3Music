# Agent Guidelines for MD3Music

## Build & Test Commands
After making any code changes, you MUST run the following commands in the terminal to verify your changes:
- Check static analysis: `flutter analyze`
- Verify Android build: `flutter build apk --release --flavor standard --target-platform android-arm64 --split-per-abi`

## Quality Requirements
- Do not create or update a Pull Request if `flutter analyze` reports any errors or missing types.
- If any command fails, read the terminal output, locate the missing methods/types, and fix them automatically before finalizing.
