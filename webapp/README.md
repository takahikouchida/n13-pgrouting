# pgRouting リッチデモ

## 変更点

- 地理院地図
- 地理院写真
- OpenStreetMap
- 地図クリックで開始地点を指定
- 続けて地図クリックで終了地点を指定
- 経路距離、エッジ数、処理時間を表示
- スマートフォン向けレイアウト

## 配置

既存の `webapp/index.html` を、このパッケージ内の `index.html` に置き換えてください。

`route.php` は既存のものをそのまま利用できます。

## 再起動

```bash
docker compose restart web
```

ブラウザ:

```text
http://localhost:8080/
```
