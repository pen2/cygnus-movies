# 配布用の署名とAppleの公証

`build-app.sh` はローカル開発用の仮署名でアプリを作成します。
一般配布するときは、ビルド後に `release-app.sh` を実行してください。
アプリを変更・再ビルドした場合は、署名と公証も再実行します。

## 必要なもの

- Xcode（標準の場所 `/Applications/Xcode.app`。別の場所なら `DEVELOPER_DIR` を指定）
- 秘密鍵とともにキーチェーンに登録された有効な **Developer ID Application** 証明書
- `notarytool store-credentials` でキーチェーンに保存済みの公証用プロファイル

パスワードや秘密鍵はソースコード、配布物、コマンドの引数に書き込みません。
認証情報の初回登録は、Xcode付属の `xcrun notarytool store-credentials` の対話入力を使用できます。

## 実行

macOS 13以降・Apple silicon / Intel両対応のビルドを作成します。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./build-app.sh --universal --disable-sandbox --build-system native
```

続いて署名・公証を実行します。

```sh
SIGNING_IDENTITY="Developer ID Application: 氏名 (TEAMID)" \
NOTARY_PROFILE="登録したプロファイル名" \
./release-app.sh
```

スクリプトは一時コピーに正式署名、Hardened Runtime、セキュアタイムスタンプを適用し、
Appleへ公証を申請します。承認後に公証チケットをアプリへ添付し、Gatekeeperで検証します。
最後に配布用ZIPを作り、そのZIPを展開したアプリでも署名とチケットを再検証します。
検証に失敗した場合、元のアプリは置き換えません。

## 成果物

- `dist/cygnus movies.app`：正式署名・公証チケット添付済みアプリ
- `dist/cygnus-movies-<バージョン>-macOS-<CPU>.zip`：ダウンロード用ZIP
- 同名の `.zip.sha256`：ZIPのチェックサム
- `dist/notarization/`：Appleの審査結果、署名情報、Gatekeeper検証結果

公開するファイルは配布用ZIPです。`universal` 版はApple silicon / Intel両対応で、macOS 13以降が必要です。
`--universal` なしのビルドは通常、ビルドしたMacと同じCPU向けになります。
署名・公証処理だけでは対応CPUは変わりません。

署名・公証は「開発元を確認できない」「Appleが悪質なソフトウェアか確認できない」といった
起動ブロックへの対応です。macOS標準の、インターネットからダウンロードしたアプリを初回に開くかどうかの確認は残る場合があります。

Apple公式資料：[Developer ID](https://developer.apple.com/developer-id/)、
[公証ワークフロー](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
