#!/usr/bin/env python3
import csv, hashlib, os, re, subprocess, sys, time
from pathlib import Path
import psycopg2

PGHOST=os.getenv('PGHOST','db'); PGPORT=os.getenv('PGPORT','5432')
PGDATABASE=os.getenv('PGDATABASE','regional_map'); PGUSER=os.getenv('PGUSER','postgres')
PGPASSWORD=os.getenv('PGPASSWORD','postgres')
INPUT_DIR=Path(os.getenv('INPUT_DIR','/data/input')); OUTPUT_DIR=Path(os.getenv('OUTPUT_DIR','/data/output'))
RESET_SOURCE=os.getenv('RESET_SOURCE','true').lower()=='true'
EXCLUDE_TOLL=os.getenv('EXCLUDE_TOLL_ROADS','false').lower()=='true'
DSN=f'host={PGHOST} port={PGPORT} dbname={PGDATABASE} user={PGUSER} password={PGPASSWORD}'

def run(cmd, env=None):
    print('+',' '.join(map(str,cmd)),flush=True); subprocess.run(cmd,check=True,env=env)

def sql(q,p=None,fetch=False):
    with psycopg2.connect(DSN) as c:
        with c.cursor() as cur:
            cur.execute(q,p)
            return cur.fetchall() if fetch else None

def wait_db():
    for _ in range(60):
        try: sql('SELECT 1'); return
        except Exception as e: print('DB待機中:',e,flush=True); time.sleep(2)
    raise RuntimeError('PostgreSQLへ接続できません')

def psql_file(path, settings=None):
    env=os.environ.copy(); env['PGPASSWORD']=PGPASSWORD
    cmd=['psql','-v','ON_ERROR_STOP=1','-h',PGHOST,'-p',PGPORT,'-U',PGUSER,'-d',PGDATABASE]
    if settings:
        for k,v in settings.items(): cmd += ['-c',f"SET {k} = '{v}';"]
    cmd += ['-f',str(path)]; run(cmd,env)

def tmp_name(path):
    return 'tmp_'+re.sub(r'[^a-zA-Z0-9_]+','_',path.stem).lower()[:24]+'_'+hashlib.sha1(str(path).encode()).hexdigest()[:8]

def import_shp(shp):
    t=tmp_name(shp)
    pg=f'PG:host={PGHOST} port={PGPORT} dbname={PGDATABASE} user={PGUSER} password={PGPASSWORD}'
    run(['ogr2ogr','-f','PostgreSQL',pg,str(shp),'-nln',f'work.{t}',
         '-lco','GEOMETRY_NAME=geom','-lco','LAUNDER=YES','-nlt','PROMOTE_TO_MULTI',
         '-a_srs','EPSG:6668','-gt','65536','--config','PG_USE_COPY','YES','-overwrite'])
    cols={r[0] for r in sql("SELECT column_name FROM information_schema.columns WHERE table_schema='work' AND table_name=%s",(t,),True)}
    need={f'n13_{i:03d}' for i in range(1,9)}
    miss=sorted(need-cols)
    if miss: raise RuntimeError(f'{shp.name}: 必須属性不足 {miss}')
    sql(f"""
      INSERT INTO source.n13_road_raw
      (source_file,n13_001,n13_002,n13_003,n13_004,n13_005,n13_006,n13_007,n13_008,geom)
      SELECT %s,n13_001::text,NULLIF(n13_002::text,'')::integer,NULLIF(n13_003::text,'')::integer,
             NULLIF(n13_004::text,'')::integer,NULLIF(n13_005::text,'')::integer,
             NULLIF(n13_006::text,'')::integer,NULLIF(n13_007::text,'')::integer,n13_008::text,
             ST_Multi(ST_CollectionExtract(ST_Force2D(geom),2))::geometry(MultiLineString,6668)
      FROM work.{t} WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
    """,(str(shp.relative_to(INPUT_DIR)),))
    sql(f'DROP TABLE work.{t} CASCADE')

def export_reports():
    OUTPUT_DIR.mkdir(parents=True,exist_ok=True)
    rows=sql('SELECT * FROM audit.network_summary',fetch=True)
    with open(OUTPUT_DIR/'network_summary.csv','w',newline='',encoding='utf-8-sig') as f:
        w=csv.writer(f); w.writerow(['raw_count','line_count','edge_count','vertex_count','degree_one_count','component_count','largest_component_vertices','created_at']); w.writerows(rows)
    rows=sql("""SELECT COUNT(*) FILTER (WHERE source IS NULL OR target IS NULL), COUNT(*) FILTER (WHERE source=target), COUNT(*) FILTER (WHERE length_m<=0), COUNT(*) FILTER (WHERE cost<0 OR reverse_cost<0) FROM routing.road_edges""",fetch=True)
    with open(OUTPUT_DIR/'validation.csv','w',newline='',encoding='utf-8-sig') as f:
        w=csv.writer(f); w.writerow(['null_node_count','self_loop_count','non_positive_length_count','negative_cost_count']); w.writerows(rows)

def main():
    wait_db(); psql_file('/sql/00_init.sql')
    if RESET_SOURCE: sql('TRUNCATE source.n13_road_raw RESTART IDENTITY CASCADE')
    shps=sorted(INPUT_DIR.rglob('*.shp'))
    if not shps: raise RuntimeError(f'{INPUT_DIR} 配下にShapefileがありません')
    for shp in shps: print('\n===',shp.name,'===',flush=True); import_shp(shp)
    psql_file('/sql/10_build_network.sql',{'app.exclude_toll_roads':'true' if EXCLUDE_TOLL else 'false'})
    export_reports(); print('\n完了: routing.road_edges / routing.road_vertices',flush=True)

if __name__=='__main__':
    try: main()
    except Exception as e: print('ERROR:',e,file=sys.stderr); sys.exit(1)
