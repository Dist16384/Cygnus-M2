無線キーボード　Cygnusのファームウェアです。
使い方などは別途添付のマニュアルをご参照ください。

## PMW3610 USBログの自動チェック

右側に `Cygnus_R_pmw3610_usb_logging.uf2`、左側に
`Cygnus_L_peripheral.uf2` を書き込んだ状態で、PowerShellから次を実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\check-pmw3610-log.ps1
```

USB CDCのCOMポートを自動検出し、20秒間ログを取得します。その間に
トラックボールを動かしてください。COMポートを指定する場合は次のように実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\check-pmw3610-log.ps1 -Port COM7 -DurationSeconds 30
```

cold bootを調べる場合は、右側の電源を切った状態で既知のCOM番号を指定して実行し、
待機メッセージが出てから右側を接続します。切断後の同じCOMポートへの再接続にも対応します。

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\check-pmw3610-log.ps1 -Port COM7 -PortWaitSeconds 60
```

ログは既定でドキュメント内の `Cygnus-M2-logs` フォルダーへ保存されます。
保存済みログだけを再解析することもできます。

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\check-pmw3610-log.ps1 -InputLog C:\path\to\pmw3610.log
```

判定結果は以下のとおりです。

- `PASS`: PMW3610の初期化と座標出力を確認
- `WARN`: 初期化には成功したが座標出力なし
- `FAIL`: 初期化、SPI、Product ID、自己診断、IRQのいずれかでエラー
- `INCOMPLETE`: 判定に必要なPMW3610ログなし

USBログ版は診断専用で、ZMK Studioとの同時利用には対応していません。
調査後は右側を `Cygnus_R_central.uf2` へ戻してください。
