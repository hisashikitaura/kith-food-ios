# Kith Food BCP (AWS)

Kith Food の記録を GCP(Firebase) から AWS へほぼリアルタイムに片方向コピーし、iOS アプリの「設定 > バックエンド」で GCP / AWS を切り替えられるようにする仕組みです。日記(diary)のデータ・関数・ルールは対象外です。

## 構成 (ap-northeast-1)
- GCP: `syncMealToAws` (Firestore `users/{uid}/meals/{id}` の onDocumentWritten, asia-northeast1) → Google ID トークン → STS AssumeRoleWithWebIdentity (`kith-food-gcp-sync`, aud/oaud/sub 条件) → S3 へ写真コピー → SQS FIFO (`MessageGroupId=uid#mealId`)
- AWS: SQS FIFO (+DLQ, 5回) → `SyncFn` → DynamoDB (`PK=USER#uid`, `SK=MEAL#takenAt#id`)
  - `syncVersion` (Firestore updateTime μs) で条件付き書き込み → 冪等・順序保証。削除は `TOMB#id` (30日TTL)
- iOS 用 API: API Gateway HTTP API + `ApiFn` (Cognito JWT authorizer)
  - Cognito (Google フェデレーション, Hosted UI, セルフ登録不可, PreSignUp で owner メールのみ許可)
  - uid は JWT の sub → サーバ側マッピング `IDMAP#sub` からのみ導出 (BOLA 対策)
  - `GET/POST /meals`, `PATCH/DELETE /meals/{id}`, `GET /meals/{id}/photo`, `POST /meals/{id}/upload-url`, `POST /meals/{id}/analyze` (Bedrock Nova 2 Lite, 失敗時 503 で縮退)
- S3: パブリックブロック, SSE-S3, バージョニング(旧版30日), TLS 必須
- ログ保持 14 日, 予算 $10/月 (80% 実績・100% 予測でメール)

## デプロイ
```sh
cp config.example.json config.local.json   # 値を埋める (gitignore 済み)
npm ci
npm test
npx cdk bootstrap --profile kith            # 初回のみ
npx cdk deploy --profile kith --outputs-file outputs.json
```
`gcpServiceAccountUniqueId` は GCP 関数の SA の unique id (21桁)。不明なら関数ログの `AssumeRole failed ... sub=` から取得して再デプロイ。

GCP 側は `kith-diary-web/functions/.env.kith-diary` (gitignore) に `KF_AWS_ROLE_ARN / KF_AWS_QUEUE_URL / KF_AWS_BUCKET / KF_AWS_REGION / KF_AWS_AUDIENCE` を書き、
`npx firebase-tools deploy --only functions:syncMealToAws,functions:backfillMealsToAws`。
初回の全件コピーはアプリの「設定 > AWSへ全件コピー」(callable `backfillMealsToAws`)。

## Google ログイン (Cognito) の有効化
1. Google Cloud Console > API とサービス > 認証情報 > OAuth クライアント ID (ウェブ) を作成
   - 承認済みリダイレクト URI: `https://<cognitoDomainPrefix>.auth.ap-northeast-1.amazoncognito.com/oauth2/idpresponse`
2. `aws secretsmanager create-secret --name kith-food/google-oauth-client-secret --secret-string '<secret>' --profile kith`
3. `config.local.json` の `googleClientId` に設定して `cdk deploy`
4. 初回ログイン時に PostConfirmation がマッピングを作成。手動の場合は `scripts/set-owner-mapping.sh`

## Bedrock
コンソール > Bedrock > Model access で Amazon Nova 2 Lite を有効化 (未有効の間は AI 判定のみ 503、他は動作)。

## iOS
`kith-food-ios/KithFood/Resources/AWSConfig.plist` (gitignore) に `ApiBaseURL / CognitoDomain / ClientId` (outputs.json から)。見本: `aws/AWSConfig.example.plist`。

## AWS → GCP への戻し (片方向の注意)
AWS モードでの追加・編集・削除は GCP に自動では戻りません。復旧後:
```sh
AWS_PROFILE=kith npx tsx restore-to-gcp/export.ts <TableName> <FirebaseUid> aws-changes.export.json
```
で `origin=aws` の変更と削除を書き出し、内容を確認して Firestore に反映してください (簡易版。反映は手動/今後のスクリプト)。

## 概算コスト (個人利用, 月)
| 項目 | 目安 |
|---|---|
| DynamoDB オンデマンド + PITR | < $0.10 |
| S3 (写真 数百MB〜1GB, バージョニング) | $0.03〜0.05 |
| SQS / Lambda / API Gateway / CloudWatch Logs | 無料枠内〜 $0.10 |
| Cognito (MAU 1) | 無料枠内 |
| Secrets Manager (Google client secret) | $0.40 |
| Bedrock Nova 2 Lite (AI判定, 数十回) | < $0.05 |
| GCP 側 (関数実行・下り転送) | ほぼ $0 |
| **合計** | **約 $0.5〜1/月** (常時稼働の有料リソースなし) |
