# aws-vpn-lab — AWS の Linux と自宅 Cisco の VPN

東京リージョンに Ubuntu を 1 台置き、自宅の Cisco C841M "Kobe" と IKEv2 のルートベース VPN でつなぐ練習環境。
ブログ本体 (S3 + CloudFront) とは関係ない。

```
Zadara 10.10.11.6 ─┐
Pi     10.10.10.53 ─┤ Cisco Kobe ── 自宅ルーター (NAT) ══ インターネット ══ EIP 18.179.189.78
                     Tunnel20 169.254.201.1  ─── IPsec (NAT-T, UDP 4500) ───  ipsec0 169.254.201.2
                                                                              EC2 10.20.1.10 (VPC 10.20.0.0/16)
```

| 項目 | 値 |
|---|---|
| EC2 | Ubuntu 24.04 arm64、`t4g.nano`、タグ `Name=aws-vpn-lab` |
| VPC / サブネット | `10.20.0.0/16` / `10.20.1.0/24` |
| Elastic IP | `18.179.189.78` (停止・起動しても変わらない) |
| VPN | IKEv2、PSK、AES-256 / SHA-256 / DH group 14 (IKE・ESP とも)、PFS あり |
| トンネル内アドレス | Cisco `Tunnel20` 169.254.201.1/30、EC2 `ipsec0` (XFRM, if_id 42) 169.254.201.2/30 |
| 届く範囲 | 自宅側 `10.10.10.0/24`・`10.10.11.0/24` ⇔ AWS 側 `10.20.0.0/16` |

## On / Off (この Windows PC から)

```powershell
.\aws-vpn-lab\scripts\vm.ps1 status   # 状態、IP、VPN がつながっているか
.\aws-vpn-lab\scripts\vm.ps1 start    # 起動して SSH が通るまで待つ
.\aws-vpn-lab\scripts\vm.ps1 stop     # 停止
.\aws-vpn-lab\scripts\vm.ps1 ssh      # ubuntu でログイン (鍵 ~/.ssh/aws-vpn-lab)
```

**毎晩 23:00 (JST) に自動停止する** (EventBridge Scheduler `aws-vpn-lab-auto-stop`、AWS 側で動くので
PC が消えていても止まる)。自動で起動はしないので、使うときは `vm.ps1 start`。
時刻を変えるときは `terraform.tfvars` に `auto_stop_cron = "cron(30 22 * * ? *)"` のように書いて `terraform apply`。

起動すると Cisco が自分で VPN をつなぎ直す (DPD periodic 30 秒)。実測では SSH が通った時点でもう通信できた。

費用の目安: 動かしている間 約 $7/月 (インスタンス約 $3 + パブリック IPv4 約 $3.6)。
止めている間も Elastic IP と 8GB ディスクで約 $4.4/月かかる。全部消すなら下の「片付け」。

## 作り方 (やり直すとき)

1. `terraform\terraform.tfvars` に自宅のグローバル IP を書く (gitignore 済み):
   `home_cidr = "x.x.x.x/32"` — `(Invoke-RestMethod https://checkip.amazonaws.com).Trim()` で分かる
2. `cd aws-vpn-lab\terraform; terraform init; terraform apply`
   (鍵 `~/.ssh/aws-vpn-lab` が無ければ先に `ssh-keygen -t ed25519 -f $HOME\.ssh\aws-vpn-lab`)
3. `.\aws-vpn-lab\scripts\configure-vpn.ps1` — strongSwan の設定を EC2 に送る。
   PSK は初回に `secrets\psk.txt` (gitignore 済み) に作られ、以後は使い回す
4. Cisco 側 (下) を入れ、PSK だけは自分で打つ。疎通を確かめてから `write memory`

## Cisco 側の設定 (保存済み)

```
crypto ikev2 proposal AWSLAB-PROP
 encryption aes-cbc-256
 integrity sha256
 group 14
crypto ikev2 policy AWSLAB-POL
 match address local 192.168.0.100
 proposal AWSLAB-PROP
 proposal ikev2-proposal          ! 既存 Tunnel1 (旧 AWS VPN) 用の proposal も残す
crypto ikev2 keyring AWSLAB-KR
 peer ec2
  address 18.179.189.78
  pre-shared-key <secrets\psk.txt の中身>
crypto ikev2 profile AWSLAB-PROF
 match identity remote address 18.179.189.78 255.255.255.255
 identity local address 192.168.0.100
 authentication local pre-share
 authentication remote pre-share
 keyring local AWSLAB-KR
 dpd 30 5 periodic
 nat keepalive 20
crypto ipsec transform-set AWSLAB-TS esp-aes 256 esp-sha256-hmac
 mode tunnel
crypto ipsec profile AWSLAB-IPSEC
 set transform-set AWSLAB-TS
 set pfs group14
 set ikev2-profile AWSLAB-PROF
interface Tunnel20
 description VPN to aws-vpn-lab EC2
 ip address 169.254.201.1 255.255.255.252
 ip mtu 1400
 ip tcp adjust-mss 1360
 tunnel source GigabitEthernet0/4
 tunnel mode ipsec ipv4
 tunnel destination 18.179.189.78
 tunnel protection ipsec profile AWSLAB-IPSEC
ip route 10.20.0.0 255.255.0.0 Tunnel20
```

## 確認

```
Kobe# show crypto ikev2 sa                 ! 18.179.189.78/4500 が READY
Kobe# ping 10.20.1.10 source Vlan10
ubuntu@ec2$ sudo swanctl --list-sas        ! ESTABLISHED / INSTALLED
```

## ハマりどころ

- **両側とも NAT の内側**: Cisco は自宅ルーターの、EC2 は AWS の 1:1 NAT の内側にいる。
  IKE の ID は「相手から見える IP」ではなく自分で名乗る値なので、Cisco は `192.168.0.100`、
  EC2 は Elastic IP を名乗るように両側で合わせている。NAT-T (UDP 4500) で ESP をくるむ。
- **接続を始めるのは Cisco 側だけ**: 自宅ルーターにポート転送が無いので、EC2 からは始められない。
  EC2 側は待ち受けだけ (`start_action` なし)。
- **自宅のグローバル IP が変わったら**: セキュリティグループが旧 IP しか通さないので VPN も SSH も止まる。
  `vm.ps1` が警告を出すので、`terraform.tfvars` の `home_cidr` を直して `terraform apply`。
- **PowerShell 5.1 → ssh のパイプ**: 先頭に UTF-8 BOM が付き、swanctl はエラーも出さずに
  接続を 0 件読み込む。`configure-vpn.ps1` は受け側で BOM を取り除いている。

## 片付け

```powershell
cd aws-vpn-lab\terraform; terraform destroy
```

Cisco 側も消すなら `no interface Tunnel20`、`no ip route 10.20.0.0 255.255.0.0 Tunnel20`、
AWSLAB-* の各設定を `no` で消して `write memory`。
