# Kith Food (iOS, personal)

料理の写真を取り込み、撮影場所の地図と AI（Vertex AI Gemini）の料理判定で記録する個人用アプリ。

- SwiftUI / iOS 17+、Firebase（Auth・Firestore・Storage・Functions）、MapKit
- 写真は 1600px に縮小し EXIF/GPS を除去してから `users/{uid}/meals/{id}.jpg` に保存
- AI 判定は Cloud Function `analyzeDish`（kith-diary-web/functions）

## セットアップ
1. `brew install xcodegen && xcodegen generate`
2. `KithFood/Resources/GoogleService-Info.plist` を置く（gitignore 済み）
   `npx firebase-tools apps:sdkconfig IOS <APP_ID> --project kith-diary -o KithFood/Resources/GoogleService-Info.plist`
3. `KithFood.xcodeproj` を開き、Signing の Team を選んで iPhone で実行
