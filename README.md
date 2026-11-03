# DropToMail

macOS SwiftUI app for preparing password-protected ZIP files from Finder drops.
The current implementation covers Phases 1–5 in [DropToMail.md](./DropToMail.md).
Google OAuth and Gmail API delivery are implemented. After authentication, dropping
files sends a real email when the countdown and ZIP preparation finish. Click the
countdown to cancel before sending begins. API acceptance does not confirm delivery.

## Requirements

- macOS 14 or later
- Xcode 15 or later
- Homebrew and libzip (`brew install libzip`)

libzip is linked as a system library for development and testing. A distributable
app should embed a signed libzip build; the current project does not yet package
that dependency for standalone distribution.

## Build and test

Open [DropToMail.xcodeproj](./DropToMail.xcodeproj) in Xcode and choose the
shared `DropToMail` scheme to run the app or its unit tests. The project uses
`/opt/homebrew/opt/libzip` by default. On an Intel Mac, set the `LIBZIP_PREFIX`
build setting to `/usr/local/opt/libzip`.

```sh
xcodebuild -project DropToMail.xcodeproj -scheme DropToMail -destination 'platform=macOS' test
swift test
swift run DropToMail
```

The Swift package commands remain available for command-line development.

## ZIP encryption limitation

Archives use traditional ZipCrypto (`ZIP_EM_TRAD_PKWARE`) as required for
compatibility. ZipCrypto is weak and must not be used as modern confidentiality
protection. Follow your organization's mail and data-handling policies.
Passwords are stored in macOS Keychain, not UserDefaults or command-line
arguments. Temporary archives are kept in a per-job directory under the system
temporary directory and removed after processing or on the next launch.

## Google認証の設定（Phase 4）

Google Workspaceの組織アカウントと、その組織配下のGoogle Cloudプロジェクトを使用します。
実際のクライアント設定値・メールアドレス・トークンはリポジトリに追加しないでください。

1. Google Cloud Consoleでプロジェクトを作成または選択し、**Gmail API**を有効にします。
2. **Google Auth Platform**のBrandingでアプリ名・サポート連絡先を設定し、Audienceを
   **Internal（内部）**にします。Internalを選べない場合は、Workspace組織配下の
   プロジェクトか確認してください。
3. Data Accessに次のスコープを登録します。メールの読取・削除権限は不要です。
   - `https://www.googleapis.com/auth/gmail.send`
   - `openid`
   - `https://www.googleapis.com/auth/userinfo.email`（認証リクエストでは`email`）
4. Clientsで種類が**Desktop app（デスクトップアプリ）**のOAuthクライアントを作成し、
   JSONをダウンロードします。Web applicationやiOSクライアントは使用しません。
5. ダウンロードしたJSONを、以下の場所に`google-oauth.json`という名前で配置します。
   Xcode・`swift run`・Finderからの起動で共通の設定ファイルです。

   ```text
   ~/Library/Application Support/DropToMail/google-oauth.json
   ```

   親フォルダがない場合はFinder等で作成してください。Googleから取得した
   `{"installed": {...}}`形式をそのまま使用できます。`client_id`が必須、
   `client_secret`は存在すればトークン交換・更新時に使用します。デスクトップアプリの
   client secretは配布物から読み出せる公開クライアントの設定値として扱い、
   秘密を保護できることに依存しません。認証情報の保護にはPKCEとKeychainを使います。
   JSONのエンドポイント値は読み込まず、通信先はGoogleのHTTPSエンドポイントに固定しています。
6. Workspace管理者によるAPI制御がある場合は、管理コンソールの
   **セキュリティ → アクセスとデータ管理 → APIの制御 → アプリのアクセス制御**で
   OAuthクライアントIDを検索・追加し、対象の組織部門／グループに必要なスコープへの
   アクセスを許可してください。設定名は管理コンソールの言語・契約によって異なります。
   Gmailサービスと組織のメールポリシーも確認します。ドメイン全体の委任や
   サービスアカウントは使用しません。
7. アプリのSettingsで**Authenticate with Google**を押し、標準ブラウザで組織アカウントを
   選択して承認します。設定画面に認証済みアドレスが表示されれば完了です。

認証はAuthorization Code Flow + PKCE（S256）を使い、ランダムなstateを照合します。
認証時だけ`127.0.0.1`のOSが割り当てるポートでコールバックを受け取ります。
LANに公開するサーバーや固定ポート、独自URLスキームの登録は不要です。
ブラウザを閉じただけでは認証は完了しません。SettingsのCancelで中止するか、
3分でタイムアウトします。設定画面を閉じた場合も進行中の認証を中止します。

リフレッシュトークン・アカウント情報・対応するクライアントIDは、ZIPパスワードと
別のKeychain項目にまとめて保存します。アクセストークンはメモリ内にのみ保持し、
起動時と必要時に更新します。有効期限の60秒前から更新対象になります。
`invalid_grant`などの認証失効時は保存済みセッションを削除し、再認証を案内します。
ネットワークの一時エラー時はリフレッシュトークンを保持して再試行可能にします。

**Change / Reauthenticate**で別アカウントを選択できます。変更が失敗・キャンセルされた
場合は以前のアカウントを保持します。クライアントIDを変更した場合も再認証が必要です。
**Disconnect**はローカルの認証情報を削除し、Googleにも権限失効を要求します。
失効要求が通信エラーで失敗した場合は、その旨を表示します。必要に応じて
Googleアカウントの「サードパーティとの接続」からDropToMailへのアクセスを削除してください。
内部アプリの設定に加え、アプリ側もGoogleのUserInfoで検証済みメールとWorkspaceの
組織情報を確認します。

Google公式の[デスクトップOAuth手順](https://developers.google.com/identity/protocols/oauth2/native-app)、
[UserInfo／メール情報の取得](https://developers.google.com/identity/openid-connect/openid-connect)、
[Workspace APIアクセス制御](https://support.google.com/a/answer/7281227)を参照してください。

### 検証範囲

ユニットテストではPKCE、state／コールバック検証、ローカルHTTPコールバック、
タイムアウト／キャンセル、トークン交換と更新、失効、アカウント変更・解除、
権限不足、保存失敗を検証します。Google通信はモックに置き換え、
テストから実アカウントへのログインやメール送信は行いません。
実際のWorkspaceアカウントによる初回認証は、上記設定後に利用者が明示的に操作してください。

## Gmail送信（Phase 5）

Phase 4で認証したWorkspaceアカウントから、メイン画面の宛先1件へZIPを送信します。
追加のOAuthスコープは不要です。送信先・ZIPパスワードを設定してファイルをドロップすると、
設定した待機時間後に**実際のメールが送信されます**。0秒設定では準備完了後すぐに送信します。
本文は空欄で、件名とZIP名は仕様書のファイル／フォルダ名のルールに従います。
宛先はASCIIのメールアドレス1件に対応し、表示名・複数宛先・国際化メールアドレスは受け付けません。

件名はRFC 2047のUTF-8 encoded-word、添付名はRFC 2231のUTF-8パラメーターで表現し、
ZIPをMIME base64に変換します。CRLFのMIMEメッセージ全体をbase64URL化し、
`POST https://gmail.googleapis.com/gmail/v1/users/me/messages/send`にJSONの`raw`として渡します。
元ファイルのフルパスやZIPパスワードを本文に含めません。通信先へのリダイレクトは追跡しません。

ZIP添付はアプリの保守的な上限として**25,000,000バイト（25 MB）**までです。
送信前にファイルサイズを確認し、MIME生成中にも読み取り量と最終MIMEサイズ
（上限35,000,000バイト）を検証します。大きなファイルをDriveリンクに置き換えません。
Workspace管理者や受信側の制限がこれより小さい場合、送信が拒否されることがあります。

ZIP作成・MIME生成・認証確認が終わるまではウィンドウを閉じるとキャンセルします。
Gmailへの送信を開始した後はキャンセル操作を表示しません。すべてのウィンドウで
ジョブを1件に制限し、処理中は宛先の編集とアカウント変更・解除を無効にします。
処理開始時の宛先、送信元、待機時間を使用します。

- Gmailの成功応答とメッセージIDを確認した場合だけチェックマークを表示します。
  受信者への配達完了を示すものではありません。
- 認証エラー、権限／組織ポリシーによる拒否、容量超過、API／送信制限、
  接続エラーを区別して案内します。401応答でアクセストークンのキャッシュを破棄しますが、
  同じメールを自動で送り直しません。
- タイムアウト、接続切断、サーバーエラー、成功応答の破損などは
  **Send result unknown（送信結果不明）**として表示します。すでに送られた可能性があるため、
  Gmailの「送信済み」を利用者が確認してから再操作してください。自動再送は行いません。
- エラー／結果不明のアイコンをクリックすると詳細を再表示できます。
- 一時ZIPは成功・失敗・キャンセル時に削除します。削除に失敗した場合は警告し、
  確認済みの送信結果を保持します。異常終了で残ったZIPは次回起動時の清掃対象です。

テストでは通信をモックに差し替え、MIMEの日本語・バイナリ添付の復元、容量超過、
APIエラー、結果不明、重複送信防止、送信前後のキャンセル境界、一時ファイル削除を確認します。
実アカウントへの送信は自動テストで実行しません。実際のWorkspaceアカウントでの送信・
受信確認はPhase 6として、利用者が宛先と添付内容を確認したうえで明示的に操作してください。

参考：[Gmail API送信ガイド](https://developers.google.com/workspace/gmail/api/guides/sending)、
[送信エンドポイント](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send)、
[APIエラー](https://developers.google.com/workspace/gmail/api/guides/handle-errors)、
[添付制限](https://support.google.com/mail/answer/6584)。

### Gmailの権限エラー（HTTP 403）

認証に成功しても、Gmail APIが利用可能とは限りません。スコープの登録とAPIの有効化は
別の設定です。アプリはGoogleの`errors[].reason`と`google.rpc.ErrorInfo`を確認し、
次の原因を区別します。応答本文・プロジェクト情報・トークンは表示／記録しません。

| 表示 | 対応 |
|---|---|
| Gmail API is disabled ... | OAuthクライアントを作成したプロジェクトを選び、Google Cloudの「APIとサービス → ライブラリ → Gmail API」で有効化します。反映まで数分待ってから再操作してください。 |
| Google authorization does not include ... gmail.send | Settingsの「Change / Reauthenticate」でメール送信権限を承認します。Cloud側にスコープを追加しただけでは既存の認証は更新されません。 |
| Your Google Workspace domain policy blocks ... | Workspace管理者に、APIの制御で対象OAuthクライアントと`gmail.send`の利用許可を確認してもらいます。 |
| Gmail denied permission ... reason could not be identified | 既知の理由コードが応答にないため特定できません。上記設定とアカウントのGmail利用可否を確認します。 |

旧バージョンの「Gmail denied permission to send. Check Gmail API access ...」は
403をすべて同じ文章にまとめていました。この表示だけで原因は確定できません。
まず[Google CloudのGmail APIページ](https://console.cloud.google.com/apis/library/gmail.googleapis.com)で、
**OAuthクライアントと同じプロジェクト**にAPIが有効化されているか確認してください。
クライアントJSONの`installed.project_id`がプロジェクト選択の手掛かりになります。
詳細表示を改善した版はXcodeで再ビルドして起動してください。
