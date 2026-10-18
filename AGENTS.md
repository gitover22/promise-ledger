# Promise Ledger development

- This is a native macOS SwiftUI/AppKit application, not a web app. Keep the application lightweight and avoid third-party runtimes unless explicitly justified.
- Use the user's existing Rednote MaaS configuration at `~/.config/promise-ledger/model.json`; read its accompanying README before changing AI integration. Default model is GPT-5.6 Sol. Read headers, application ID, and streaming defaults from that file.
- The existing credential is in macOS Keychain, service `promise-ledger.maas.api-key`, account `promise-ledger`. Read it inside the calling process, capturing stdout. Never print, persist, commit, or send it to any unconfigured service. Do not ask for this saved key again.
- Include the configured `x-maas-app-id` (currently `seal`) and the actual `x-maas-scenario` (`bill-extraction` for this product). Do not replace the default model because a different model was used in a diagnostic example.
- Do not copy secrets or model credentials to H20, a server, or a Pod without explicit authorization.
- `swift run LedgerTests` runs the dependency-free core test suite. `swift run LedgerCheck` tests local OCR/storage. `swift run LedgerCheck --live-ai` additionally sends only a generated synthetic receipt's OCR to the real model. Never capture the user's screen as part of automated diagnostics.
- `./scripts/build.sh` creates an ad-hoc signed local app in `dist/Promise Ledger.app`. `./scripts/run.sh` builds and launches it. Full Xcode and XCTest are not required.
- Preserve explicit first-use AI consent, manual capture, local originals, review-before-confirmation, exact decimal money, source-grounded promises, and recoverable failures. Do not introduce continuous capture, silent data uploads, fake AI responses, or automatic retries that spend tokens without user action.
- Runtime data belongs under Application Support, never the checkout. Do not delete or rewrite a user's ledger while testing. Diagnostics use isolated temporary databases.
