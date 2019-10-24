SET client_min_messages TO ERROR;
DO
$do$
BEGIN
   IF NOT EXISTS (
      SELECT *
      FROM   pg_catalog.pg_user
      WHERE  usename = 'publicuser') THEN

      CREATE ROLE publicuser LOGIN;
   END IF;
END
$do$;
SET client_min_messages TO NOTICE;

CREATE TABLE pub(a int);
CREATE TABLE prv(a int);
GRANT SELECT ON TABLE pub TO publicuser;
REVOKE SELECT ON TABLE prv FROM publicuser;
SELECT cartodb.CDB_UserTables() ORDER BY 1;
SELECT 'all', cartodb.CDB_UserTables('all') ORDER BY 2;
SELECT 'public', cartodb.CDB_UserTables('public') ORDER BY 2;
SELECT 'private', cartodb.CDB_UserTables('private') ORDER BY 2;
SELECT '--unsupported--', cartodb.CDB_UserTables('--unsupported--') ORDER BY 2;
-- now tests with public user
\c contrib_regression publicuser
SELECT 'all_publicuser', cartodb.CDB_UserTables('all') ORDER BY 2;
SELECT 'public_publicuser', cartodb.CDB_UserTables('public') ORDER BY 2;
SELECT 'private_publicuser', cartodb.CDB_UserTables('private') ORDER BY 2;
\c contrib_regression postgres
DROP TABLE pub;
DROP TABLE prv;
