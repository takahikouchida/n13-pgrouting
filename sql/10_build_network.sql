DROP TABLE IF EXISTS work.road_lines CASCADE;
CREATE TABLE work.road_lines AS
SELECT
  row_number() OVER ()::bigint AS id,
  r.raw_id, r.source_file, r.n13_001,
  r.n13_002 AS road_type_code,
  CASE r.n13_002 WHEN 1 THEN '通常部' WHEN 2 THEN '庭園路' WHEN 3 THEN '徒歩道' WHEN 4 THEN '石段' WHEN 5 THEN '不明' ELSE 'コード外' END AS road_type_name,
  r.n13_003 AS road_category_code,
  CASE r.n13_003 WHEN 1 THEN '国道' WHEN 2 THEN '都道府県道' WHEN 3 THEN '市区町村道等' WHEN 4 THEN '高速自動車国道等' WHEN 5 THEN 'その他' WHEN 6 THEN '不明' ELSE 'コード外' END AS road_category_name,
  r.n13_004 AS road_state_code,
  CASE r.n13_004 WHEN 1 THEN '通常部' WHEN 2 THEN '橋・高架' WHEN 3 THEN 'トンネル' WHEN 4 THEN '雪囲い' WHEN 5 THEN '建設中' WHEN 6 THEN 'その他' WHEN 7 THEN '不明' ELSE 'コード外' END AS road_state_name,
  r.n13_005,
  r.n13_006 AS road_width_code,
  CASE r.n13_006 WHEN 1 THEN '3m未満' WHEN 2 THEN '3m以上5.5m未満' WHEN 3 THEN '5.5m以上13m未満' WHEN 4 THEN '13m以上19.5m未満' WHEN 5 THEN '19.5m以上' WHEN 6 THEN '不明' ELSE 'コード外' END AS road_width_name,
  r.n13_007 AS toll_code,
  CASE r.n13_007 WHEN 1 THEN '無料' WHEN 2 THEN '有料' ELSE 'コード外' END AS toll_name,
  r.n13_008 AS mesh_code,
  d.geom::geometry(LineString, 6668) AS geom
FROM source.n13_road_raw r
CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(ST_MakeValid(ST_Force2D(r.geom)), 2)) AS d
WHERE r.geom IS NOT NULL AND NOT ST_IsEmpty(r.geom) AND NOT ST_IsEmpty(d.geom);
ALTER TABLE work.road_lines ADD PRIMARY KEY (id);
CREATE INDEX road_lines_geom_gix ON work.road_lines USING GIST (geom);
ANALYZE work.road_lines;

DROP TABLE IF EXISTS work.road_walkable CASCADE;
CREATE TABLE work.road_walkable AS
SELECT DISTINCT ON (
  encode(ST_AsEWKB(geom), 'hex'), road_type_code, road_category_code,
  road_state_code, road_width_code, toll_code
) *
FROM work.road_lines
WHERE ST_Length(geom::geography) > 0.05
  AND road_category_code IS DISTINCT FROM 4
  AND road_state_code IS DISTINCT FROM 5
  AND (
    lower(COALESCE(current_setting('app.exclude_toll_roads', true), 'false')) <> 'true'
    OR toll_code IS DISTINCT FROM 2
  )
ORDER BY encode(ST_AsEWKB(geom), 'hex'), road_type_code, road_category_code,
         road_state_code, road_width_code, toll_code, id;
ALTER TABLE work.road_walkable DROP COLUMN id;
ALTER TABLE work.road_walkable ADD COLUMN id bigserial PRIMARY KEY;
CREATE INDEX road_walkable_geom_gix ON work.road_walkable USING GIST (geom);
ANALYZE work.road_walkable;

DROP TABLE IF EXISTS work.road_endpoints CASCADE;
CREATE TABLE work.road_endpoints AS
SELECT id AS edge_id, 1::smallint AS endpoint_type,
       encode(ST_AsEWKB(ST_StartPoint(geom)), 'hex') AS endpoint_key,
       ST_StartPoint(geom)::geometry(Point, 6668) AS geom
FROM work.road_walkable
UNION ALL
SELECT id, 2::smallint,
       encode(ST_AsEWKB(ST_EndPoint(geom)), 'hex'),
       ST_EndPoint(geom)::geometry(Point, 6668)
FROM work.road_walkable;
CREATE INDEX road_endpoints_key_idx ON work.road_endpoints (endpoint_key);
CREATE INDEX road_endpoints_geom_gix ON work.road_endpoints USING GIST (geom);
ANALYZE work.road_endpoints;

DROP TABLE IF EXISTS routing.road_vertices CASCADE;
CREATE TABLE routing.road_vertices (
  id bigserial PRIMARY KEY,
  endpoint_key text NOT NULL UNIQUE,
  geom geometry(Point, 6668) NOT NULL
);
INSERT INTO routing.road_vertices (endpoint_key, geom)
SELECT endpoint_key, (array_agg(geom))[1]::geometry(Point, 6668)
FROM work.road_endpoints
GROUP BY endpoint_key
ORDER BY endpoint_key;
CREATE INDEX road_vertices_geom_gix ON routing.road_vertices USING GIST (geom);

DROP TABLE IF EXISTS routing.road_edges CASCADE;
CREATE TABLE routing.road_edges AS
SELECT
  w.id, w.raw_id, w.source_file, w.n13_001,
  w.road_type_code, w.road_type_name,
  w.road_category_code, w.road_category_name,
  w.road_state_code, w.road_state_name,
  w.n13_005, w.road_width_code, w.road_width_name,
  w.toll_code, w.toll_name, w.mesh_code,
  vs.id::bigint AS source,
  vt.id::bigint AS target,
  ST_Length(w.geom::geography)::double precision AS length_m,
  NULL::double precision AS base_cost,
  NULL::double precision AS cost,
  NULL::double precision AS reverse_cost,
  NULL::double precision AS start_elevation_m,
  NULL::double precision AS end_elevation_m,
  NULL::double precision AS ascent_m,
  NULL::double precision AS descent_m,
  NULL::double precision AS average_slope_pct,
  NULL::double precision AS max_slope_pct,
  w.geom::geometry(LineString, 6668) AS geom
FROM work.road_walkable w
JOIN routing.road_vertices vs ON vs.endpoint_key = encode(ST_AsEWKB(ST_StartPoint(w.geom)), 'hex')
JOIN routing.road_vertices vt ON vt.endpoint_key = encode(ST_AsEWKB(ST_EndPoint(w.geom)), 'hex');
ALTER TABLE routing.road_edges ADD PRIMARY KEY (id);
CREATE INDEX road_edges_geom_gix ON routing.road_edges USING GIST (geom);
CREATE INDEX road_edges_source_idx ON routing.road_edges (source);
CREATE INDEX road_edges_target_idx ON routing.road_edges (target);
CREATE INDEX road_edges_mesh_idx ON routing.road_edges (mesh_code);

UPDATE routing.road_edges
SET base_cost = length_m,
    cost = length_m
      * CASE WHEN road_type_code = 4 THEN 10.0 WHEN road_type_code = 2 THEN 1.10 ELSE 1.0 END
      * CASE WHEN road_width_code = 1 THEN 1.30 WHEN road_width_code = 2 THEN 1.15 WHEN road_width_code = 6 THEN 1.10 ELSE 1.0 END,
    reverse_cost = length_m
      * CASE WHEN road_type_code = 4 THEN 10.0 WHEN road_type_code = 2 THEN 1.10 ELSE 1.0 END
      * CASE WHEN road_width_code = 1 THEN 1.30 WHEN road_width_code = 2 THEN 1.15 WHEN road_width_code = 6 THEN 1.10 ELSE 1.0 END;
ANALYZE routing.road_edges;

DROP MATERIALIZED VIEW IF EXISTS audit.network_summary;
CREATE MATERIALIZED VIEW audit.network_summary AS
WITH degrees AS (
  SELECT node_id, COUNT(*) AS degree
  FROM (
    SELECT source AS node_id FROM routing.road_edges
    UNION ALL
    SELECT target AS node_id FROM routing.road_edges
  ) s
  GROUP BY node_id
), components AS (
  SELECT * FROM pgr_connectedComponents(
    'SELECT id, source, target, cost, reverse_cost FROM routing.road_edges'
  )
)
SELECT
  (SELECT COUNT(*) FROM source.n13_road_raw) AS raw_count,
  (SELECT COUNT(*) FROM work.road_lines) AS line_count,
  (SELECT COUNT(*) FROM routing.road_edges) AS edge_count,
  (SELECT COUNT(*) FROM routing.road_vertices) AS vertex_count,
  (SELECT COUNT(*) FROM degrees WHERE degree = 1) AS degree_one_count,
  (SELECT COUNT(DISTINCT component) FROM components) AS component_count,
  (SELECT MAX(c) FROM (SELECT component, COUNT(*) AS c FROM components GROUP BY component) x) AS largest_component_vertices,
  now() AS created_at;
