-- {
-- Return pixel resolution at the given zoom level
-- }{
CREATE OR REPLACE FUNCTION @extschema@.CDB_XYZ_Resolution(z INTEGER)
RETURNS FLOAT8
AS $$
  -- circumference divided by 256 is z0 resolution, then divide by 2^z
  SELECT 6378137.0*2.0*pi() / 256.0 / power(2.0, z);
$$ LANGUAGE SQL IMMUTABLE  STRICT;
-- }

-- {
-- Returns a polygon representing the bounding box of a given XYZ tile
--
-- SRID of the returned polygon is forceably 3857
--
-- }{
CREATE OR REPLACE FUNCTION @extschema@.CDB_XYZ_Extent(x INTEGER, y INTEGER, z INTEGER)
RETURNS GEOMETRY
AS $$
DECLARE
  origin_shift FLOAT8;
  initial_resolution FLOAT8;
  tile_geo_size FLOAT8;
  pixres FLOAT8;
  xmin FLOAT8;
  ymin FLOAT8;
  xmax FLOAT8;
  ymax FLOAT8;
  earth_circumference FLOAT8;
  tile_size INTEGER;
BEGIN

  -- Size of each tile in pixels (1:1 aspect ratio)
  tile_size := 256;

  initial_resolution := @extschema@.CDB_XYZ_Resolution(0);
  --RAISE DEBUG 'Initial resolution: %', initial_resolution;

  origin_shift := (initial_resolution * tile_size) / 2.0;
  -- RAISE DEBUG 'Origin shift  (after): %', origin_shift;

  pixres := initial_resolution / (power(2,z));
  --RAISE DEBUG 'Pixel resolution: %', pixres;

  tile_geo_size = tile_size * pixres;
  --RAISE DEBUG 'Tile_geo_size: %', tile_geo_size;

  xmin := -origin_shift + x*tile_geo_size;
  xmax := -origin_shift + (x+1)*tile_geo_size;
  --RAISE DEBUG 'xmin: %', xmin;
  --RAISE DEBUG 'xmax: %', xmax;

  ymin := origin_shift - y*tile_geo_size;
  ymax := origin_shift - (y+1)*tile_geo_size;
  --RAISE DEBUG 'ymin: %', ymin;
  --RAISE DEBUG 'ymax: %', ymax;
  
  RETURN @postgisschema@.ST_MakeEnvelope(xmin, ymin, xmax, ymax, 3857);
END
$$ LANGUAGE 'plpgsql' IMMUTABLE STRICT ;
-- }
