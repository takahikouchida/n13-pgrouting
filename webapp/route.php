<?php
declare(strict_types=1);

header('Content-Type: application/geo+json; charset=utf-8');

function fail(string $message, int $status = 400): never {
    http_response_code($status);
    echo json_encode(['error' => $message], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function inputFloat(string $name, float $default): float {
    $raw = $_GET[$name] ?? (string)$default;
    if (!is_numeric($raw)) {
        fail("{$name} が数値ではありません");
    }
    return (float)$raw;
}

$startLng = inputFloat('start_lng', 139.767125);
$startLat = inputFloat('start_lat', 35.681236);
$endLng   = inputFloat('end_lng',   139.700258);
$endLat   = inputFloat('end_lat',   35.690921);
$margin   = inputFloat('margin',    0.05);

if ($margin <= 0 || $margin > 2.0) {
    fail('margin は0より大きく2.0以下にしてください');
}

$connString = sprintf(
    'host=%s port=%s dbname=%s user=%s password=%s',
    getenv('PGHOST') ?: '127.0.0.1',
    getenv('PGPORT') ?: '5432',
    getenv('PGDATABASE') ?: 'regional_map',
    getenv('PGUSER') ?: 'postgres',
    getenv('PGPASSWORD') ?: 'postgres'
);

$db = @pg_connect($connString);
if ($db === false) {
    fail('PostgreSQLへ接続できません', 500);
}

$sql = <<<'SQL'
WITH params AS (
    SELECT
        ST_SetSRID(ST_MakePoint($1, $2), 6668) AS start_point,
        ST_SetSRID(ST_MakePoint($3, $4), 6668) AS end_point,
        $5::double precision AS margin
),
search_area AS (
    SELECT
        ST_Expand(
            ST_Envelope(ST_Collect(start_point, end_point)),
            margin
        ) AS geom
    FROM params
),
nearest_vertices AS (
    SELECT
        (
            SELECT v.id
            FROM routing.road_vertices v, params p
            ORDER BY v.geom <-> p.start_point
            LIMIT 1
        ) AS start_vid,
        (
            SELECT v.id
            FROM routing.road_vertices v, params p
            ORDER BY v.geom <-> p.end_point
            LIMIT 1
        ) AS end_vid
),
routing_sql AS (
    SELECT format(
        $fmt$
        SELECT
            id,
            source,
            target,
            length_m AS cost,
            length_m AS reverse_cost
        FROM routing.road_edges
        WHERE geom && ST_MakeEnvelope(%s, %s, %s, %s, 6668)
        $fmt$,
        ST_XMin(geom),
        ST_YMin(geom),
        ST_XMax(geom),
        ST_YMax(geom)
    ) AS sql_text
    FROM search_area
),
route AS (
    SELECT d.*
    FROM nearest_vertices v
    CROSS JOIN routing_sql q
    CROSS JOIN LATERAL pgr_dijkstra(
        q.sql_text,
        v.start_vid,
        v.end_vid,
        directed := false
    ) AS d
),
route_edges AS (
    SELECT
        r.seq,
        r.edge,
        r.cost,
        r.agg_cost,
        ST_Transform(e.geom, 4326) AS geom
    FROM route r
    JOIN routing.road_edges e ON e.id = r.edge
    WHERE r.edge <> -1
),
features AS (
    SELECT jsonb_agg(
        jsonb_build_object(
            'type', 'Feature',
            'properties', jsonb_build_object(
                'seq', seq,
                'edge', edge,
                'cost', cost,
                'agg_cost', agg_cost
            ),
            'geometry', ST_AsGeoJSON(geom)::jsonb
        )
        ORDER BY seq
    ) AS feature_list
    FROM route_edges
),
summary AS (
    SELECT
        COALESCE(MAX(agg_cost), 0) AS distance_m,
        COUNT(*) AS edge_count
    FROM route_edges
)
SELECT jsonb_build_object(
    'type', 'FeatureCollection',
    'features', COALESCE(features.feature_list, '[]'::jsonb),
    'summary', jsonb_build_object(
        'distance_m', summary.distance_m,
        'distance_km', summary.distance_m / 1000.0,
        'edge_count', summary.edge_count
    )
)
FROM features, summary;
SQL;

$started = microtime(true);
$result = pg_query_params(
    $db,
    $sql,
    [$startLng, $startLat, $endLng, $endLat, $margin]
);

if ($result === false) {
    fail(pg_last_error($db) ?: 'SQL実行に失敗しました', 500);
}

$row = pg_fetch_row($result);
if (!$row || !$row[0]) {
    fail('経路結果を取得できませんでした', 500);
}

$data = json_decode($row[0], true, 512, JSON_THROW_ON_ERROR);
$data['summary']['elapsed_ms'] = round((microtime(true) - $started) * 1000, 1);

echo json_encode(
    $data,
    JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRESERVE_ZERO_FRACTION
);
