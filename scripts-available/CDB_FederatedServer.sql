--------------------------------------------------------------------------------
-- Private functions
--------------------------------------------------------------------------------

--
-- This function is just a placement to store and use the pattern for
-- foreign object names
-- Servers:         cdb_fs_$(server_name)
-- View schema:     cdb_fs_$(server_name)
--  > This is where all views created when importing tables are placed
--  > One server has only one view schema
-- Import Schemas:  cdb_fs_schema_$(md5sum(server_name || remote_schema_name))
--  > This is where the foreign tables are placed
--  > One server has one import schema per remote schema plus auxiliar ones used
--      to access the remote catalog (pg_catalog, information_schema...)
-- Owner role:      cdb_fs_$(md5sum(current_database() || server_name)
--  > This is the role than owns all schemas and tables related to the server
--
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_Name_Pattern()
RETURNS TEXT
AS $$
    SELECT 'cdb_fs_'::text;
$$
LANGUAGE SQL IMMUTABLE ;

--
-- Produce a valid DB name for servers generated for the Federated Server
-- If check_existence is true, it'll throw if the server doesn't exists
-- This name is also used as the schema to store views
--
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_Generate_Server_Name(input_name TEXT, check_existence BOOL)
RETURNS NAME
AS $$
DECLARE
    internal_server_name text := format('%s%s', @extschema@.__CDB_FS_Name_Pattern(), input_name);
BEGIN
    IF input_name IS NULL OR char_length(input_name) = 0 THEN
        RAISE EXCEPTION 'Server name cannot be NULL';
    END IF;

    -- We discard anything that would be truncated
    IF (char_length(internal_server_name) >= 64) THEN
        RAISE EXCEPTION 'Server name (%) is too long to be used as identifier', input_name;
    END IF;

    IF (check_existence AND (NOT EXISTS (SELECT * FROM pg_foreign_server WHERE srvname = internal_server_name))) THEN
        RAISE EXCEPTION 'Server "%" does not exist', input_name;
    END IF;

    RETURN internal_server_name::name;
END
$$
LANGUAGE PLPGSQL IMMUTABLE ;

--
-- Given the internal name for a remote server, it returns the name used by the user
-- Reverses __CDB_FS_Generate_Server_Name
--
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_Extract_Server_Name(internal_server_name NAME)
RETURNS TEXT
AS $$
    SELECT right(internal_server_name,
            char_length(internal_server_name::TEXT) - char_length(@extschema@.__CDB_FS_Name_Pattern()))::TEXT;
$$
LANGUAGE SQL IMMUTABLE ;

--
-- Produce a valid name for a schema generated for the Federated Server
--
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_Generate_Schema_Name(internal_server_name NAME, schema_name TEXT)
RETURNS NAME
AS $$
DECLARE
    hash_value text := md5(internal_server_name::text || '__' || schema_name::text);
BEGIN
    IF schema_name IS NULL THEN
        RAISE EXCEPTION 'Schema name cannot be NULL';
    END IF;
    RETURN format('%s%s%s', @extschema@.__CDB_FS_Name_Pattern(), 'schema_', hash_value)::name;
END
$$
LANGUAGE PLPGSQL IMMUTABLE ;

--
-- Produce a valid name for a role generated for the Federated Server
-- This needs to include the current database in its hash to avoid collisions in clusters with more than one database
--
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_Generate_Server_Role_Name(internal_server_name NAME)
RETURNS NAME
AS $$
DECLARE
    hash_value text := md5(current_database()::text || '__' || internal_server_name::text);
    role_name text := format('%s%s%s', @extschema@.__CDB_FS_Name_Pattern(), 'role_', hash_value);
BEGIN
    RETURN role_name::name;
END
$$
LANGUAGE PLPGSQL STABLE ;

--
-- Creates (if not exist) a schema to place the objects for a remote schema
-- The schema is with the same AUTHORIZATION as the server
--
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_Create_Schema(internal_server_name NAME, schema_name TEXT)
RETURNS NAME
AS $$
DECLARE
    schema_name name := @extschema@.__CDB_FS_Generate_Schema_Name(internal_server_name, schema_name);
    role_name name := @extschema@.__CDB_FS_Generate_Server_Role_Name(internal_server_name);
BEGIN
    -- By changing the local role to the owner of the server we have an
    -- easy way to check for permissions and keep all objects under the same owner
    BEGIN
        EXECUTE 'SET LOCAL ROLE ' || quote_ident(role_name);
    EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE EXCEPTION 'Server "%" does not exist',
                        @extschema@.__CDB_FS_Extract_Server_Name(internal_server_name);
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Not enough permissions to access the server "%"',
                        @extschema@.__CDB_FS_Extract_Server_Name(internal_server_name);
    END;

    IF NOT EXISTS (SELECT oid FROM pg_namespace WHERE nspname = schema_name) THEN
        EXECUTE 'CREATE SCHEMA ' || quote_ident(schema_name) || ' AUTHORIZATION ' || quote_ident(role_name);
    END IF;
    RETURN schema_name;
END
$$
LANGUAGE PLPGSQL VOLATILE ;

--
-- Returns the type of a server by internal name
-- Currently all of them should be postgres_fdw
--
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_server_type(internal_server_name NAME)
RETURNS name
AS $$
    SELECT f.fdwname
        FROM pg_foreign_server s
        JOIN pg_foreign_data_wrapper f ON s.srvfdw = f.oid
        WHERE s.srvname = internal_server_name;
$$
LANGUAGE SQL VOLATILE ;

--
-- Take a config jsonb and transform it to an input suitable for _CDB_SetUp_User_PG_FDW_Server
-- 
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_credentials_to_user_mapping(input_config JSONB)
RETURNS jsonb
AS $$
DECLARE
    mapping jsonb := '{}'::jsonb;
BEGIN
    IF NOT (input_config ? 'credentials') THEN
        RAISE EXCEPTION 'Credentials are mandatory';
    END IF;

    -- For now, allow not passing username or password
    IF input_config->'credentials'->'username' IS NOT NULL THEN
        mapping := jsonb_build_object('user', input_config->'credentials'->'username');
    END IF;
    IF input_config->'credentials'->'password' IS NOT NULL THEN
        mapping := mapping || jsonb_build_object('password', input_config->'credentials'->'password');
    END IF;

    RETURN (input_config - 'credentials')::jsonb || jsonb_build_object('user_mapping', mapping);
END
$$
LANGUAGE PLPGSQL IMMUTABLE ;

-- Take a config jsonb as input and return it augmented with default
-- options
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_add_default_options(input_config jsonb)
RETURNS jsonb
AS $$
DECLARE
    default_options jsonb := '{
        "extensions": "postgis",
        "updatable": "false",
        "use_remote_estimate": "true",
        "fetch_size": "1000"
    }';
    server_config jsonb;
BEGIN
    IF NOT (input_config ? 'server') THEN
        RAISE EXCEPTION 'Server information is mandatory';
    END IF;
    server_config := default_options || to_jsonb(input_config->'server');
    RETURN jsonb_set(input_config, '{server}'::text[], server_config);
END
$$
LANGUAGE PLPGSQL IMMUTABLE ;

-- Given an server name, returns the username used in the configuration if the caller has rights to access it
CREATE OR REPLACE FUNCTION @extschema@.__CDB_FS_get_usermapping_username(internal_server_name NAME)
RETURNS text
AS $$
DECLARE
    role_name name := @extschema@.__CDB_FS_Generate_Server_Role_Name(internal_server_name);
    username text;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE ' || quote_ident(role_name);
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;

    SELECT (SELECT option_value FROM pg_options_to_table(u.umoptions) WHERE option_name LIKE 'user') as name INTO username
        FROM pg_foreign_server s
        LEFT JOIN pg_user_mappings u
        ON u.srvid = s.oid
        WHERE s.srvname = internal_server_name
        ORDER BY 1;

    RESET ROLE;

    RETURN username;
END
$$
LANGUAGE PLPGSQL VOLATILE ;


--------------------------------------------------------------------------------
-- Public functions
--------------------------------------------------------------------------------


--
-- Registers a new PG server
--
-- Example config: '{
--     "server": {
--         "dbname": "fdw_target",
--         "host": "localhost",
--         "port": 5432,
--         "extensions": "postgis",
--         "updatable": "false",
--         "use_remote_estimate": "true",
--         "fetch_size": "1000"
--     },
--     "credentials": {
--         "username": "fdw_user",
--         "password": "foobarino"
--     }
-- }'
--
-- The configuration from __CDB_FS_add_default_options will be appended
--
CREATE OR REPLACE FUNCTION @extschema@.CDB_Federated_Server_Register_PG(server TEXT, config JSONB)
RETURNS void
AS $$
DECLARE
    server_internal name := @extschema@.__CDB_FS_Generate_Server_Name(input_name => server, check_existence => false);
    final_config json := @extschema@.__CDB_FS_credentials_to_user_mapping(@extschema@.__CDB_FS_add_default_options(config));
    role_name name := @extschema@.__CDB_FS_Generate_Server_Role_Name(server_internal);
    row record;
    option record;
BEGIN
    IF NOT EXISTS (SELECT * FROM pg_extension WHERE extname = 'postgres_fdw') THEN
        RAISE EXCEPTION 'postgres_fdw extension is not installed'
            USING HINT = 'Please install it with `CREATE EXTENSION postgres_fdw`';
    END IF;

    -- We only create server and roles if the server didn't exist before
    IF NOT EXISTS (SELECT * FROM pg_foreign_server WHERE srvname = server_internal) THEN
        BEGIN
            EXECUTE FORMAT('CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw', server_internal);
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
                EXECUTE FORMAT('CREATE ROLE %I NOLOGIN', role_name);
            END IF;
            EXECUTE FORMAT('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', current_database(), role_name);

            -- These grants over `@extschema@` and `@postgisschema@` are necessary for the cases
            -- where the schemas aren't accessible to PUBLIC, which is what happens in a CARTO database
            EXECUTE FORMAT('GRANT USAGE ON SCHEMA %I TO %I', '@extschema@', role_name);
            EXECUTE FORMAT('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', '@extschema@', role_name);
            EXECUTE FORMAT('GRANT USAGE ON SCHEMA %I TO %I', '@postgisschema@', role_name);
            EXECUTE FORMAT('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', '@postgisschema@', role_name);
            EXECUTE FORMAT('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', '@postgisschema@', role_name);

            EXECUTE FORMAT('GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO %I', role_name);
            EXECUTE FORMAT('GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO %I', role_name);
            EXECUTE FORMAT('GRANT USAGE ON FOREIGN SERVER %I TO %I', server_internal, role_name);
            EXECUTE FORMAT('ALTER SERVER %I OWNER TO %I', server_internal, role_name);
            EXECUTE FORMAT ('CREATE USER MAPPING FOR %I SERVER %I', role_name, server_internal);
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'Could not create server %: %', server, SQLERRM
                USING HINT = 'Please clean the left over objects';
        END;
    END IF;

    -- Add new options
    FOR row IN SELECT p.key, p.value from lateral json_each_text(final_config->'server') p
    LOOP
        IF NOT EXISTS (
            WITH a AS (
                SELECT split_part(unnest(srvoptions), '=', 1) AS options FROM pg_foreign_server WHERE srvname=server_internal
            ) SELECT * from a where options = row.key)
        THEN
            EXECUTE FORMAT('ALTER SERVER %I OPTIONS (ADD %I %L)', server_internal, row.key, row.value);
        ELSE
            EXECUTE FORMAT('ALTER SERVER %I OPTIONS (SET %I %L)', server_internal, row.key, row.value);
        END IF;
    END LOOP;

    -- Update user mapping settings
    FOR option IN SELECT o.key, o.value from lateral json_each_text(final_config->'user_mapping') o
    LOOP
        IF NOT EXISTS (
            WITH a AS (
                SELECT split_part(unnest(umoptions), '=', 1) as options from pg_user_mappings WHERE srvname = server_internal AND usename = role_name
            ) SELECT * from a where options = option.key)
        THEN
            EXECUTE FORMAT('ALTER USER MAPPING FOR %I SERVER %I OPTIONS (ADD %I %L)', role_name, server_internal, option.key, option.value);
        ELSE
            EXECUTE FORMAT('ALTER USER MAPPING FOR %I SERVER %I OPTIONS (SET %I %L)', role_name, server_internal, option.key, option.value);
        END IF;
    END LOOP;
END
$$
LANGUAGE PLPGSQL VOLATILE ;

--
-- Drops a registered server and all the objects associated with it
-- 
CREATE OR REPLACE FUNCTION @extschema@.CDB_Federated_Server_Unregister(server TEXT)
RETURNS void
AS $$
DECLARE
    server_internal name := @extschema@.__CDB_FS_Generate_Server_Name(input_name => server, check_existence => true);
    role_name name := @extschema@.__CDB_FS_Generate_Server_Role_Name(server_internal);
BEGIN
    SET client_min_messages = ERROR;
    BEGIN
        EXECUTE FORMAT ('DROP USER MAPPING FOR %I SERVER %I', role_name, server_internal);
        EXECUTE FORMAT ('DROP OWNED BY %I', role_name);
        EXECUTE FORMAT ('DROP ROLE %I', role_name);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Not enough permissions to drop the server "%"', server;
    END;
END
$$
LANGUAGE PLPGSQL VOLATILE ;

--
-- List registered servers
--
CREATE OR REPLACE FUNCTION @extschema@.CDB_Federated_Server_List_Servers(server TEXT DEFAULT '%')
RETURNS TABLE (
    name        text,
    driver      text,
    host        text,
    port        text,
    dbname      text,
    readmode    text,
    username    text
)
AS $$
DECLARE
    server_name text := concat(@extschema@.__CDB_FS_Name_Pattern(), server);
BEGIN
    RETURN QUERY SELECT 
        -- Name as shown to the user
        @extschema@.__CDB_FS_Extract_Server_Name(s.srvname) AS "Name",

        -- Which driver are we using (postgres_fdw, odbc_fdw...)
        @extschema@.__CDB_FS_server_type(s.srvname)::text AS "Driver",

        -- Read options from pg_foreign_server
        (SELECT option_value FROM pg_options_to_table(s.srvoptions) WHERE option_name LIKE 'host') AS "Host",
        (SELECT option_value FROM pg_options_to_table(s.srvoptions) WHERE option_name LIKE 'port') AS "Port",
        (SELECT option_value FROM pg_options_to_table(s.srvoptions) WHERE option_name LIKE 'dbname') AS "DBName",
        CASE WHEN (SELECT NOT option_value::boolean FROM pg_options_to_table(s.srvoptions) WHERE option_name LIKE 'updatable') THEN 'read-only' ELSE 'read-write' END AS "ReadMode",

        @extschema@.__CDB_FS_get_usermapping_username(s.srvname)::text AS "Username"
    FROM pg_foreign_server s
    LEFT JOIN pg_user_mappings u
    ON u.srvid = s.oid
    WHERE s.srvname ILIKE server_name
    ORDER BY 1;
END
$$
LANGUAGE PLPGSQL VOLATILE ;


--
-- Grant access to a server
-- In the future we might consider adding the server's view schema to the role search_path
-- to make it easier to access the created views
--
CREATE OR REPLACE FUNCTION @extschema@.CDB_Federated_Server_Grant_Access(server TEXT, db_role NAME)
RETURNS void
AS $$
DECLARE
    server_internal name := @extschema@.__CDB_FS_Generate_Server_Name(input_name => server, check_existence => true);
    server_role_name name := @extschema@.__CDB_FS_Generate_Server_Role_Name(server_internal);
BEGIN
    IF (db_role IS NULL) THEN
        RAISE EXCEPTION 'User role "%" cannot be NULL', username;
    END IF;
    BEGIN
        EXECUTE format('GRANT %I TO %I', server_role_name, db_role);
    EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE EXCEPTION 'You do not have rights to grant access on "%"', server;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Could not grant access on "%" to "%": %', server, db_role, SQLERRM;
    END;
END
$$
LANGUAGE PLPGSQL VOLATILE ;

--
-- Revoke access to a server
--
CREATE OR REPLACE FUNCTION @extschema@.CDB_Federated_Server_Revoke_Access(server TEXT, db_role NAME)
RETURNS void
AS $$
DECLARE
    server_internal name := @extschema@.__CDB_FS_Generate_Server_Name(input_name => server, check_existence => true);
    server_role_name name := @extschema@.__CDB_FS_Generate_Server_Role_Name(server_internal);
BEGIN
    IF (db_role IS NULL) THEN
        RAISE EXCEPTION 'User role "%" cannot be NULL', username;
    END IF;
    BEGIN
        EXECUTE format('REVOKE %I FROM %I', server_role_name, db_role);
    EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE EXCEPTION 'You do not have rights to revoke access on "%"', server;
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Could not revoke access on "%" to "%": %', server, db_role, SQLERRM;
    END;
END
$$
LANGUAGE PLPGSQL VOLATILE ;
