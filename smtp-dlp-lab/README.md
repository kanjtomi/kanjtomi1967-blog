# SMTP DLP ラボ (Zscaler の SMTP DLP を OSS で模擬)

Zscaler (ZIA) の SMTP DLP は、送信メールを Zscaler の SMTP プロキシに通し、本文と添付を DLP 辞書で検査して、
違反していれば配送を止めて送信者や監査担当者に通知する仕組み。その流れを、自宅の RHEL k8s クラスタ上で
OSS だけで再現する。本物の Zscaler テナントは使わない。

| 決めたこと | 内容 |
|---|---|
| 方式 | OSS で模擬 (Postfix + 自作の DLP エンジン + Mailpit + swaks) |
| 検出するもの | クレジットカード番号、キーワード、添付ファイル (中身、ZIP の中、拡張子、パスワード付き ZIP) |
| 検出したときの動作 | ブロック (送信者に 550) + 隔離 (原本を保存) + 通知 (送信者と監査担当者にメール) |

## 構成

```
                       Pod: mta (namespace smtp-dlp-lab)
 swaks ──SMTP──▶ Postfix :25 ──smtpd_proxy_filter──▶ DLP エンジン 127.0.0.1:10024
 (client Pod                                            │ 本文・添付を検査
  / LAN :30025)                                         ├─ 問題なし ──▶ Postfix 127.0.0.1:10025 ──▶ キュー ──▶ Mailpit :1025
                                                        │               (X-DLP-Result: pass を付ける)
       ◀──── 550 5.7.1 blocked by DLP ──────────────────┴─ 違反 ──▶ /quarantine に原本を保存
                                                                     通知メール (送信者 / 監査担当者) ──▶ 10025 ──▶ Mailpit
```

| コンポーネント | 中身 | 役割 |
|---|---|---|
| `mta` の `postfix` コンテナ | Alpine 3.22 + `postfix` パッケージ (起動時に `apk add`) | 受信、キュー、Mailpit への中継 |
| `mta` の `dlp` コンテナ | python:3.12-alpine + `dlp/dlp_proxy.py` (標準ライブラリだけ) | DLP エンジン。SMTP を話すプロキシ |
| `mailpit` | `axllent/mailpit:v1.31.4` | 「社外」の代わり。届いたメールを Web UI で見る |
| `client` | Debian 12 + `swaks` + `zip` | テストメールの送信。swaks は Alpine にパッケージがないので Debian |

| 入口 | アドレス |
|---|---|
| SMTP (LAN から) | `192.168.0.200:30025` (NodePort) |
| Mailpit の Web UI | http://192.168.0.200:30825 (NodePort) |
| SMTP (クラスタ内) | `mta.smtp-dlp-lab.svc.cluster.local:25` |

NodePort の範囲は firewalld で開いているので、firewalld の変更は不要。秘密情報 (パスワードや鍵) は使わないので
Secret もない。Postfix は全部のメールを Mailpit に中継する (`relayhost`) ので、インターネットにメールが出ることはない。

### Zscaler とのおおまかな対応

| Zscaler (ZIA) | このラボ |
|---|---|
| メールサーバー (Microsoft 365 / Gmail) の送信先を Zscaler の SMTP プロキシにする | クライアントの送信先を Postfix :25 にする |
| DLP 辞書 (定義済みのクレジットカード番号など、カスタムのキーワード) | `dlp/policy.json` の `rules` |
| DLP エンジン (辞書の組み合わせ、一致件数のしきい値) | `type` と `min_matches` |
| ファイルの種類による制御、検査できないファイル (暗号化) の扱い | `file_type` と `unscannable` ルール |
| 動作: ブロック / 許可 (監査のみ) | `action`: `block` / `monitor` |
| 送信者と監査担当者 (auditor) への通知 | 通知メール (`notify`) |
| DLP インシデントのログ | `dlp` コンテナのログ (JSON 1 行ずつ) と `/quarantine` |

本物の Zscaler は Office/PDF のテキスト抽出、OCR、EDM/IDM (登録したデータとの照合) なども持っている。
このラボはそこまではしない (`.docx`/`.xlsx` は中身が ZIP + XML なので、XML のテキストとしてなら検査される)。

## 起動 / 停止

```bash
kubectl apply -k smtp-dlp-lab                                  # 起動 (postfix/ dlp/ tests/ を変えたらこれで反映)
kubectl -n smtp-dlp-lab get pods                               # mta が 2/2、client が 1/1 になるまで待つ (apk/apt で 1〜2 分)
kubectl -n smtp-dlp-lab scale deploy --all --replicas=0        # 停止 (1 で再開)
```

起動時に `apk add` / `apt-get install` するので、Pod からインターネットに出られる必要がある (ipsec-lab と同じ)。

## テスト

```bash
kubectl -n smtp-dlp-lab exec deploy/client -- bash /opt/tests/run-tests.sh
```

`tests/run-tests.sh` が 11 通を送り、それぞれ期待どおり「通過」か「ブロック」かを確かめる。
カード番号は各ブランドが公開しているテスト用の番号 (4111 1111 1111 1111 など) で、本物ではない。

| # | ケース | 期待 | ルール |
|---|---|---|---|
| 01 | 普通のメール | 通過 | |
| 02 | 本文にカード番号 `4111 1111 1111 1111` | ブロック | CreditCard |
| 03 | 16 桁だが Luhn のチェックが合わない `4111 1111 1111 1112` | 通過 | (誤検知しない) |
| 04 | 全角のカード番号 `４１１１…` (UTF-8 の本文) | ブロック | CreditCard |
| 05 | 件名に「社外秘」(MIME エンコードされた件名) | ブロック | ConfidentialKeyword |
| 06 | 本文に `Confidential` (大文字小文字は区別しない) | ブロック | ConfidentialKeyword |
| 07 | CSV 添付 (問題なし) | 通過 | |
| 08 | CSV 添付の中にカード番号 (base64 で添付される) | ブロック | CreditCard |
| 09 | ZIP の中の CSV にカード番号 | ブロック | CreditCard |
| 10 | パスワード付き ZIP | ブロック | UnscannableFile |
| 11 | `.exe` の添付 | ブロック | BlockedFileType |

初回の結果 (2026-10-21): 11 件すべて期待どおり (OK=11 NG=0)。LAN (Windows PC) から NodePort 30025 に
直接送った場合も、普通のメールは通過、カード番号入りは `550 5.7.1` で拒否された。

1 通だけ手で送るなら:

```bash
kubectl -n smtp-dlp-lab exec deploy/client -- swaks --server mta --from alice@corp.lab --to bob@partner.example \
  --header "Subject: test" --body "card 5555 5555 5555 4444"
# <** 550 5.7.1 Message blocked by DLP policy (CreditCard); incident DLP-...
```

## 結果を確認する

| 見たいこと | 方法 |
|---|---|
| 判定 (pass / block / monitor) | `kubectl -n smtp-dlp-lab logs -f deploy/mta -c dlp` (JSON 1 行ずつ) |
| Postfix の受信・中継 | `kubectl -n smtp-dlp-lab logs -f deploy/mta -c postfix` |
| 通過したメール | Mailpit の Web UI。ヘッダーに `X-DLP-Result: pass` が付いている |
| ブロックしたときの通知 | Mailpit に `dlp-noreply@corp.lab` から 2 通: 送信者宛て「送信したメールはブロックされました」と、監査担当者 (`dlp-auditor@corp.lab`) 宛て「ポリシー違反」(原本の `.eml` を添付) |
| 隔離したメール | `kubectl -n smtp-dlp-lab exec deploy/mta -c dlp -- ls /quarantine` (`<incident>.eml` と、一致したルールを書いた `<incident>.json`) |

ブロックしたメールの宛先 (`bob@partner.example`) には何も届かない。Mailpit に届くのは通知だけ。
隔離は `emptyDir` なので、Pod を作り直すと消える。インシデント ID の時刻は UTC (python:alpine に tzdata がないため)。

## DLP のルール (`dlp/policy.json`)

```json
{ "name": "CreditCard", "type": "credit_card", "min_matches": 1, "action": "block" }
```

| `type` | 検出するもの |
|---|---|
| `credit_card` | 13〜19 桁 (4-4-4-4、Amex の 4-6-5、区切りなし)。先頭が 3〜6 で、Luhn のチェックが合うものだけ |
| `keyword` | `keywords` のどれか。大文字小文字と全角半角を区別しない |
| `file_type` | 添付 (と ZIP の中) のファイル名が `extensions` で終わるもの |
| `unscannable` | 検査できないもの: パスワード付き ZIP、壊れた ZIP、入れ子が深すぎる/大きすぎる中身 |

`min_matches` は一致件数のしきい値 (例: カード番号 5 件以上でブロック)。`action` は `block` (ブロック + 隔離 + 通知) か
`monitor` (配送はして、`X-DLP-Result: monitor` を付け、監査担当者にだけ通知)。編集したら `kubectl apply -k smtp-dlp-lab`。

検査の対象は件名、テキストの本文 (HTML はタグを除く)、添付。添付は base64 などを戻してから見て、ZIP なら中を開く
(Office 文書も ZIP なので中の XML を見る)。文字コードは UTF-8 → CP932 → EUC-JP の順に試す。

## 学んだこと

- **before-queue と after-queue**: Postfix の `smtpd_proxy_filter` (before-queue) は、メールを受け取る前に DLP の判定を
  待つ。違反なら SMTP のやりとりの中で `550` を返せるので、送信者のメールソフトにすぐエラーが出て、こちらは
  メールを一度も預からない。`content_filter` (after-queue) だと、一度受け取ってから検査するので、ブロックは
  「受け取った後に捨てる + バウンスメールを返す」になる。インラインのゲートウェイらしいのは before-queue。
  代わりに、検査が遅いと SMTP の接続が待たされる (`smtpd_proxy_timeout`)。
- **戻し口にはフィルタをかけない**: DLP を通ったメールと通知メールは、フィルタなしの `127.0.0.1:10025` に戻す。
  ここにもフィルタをかけると、通知メール (違反したメールの内容を含む) がまた検査されてブロックされ、ループする。
- **DLP は「戻してから」見る**: 添付は base64、件名は `=?UTF-8?B?...?=` でエンコードされているので、生の SMTP データに
  正規表現をかけても見つからない。MIME を解いて、文字コードを戻してから検査する。
- **全角に注意**: `４１１１ １１１１…` や `ＣＯＮＦＩＤＥＮＴＩＡＬ` は、そのままでは半角の正規表現に一致しない。
  Unicode の NFKC 正規化で半角にそろえてから検査する。日本語のメールでは必須。
- **誤検知を減らす**: 16 桁の数字は注文番号や追跡番号にもある。Luhn のチェックと先頭の番号 (ブランド) で絞ると、
  テスト 03 のような番号は通る。
- **検査できないものをどうするか**: パスワード付き ZIP は中を見られない。ZIP の各ファイルには「暗号化されている」
  フラグがあるので、それを見て「検査できない」としてブロックする (Zscaler にも暗号化ファイルの扱いを決める設定がある)。
  パスワードを別のメールで送る運用 (いわゆる PPAP) は、DLP から見ると検査をすり抜ける抜け穴になる。
- **k8s の readinessProbe**: DLP エンジンは `127.0.0.1` だけで待ち受けるので、kubelet からの `tcpSocket` プローブは
  届かず、Pod が Ready にならなかった。`exec` プローブに変えた。Postfix の :25 も `tcpSocket` にすると、5 秒ごとに
  `connect from ... lost connection after CONNECT` がログに出てうるさいので、`postfix status` の `exec` にした。
- **NodePort の送信元**: LAN から NodePort に来た接続は、Postfix からはノードの IP (192.168.0.200) から来たように見える
  (kube-proxy の SNAT)。そのため `mynetworks` に `192.168.0.0/24` と Pod の `10.244.0.0/16` を入れている。
  どこから送っても中継先は Mailpit だけなので、外に出るオープンリレーにはならない。
- **swaks は Alpine にない**: Alpine 3.22 の main/community には `swaks` のパッケージがないので、クライアントは Debian にした。

## 練習メニュー

1. **monitor にする**: `ConfidentialKeyword` の `action` を `monitor` にして apply し、テスト 05/06 が通過して
   `X-DLP-Result: monitor; incident=...` が付き、監査担当者にだけ通知が来るのを確かめる
2. **しきい値**: `CreditCard` の `min_matches` を 3 にして、カード番号 1 件では通り、3 件でブロックされるのを確かめる
3. **すり抜けを試す**: 番号を `4111-1111 1111.1111` のように区切る、画像にする、本文を ISO-2022-JP にする
   (`swaks --add-header "Content-Type: text/plain; charset=ISO-2022-JP"` と `iconv`) など。どれが検出され、
   どれがすり抜けるかを調べ、エンジンを直す
4. **マイナンバー**: 12 桁 + チェックデジットの検出ルール (`type`) を `dlp_proxy.py` に足す
5. **SMTP のやりとりを見る**: `swaks` の出力で、`550` が DATA の終わり (`.` の直後) に返ることを確かめる。
   `content_filter` (after-queue) に変えると、どう変わるか (送信者側は `250`、後からバウンス) を比べる

## 片付け

```bash
kubectl delete -k smtp-dlp-lab
```
