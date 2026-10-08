# Whisper App Store creative — 2026-10-08

## Deliverable
`whisper-editorial-universal-ja.png`: opaque RGB PNG, 5244 × 2950. Universal asset for iOS/iPadOS 27 product page header and search results. Generated with the built-in imagegen tool; exported to Apple's exact dimensions with macOS sips. Original generation is 1672 × 941, so the upload file is resampled, not native 5K artwork.

## Research and design decisions
- Apple distinguishes creative assets from screenshots: creative assets can express the brand, while screenshots must show actual app use. Preserve existing screenshots; add this image as a creative asset.
- Apple requires opaque images. Universal: 5244 × 2950 PNG. Header only: 3840 × 1646 PNG. Search only: 1920 × 1280 to 3840 × 2560, 3:2.
- Keep the focal point central and validate device crops using Connect Preview. Short localized copy; no prices, URLs, invented awards or platform logos.
- 2025 Appfigures screenshot critiques emphasize clear benefit-led sequencing and coordinated product-page messaging. Moburst's 2026 design observations emphasize calm visual hierarchy, deliberately designed dark themes and human craft. These are qualitative observations, not evidence that this artwork will improve conversion.
- International Typographic Style / Swiss Typography: aligned grotesk type, restrained three-color palette, consistent baseline rhythm and asymmetric optical balance.
- Editorial Design: large Japanese headline, generous surrounding space, one graphic metaphor of waveform becoming text. Subtle print texture gives the app's charcoal/amber recorder aesthetic a tangible character.
- Copy: “Whisper”, “声を、記録に。”, “オフラインで文字起こし”. Initial model download requirement is explained in the page's promotional copy.

## Sources
- https://developer.apple.com/app-store/asset-best-practices/
- https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets
- https://developer.apple.com/app-store/custom-product-pages/
- https://assets.appfigures.com/resources/videos/are-your-screenshots-crushing-your-downloads-live-screenshot-teardown-aso (2025-02-05)
- https://staging.appfigures.com/resources/videos/level-up-your-conversion-rates-live-product-page-teardown-aso (2025-04-16)
- https://www.moburst.com/blog/top-mobile-web-design-trends/ (2026-01-20)

## App Store Connect
App ID: 6771686580. Custom page reference: 声を、記録に。 — Offline Editorial 2026. Copied the released 0923 page to preserve its real screenshots.
Product page ID: 64a813da-f386-43f7-86d8-7d84ab68551e.
Keywords: 文字起こし, 録音, オフライン, 議事録, プライバシー, 文字起こしアプリ.
Promotional copy: 会議も、講義も、取材も。録音や音声・動画ファイルをiPhoneの中で文字起こし。初回モデルのダウンロード後はオフラインで使えます。音声を外部サーバーへ送信せず、テキストやSRT字幕として書き出せます。

## Crop refinement
The universal artwork is legible in search, but the iPhone header preview crops the one-line headline. A separate 3840 × 1646 header (`whisper-editorial-header-ja.png`) places two-line type in the central 30% width. Generated with built-in imagegen and resampled to Apple's exact dimensions. Keep the universal artwork for search results.

The selected two-line header retains the exact offline-transcription copy. A subsequent enlargement variant changed that copy and was discarded. iPhone header and search placements were checked in Connect's device preview; screenshots are included alongside the artwork. Source prompts are `imagegen-prompt.txt` and `header-imagegen-prompt.txt`.

## Submission result
Submitted 2026-10-08 at 17:57 JST. App Review visibly confirms exactly one submitted item, the custom product page, with status 審査待ち (Waiting for Review). Submission ID: bb26039d-2004-4b74-9187-dafe7255a87a. No app binary or app-version submission was included. Public availability remains subject to Apple's approval.
https://appstoreconnect.apple.com/apps/6771686580/distribution/reviewsubmissions/details/bb26039d-2004-4b74-9187-dafe7255a87a

Marketing files live outside the source/resource paths in project.yml and do not affect generated Xcode project structure.
