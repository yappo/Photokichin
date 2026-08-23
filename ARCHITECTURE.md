# Photokichin Architecture

PhotokichinはSwift 6.3、macOS 26、SwiftPMを基準にした5モジュール構成です。外部パッケージ、DIコンテナ、状態管理ライブラリは使用しません。依存は外側から内側への一方向だけに限定し、SwiftPMターゲットによって逆向きのimportをコンパイル時に拒否します。

```text
PhotokichinApp
├── PhotokichinPresentation ──→ PhotokichinApplication ──→ PhotokichinDomain
└── PhotokichinInfrastructure ───────────────────────────→ PhotokichinDomain
                         └─────→ PhotokichinApplication
```

## 各モジュールの責務

### PhotokichinDomain

写真、rendered image／RAW／movieというsemantic role、取り込み状態、ラベル、カメラの値型スナップショット、ソース識別などを置きます。`AssetVariant`のrawValueである`JPG`、`CR3`、`動画`は、SQLiteとSourceIdentityの既存データを読むための互換契約であり、ユーザー向けの形式分類ではありません。UI、ファイルシステム、SQLite、Appleフレームワークをimportしません。値は原則`Sendable`にします。

### PhotokichinApplication

アプリが実行する操作と、外部機能に要求するポートを置きます。フォルダ閲覧、カタログを開く処理、取り込み、ライブラリ間コピー、ゴミ箱への移動、共有、Ejectをユースケースとして表現します。SwiftUI、AppKit、SQLite3、ImageIO、ImageCaptureCore、DiskArbitrationはimportしません。

一回で完了する操作は`async throws`または同期の`throws`として表現します。通知や長時間処理を新設する場合は、キャンセル可能な`AsyncSequence`または明示されたコールバック境界をApplication側で定義します。

### PhotokichinInfrastructure

Applicationのポートを実装します。SQLiteカタログ、ファイル探索と安全な転送、ImageIO、ImageCaptureCore、Disk Arbitration、AirDropの実装を置きます。`ICCameraDevice`、`ICCameraFile`、SQLiteハンドルはこのモジュールの外へ渡しません。

形式とカメラ差分はInfrastructureのcontributionとして分離します。`MediaFormatRegistry`は拡張子からsemantic roleを解決し、`CameraSupportDefinition`は形式、ファイルシステム探索rule、metadata enricher、camera matcherを一つの薄い値として提供します。productionの構成順は`GenericMediaSupport`、`CanonCameraSupport`、`SonyCameraSupport`、`NikonCameraSupport`、`FujifilmCameraSupport`、`PanasonicCameraSupport`、`OMSystemCameraSupport`、`PentaxCameraSupport`、`RicohCameraSupport`、`SigmaCameraSupport`です。GenericはJPEG／HEIF family、DNG、movieを所有し、CanonはCR3／CR2、その他のvendor contributionはそれぞれARW／NEF／RAF／RW2／ORF／PEFだけを所有します。RICOHとSIGMAはDNGを重複登録しません。`FilesystemTraversalPolicy`は登録されたruleを順に評価し、`MetadataEnrichmentPipeline`は標準ImageIO値を保ったままvendor補完の失敗を隔離します。`CameraIdentity`とmatcher／resolverはImageCaptureCoreが報告した値だけからsupport identifierを解決し、能力やI/Oの分岐は上書きしません。

production compositionは`InfrastructureFactory`で一度だけ構成します。同じclassifierをカード、USBカメラ、ライブラリ検査へ注入し、同じmetadata pipelineをURL経路とUSB経路へ渡します。consumerはclassifier、traversal policy、resolver、reader、pipelineなどの狭い依存だけを受け取り、global singleton、service locator、runtime plugin、DI frameworkは使いません。vendor固有の拡張子、管理directory、MakerNoteキーは各contributionの中だけに置きます。

分類とImageIO decode能力は別の契約です。classifierが形式を認識できることは、macOS ImageIOがその実ファイルのsource、thumbnail、metadataを成功させることを意味しません。OSが報告するreader identifierは環境の能力調査として記録し、実ファイル確認は独立したsample test入口で行います。形式を追加しても、Domainのrendered image／RAW／movieという3-slot、`AssetVariant`のlegacy rawValue（`JPG`／`CR3`／`動画`）、schema v3、SourceIdentity、photo ID、label UUIDの互換契約は変更しません。

### PhotokichinPresentation

SwiftUI画面、AppKitとの画面境界、Observationモデルを置きます。状態はソース閲覧、写真グリッド／選択、ライブラリ／ラベル、ファイル操作、Viewerに分割されています。サムネイルとメタデータのコーディネーターは生成時にポートを注入し、共有インスタンスを画面から直接参照しません。

### PhotokichinApp

`@main`とComposition Rootだけを置きます。`InfrastructureFactory`で本番アダプターを生成し、ApplicationのユースケースとPresentationモデルへ注入します。業務規則、画面、I/O実装は追加しません。

## 依存とアクセス制御

- パッケージ外へ公開するAPIはありません。モジュール間のAPIは原則`package`、モジュール内部の実装詳細は`internal`または`private`です。
- AppとPresentationだけがMainActorデフォルト隔離です。DomainとApplicationの値型・ユースケースは非隔離を基本にします。
- AppleのObjective-C APIでMainActorが必要なInfrastructure型には、その型だけ`@MainActor`を付けます。
- 新しい`@unchecked Sendable`は追加しません。避けられない境界が発生した場合は、所有者、直列化方法、終了条件をコードと本書に記録してから導入を判断します。
- SQLiteとファイル操作をUIモデルへ直接追加しません。Applicationのポートとユースケースを通します。

## 新しいコードを置く場所

1. Apple APIや保存方式を知らない純粋な値・規則ならDomainです。
2. ユーザー操作として名前を付けられる処理、または外部機能への要求ならApplicationです。
3. SQLite、ファイル、ImageIO、ImageCaptureCore、Disk Arbitrationなど具体的な実装ならInfrastructureです。
4. SwiftUI表示、選択、絞り込み、キーボード、ウィンドウ状態ならPresentationです。
5. 本番実装の生成と接続だけならAppです。

迷う場合は、具体的なフレームワーク型を内側へ渡さず、Applicationに値型を入出力するポートを定義します。

## テスト

テストはSwiftPMの5テストターゲットに分かれています。

```text
Tests/
  PhotokichinDomainTests/
  PhotokichinApplicationTests/
  PhotokichinInfrastructureTests/
  PhotokichinPresentationTests/
  PhotokichinHardwareTests/
```

各テストはSwift Testingを使用し、固有の一時ディレクトリとUserDefaults suiteを使います。通常テストは並列実行可能です。OS全体の状態や実機を使うテストだけを直列化します。EOS実機テストは`PHOTOKICHIN_RUN_HARDWARE_TESTS=1`を指定した場合だけ実行し、未指定のスキップを成功実績として数えません。

標準の確認コマンドは次のとおりです。

```sh
swift build --explicit-target-dependency-import-check error
swift test
./run-coverage.sh
./build.sh
```
