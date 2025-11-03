USE [Com5600G13];
GO

-- ////////////////////////////////////////////////////////////////
-- Remover miembros de roles existentes antes de eliminarlos
IF DATABASE_PRINCIPAL_ID('administrativo_general') IS NOT NULL
BEGIN
    ALTER ROLE [administrativo_general] DROP MEMBER [usr_admin_general];
    DROP ROLE [administrativo_general];
END

IF DATABASE_PRINCIPAL_ID('administrativo_bancario') IS NOT NULL
BEGIN
    ALTER ROLE [administrativo_bancario] DROP MEMBER [usr_admin_bancario];
    DROP ROLE [administrativo_bancario];
END

IF DATABASE_PRINCIPAL_ID('administrativo_operativo') IS NOT NULL
BEGIN
    ALTER ROLE [administrativo_operativo] DROP MEMBER [usr_admin_operativo];
    DROP ROLE [administrativo_operativo];
END

IF DATABASE_PRINCIPAL_ID('sistemas') IS NOT NULL
BEGIN
    ALTER ROLE [sistemas] DROP MEMBER [usr_sistemas];
    DROP ROLE [sistemas];
END
GO

-- ////////////////////////////////////////////////////////////////
-- Crear Roles
CREATE ROLE [administrativo_general];
CREATE ROLE [administrativo_bancario];
CREATE ROLE [administrativo_operativo];
CREATE ROLE [sistemas];
GO

-- ////////////////////////////////////////////////////////////////
-- Permisos administrativo_general

-- Actualización de datos de UF (SÍ)
GRANT EXECUTE ON [importacion].[Sp_CargarConsorcioYUF_DesdeCsv] TO [administrativo_general];
GRANT EXECUTE ON [importacion].[Sp_CargarUFsDesdeTxt] TO [administrativo_general];
GRANT EXECUTE ON [importacion].[Sp_CargarUFInquilinosDesdeCsv] TO [administrativo_general];

-- Importación de información bancaria (NO)
DENY EXECUTE ON [importacion].[Sp_CargarPagosDesdeCsv] TO [administrativo_general];

-- Generación de reportes (SÍ)
GRANT SELECT ON SCHEMA::[app] TO [administrativo_general];
GRANT EXECUTE ON SCHEMA::[reportes] TO [administrativo_general];

-- DENEGAR acceso a objetos sensibles
DENY ALTER ON SCHEMA::[app] TO [administrativo_general];
DENY ALTER ON SCHEMA::[importacion] TO [administrativo_general];
GO

-- ////////////////////////////////////////////////////////////////
-- Permisos administrativo_bancario

-- Actualización de datos de UF (NO)
DENY EXECUTE ON [importacion].[Sp_CargarConsorcioYUF_DesdeCsv] TO [administrativo_bancario];
DENY EXECUTE ON [importacion].[Sp_CargarUFsDesdeTxt] TO [administrativo_bancario];
DENY EXECUTE ON [importacion].[Sp_CargarUFInquilinosDesdeCsv] TO [administrativo_bancario];

-- Importación de información bancaria (SÍ)
GRANT EXECUTE ON [importacion].[Sp_CargarPagosDesdeCsv] TO [administrativo_bancario];

-- Generación de reportes (SÍ)
GRANT SELECT ON SCHEMA::[app] TO [administrativo_bancario];
GRANT EXECUTE ON SCHEMA::[reportes] TO [administrativo_bancario];

-- DENEGAR acceso a modificación de datos
DENY INSERT, UPDATE, DELETE ON SCHEMA::[app] TO [administrativo_bancario];
DENY ALTER ON DATABASE::[Com5600G13] TO [administrativo_bancario];
GO

-- ////////////////////////////////////////////////////////////////
-- Permisos administrativo_operativo

-- Actualización de datos de UF (SÍ)
GRANT EXECUTE ON [importacion].[Sp_CargarConsorcioYUF_DesdeCsv] TO [administrativo_operativo];
GRANT EXECUTE ON [importacion].[Sp_CargarUFsDesdeTxt] TO [administrativo_operativo];
GRANT EXECUTE ON [importacion].[Sp_CargarUFInquilinosDesdeCsv] TO [administrativo_operativo];

-- Importación de información bancaria (NO)
DENY EXECUTE ON [importacion].[Sp_CargarPagosDesdeCsv] TO [administrativo_operativo];

-- Generación de reportes (SÍ)
GRANT SELECT ON SCHEMA::[app] TO [administrativo_operativo];
GRANT EXECUTE ON SCHEMA::[reportes] TO [administrativo_operativo];

-- DENEGAR acceso a objetos de sistema
DENY ALTER ON SCHEMA::[app] TO [administrativo_operativo];
DENY ALTER ON SCHEMA::[importacion] TO [administrativo_operativo];
GO

-- ////////////////////////////////////////////////////////////////
-- Permisos sistemas

-- Actualización de datos de UF (NO)
DENY EXECUTE ON [importacion].[Sp_CargarConsorcioYUF_DesdeCsv] TO [sistemas];
DENY EXECUTE ON [importacion].[Sp_CargarUFsDesdeTxt] TO [sistemas];
DENY EXECUTE ON [importacion].[Sp_CargarUFInquilinosDesdeCsv] TO [sistemas];

-- Importación de información bancaria (NO)
DENY EXECUTE ON [importacion].[Sp_CargarPagosDesdeCsv] TO [sistemas];

-- Generación de reportes (SÍ)
GRANT SELECT ON SCHEMA::[app] TO [sistemas];
GRANT SELECT ON SCHEMA::[importacion] TO [sistemas];
GRANT SELECT ON SCHEMA::[reportes] TO [sistemas];
GRANT EXECUTE ON SCHEMA::[reportes] TO [sistemas];

-- DENEGAR cualquier modificación
DENY INSERT, UPDATE, DELETE, ALTER ON SCHEMA::[app] TO [sistemas];
DENY INSERT, UPDATE, DELETE, ALTER ON SCHEMA::[importacion] TO [sistemas];
GO

-- ////////////////////////////////////////////////////////////////
-- Creación usuarios

-- Crear usuarios (sin login)
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'usr_admin_general')
    CREATE USER [usr_admin_general] WITHOUT LOGIN;
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'usr_admin_bancario')
    CREATE USER [usr_admin_bancario] WITHOUT LOGIN;
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'usr_admin_operativo')
    CREATE USER [usr_admin_operativo] WITHOUT LOGIN;
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'usr_sistemas')
    CREATE USER [usr_sistemas] WITHOUT LOGIN;

-- Asignar usuarios a roles
ALTER ROLE [administrativo_general] ADD MEMBER [usr_admin_general];
ALTER ROLE [administrativo_bancario] ADD MEMBER [usr_admin_bancario];
ALTER ROLE [administrativo_operativo] ADD MEMBER [usr_admin_operativo];
ALTER ROLE [sistemas] ADD MEMBER [usr_sistemas];
GO

-- Consulta para verificar los roles creados
/*
SELECT name AS Nombre_Rol 
FROM sys.database_principals 
WHERE type = 'R' 
ORDER BY name;
*/

------ EN CASO DE BORRAR LOS ROLES
/*
DROP ROLE administrativo_general;
DROP ROLE administrativo_bancario;
DROP ROLE administrativo_operativo;
DROP ROLE sistemas;
*/