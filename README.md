# 国土数値情報 道路中心線 → PostGIS / pgRouting 自動構築

`data/input`へShapefile一式を置き、DockerでETLを実行すると、次を自動生成します。

- `source.n13_road_raw`：原本統合テーブル（EPSG:6668）
- `work.road_lines`：LineString化済み道路
- `work.road_walkable`：徒歩経路候補
- `routing.road_vertices`：道路端点ノード
- `routing.road_edges`：pgRouting用エッジ
- `audit.network_summary`：接続状況の集計

## 1. 元データ配置

```text
data/input/N13-24_5339/
├── N13-24_5339.shp
├── N13-24_5339.shx
├── N13-24_5339.dbf
├── N13-24_5339.prj
└── N13-24_5339.cpg  # 存在する場合
```

`data/input`配下は再帰検索されるため、複数メッシュをサブディレクトリへ分けて配置できます。

## 2. 起動・構築

```bash
cp .env.example .env
docker compose build
docker compose up -d db
docker compose run --rm etl
```

検証CSVは`data/output`へ出力されます。

## 3. DB確認

```bash
docker compose exec db psql -U postgres -d regional_map
```

```sql
SELECT * FROM audit.network_summary;
SELECT COUNT(*) FROM routing.road_edges;
SELECT COUNT(*) FROM routing.road_vertices;
```

## 4. 最短経路

```sql
SELECT *
FROM pgr_dijkstra(
  'SELECT id, source, target,
          length_m AS cost,
          length_m AS reverse_cost
   FROM routing.road_edges',
  100,
  200,
  directed := false
);
```

## 5. 任意座標の最寄りノード

```sql
WITH p AS (
  SELECT ST_Transform(
    ST_SetSRID(ST_Point(139.5065, 35.6998), 4326),
    6668
  ) AS geom
)
SELECT v.id,
       ST_Distance(v.geom::geography, p.geom::geography) AS distance_m
FROM routing.road_vertices v
CROSS JOIN p
ORDER BY v.geom <-> p.geom
LIMIT 1;
```

## 6. 再実行

初期値では毎回原本テーブルを空にして再構築します。

```env
RESET_SOURCE=true
```

追加投入する場合のみ`false`へ変更します。同じShapefileを重ねて入れないでください。

## 7. 自動処理の範囲と制約

この版は、道路の始点・終点座標が完全一致する箇所を同一ノードにします。

自動補正しないもの：

- 微小な端点ずれ
- 道路途中へ接続するT字路
- 交差しているが線が分割されていない交差点
- メッシュ境界の位置ずれ

全国一律でスナップすると、橋・高架・トンネル・並行道路を誤接続する危険があるためです。まず`audit.network_summary`の連結成分数を確認し、必要地域だけローカル投影座標系で補正してください。

## 8. 注意

Dockerイメージのタグは環境に応じて更新が必要な場合があります。`Dockerfile.db`はPostgreSQL 16 / PostGIS 3.4を基準にしています。
