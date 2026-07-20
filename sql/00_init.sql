CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgrouting;
CREATE SCHEMA IF NOT EXISTS source;
CREATE SCHEMA IF NOT EXISTS work;
CREATE SCHEMA IF NOT EXISTS routing;
CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS source.n13_road_raw (
  raw_id bigserial PRIMARY KEY,
  source_file text NOT NULL,
  n13_001 text,
  n13_002 integer,
  n13_003 integer,
  n13_004 integer,
  n13_005 integer,
  n13_006 integer,
  n13_007 integer,
  n13_008 text,
  geom geometry(MultiLineString, 6668) NOT NULL
);
CREATE INDEX IF NOT EXISTS n13_road_raw_geom_gix ON source.n13_road_raw USING GIST (geom);
CREATE INDEX IF NOT EXISTS n13_road_raw_mesh_idx ON source.n13_road_raw (n13_008);
